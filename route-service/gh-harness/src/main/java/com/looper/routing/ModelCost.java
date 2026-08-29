package com.looper.routing;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.graphhopper.GHRequest;
import com.graphhopper.GraphHopper;
import com.graphhopper.config.Profile;
import com.graphhopper.jackson.Jackson;
import com.graphhopper.routing.weighting.Weighting;
import com.graphhopper.util.CustomModel;
import com.graphhopper.util.PMap;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Phase 2 §18 and §20: what an avoidance corridor costs before any searching
 * happens.
 *
 * The lab shows an avoidance call costing about a millisecond more than a
 * plain one inside the JVM, while GraphHopper's own stopwatch attributes only
 * a fraction of that to the search. This measures the other candidate
 * directly: turning the request's custom model into a `Weighting`.
 *
 * That step is not free and it is not obviously cacheable. GraphHopper
 * compiles a custom model into a Java class through Janino and caches the
 * class — but the cache key is the model's content string, and for an
 * avoidance model that string contains the full geometry of every corridor.
 * Looper's corridors are different on every call by construction, so whether
 * the cache ever hits is a question about Looper's workload, not about
 * GraphHopper's design, and it is answered here rather than reasoned about.
 *
 *   java -cp gh-harness.jar com.looper.routing.ModelCost \
 *       &lt;config.yml&gt; &lt;graph-dir&gt; &lt;corpus-dir&gt; &lt;out.json&gt; [repeats]
 */
public final class ModelCost {

    public static void main(String[] args) throws Exception {
        Path configYml = Path.of(args[0]);
        Path graphDir = Path.of(args[1]);
        Path corpusDir = Path.of(args[2]);
        Path out = Path.of(args[3]);
        int repeats = args.length > 4 ? Integer.parseInt(args[4]) : 5;

        ObjectMapper mapper = Jackson.newObjectMapper();
        List<Lab.Call> corpus = Lab.readCorpus(mapper, corpusDir);

        try (LooperRoutingCore core = LooperRoutingCore.open(configYml, graphDir, "foot")) {
            GraphHopper hopper = core.raw();
            Profile profile = hopper.getProfile("foot");

            Map<String, double[]> warmByClass = new LinkedHashMap<>();
            Map<String, double[]> coldByClass = new LinkedHashMap<>();
            for (Lab.Call call : corpus) build(hopper, profile, call);   // warm the JIT and the class cache

            for (Lab.Call call : corpus) {
                // Warm: the same model built again, so GraphHopper's compiled
                // class cache can hit if the key allows it. This is the cost
                // Looper pays on a *repeat* of an identical request.
                double warm = time(hopper, profile, call, repeats);
                // Cold: the model altered by one character of a rule that does
                // not change what it selects, which moves the cache key
                // without moving the weighting. This is the cost Looper pays
                // on a corridor it has never sent before — that is, on every
                // real avoidance call.
                double cold = timeUnique(hopper, profile, call, repeats);
                warmByClass.computeIfAbsent(call.klass(), k -> new double[2])[0] += warm;
                warmByClass.get(call.klass())[1]++;
                coldByClass.computeIfAbsent(call.klass(), k -> new double[2])[0] += cold;
                coldByClass.get(call.klass())[1]++;
            }

            ObjectNode results = mapper.createObjectNode();
            results.put("corpusCalls", corpus.size());
            ObjectNode rows = results.putObject("byClass");
            System.out.println("\n| class | calls | weighting build, cache hit | per call | cache miss | per call |");
            System.out.println("|---|---:|---:|---:|---:|---:|");
            for (var entry : warmByClass.entrySet()) {
                double[] warm = entry.getValue(), cold = coldByClass.get(entry.getKey());
                ObjectNode row = rows.putObject(entry.getKey());
                row.put("calls", (int) warm[1]);
                row.put("warmMs", round(warm[0]));
                row.put("warmMeanMs", round(warm[0] / warm[1]));
                row.put("coldMs", round(cold[0]));
                row.put("coldMeanMs", round(cold[0] / cold[1]));
                System.out.printf("| %s | %d | %.1f ms | %.3f ms | %.1f ms | %.3f ms |%n",
                        entry.getKey(), (int) warm[1], warm[0], warm[0] / warm[1], cold[0], cold[0] / cold[1]);
            }
            Files.writeString(out, mapper.writerWithDefaultPrettyPrinter().writeValueAsString(results), StandardCharsets.UTF_8);
            System.out.println("\nwrote " + out);
        }
    }

    static Weighting build(GraphHopper hopper, Profile profile, Lab.Call call) {
        GHRequest request = call.request();
        PMap hints = new PMap();
        CustomModel model = request.getCustomModel();
        if (model != null) hints.putObject(CustomModel.KEY, model);
        return hopper.createWeighting(profile, hints);
    }

    static double time(GraphHopper hopper, Profile profile, Lab.Call call, int repeats) {
        long began = System.nanoTime();
        for (int i = 0; i < repeats; i++) build(hopper, profile, call);
        return (System.nanoTime() - began) / 1e6 / repeats;
    }

    /**
     * The same model with a cache key nothing has seen before.
     *
     * A whitespace difference in a rule is enough: the key is the model's
     * content string, so this misses the compiled-class cache while selecting
     * exactly the same edges. Each repeat gets its own key, because a repeat
     * that reused one would be measuring the hit again.
     */
    static double timeUnique(GraphHopper hopper, Profile profile, Lab.Call call, int repeats) {
        long began = System.nanoTime();
        for (int i = 0; i < repeats; i++) {
            GHRequest request = call.request();
            CustomModel model = request.getCustomModel();
            PMap hints = new PMap();
            if (model != null) {
                CustomModel unique = new CustomModel(model);
                unique.addToPriority(com.graphhopper.json.Statement.If("true", com.graphhopper.json.Statement.Op.MULTIPLY, "1" + " ".repeat(i + 1)));
                hints.putObject(CustomModel.KEY, unique);
            }
            hopper.createWeighting(profile, hints);
        }
        return (System.nanoTime() - began) / 1e6 / repeats;
    }

    static double round(double value) { return Math.round(value * 1000) / 1000.0; }
}
