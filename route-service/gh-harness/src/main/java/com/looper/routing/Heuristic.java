package com.looper.routing;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.graphhopper.GHRequest;
import com.graphhopper.GraphHopper;
import com.graphhopper.config.Profile;
import com.graphhopper.jackson.Jackson;
import com.graphhopper.routing.Dijkstra;
import com.graphhopper.routing.ev.Subnetwork;
import com.graphhopper.routing.lm.LMApproximator;
import com.graphhopper.routing.lm.LandmarkStorage;
import com.graphhopper.routing.querygraph.QueryGraph;
import com.graphhopper.routing.util.DefaultSnapFilter;
import com.graphhopper.routing.util.TraversalMode;
import com.graphhopper.routing.weighting.BeelineWeightApproximator;
import com.graphhopper.routing.weighting.Weighting;
import com.graphhopper.storage.index.Snap;
import com.graphhopper.util.CustomModel;
import com.graphhopper.util.PMap;
import com.graphhopper.util.shapes.GHPoint;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Random;

/**
 * Phase 2 §4: what the landmark heuristic is actually worth, in weight units.
 *
 * "Custom models hurt landmarks" is a slogan. This measures the thing the
 * slogan is about. For one pair of points under several weightings, it takes
 * the two bounds `LMApproximator.approximate` chooses between — the landmark
 * bound and the beeline bound — and compares each against the true remaining
 * weight to the target, computed exactly by a Dijkstra from every sampled
 * node. The ratio between the chosen bound and the truth is the only thing
 * that decides how much of the graph an A* has to settle, so it is the number
 * the whole question reduces to.
 *
 * Nothing here is a reimplementation. `LMApproximator` and
 * `BeelineWeightApproximator` are GraphHopper's own classes, constructed the
 * way `LMRoutingAlgorithmFactory` constructs them, and the truth they are
 * measured against is GraphHopper's own Dijkstra.
 *
 *   java -cp gh-harness.jar com.looper.routing.Heuristic \
 *       &lt;config.yml&gt; &lt;graph-dir&gt; &lt;cases.json&gt; &lt;out.json&gt; [samples]
 */
public final class Heuristic {

    /** GraphHopper's own default for this preparation: min(prepared/2, 12). */
    private static final int ACTIVE_LANDMARKS = 8;

    public static void main(String[] args) throws Exception {
        Path configYml = Path.of(args[0]);
        Path graphDir = Path.of(args[1]);
        Path cases = Path.of(args[2]);
        Path out = Path.of(args[3]);
        int samples = args.length > 4 ? Integer.parseInt(args[4]) : 60;

        ObjectMapper mapper = Jackson.newObjectMapper();
        try (LooperRoutingCore core = LooperRoutingCore.open(configYml, graphDir, "foot")) {
            GraphHopper hopper = core.raw();
            LandmarkStorage lms = hopper.getLandmarks().get("foot");
            if (lms == null) throw new IllegalStateException("no landmark storage for profile foot");

            ObjectNode results = mapper.createObjectNode();
            results.put("preparedLandmarks", lms.getLandmarkCount());
            results.put("activeLandmarks", ACTIVE_LANDMARKS);
            results.put("landmarkWeighting", lms.getWeighting().getName());
            // `LandmarkStorage.getFactor()` is package-private; the
            // approximator publishes the same number as its slack, which is
            // the resolution the stored integer weights are quantised at.
            results.put("landmarkWeightResolution",
                    LMApproximator.forLandmarks(hopper.getBaseGraph(), lms.getWeighting(), lms, ACTIVE_LANDMARKS).getSlack());
            results.put("samplesPerCase", samples);
            landmarkLocations(mapper, hopper, lms, results.putArray("landmarks"));

            ArrayNode rows = results.putArray("cases");
            for (JsonNode node : (ArrayNode) mapper.readTree(cases.toFile()))
                rows.add(measure(mapper, hopper, lms, node, samples));

            Files.writeString(out, mapper.writerWithDefaultPrettyPrinter().writeValueAsString(results), StandardCharsets.UTF_8);
            System.out.println("\nwrote " + out);
        }
    }

