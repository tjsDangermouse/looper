package com.looper.routing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.graphhopper.GHRequest;
import com.graphhopper.GHResponse;
import com.graphhopper.jackson.Jackson;
import com.graphhopper.jackson.ResponsePathSerializer;
import com.graphhopper.util.JsonFeature;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Executors;

/**
 * The minimal routing core, reachable from the route service.
 *
 * The only reason this exists is that Looper is TypeScript and the core is
 * Java: the full-generation comparison cannot be run without a socket between
 * them. It is deliberately the JDK's own HTTP server and GraphHopper's own
 * response serializer, rather than the Dropwizard stack the shipped image runs
 * — which is the point. What it costs to answer a leg here, versus what the
 * container costs, is the price of that stack.
 *
 * Not a production server: no TLS, no rate limiting, no request log, one
 * profile. Looper's own service already owns all of that.
 *
 * <h2>The model handle protocol</h2>
 * {@code /route} still takes exactly the body {@code src/graphhopper.ts} has
 * always sent. A body may additionally carry {@code looper_model}, which names
 * a corridor set the caller has already described rather than describing it
 * again:
 *
 * <pre>
 * POST /generation                    -> { "generation": "..." }
 * POST /route  { ..., "looper_model": {
 *          "generation": "...",
 *          "id": "&lt;caller's content hash of the model&gt;",
 *          "register": { "&lt;area handle&gt;": &lt;GeoJSON Feature&gt;, ... },   // only what is new
 *          "define":   { "areas": ["&lt;area handle&gt;", ...],              // only on first use
 *                        "multiply_by": "0.05",
 *                        "distance_influence": 2000 }
 *      } }
 * DELETE /generation/{id}
 * </pre>
 *
 * Registration rides on the route request rather than taking a round trip of
 * its own, because a round trip is the thing this phase is trying to spend
 * less of. Handles are the caller's own content hashes, so the caller never has
 * to wait to learn one, and a handle that names nothing is an error rather than
 * a silently different walk.
 */
public final class Serve {

