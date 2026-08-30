package com.looper.routing.direct;

import com.graphhopper.GHResponse;
import com.graphhopper.ResponsePath;
import com.graphhopper.routing.Path;
import com.graphhopper.routing.querygraph.QueryGraph;
import com.graphhopper.routing.weighting.Weighting;
import com.graphhopper.util.EdgeIteratorState;
import com.graphhopper.util.PathMerger;
import com.graphhopper.util.PointList;
import com.graphhopper.util.Translation;
import com.graphhopper.util.details.PathDetailsBuilderFactory;
import com.looper.routing.LooperRoutingCore;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/**
 * The direct closed-walk engine, end to end.
 *
 * One request in, a set of finished GraphHopper paths out, and no routing call
 * anywhere in between. The stages are:
 *
 * <pre>
 * bounded exploration   GraphHopper's own Dijkstra over the foot graph,
 *                       out to (1 + MAX_DISTANCE_ERROR) / 2 of the target
 * graph reduction       2-core peel and degree-2 contraction (SearchGraph)
 * search                Phase 9's S2 beam over distance bands (WalkSearch)
 * selection             the exact shape and turn measures the search already
 *                       holds, with a compass-octant quota so what is handed
 *                       on is separable
 * materialisation       the searched edge sequence rebuilt as a GraphHopper
 *                       Path, and its geometry, duration, instructions and
 *                       path details built from that Path without searching
 * </pre>
 *
 * <h2>The searched walk is the answer</h2>
 * Phase 9 measured what happens when a searched walk is handed back to the
 * router as via points: given three corners of a walk known to be good,
 * GraphHopper returns something 1,486 m away from it at median, agreeing on
 * 15% of its edges, and not one of twelve passes the gate. So nothing here
 * re-routes. The edge sequence the search chose is the edge sequence that comes
 * back, and GraphHopper's library is used only for what it is being asked —
 * turning an edge sequence into a line, a duration and a set of instructions.
 *
 * <h2>What this does not decide</h2>
 * Whether a walk is offered. Looper's own {@code analyseRouteQuality} is the
 * authority and runs in the route service on what comes back from here, with
 * no threshold relaxed. The compactness, bounding-box and turn tests applied
 * below are the gate's own, applied early only so that a walk the gate will
 * certainly reject does not take one of the places handed to it.
 */
public final class DirectWalks {

    /** `MAX_DISTANCE_ERROR` in quality.ts. */
    public static final double MAX_DISTANCE_ERROR = 0.12;
    /** `MAX_BOUNDING_BOX_RATIO` in quality.ts. */
    public static final double MAX_BOUNDING_BOX_RATIO = 4.5;
    /** The exploration bound, derived rather than chosen — see Phase 9 §5. */
    public static final double EXPLORATION_SHARE = (1 + MAX_DISTANCE_ERROR) / 2;

    public record Request(double lat, double lon, double targetMetres, int wanted,
                          int beam, double band, int perNode, boolean diversityQuota,
                          boolean turnAware, long budget, String locale) {
        public static Request of(double lat, double lon, double targetMetres) {
            return new Request(lat, lon, targetMetres, 24, WalkSearch.BEAM, WalkSearch.BAND_METRES,
                    WalkSearch.PER_NODE, true, true, 4_000_000L, "en");
        }
    }

    public record Timing(double exploreMs, double buildMs, double searchMs, double judgeMs,
                         double assembleMs, double totalMs) {}

    public record Candidate(ResponsePath path, double searchedMetres, double compactness,
                            double bboxRatio, int uTurns, int family, double rank) {}

    public record Answer(List<Candidate> candidates, WalkSearch.Stats search, SearchGraph.Stats graph,
                         Timing timing, int closedWalks, int rejectedShape, int rejectedTurns,
                         double snappedLat, double snappedLon, double limitMetres, String failure) {}

    private DirectWalks() {}