    /**
     * §8: where GraphHopper put the landmarks. Reported as coordinates so the
     * placement can be looked at rather than assumed — the question of whether
     * a set chosen by GraphHopper's own farthest-point search suits an island
     * shaped like this one is not answerable from the count alone.
     */
    static void landmarkLocations(ObjectMapper mapper, GraphHopper hopper, LandmarkStorage lms, ArrayNode into) {
        var nodeAccess = hopper.getBaseGraph().getNodeAccess();
        // Subnetwork 0 is the one the whole island routes in; a preparation on
        // a graph with several would have a landmark set per subnetwork.
        for (int subnetwork = 0; subnetwork < lms.getSubnetworksWithLandmarks(); subnetwork++) {
            int[] nodes = lms.getLandmarks(subnetwork);
            for (int node : nodes) {
                // A subnetwork smaller than the landmark count leaves unused
                // slots, and GraphHopper marks those -1 rather than shortening
                // the array.
                if (node < 0) continue;
                ObjectNode row = into.addObject();
                row.put("subnetwork", subnetwork);
                row.put("node", node);
                row.put("lat", nodeAccess.getLat(node));
                row.put("lon", nodeAccess.getLon(node));
            }
        }
    }

    static ObjectNode measure(ObjectMapper mapper, GraphHopper hopper, LandmarkStorage lms, JsonNode node, int samples) throws Exception {
        String name = node.get("name").asText();
        GHRequest request = mapper.treeToValue(node.get("body"), GHRequest.class);

        Profile profile = hopper.getProfile("foot");
        PMap hints = new PMap();
        CustomModel model = request.getCustomModel();
        if (model != null) hints.putObject(CustomModel.KEY, model);
        Weighting weighting = hopper.createWeighting(profile, hints);

        var subnetworkEnc = hopper.getEncodingManager().getBooleanEncodedValue(Subnetwork.key("foot"));
        var filter = new DefaultSnapFilter(hopper.createWeighting(profile, new PMap()), subnetworkEnc);
        List<Snap> snaps = new ArrayList<>();
        for (GHPoint point : request.getPoints())
            snaps.add(hopper.getLocationIndex().findClosest(point.lat, point.lon, filter));
        QueryGraph queryGraph = QueryGraph.create(hopper.getBaseGraph(), snaps);

        int source = snaps.get(0).getClosestNode();
        int target = snaps.get(snaps.size() - 1).getClosestNode();

        // Built exactly as LMRoutingAlgorithmFactory builds it, including the
        // epsilon the default astarbi path uses.
        LMApproximator landmark = LMApproximator.forLandmarks(queryGraph, weighting, lms, ACTIVE_LANDMARKS).setEpsilon(1);
        landmark.setTo(target);
        // The active landmarks are chosen on the first node the search asks
        // about, which in a real search is the source. Asking here in the same
        // order means the bounds below are the ones the search would have seen.
        landmark.approximate(source);

        BeelineWeightApproximator beeline = new BeelineWeightApproximator(queryGraph.getNodeAccess(), weighting);
        beeline.setTo(target);

        ObjectNode row = mapper.createObjectNode();
        row.put("name", name);
        row.put("minWeightPerDistance", weighting.calcMinWeightPerDistance());
        row.put("weighting", weighting.getName());

        // The nodes sampled are the ones on the true path plus a spread of
        // others nearby, because a bound that is tight on the path and loose
        // beside it is exactly the bound that makes A* settle the neighbours.
        List<Integer> sampled = sample(queryGraph, weighting, source, target, samples);
        row.put("sampledNodes", sampled.size());

        List<Double> lmRatios = new ArrayList<>(), beelineRatios = new ArrayList<>(), chosenRatios = new ArrayList<>();
        int lmWon = 0;
        ArrayNode detail = row.putArray("samples");
        for (int v : sampled) {
            double exact = exactRemainingWeight(queryGraph, weighting, v, target);
            if (!(exact > 0) || Double.isInfinite(exact)) continue;
            double beelineBound = beeline.approximate(v);
            double chosen = landmark.approximate(v);
            // `approximate` returns max(landmark, beeline); the landmark term
            // on its own is therefore only visible by subtraction, and where
            // the two are equal the landmark term is at most the beeline one.
            boolean landmarkDecided = chosen > beelineBound + 1e-9;
            if (landmarkDecided) lmWon++;
            lmRatios.add(landmarkDecided ? chosen / exact : Double.NaN);
            beelineRatios.add(beelineBound / exact);
            chosenRatios.add(chosen / exact);
            if (detail.size() < 12) {
                ObjectNode s = detail.addObject();
                s.put("node", v);
                s.put("exactRemainingWeight", round(exact));
                s.put("beelineBound", round(beelineBound));
                s.put("chosenBound", round(chosen));
                s.put("landmarkDecided", landmarkDecided);
                s.put("tightness", round(chosen / exact));
            }
        }
        row.put("landmarkDecidedFraction", round((double) lmWon / chosenRatios.size()));
        row.put("meanBeelineTightness", round(mean(beelineRatios)));
        row.put("meanChosenTightness", round(mean(chosenRatios)));
        row.put("medianChosenTightness", round(median(chosenRatios)));
        System.out.printf("%-26s minWeight/m %7.4f  chosen bound is %5.1f%% of truth  landmark decided %4.1f%% of nodes%n",
                name, weighting.calcMinWeightPerDistance(), 100 * mean(chosenRatios), 100 * (double) lmWon / chosenRatios.size());
        return row;
    }

