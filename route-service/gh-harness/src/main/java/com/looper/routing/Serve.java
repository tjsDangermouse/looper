package com.looper.routing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.graphhopper.GHRequest;
import com.graphhopper.GHResponse;
import com.graphhopper.jackson.Jackson;
import com.graphhopper.jackson.ResponsePathSerializer;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.Executors;

/**
 * The minimal routing core, reachable from the route service.
 *
 * The only reason this exists is that Looper is TypeScript and the core is
 * Java: the full-generation comparison cannot be run without a socket between
 * them. It is deliberately the JDK's own HTTP server and GraphHopper's own
 * response serializer, roughly a hundred lines, rather than the Dropwizard
 * stack the shipped image runs — which is the point. What it costs to answer a
 * leg here, versus what the container costs, is the price of that stack.
 *
 * Not a production server: no TLS, no rate limiting, no request log, one
 * profile, two endpoints. Looper's own service already owns all of that.
 */
public final class Serve {

    public static void main(String[] args) throws Exception {
        Path configYml = Path.of(args[0]);
        Path graphDir = Path.of(args[1]);
        int port = args.length > 2 ? Integer.parseInt(args[2]) : 8991;

        ObjectMapper mapper = Jackson.newObjectMapper();
        LooperRoutingCore core = LooperRoutingCore.open(configYml, graphDir, "foot");

        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        // One thread per core: the route service already limits its own
        // concurrency, and an unbounded pool would only hide queueing.
        server.setExecutor(Executors.newFixedThreadPool(Runtime.getRuntime().availableProcessors()));

        server.createContext("/route", exchange -> {
            if (!"POST".equals(exchange.getRequestMethod())) { send(exchange, 405, "{}"); return; }
            try (InputStream in = exchange.getRequestBody()) {
                GHRequest request = mapper.readValue(in, GHRequest.class);
                GHResponse response = core.routeJsonBody(request);
                if (response.hasErrors()) {
                    ObjectNode error = mapper.createObjectNode();
                    // The route service reads 400 as "no path", which is an
                    // ordinary outcome for it; anything else is a fault.
                    error.put("message", response.getErrors().get(0).getMessage());
                    send(exchange, 400, mapper.writeValueAsString(error));
                    return;
                }
                boolean instructions = request.getHints().getBool("instructions", true);
                boolean calcPoints = request.getHints().getBool("calc_points", true);
                boolean elevation = request.getHints().getBool("elevation", false);
                boolean pointsEncoded = request.getHints().getBool("points_encoded", true);
                double multiplier = request.getHints().getDouble("points_encoded_multiplier", 1e5);
                // GraphHopper's own serializer, so the bytes on the wire are
                // the bytes the container would have sent.
                ObjectNode json = ResponsePathSerializer.jsonObject(response,
                        new ResponsePathSerializer.Info(List.of("GraphHopper", "OpenStreetMap contributors"), 0, null),
                        instructions, calcPoints, elevation, pointsEncoded, multiplier);
                send(exchange, 200, mapper.writeValueAsString(json));
            } catch (Exception e) {
                ObjectNode error = mapper.createObjectNode();
                error.put("message", e.getClass().getSimpleName() + ": " + e.getMessage());
                send(exchange, 500, mapper.writeValueAsString(error));
            }
        });

        server.createContext("/info", exchange -> {
            ObjectNode info = mapper.createObjectNode();
            info.put("version", com.graphhopper.util.Constants.VERSION);
            info.putArray("profiles").addObject().put("name", "foot");
            var bbox = core.raw().getBaseGraph().getBounds();
            info.putArray("bbox").add(bbox.minLon).add(bbox.minLat).add(bbox.maxLon).add(bbox.maxLat);
            send(exchange, 200, mapper.writeValueAsString(info));
        });

        server.start();
        System.out.println("LooperRoutingCore listening on :" + port);
    }

    private static void send(HttpExchange exchange, int status, String body) throws java.io.IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("Content-Type", "application/json");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) { out.write(bytes); }
    }
}
