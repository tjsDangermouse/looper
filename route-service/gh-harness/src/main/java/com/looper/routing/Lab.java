package com.looper.routing;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.graphhopper.GHRequest;
import com.graphhopper.GHResponse;
import com.graphhopper.ResponsePath;
import com.graphhopper.jackson.Jackson;
import com.graphhopper.jackson.ResponsePathSerializer;
import com.graphhopper.util.details.PathDetail;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Phase 2's experimental bench: Looper's own captured workload, replayed
 * through GraphHopper under configurations we control.
 *
 * Input is the corpus `bench/phase2/capture.mts` records — every engine call
 * six production probes actually made, with the points and the custom model
 * each carried. That matters more than it sounds. Phase 1's seventeen fixtures
 * were chosen to cover the request *shapes*, and they do; but they were not
 * chosen to be representative of the *mix*, and the mix is what a latency
 * budget is spent on. An avoidance fixture that settles five thousand nodes
 * says something true about a hard leg and nothing at all about the median
 * one.
 *
 * Each named configuration is a set of knobs applied to every request in the
 * corpus. Nothing here changes GraphHopper: the knobs are the ones its own
 * request and config API expose, and a configuration that cannot be expressed
 * that way is not tested here — it is reported as unsupported.
 *
 *   java -cp gh-harness.jar com.looper.routing.Lab \
 *       &lt;config.yml&gt; &lt;graph-dir&gt; &lt;corpus-dir&gt; &lt;out.json&gt; [repeats] [configs...]
 */
public final class Lab {

    /** The response fields Looper asks for on every leg, from `buildRouteBody`. */
    private static final List<String> LOOPER_DETAILS = List.of("street_name", "road_class", "edge_id");

    public static void main(String[] args) throws Exception {
        Path configYml = Path.of(args[0]);
        Path graphDir = Path.of(args[1]);
        Path corpusDir = Path.of(args[2]);
        Path out = Path.of(args[3]);
        int repeats = args.length > 4 ? Integer.parseInt(args[4]) : 5;
        // §11: which prepared profile the corpus is asked of. The corpus
        // records carry no profile of their own — they were captured from a
        // service that only knows one — so testing a second one means naming
        // it here rather than rewriting every record.
        String profile = System.getProperty("looper.profile", "foot");
        List<String> wanted = args.length > 5 ? Arrays.asList(args).subList(5, args.length) : List.of();

        ObjectMapper mapper = Jackson.newObjectMapper();
        List<Call> corpus = readCorpus(mapper, corpusDir);
        System.out.println("corpus: " + corpus.size() + " calls from " + corpusDir);

        List<Config> configs = configurations().stream()
                .filter(c -> wanted.isEmpty() || wanted.contains(c.name()))
                .toList();

        ObjectNode results = mapper.createObjectNode();
        results.put("corpusCalls", corpus.size());
        results.put("repeats", repeats);
        ArrayNode rows = results.putArray("configs");

        // Warm the JVM against the whole corpus before the first configuration
        // is measured, and throw the engine away afterwards.
        //
        // Without this the ordering of the list is a variable: the first
        // configuration pays for compiling GraphHopper's search, its custom
        // weighting and Jackson, and the ones after it inherit that for free.
        // Measured, the effect is around 7% — which is larger than several of
        // the differences this bench exists to detect, and it points the wrong
        // way, flattering whatever is tested last.
        System.out.println("warming the JVM against the corpus...");
        try (LooperRoutingCore warm = LooperRoutingCore.open(configYml, graphDir, profile)) {
            Config plain = Config.of("warmup", "");
            for (int pass = 0; pass < 2; pass++) for (Call call : corpus) route(warm, call, plain);
        }

        for (Config config : configs) {
            System.out.println("\n=== " + config.name() + " — " + config.what());
            // `lm.active_landmarks` is read when the graph is opened, not per
            // request, so a configuration that changes it needs its own engine.
            // Everything else could share one; they do not, because a shared
            // JVM would also share the custom-weighting class cache, and
            // whether that cache is warm is one of the things under test.
            try (LooperRoutingCore core = LooperRoutingCore.open(configYml, graphDir, profile, config.engineHints())) {
                rows.add(run(mapper, core, corpus, config, repeats));
            }
        }
        Files.writeString(out, mapper.writerWithDefaultPrettyPrinter().writeValueAsString(results), StandardCharsets.UTF_8);
        System.out.println("\nwrote " + out);
    }