    /** The true remaining weight from v to the target, under the request's own weighting. */
    static double exactRemainingWeight(QueryGraph graph, Weighting weighting, int from, int to) {
        com.graphhopper.routing.Path path = new Dijkstra(graph, weighting, TraversalMode.NODE_BASED).calcPath(from, to);
        return path.isFound() ? path.getWeight() : Double.POSITIVE_INFINITY;
    }

    /**
     * Nodes on the true path, plus a deterministic spread of others drawn from
     * the whole graph and kept if they are no further from the target than the
     * source is. That is roughly the region a bidirectional A* has to consider,
     * and sampling outside it would measure a bound nothing ever asks for.
     */
    static List<Integer> sample(QueryGraph graph, Weighting weighting, int source, int target, int wanted) {
        List<Integer> nodes = new ArrayList<>();
        com.graphhopper.routing.Path path = new Dijkstra(graph, weighting, TraversalMode.NODE_BASED).calcPath(source, target);
        if (path.isFound()) {
            var onPath = path.calcNodes();
            for (int i = 0; i < onPath.size(); i++) nodes.add(onPath.get(i));
        }

        var access = graph.getNodeAccess();
        var dist = com.graphhopper.util.DistanceCalcEarth.DIST_EARTH;
        double radius = dist.calcDist(access.getLat(source), access.getLon(source), access.getLat(target), access.getLon(target));
        Random random = new Random(20260829);
        int base = graph.getBaseGraph().getNodes();
        for (int tries = 0; tries < wanted * 200 && nodes.size() < wanted * 2; tries++) {
            int v = random.nextInt(base);
            if (dist.calcDist(access.getLat(v), access.getLon(v), access.getLat(target), access.getLon(target)) <= radius) nodes.add(v);
        }
        Collections.shuffle(nodes, new Random(20260829));
        return nodes.subList(0, Math.min(wanted, nodes.size()));
    }

    static double mean(List<Double> values) {
        double sum = 0; int n = 0;
        for (double v : values) if (!Double.isNaN(v)) { sum += v; n++; }
        return n == 0 ? Double.NaN : sum / n;
    }

    static double median(List<Double> values) {
        List<Double> kept = new ArrayList<>(values.stream().filter(v -> !Double.isNaN(v)).toList());
        if (kept.isEmpty()) return Double.NaN;
        Collections.sort(kept);
        return kept.get(kept.size() / 2);
    }

    static double round(double value) { return Math.round(value * 10000) / 10000.0; }
}
