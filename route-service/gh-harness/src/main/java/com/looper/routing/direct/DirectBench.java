package com.looper.routing.direct;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.graphhopper.jackson.Jackson;
import com.graphhopper.jackson.ResponsePathSerializer;
import com.looper.routing.LooperRoutingCore;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * The Java-side benchmark for the direct closed-walk engine.
 *
 * Every stage is timed separately, because the Phase 9 report's own conclusion
 * was that the cost sat in stages an in-process implementation removes — the
 * export, the 0.97 MB payload and the graph rebuild — and a single total would
 * hide whether that turned out to be true. Memory is measured the same way:
 * peak during the search, and what is still retained when it finishes.
 *
 * <pre>
 * DirectBench &lt;config.yml&gt; &lt;graph-cache&gt; &lt;fixtures.json&gt; &lt;out.json&gt; [repeats]
 * </pre>
 */
public final class DirectBench {

    public static void main(String[] args) throws Exception {
        Path config = Path.of(args[0]), graphDir = Path.of(args[1]);
        Path fixturesFile = Path.of(args[2]), output = Path.of(args[3]);
        int repeats = args.length > 4 ? Integer.parseInt(args[4]) : 5;
        int wanted = Integer.parseInt(System.getProperty("looper.direct.wanted", "24"));
        int beam = Integer.parseInt(System.getProperty("looper.direct.beam", String.valueOf(WalkSearch.BEAM)));
        double band = Double.parseDouble(System.getProperty("looper.direct.band", String.valueOf(WalkSearch.BAND_METRES)));
        int perNode = Integer.parseInt(System.getProperty("looper.direct.perNode", String.valueOf(WalkSearch.PER_NODE)));
        boolean quota = Boolean.parseBoolean(System.getProperty("looper.direct.quota", "true"));
        boolean turnAware = Boolean.parseBoolean(System.getProperty("looper.direct.turnAware", "true"));
        boolean dumpPaths = Boolean.parseBoolean(System.getProperty("looper.direct.dumpPaths", "false"));

        ObjectMapper mapper = Jackson.newObjectMapper();
        ArrayNode fixtures = (ArrayNode) mapper.readTree(fixturesFile.toFile());
        ArrayNode out = mapper.createArrayNode();

        try (LooperRoutingCore core = LooperRoutingCore.open(config, graphDir, "foot")) {
            System.out.printf("| fixture | explore | reduce | search | judge | assemble | total | expanded | generated | states | closed | offered | store MB | peak store MB | heap delta MB |%n");
            System.out.printf("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|%n");
            for (var fixture : fixtures) {
                String name = fixture.get("name").asText();
                double lat = fixture.get("lat").asDouble(), lon = fixture.get("lon").asDouble();
                double target = fixture.get("targetMetres").asDouble();
                DirectWalks.Request request = new DirectWalks.Request(lat, lon, target, wanted, beam, band,
                        perNode, quota, turnAware, 4_000_000L, "en");

                DirectWalks.search(core, request); // warm the JIT and the graph pages
                List<DirectWalks.Answer> runs = new ArrayList<>();
                for (int i = 0; i < repeats; i++) runs.add(DirectWalks.search(core, request));
                DirectWalks.Answer answer = runs.get(runs.size() / 2);
                double totalMs = median(runs.stream().mapToDouble(a -> a.timing().totalMs()).toArray());
                double searchMs = median(runs.stream().mapToDouble(a -> a.timing().searchMs()).toArray());
                double exploreMs = median(runs.stream().mapToDouble(a -> a.timing().exploreMs()).toArray());
                double buildMs = median(runs.stream().mapToDouble(a -> a.timing().buildMs()).toArray());
                double judgeMs = median(runs.stream().mapToDouble(a -> a.timing().judgeMs()).toArray());
                double assembleMs = median(runs.stream().mapToDouble(a -> a.timing().assembleMs()).toArray());

                System.gc();
                long retainedAfter = Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory();

                System.out.printf("| %s | %.1f | %.1f | %.1f | %.1f | %.1f | %.1f | %d | %d | %d | %d | %d | %.2f | %.2f | %.1f |%n",
                        name, exploreMs, buildMs, searchMs, judgeMs, assembleMs, totalMs,
                        answer.search().expanded(), answer.search().generated(), answer.search().storeSize(),
                        answer.closedWalks(), answer.candidates().size(),
                        answer.search().retainedBytes() / 1e6, answer.search().peakStoreBytes() / 1e6,
                        answer.search().peakHeapDeltaBytes() / 1e6);

                ObjectNode record = out.addObject();
                record.put("name", name);
                record.put("targetMetres", target);
                record.put("limitMetres", answer.limitMetres());
                record.put("snappedLat", answer.snappedLat());
                record.put("snappedLon", answer.snappedLon());
                record.set("timing", mapper.valueToTree(new double[]{exploreMs, buildMs, searchMs, judgeMs, assembleMs, totalMs}));
                record.set("search", mapper.valueToTree(answer.search()));
                record.set("graph", mapper.valueToTree(answer.graph()));
                record.put("closedWalks", answer.closedWalks());
                record.put("rejectedShape", answer.rejectedShape());
                record.put("rejectedTurns", answer.rejectedTurns());
                record.put("retainedAfterBytes", retainedAfter);
                ArrayNode walks = record.putArray("walks");
                for (DirectWalks.Candidate candidate : answer.candidates()) {
                    ObjectNode walk = walks.addObject();
                    walk.put("searchedMetres", candidate.searchedMetres());
                    walk.put("compactness", candidate.compactness());
                    walk.put("bboxRatio", candidate.bboxRatio());
                    walk.put("uTurns", candidate.uTurns());
                    walk.put("family", candidate.family());
                    // What the walk is, rather than the whole of it. The full
                    // serialised path is 25 KB and four fixtures' worth is 3 MB
                    // of geometry nobody reads; `-Dlooper.direct.dumpPaths=true`
                    // puts it back when a walk needs to be looked at directly.
                    walk.put("routedMetres", candidate.path().getDistance());
                    walk.put("durationSeconds", candidate.path().getTime() / 1000);
                    walk.put("points", candidate.path().getPoints().size());
                    walk.put("instructions", candidate.path().getInstructions().size());
                    walk.put("edgeSpans", candidate.path().getPathDetails().getOrDefault("edge_id", List.of()).size());
                    if (dumpPaths) {
                        walk.set("path", ResponsePathSerializer.jsonObject(DirectWalks.asResponse(candidate.path()),
                                new ResponsePathSerializer.Info(List.of("GraphHopper", "OpenStreetMap contributors"), 0, null),
                                true, true, false, false, 1e5));
                    }
                }
            }

            // P27 — the same request, over and over, with the heap read after
            // a collection each time. A store that kept every state it ever
            // generated would show here as a line that only goes up; what this
            // is looking for is one that does not.
            int leakRuns = Integer.parseInt(System.getProperty("looper.direct.leakRuns", "0"));
            if (leakRuns > 0) {
                var fixture = fixtures.get(0);
                DirectWalks.Request request = new DirectWalks.Request(
                        fixture.get("lat").asDouble(), fixture.get("lon").asDouble(),
                        fixture.get("targetMetres").asDouble(), wanted, beam, band, perNode, quota, turnAware,
                        4_000_000L, "en");
                System.out.printf("%n### Repeated requests — %s x %d%n%n", fixture.get("name").asText(), leakRuns);
                System.out.println("| request | offered | settled heap MB |");
                System.out.println("|---:|---:|---:|");
                ArrayNode leak = out.addObject().putArray("leak");
                for (int i = 1; i <= leakRuns; i++) {
                    DirectWalks.Answer answer = DirectWalks.search(core, request);
                    if (i % Math.max(1, leakRuns / 10) != 0 && i != leakRuns) continue;
                    System.gc();
                    Thread.sleep(50);
                    long settled = Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory();
                    System.out.printf("| %d | %d | %.1f |%n", i, answer.candidates().size(), settled / 1e6);
                    ObjectNode entry = leak.addObject();
                    entry.put("request", i);
                    entry.put("offered", answer.candidates().size());
                    entry.put("settledHeapBytes", settled);
                }
            }
        }
        Files.writeString(output, mapper.writerWithDefaultPrettyPrinter().writeValueAsString(out));
        System.out.println("wrote " + output);
    }

    private static double median(double[] values) {
        double[] sorted = values.clone();
        java.util.Arrays.sort(sorted);
        return sorted[sorted.length / 2];
    }
}