    // --- the configurations ------------------------------------------------

    /**
     * A named set of knobs. `engineHints` are applied to the GraphHopper
     * configuration before the graph is loaded; `requestHints` to each request.
     * `details`, `instructions` and `calcPoints` override what Looper asks for
     * in the response, which is how the cost of building the response is
     * separated from the cost of finding the path.
     */
    record Config(String name, String what, Map<String, Object> engineHints, Map<String, Object> requestHints,
                  List<String> details, Boolean instructions, Boolean calcPoints) {
        static Config of(String name, String what) { return new Config(name, what, Map.of(), Map.of(), null, null, null); }
        Config engine(String key, Object value) {
            var merged = new LinkedHashMap<>(engineHints); merged.put(key, value);
            return new Config(name, what, merged, requestHints, details, instructions, calcPoints);
        }
        Config request(String key, Object value) {
            var merged = new LinkedHashMap<>(requestHints); merged.put(key, value);
            return new Config(name, what, engineHints, merged, details, instructions, calcPoints);
        }
        Config response(List<String> wantedDetails, Boolean wantInstructions, Boolean wantPoints) {
            return new Config(name, what, engineHints, requestHints, wantedDetails, wantInstructions, wantPoints);
        }
    }

    static List<Config> configurations() {
        List<Config> all = new ArrayList<>();
        all.add(Config.of("baseline", "exactly what Looper sends today"));

        // §6: how many landmarks the query actually consults. Counts above
        // the prepared set are rejected by GraphHopper rather than clamped, so
        // the larger entries only run against the larger preparations.
        for (int active : new int[]{1, 2, 4, 6, 8, 12, 16, 24, 32})
            all.add(Config.of("active-" + active, active + " active landmarks").engine("routing.lm.active_landmarks", active));

        // §16: the same searches with the landmark heuristic switched off, so
        // the beeline-only bound is the comparison rather than the theory.
        all.add(Config.of("lm-off", "flexible routing, no landmark heuristic").request("lm.disable", true));

        // §15: the algorithms the LM factory will actually accept.
        all.add(Config.of("algo-astar", "unidirectional A* with landmarks").request("algorithm", "astar"));
        all.add(Config.of("algo-astarbi", "bidirectional A* named explicitly (the default)").request("algorithm", "astarbi"));
        all.add(Config.of("flex-dijkstrabi", "bidirectional Dijkstra, no heuristic at all")
                .request("lm.disable", true).request("algorithm", "dijkstrabi"));

        // §19/§20: what the response costs, as against what the search costs.
        all.add(Config.of("no-details", "same search, no path details").response(List.of(), null, null));
        all.add(Config.of("no-instructions", "same search, no instructions").response(null, false, null));
        all.add(Config.of("edge-id-only", "path details cut to the one the overlap measure needs").response(List.of("edge_id"), null, null));
        all.add(Config.of("candidate-output", "what a candidate leg could ask for: geometry and edge ids, no instructions or street names")
                .response(List.of("edge_id"), false, true));
        all.add(Config.of("minimal", "the path and nothing else: no details, no instructions, no geometry")
                .response(List.of(), false, false));
        return all;
    }

    // --- the run ------------------------------------------------------------