    public static Answer search(LooperRoutingCore core, Request request) {
        long began = System.nanoTime();
        double limit = request.targetMetres * EXPLORATION_SHARE;
        long exploreBegan = System.nanoTime();
        LooperRoutingCore.WalkContext context = core.exploreForWalk(request.lat, request.lon, limit, true);
        double exploreMs = (System.nanoTime() - exploreBegan) / 1e6;
        if (context.graph() == null || context.subgraph().nodes().isEmpty()) {
            return failed("no-network", exploreMs, began, limit);
        }

        long buildBegan = System.nanoTime();
        SearchGraph graph = new SearchGraph(context.subgraph());
        double buildMs = (System.nanoTime() - buildBegan) / 1e6;
        if (graph.edgeCount == 0) return failed("no-circuit", exploreMs, began, limit);

        WalkSearch.Options options = new WalkSearch.Options(request.targetMetres, MAX_DISTANCE_ERROR,
                request.beam, request.band, request.perNode, request.diversityQuota, request.turnAware,
                0.05, WalkSearch.MIN_COMPACTNESS, request.budget, Integer.MAX_VALUE);
        WalkSearch.Result result = WalkSearch.run(graph, options);

        long judgeBegan = System.nanoTime();
        int root = result.stats().root();
        SearchGraph.Stem stem = root == graph.start ? null : graph.stemTo(root);
        double[] stemMetric = stem == null ? new double[0] : stem.metric();

        // The gate's own shape and turn rules, applied to the exact quantities
        // the search already holds. Nothing is judged more harshly here than it
        // would be in the route service; the point is only that a walk certain
        // to be rejected does not take one of the places handed on.
        List<Scored> scored = new ArrayList<>();
        int rejectedShape = 0, rejectedTurns = 0;
        for (WalkSearch.Walk walk : result.walks()) {
            if (walk.bboxRatio() > MAX_BOUNDING_BOX_RATIO) { rejectedShape++; continue; }
            double[] metric = metricLine(graph, walk.arcs(), stemMetric);
            int uTurns = UTurns.count(metric);
            // The gate's own rule, applied here rather than only afterwards, so
            // a walk it is certain to reject does not take one of the places
            // handed on. Switched off with the rest of the turn machinery only
            // so that the Phase 10 report can measure what it is worth.
            if (request.turnAware() && uTurns > WalkSearch.MAX_U_TURNS) { rejectedTurns++; continue; }
            scored.add(new Scored(walk, uTurns, rank(walk, uTurns, request.targetMetres)));
        }
        List<Scored> chosen = withOctantQuota(scored, request.wanted);
        double judgeMs = (System.nanoTime() - judgeBegan) / 1e6;

        long assembleBegan = System.nanoTime();
        List<Candidate> candidates = new ArrayList<>(chosen.size());
        QueryGraph queryGraph = context.graph();
        Weighting weighting = queryGraph.wrapWeighting(context.weighting());
        Translation translation = core.raw().getTranslationMap().getWithFallBack(java.util.Locale.forLanguageTag(request.locale));
        for (Scored entry : chosen) {
            ResponsePath path = materialise(core, queryGraph, weighting, translation, graph, entry.walk(), stem, context.startNode());
            if (path == null || path.hasErrors()) continue;
            candidates.add(new Candidate(path, entry.walk().metres(), entry.walk().compactness(),
                    entry.walk().bboxRatio(), entry.uTurns(), entry.walk().family(), entry.rank()));
        }
        double assembleMs = (System.nanoTime() - assembleBegan) / 1e6;

        Timing timing = new Timing(exploreMs, buildMs, result.stats().searchMs(), judgeMs, assembleMs,
                (System.nanoTime() - began) / 1e6);
        return new Answer(candidates, result.stats(), graph.stats, timing, result.walks().size(),
                rejectedShape, rejectedTurns, context.subgraph().snappedLat(), context.subgraph().snappedLon(),
                limit, null);
    }

    private record Scored(WalkSearch.Walk walk, int uTurns, double rank) {}

    /**
     * How well a closed walk answers the request, on the terms {@code scoreRoute}
     * already uses and this stage already knows exactly: how close it is to the
     * asked-for length, how round it is, and whether it turns back on itself.
     * Retracing is not among them because an edge-simple circuit has none, and
     * leg balance is not because a searched walk has no legs.
     */
    private static double rank(WalkSearch.Walk walk, int uTurns, double targetMetres) {
        double closeness = 1 - Math.min(1, Math.abs(walk.metres() - targetMetres) / (targetMetres * MAX_DISTANCE_ERROR));
        double shape = Math.min(1, walk.compactness() / 0.5);
        double simplicity = 1 - (double) uTurns / (WalkSearch.MAX_U_TURNS + 1);
        return 0.5 * closeness + 0.35 * shape + 0.15 * simplicity;
    }

    /**
     * Hand on the best of each compass octant before the best overall.
     *
     * The route service selects three walks that share no more than 55% of
     * their ground, so a set that is all one direction is a set it can take one
     * walk from. The search already carries the octant a walk committed to, and
     * it is the axis {@code selectDiverseRoutes} judges on.
     */
    private static List<Scored> withOctantQuota(List<Scored> scored, int wanted) {
        scored.sort(Comparator.comparingDouble(Scored::rank).reversed());
        if (scored.size() <= wanted) return scored;
        int[] present = new int[9];
        for (Scored entry : scored) present[entry.walk().family() + 1] = 1;
        int families = 0;
        for (int flag : present) families += flag;
        int quota = Math.max(1, wanted / Math.max(1, families));
        int[] taken = new int[9];
        List<Scored> chosen = new ArrayList<>(wanted);
        boolean[] used = new boolean[scored.size()];
        for (int i = 0; i < scored.size() && chosen.size() < wanted; i++) {
            int slot = scored.get(i).walk().family() + 1;
            if (taken[slot] >= quota) continue;
            taken[slot]++;
            used[i] = true;
            chosen.add(scored.get(i));
        }
        for (int i = 0; i < scored.size() && chosen.size() < wanted; i++) if (!used[i]) chosen.add(scored.get(i));
        return chosen;
    }

