package com.looper.routing;

import com.fasterxml.jackson.core.JsonGenerator;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.graphhopper.jackson.Jackson;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;

/**
 * Export one request-scoped bounded subgraph per fixture, for Phase 9.
 *
 * The bound is a share of the request's own target distance, given per fixture
 * as `explorationShare`, and nothing here is fixture-specific. Timing is the
 * median of repeated warm explorations, so the preprocessing a direct search
 * would have to pay for at request time is measured rather than assumed.
 */
public final class Subgraph {
    public static void main(String[] args) throws Exception {
        Path config = Path.of(args[0]), graph = Path.of(args[1]), input = Path.of(args[2]), output = Path.of(args[3]);
        boolean withGeometry = args.length < 5 || Boolean.parseBoolean(args[4]);
        ObjectMapper mapper = Jackson.newObjectMapper();
        ArrayNode fixtures = (ArrayNode) mapper.readTree(input.toFile());
        try (LooperRoutingCore core = LooperRoutingCore.open(config, graph, "foot");
             JsonGenerator json = mapper.getFactory().createGenerator(Files.newOutputStream(output))) {
            json.writeStartArray();
            for (var fixture : fixtures) {
                double target = fixture.get("targetMetres").asDouble();
                double lat = fixture.get("lat").asDouble(), lon = fixture.get("lon").asDouble();
                double limit = target * fixture.path("explorationShare").asDouble(0.56);
                core.exploreSubgraph(lat, lon, limit, false);
                var times = new ArrayList<Double>();
                var heaps = new ArrayList<Long>();
                for (int repeat = 0; repeat < 7; repeat++) {
                    var warm = core.exploreSubgraph(lat, lon, limit, false);
                    times.add(warm.wallMs()); heaps.add(warm.heapDeltaBytes());
                }
                Collections.sort(times); Collections.sort(heaps);
                LooperRoutingCore.Subgraph sub = core.exploreSubgraph(lat, lon, limit, withGeometry);
                json.writeStartObject();
                json.writeStringField("name", fixture.get("name").asText());
                json.writeNumberField("targetMetres", target);
                json.writeNumberField("limitMetres", limit);
                json.writeNumberField("explorationShare", limit / target);
                json.writeNumberField("wallMs", times.get(times.size() / 2));
                json.writeNumberField("heapDeltaBytes", heaps.get(heaps.size() / 2));
                json.writeNumberField("snappedLat", sub.snappedLat());
                json.writeNumberField("snappedLon", sub.snappedLon());
                json.writeNumberField("startNode", sub.startNode());
                json.writeNumberField("nodeCount", sub.nodes().size());
                json.writeNumberField("edgeCount", sub.edges().size());
                // Flat arrays: a 12,000-edge subgraph as objects is mostly key names.
                json.writeArrayFieldStart("nodes");
                for (var node : sub.nodes()) {
                    json.writeStartArray();
                    json.writeNumber(node.node()); json.writeNumber(round(node.lon())); json.writeNumber(round(node.lat()));
                    json.writeNumber(Math.round(node.networkMetres() * 10) / 10.0); json.writeNumber(node.degree());
                    json.writeEndArray();
                }
                json.writeEndArray();
                json.writeArrayFieldStart("edges");
                for (var edge : sub.edges()) {
                    json.writeStartArray();
                    json.writeNumber(edge.edge()); json.writeNumber(edge.origin());
                    json.writeNumber(edge.from()); json.writeNumber(edge.to());
                    json.writeNumber(Math.round(edge.metres() * 10) / 10.0);
                    json.writeNumber((edge.forward() ? 1 : 0) + (edge.backward() ? 2 : 0));
                    if (edge.geometry() != null) {
                        json.writeStartArray();
                        for (double value : edge.geometry()) json.writeNumber(value);
                        json.writeEndArray();
                    }
                    json.writeEndArray();
                }
                json.writeEndArray();
                json.writeEndObject();
                System.out.println(fixture.get("name").asText() + ": " + sub.nodes().size() + " nodes, "
                        + sub.edges().size() + " edges, limit " + Math.round(limit) + " m, "
                        + String.format("%.2f", times.get(times.size() / 2)) + " ms warm");
            }
            json.writeEndArray();
        }
        System.out.println("wrote " + output);
    }

    private static double round(double value) { return Math.round(value * 1e6) / 1e6; }
}