    public static void main(String[] args) throws Exception {
        Path configYml = Path.of(args[0]);
        Path graphDir = Path.of(args[1]);
        int port = args.length > 2 ? Integer.parseInt(args[2]) : 8991;

        ObjectMapper mapper = Jackson.newObjectMapper();
        LooperRoutingCore core = LooperRoutingCore.open(configYml, graphDir, "foot");
        ModelRegistry registry = core.registry();

        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        // One thread per core: the route service already limits its own
        // concurrency, and an unbounded pool would only hide queueing.
        server.setExecutor(Executors.newFixedThreadPool(Runtime.getRuntime().availableProcessors()));

        server.createContext("/route", exchange -> {
            if (!"POST".equals(exchange.getRequestMethod())) { send(exchange, 405, "{}"); return; }
            long began = System.nanoTime();
            try (InputStream in = exchange.getRequestBody()) {
                Answer answer = answer(mapper, core, registry, mapper.readValue(in, GHRequest.class));
                // Microseconds, so a caller can subtract what happened inside
                // this process from the round trip it measured and be left with
                // the transport. `serialize` is what building the response
                // object cost — reading the request and writing the bytes to
                // the socket are outside it, and turn up in the caller's
                // transport figure, which is where they belong. Costs one
                // header; ignored by every caller that does not want it.
                long inProcess = micros(began, System.nanoTime());
                exchange.getResponseHeaders().add("X-Looper-Timing",
                        "dispatch=" + answer.dispatchMicros
                                + ",route=" + answer.routeMicros
                                + ",serialize=" + Math.max(0, inProcess - answer.dispatchMicros - answer.routeMicros));
                send(exchange, answer.status, mapper.writeValueAsString(answer.body));
            } catch (Exception e) {
                ObjectNode error = mapper.createObjectNode();
                error.put("message", e.getClass().getSimpleName() + ": " + e.getMessage());
                send(exchange, 500, mapper.writeValueAsString(error));
            }
        });

        // A prototype, not a production endpoint: several independent route
        // requests in one HTTP exchange, each still routed by GraphHopper on
        // its own exactly as it would have been alone. It exists to measure
        // what an HTTP exchange costs when it is not being paid per leg — see
        // bench/phase3a/batch.mts — and nothing in the route service uses it.
        server.createContext("/routeBatch", exchange -> {
            if (!"POST".equals(exchange.getRequestMethod())) { send(exchange, 405, "{}"); return; }
            try (InputStream in = exchange.getRequestBody()) {
                BatchRequest batch = mapper.readValue(in, BatchRequest.class);
                // In parallel, because what this is being compared against is
                // six concurrent HTTP calls using six threads. Routing a batch
                // on one thread would measure the loss of that concurrency
                // rather than the saving on the envelope.
                List<Answer> answers = batch.requests.parallelStream()
                        .map(request -> {
                            try {
                                return answer(mapper, core, registry, request);
                            } catch (Exception e) {
                                ObjectNode error = mapper.createObjectNode();
                                error.put("message", e.getClass().getSimpleName() + ": " + e.getMessage());
                                return new Answer(500, error, 0, 0);
                            }
                        }).toList();
                ObjectNode json = mapper.createObjectNode();
                var array = json.putArray("responses");
                for (Answer answer : answers) array.addObject().put("status", answer.status).set("body", answer.body);
                send(exchange, 200, mapper.writeValueAsString(json));
            } catch (Exception e) {
                ObjectNode error = mapper.createObjectNode();
                error.put("message", e.getClass().getSimpleName() + ": " + e.getMessage());
                send(exchange, 500, mapper.writeValueAsString(error));
            }
        });

        server.createContext("/generation", exchange -> {
            try {
                String path = exchange.getRequestURI().getPath();
                String id = path.length() > "/generation/".length() ? path.substring("/generation/".length()) : "";
                if ("POST".equals(exchange.getRequestMethod()) && id.isEmpty()) {
                    ModelRegistry.Generation generation = registry.begin();
                    ObjectNode json = mapper.createObjectNode();
                    json.put("generation", generation.id);
                    send(exchange, 200, mapper.writeValueAsString(json));
                    return;
                }
                if ("DELETE".equals(exchange.getRequestMethod()) && !id.isEmpty()) {
                    ModelRegistry.Generation generation = registry.end(id);
                    ObjectNode json = mapper.createObjectNode();
                    json.put("released", generation != null);
                    if (generation != null) json.set("stats", mapper.valueToTree(generation.stats()));
                    json.put("live", registry.size());
                    send(exchange, 200, mapper.writeValueAsString(json));
                    return;
                }
                send(exchange, 405, "{}");
            } catch (Exception e) {
                send(exchange, 500, "{\"message\":\"" + e.getClass().getSimpleName() + "\"}");
            }
        });

        server.createContext("/info", exchange -> {
            ObjectNode info = mapper.createObjectNode();
            info.put("version", com.graphhopper.util.Constants.VERSION);
            // Advertised so a caller can tell a facade that understands handles
            // from the shipped container, which does not.
            info.putArray("capabilities").add("looper_model_registry");
            info.putArray("profiles").addObject().put("name", "foot");
            var bbox = core.raw().getBaseGraph().getBounds();
            info.putArray("bbox").add(bbox.minLon).add(bbox.minLat).add(bbox.maxLon).add(bbox.maxLat);
            send(exchange, 200, mapper.writeValueAsString(info));
        });

        server.start();
        System.out.println("LooperRoutingCore listening on :" + port);
    }

    /** A batch of ordinary route bodies. Deliberately the only field. */
    public static final class BatchRequest {
        public List<GHRequest> requests = List.of();
    }

    /** One answer, and what it spent, before anything is written to a socket. */
    private record Answer(int status, ObjectNode body, long dispatchMicros, long routeMicros) {}