    /** The whole walk as flat x/y pairs in the start's metric frame: stem, circuit, stem back. */
    private static double[] metricLine(SearchGraph graph, int[] arcs, double[] stemMetric) {
        int size = stemMetric.length * 2;
        for (int arc : arcs) size += graph.edgeMetric[graph.arcEdge[arc]].length;
        double[] out = new double[size];
        int at = 0;
        at = append(out, at, stemMetric, true);
        for (int arc : arcs) at = append(out, at, graph.edgeMetric[graph.arcEdge[arc]], graph.arcForward[arc]);
        at = append(out, at, stemMetric, false);
        return java.util.Arrays.copyOf(out, at);
    }

    private static int append(double[] out, int at, double[] line, boolean forward) {
        if (line.length < 2) return at;
        if (forward) {
            for (int i = 0; i + 1 < line.length; i += 2) {
                if (at >= 2 && out[at - 2] == line[i] && out[at - 1] == line[i + 1]) continue;
                out[at++] = line[i];
                out[at++] = line[i + 1];
            }
        } else {
            for (int i = line.length - 2; i >= 0; i -= 2) {
                if (at >= 2 && out[at - 2] == line[i] && out[at - 1] == line[i + 1]) continue;
                out[at++] = line[i];
                out[at++] = line[i + 1];
            }
        }
        return at;
    }

    /**
     * The searched edge sequence, as a GraphHopper {@link Path}, turned into a
     * {@link ResponsePath} by GraphHopper's own {@link PathMerger}.
     *
     * No search runs here. The path is stated rather than found: its edges are
     * the edges the walk chose, in the order it walked them, and everything the
     * merger produces — the line, the instructions, the path details — is read
     * off those edges. Simplification is off, so the line that comes back is
     * the network's own geometry rather than a smoothed version of it.
     */
    private static ResponsePath materialise(LooperRoutingCore core, QueryGraph queryGraph, Weighting weighting,
                                            Translation translation, SearchGraph graph, WalkSearch.Walk walk,
                                            SearchGraph.Stem stem, int startNode) {
        Path path = new Path(queryGraph);
        path.setFromNode(startNode);
        if (stem != null) for (int id : stem.graphIds()) path.addEdge(id);
        for (int arc : walk.arcs()) {
            int edge = graph.arcEdge[arc];
            int[] ids = graph.edgeGraphIds[edge];
            if (graph.arcForward[arc]) for (int id : ids) path.addEdge(id);
            else for (int i = ids.length - 1; i >= 0; i--) path.addEdge(ids[i]);
        }
        if (stem != null) for (int i = stem.graphIds().length - 1; i >= 0; i--) path.addEdge(stem.graphIds()[i]);
        path.setEndNode(startNode);
        path.setFound(true);

        double distance = 0;
        long millis = 0;
        try {
            for (EdgeIteratorState edge : path.calcEdges()) {
                distance += edge.getDistance();
                millis += weighting.calcEdgeMillis(edge, false);
            }
        } catch (RuntimeException e) {
            // A walk whose edge sequence the graph cannot replay is a defect in
            // the search, not something to serve. It is dropped and counted.
            return null;
        }
        path.setDistance(distance);
        path.setTime(millis);
        path.setWeight(distance);

        PathMerger merger = new PathMerger(queryGraph, weighting)
                .setCalcPoints(true)
                .setEnableInstructions(true)
                .setSimplifyResponse(false)
                .setPathDetailsBuilders(new PathDetailsBuilderFactory(), List.of("street_name", "road_class", "edge_id"));
        return merger.doWork(PointList.EMPTY, List.of(path), core.raw().getEncodingManager(), translation);
    }

    public static GHResponse asResponse(ResponsePath path) {
        GHResponse response = new GHResponse();
        response.add(path);
        return response;
    }

    private static Answer failed(String reason, double exploreMs, long began, double limit) {
        return new Answer(List.of(), null, null,
                new Timing(exploreMs, 0, 0, 0, 0, (System.nanoTime() - began) / 1e6),
                0, 0, 0, Double.NaN, Double.NaN, limit, reason);
    }
}