    static ObjectNode run(ObjectMapper mapper, LooperRoutingCore core, List<Call> corpus, Config config, int repeats) throws Exception {
        // Warm the whole corpus once before measuring anything. A JIT-cold JVM
        // measures the JIT — and this pass also warms GraphHopper's compiled
        // custom-weighting cache, which is itself one of the things under test,
        // so the warm-up is a pass over the same requests rather than a
        // handful of representative ones.
        for (Call call : corpus) route(core, call, config);

        Map<String, Agg> byClass = new LinkedHashMap<>();
        Agg total = new Agg();
        List<String> pathHashes = new ArrayList<>(corpus.size());

        for (Call call : corpus) {
            double[] times = new double[repeats];
            GHResponse last = null;
            for (int i = 0; i < repeats; i++) {
                long began = System.nanoTime();
                last = route(core, call, config);
                times[i] = (System.nanoTime() - began) / 1e6;
            }
            Arrays.sort(times);
            double median = times[times.length / 2];

            // What the answer was, so a faster configuration can be shown to
            // be answering the same question.
            pathHashes.add(last.hasErrors() ? "error" : pathHash(last.getBest()));

            // The cost of turning the answer into the bytes Looper reads,
            // measured separately because it is not routing, and Looper pays
            // it on every candidate leg whether or not the candidate survives.
            double serializeMs = Double.NaN;
            if (!last.hasErrors()) {
                long began = System.nanoTime();
                for (int i = 0; i < repeats; i++) serialize(mapper, last, config);
                serializeMs = (System.nanoTime() - began) / 1e6 / repeats;
            }

            long visited = last.getHints().getLong("visited_nodes.sum", -1);
            String debug = last.hasErrors() ? null : last.getBest().getDebugInfo();
            byClass.computeIfAbsent(call.klass(), k -> new Agg()).add(median, visited, serializeMs, debug);
            total.add(median, visited, serializeMs, debug);
        }

        ObjectNode row = mapper.createObjectNode();
        row.put("name", config.name());
        row.put("what", config.what());
        row.put("pathFingerprint", digest(String.join(";", pathHashes)));
        total.into(row.putObject("total"));
        ObjectNode classes = row.putObject("byClass");
        for (var entry : byClass.entrySet()) entry.getValue().into(classes.putObject(entry.getKey()));
        System.out.printf("  %-18s %8.1f ms total  %,10d visited  serialize %6.1f ms  paths %s%n",
                config.name(), total.ms, total.visited, total.serializeMs, row.get("pathFingerprint").asText());
        return row;
    }

    static GHResponse route(LooperRoutingCore core, Call call, Config config) {
        GHRequest request = call.request();
        if (config.details() != null) request.setPathDetails(config.details());
        if (config.instructions() != null) request.getHints().putObject("instructions", config.instructions());
        if (config.calcPoints() != null) request.getHints().putObject("calc_points", config.calcPoints());
        config.requestHints().forEach((key, value) -> request.getHints().putObject(key, value));
        return core.routeJsonBody(request);
    }

    static void serialize(ObjectMapper mapper, GHResponse response, Config config) throws Exception {
        boolean instructions = config.instructions() == null || config.instructions();
        boolean calcPoints = config.calcPoints() == null || config.calcPoints();
        // `points_encoded: false` is what Looper asks for, and it is the
        // expensive branch: every coordinate becomes a JSON array rather than
        // a character in a polyline.
        ObjectNode json = ResponsePathSerializer.jsonObject(response,
                new ResponsePathSerializer.Info(List.of("GraphHopper", "OpenStreetMap contributors"), 0, null),
                instructions, calcPoints, false, false, 1e5);
        mapper.writeValueAsString(json);
    }

    /** An aggregate over one class of request. */
    static final class Agg {
        int calls;
        double ms, serializeMs, algoInitMs, searchMsFloor;
        long visited;
        final List<Double> each = new ArrayList<>();

        void add(double median, long visitedNodes, double serialize, String debug) {
            calls++;
            ms += median;
            each.add(median);
            if (visitedNodes >= 0) visited += visitedNodes;
            if (!Double.isNaN(serialize)) serializeMs += serialize;
            // GraphHopper's own stopwatches, read out of the debug string it
            // already builds: microseconds for the algorithm's set-up,
            // milliseconds for the search. The search figure is quantised to a
            // whole millisecond and is therefore a floor, never the answer.
            algoInitMs += parse(debug, "algoInit:", " μs") / 1000;
            searchMsFloor += parse(debug, "-routing:", " ms");
        }

