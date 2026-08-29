package com.looper.routing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.graphhopper.GHRequest;
import com.graphhopper.GHResponse;
import com.graphhopper.ResponsePath;
import com.graphhopper.jackson.Jackson;
import com.graphhopper.util.PointList;
import com.graphhopper.util.details.PathDetail;
import com.graphhopper.util.shapes.GHPoint;

import java.io.BufferedWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * Gate 2: run Looper's own request bodies through GraphHopper's Java API.
 *
 * Input is a JSON array of `{name, body}` where `body` is verbatim what
 * route-service POSTs to /route. Output is a JSON array of measurements shaped
 * so the same comparison script can read it and the HTTP baseline side by side.
 *
 *   java -jar gh-harness.jar <config.yml> <graph-dir> <fixtures.json> <out.json> [repeats]
 */
public final class Harness {

    public static void main(String[] args) throws Exception {
        Path configYml = Path.of(args[0]);
        Path graphDir = Path.of(args[1]);
        Path fixtures = Path.of(args[2]);
        Path out = Path.of(args[3]);
        int repeats = args.length > 4 ? Integer.parseInt(args[4]) : 7;

        Runtime rt = Runtime.getRuntime();
        long loadBegan = System.nanoTime();
        long heapBefore = rt.totalMemory() - rt.freeMemory();

        ObjectMapper mapper = Jackson.newObjectMapper();
        try (LooperRoutingCore core = LooperRoutingCore.open(configYml, graphDir, "foot")) {
            double loadMs = (System.nanoTime() - loadBegan) / 1e6;
            System.gc();
            long heapAfter = rt.totalMemory() - rt.freeMemory();

            ArrayNode cases = (ArrayNode) mapper.readTree(fixtures.toFile());
            ArrayNode results = mapper.createArrayNode();

            for (var node : cases) {
                String name = node.get("name").asText();
                ObjectNode bodyNode = (ObjectNode) node.get("body");
                ObjectNode row = results.addObject();
                row.put("name", name);
                try {
                    // Deserialised by GraphHopper's own module: the same object
                    // the HTTP resource hands to the router, from the same bytes.
                    GHRequest template = mapper.treeToValue(bodyNode, GHRequest.class);
                    core.routeJsonBody(copyOf(mapper, bodyNode));           // warm

                    List<Double> times = new ArrayList<>();
                    GHResponse last = null;
                    for (int i = 0; i < repeats; i++) {
                        GHRequest request = copyOf(mapper, bodyNode);
                        long t0 = System.nanoTime();
                        last = core.routeJsonBody(request);
                        times.add((System.nanoTime() - t0) / 1e6);
                    }
                    if (last.hasErrors()) {
                        row.put("error", last.getErrors().get(0).toString());
                        continue;
                    }
                    Collections.sort(times);
                    row.put("ms", times.get(times.size() / 2));
                    row.put("visitedNodes", last.getHints().getLong("visited_nodes.sum", -1));
                    describe(row, core.best(last), mapper);
                    row.put("profile", template.getProfile());
                    // The facade's own snap() must agree with the snapping the
                    // router did inside this very request. If it does not, the
                    // narrow API is answering a different question from the
                    // engine behind it, which is the one bug this seam can hide.
                    var first = template.getPoints().get(0);
                    var direct = core.snap(first.lat, first.lon, template.getSnapPreventions());
                    var viaRouter = core.best(last).getWaypoints();
                    row.put("facadeSnapAgrees", direct.found
                            && Math.abs(direct.lat - viaRouter.getLat(0)) < 1e-9
                            && Math.abs(direct.lon - viaRouter.getLon(0)) < 1e-9);
                } catch (Exception e) {
                    row.put("error", e.getClass().getSimpleName() + ": " + e.getMessage());
                }
            }

            ObjectNode envelope = mapper.createObjectNode();
            envelope.put("source", "direct-java");
            envelope.put("graphhopperVersion", com.graphhopper.util.Constants.VERSION);
            envelope.put("loadMs", loadMs);
            envelope.put("heapAfterLoadBytes", heapAfter);
            envelope.put("heapBeforeLoadBytes", heapBefore);
            envelope.put("nodes", core.raw().getBaseGraph().getNodes());
            envelope.put("edges", core.raw().getBaseGraph().getEdges());
            envelope.set("results", results);

            try (BufferedWriter w = Files.newBufferedWriter(out, StandardCharsets.UTF_8)) {
                mapper.writerWithDefaultPrettyPrinter().writeValue(w, envelope);
            }
            System.out.println("wrote " + out + " (" + results.size() + " cases, load " + Math.round(loadMs) + " ms)");
        }
    }

    /** A GHRequest is mutated by the router, so each timed run gets a fresh one. */
    private static GHRequest copyOf(ObjectMapper mapper, ObjectNode bodyNode) throws Exception {
        return mapper.treeToValue(bodyNode, GHRequest.class);
    }

    /**
     * The fields the comparison actually turns on. Geometry is fingerprinted
     * rather than dumped: two routes either are the same line or they are not,
     * and a hash says so in one column.
     */
    private static void describe(ObjectNode row, ResponsePath path, ObjectMapper mapper) {
        row.put("distance", path.getDistance());
        row.put("weight", path.getRouteWeight());
        row.put("timeMs", path.getTime());
        PointList points = path.getPoints();
        row.put("pointCount", points.size());
        row.put("geometryHash", fingerprint(points));

        ArrayNode waypoints = row.putArray("snappedWaypoints");
        PointList wp = path.getWaypoints();
        for (int i = 0; i < wp.size(); i++) {
            ArrayNode p = waypoints.addArray();
            p.add(round6(wp.getLon(i)));
            p.add(round6(wp.getLat(i)));
        }

        Map<String, List<PathDetail>> details = path.getPathDetails();
        List<PathDetail> edgeIds = details.get("edge_id");
        if (edgeIds != null) {
            ArrayNode edges = row.putArray("edgeIds");
            for (PathDetail d : edgeIds) edges.add(((Number) d.getValue()).intValue());
        }
        List<PathDetail> roadClasses = details.get("road_class");
        if (roadClasses != null) {
            ArrayNode classes = row.putArray("roadClasses");
            for (PathDetail d : roadClasses) classes.add(String.valueOf(d.getValue()));
        }
        row.put("instructionCount", path.getInstructions().size());
    }

    /** Six decimals is GraphHopper's own JSON precision, so this compares like with like. */
    private static String fingerprint(PointList points) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < points.size(); i++) {
            sb.append(round6(points.getLon(i))).append(',').append(round6(points.getLat(i))).append(';');
        }
        return sha256(sb.toString());
    }

    private static double round6(double v) {
        return Math.round(v * 1e6) / 1e6;
    }

    private static String sha256(String s) {
        try {
            byte[] d = java.security.MessageDigest.getInstance("SHA-256").digest(s.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < 8; i++) sb.append(String.format("%02x", d[i]));
            return sb.toString();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
}