    /**
     * Answer one request, whether it arrived alone or in a batch.
     *
     * Everything a route body can say it says here, so a batched leg and a
     * lone one go through the same code and cannot drift apart.
     */
    private static Answer answer(ObjectMapper mapper, LooperRoutingCore core, ModelRegistry registry, GHRequest request) {
        long began = System.nanoTime();
        ModelRegistry.Registered registered;
        try {
            // Anything the body carried that GHRequest does not know about
            // landed in the hints; the handle is taken back out again so that
            // what reaches GraphHopper is the request it always was.
            Object handleSpec = request.getHints().remove("looper_model");
            registered = handleSpec == null ? null : resolve(mapper, registry, handleSpec);
        } catch (ModelRegistry.UnknownHandle e) {
            // Explicitly not a fallback: a caller that has lost its handles
            // must send the model again, not be routed under another one.
            ObjectNode error = mapper.createObjectNode();
            error.put("message", e.getMessage());
            error.put("looper_error", "unknown_handle");
            return new Answer(409, error, micros(began, System.nanoTime()), 0);
        }

        long dispatched = System.nanoTime();
        GHResponse response = registered == null
                ? core.routeJsonBody(request)
                : core.routeRegistered(request, registered);
        long routed = System.nanoTime();

        if (response.hasErrors()) {
            ObjectNode error = mapper.createObjectNode();
            // The route service reads 400 as "no path", which is an ordinary
            // outcome for it; anything else is a fault.
            error.put("message", response.getErrors().get(0).getMessage());
            return new Answer(400, error, micros(began, dispatched), micros(dispatched, routed));
        }
        boolean instructions = request.getHints().getBool("instructions", true);
        boolean calcPoints = request.getHints().getBool("calc_points", true);
        boolean elevation = request.getHints().getBool("elevation", false);
        boolean pointsEncoded = request.getHints().getBool("points_encoded", true);
        double multiplier = request.getHints().getDouble("points_encoded_multiplier", 1e5);
        // GraphHopper's own serializer, so the bytes on the wire are the bytes
        // the container would have sent.
        ObjectNode json = ResponsePathSerializer.jsonObject(response,
                new ResponsePathSerializer.Info(List.of("GraphHopper", "OpenStreetMap contributors"), 0, null),
                instructions, calcPoints, elevation, pointsEncoded, multiplier);
        return new Answer(200, json, micros(began, dispatched), micros(dispatched, routed));
    }

    /**
     * Turn {@code looper_model} into the model the request will be routed under,
     * registering whatever it brought along on the way.
     *
     * Registration happens before routing and is idempotent, so two legs that
     * reach a new corridor set together both describe it and the second one
     * costs a map lookup.
     */
    @SuppressWarnings("unchecked")
    private static ModelRegistry.Registered resolve(ObjectMapper mapper, ModelRegistry registry, Object handleSpec) {
        if (!(handleSpec instanceof Map)) throw new IllegalArgumentException("looper_model must be an object");
        Map<String, Object> spec = (Map<String, Object>) handleSpec;
        ModelRegistry.Generation generation = registry.get(String.valueOf(spec.get("generation")));

        Object register = spec.get("register");
        if (register instanceof Map<?, ?> areas) {
            for (Map.Entry<?, ?> entry : areas.entrySet()) {
                String areaId = String.valueOf(entry.getKey());
                // Through the same mapper and the same JsonFeature the request
                // body's own areas went through, so the parsed geometry is the
                // geometry GraphHopper would have had either way.
                generation.putArea(areaId, mapper.convertValue(entry.getValue(), JsonFeature.class));
            }
        }

        String modelId = String.valueOf(spec.get("id"));
        Object define = spec.get("define");
        if (define == null) return generation.model(modelId);

        Map<String, Object> definition = (Map<String, Object>) define;
        Object areaIds = definition.get("areas");
        Object distanceInfluence = definition.get("distance_influence");
        return generation.define(modelId,
                areaIds == null ? List.of() : ((List<?>) areaIds).stream().map(String::valueOf).toList(),
                definition.get("multiply_by") == null ? null : String.valueOf(definition.get("multiply_by")),
                distanceInfluence == null ? null : ((Number) distanceInfluence).doubleValue());
    }

    private static long micros(long from, long to) {
        return (to - from) / 1000;
    }

    private static void send(HttpExchange exchange, int status, String body) throws java.io.IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("Content-Type", "application/json");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) { out.write(bytes); }
    }
}