        static double parse(String debug, String marker, String unit) {
            if (debug == null) return 0;
            int at = debug.indexOf(marker);
            if (at < 0) return 0;
            int from = at + marker.length();
            int to = debug.indexOf(unit, from);
            if (to < 0) return 0;
            try { return Double.parseDouble(debug.substring(from, to).trim()); } catch (NumberFormatException e) { return 0; }
        }

        void into(ObjectNode node) {
            List<Double> sorted = new ArrayList<>(each);
            Collections.sort(sorted);
            node.put("calls", calls);
            node.put("ms", round(ms));
            node.put("meanMs", round(ms / calls));
            node.put("medianMs", round(sorted.get(sorted.size() / 2)));
            node.put("p95Ms", round(sorted.get(Math.min(sorted.size() - 1, (int) Math.ceil(0.95 * sorted.size()) - 1))));
            node.put("maxMs", round(sorted.get(sorted.size() - 1)));
            node.put("visitedNodes", visited);
            node.put("meanVisitedNodes", visited / calls);
            node.put("serializeMs", round(serializeMs));
            node.put("algoInitMs", round(algoInitMs));
            node.put("searchMsFloor", round(searchMsFloor));
        }

        static double round(double value) { return Math.round(value * 100) / 100.0; }
    }

    // --- the corpus ---------------------------------------------------------

    /** One traced engine call, rebuilt into the request Looper's body becomes. */
    public record Call(String fixture, String purpose, String klass, ObjectNode body) {
        private static final ObjectMapper MAPPER = Jackson.newObjectMapper();

        public GHRequest request() {
            try {
                return MAPPER.treeToValue(body.deepCopy(), GHRequest.class);
            } catch (Exception e) {
                throw new IllegalStateException("corpus record is not a request: " + e, e);
            }
        }
    }

    public static List<Call> readCorpus(ObjectMapper mapper, Path dir) throws Exception {
        List<Call> calls = new ArrayList<>();
        try (var files = Files.list(dir)) {
            for (Path file : files.filter(f -> f.toString().endsWith(".jsonl")).sorted().toList()) {
                String fixture = file.getFileName().toString().replace(".jsonl", "");
                for (String line : Files.readAllLines(file)) {
                    if (line.isBlank()) continue;
                    JsonNode record = mapper.readTree(line);
                    // A trace taken without `LOOPER_TRACE_BODIES` has the
                    // timings but not the request. Skipping is right: it is a
                    // smaller corpus, not a wrong one.
                    if (!record.has("points")) continue;
                    calls.add(new Call(fixture, record.get("purpose").asText(), record.get("class").asText(), body(mapper, record)));
                }
            }
        }
        return calls;
    }

    /**
     * The body `src/graphhopper.ts` builds, rebuilt from a trace record.
     *
     * Kept deliberately verbatim rather than merely equivalent: the whole
     * value of replaying a corpus is that the engine answers the request
     * Looper made, and a benchmark that quietly drops a field is measuring a
     * request Looper never sends.
     */
    static ObjectNode body(ObjectMapper mapper, JsonNode record) {
        ObjectNode body = mapper.createObjectNode();
        body.set("points", record.get("points").deepCopy());
        body.put("profile", System.getProperty("looper.profile", "foot"));
        body.put("ch.disable", true);
        body.put("points_encoded", false);
        body.put("instructions", true);
        body.put("elevation", false);
        body.put("calc_points", true);
        body.put("locale", "en");
        ArrayNode details = body.putArray("details");
        LOOPER_DETAILS.forEach(details::add);
        body.putArray("snap_preventions").add("ferry");
        JsonNode model = record.get("model");
        if (model != null && !model.isNull()) body.set("custom_model", model.deepCopy());
        return body;
    }

    // --- identity -----------------------------------------------------------

    /** The edge sequence where the engine reported one, distance where it did not. */
    static String pathHash(ResponsePath path) {
        StringBuilder sb = new StringBuilder();
        List<PathDetail> edges = path.getPathDetails().get("edge_id");
        if (edges != null) for (PathDetail detail : edges) sb.append(detail.getValue()).append(',');
        else sb.append(Math.round(path.getDistance() * 1000));
        return digest(sb.toString());
    }

    static String digest(String value) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(value.getBytes(StandardCharsets.UTF_8))).substring(0, 16);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
