package com.looper.routing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.graphhopper.jackson.Jackson;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Collections;

/** Export one reusable request-scoped network-distance field per fixture. */
public final class NetworkField {
    public static void main(String[] args) throws Exception {
        Path config = Path.of(args[0]), graph = Path.of(args[1]), input = Path.of(args[2]), output = Path.of(args[3]);
        ObjectMapper mapper = Jackson.newObjectMapper();
        ArrayNode fixtures = (ArrayNode) mapper.readTree(input.toFile());
        ArrayNode results = mapper.createArrayNode();
        try (LooperRoutingCore core = LooperRoutingCore.open(config, graph, "foot")) {
            for (var fixture : fixtures) {
                double target = fixture.get("targetMetres").asDouble();
                double limit = target * fixture.path("explorationShare").asDouble(0.35);
                core.explore(fixture.get("lat").asDouble(), fixture.get("lon").asDouble(), limit);
                var times = new ArrayList<Double>();
                var heaps = new ArrayList<Long>();
                LooperRoutingCore.NetworkField field = null;
                for (int repeat = 0; repeat < 7; repeat++) {
                    field = core.explore(fixture.get("lat").asDouble(), fixture.get("lon").asDouble(), limit);
                    times.add(field.wallMs()); heaps.add(field.heapDeltaBytes());
                }
                Collections.sort(times); Collections.sort(heaps);
                ObjectNode row = results.addObject();
                row.put("name", fixture.get("name").asText());
                row.put("targetMetres", target); row.put("limitMetres", limit);
                row.put("nodesVisited", field.nodesVisited()); row.put("edgesVisited", field.edgesVisited());
                row.put("wallMs", times.get(times.size() / 2)); row.put("heapDeltaBytes", heaps.get(heaps.size() / 2));
                row.put("snappedLat", field.snappedLat()); row.put("snappedLon", field.snappedLon());
                row.put("startNode", field.startNode());
                row.set("nodes", mapper.valueToTree(field.nodes()));
            }
        }
        mapper.writerWithDefaultPrettyPrinter().writeValue(output.toFile(), results);
        System.out.println("wrote " + output + " (" + results.size() + " fields)");
    }
}
