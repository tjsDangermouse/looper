package com.looper.routing.direct;

import java.util.ArrayList;
import java.util.List;
import java.util.TreeMap;

/**
 * Phase 9's S2 — a beam over distance bands, searching for the walk itself.
 *
 * This is a faithful port of {@code bench/phase9/search.mts}. The formulation,
 * the two exact prunes, the ranking proxy, the per-node cap and the compass
 * octant quota are all Phase 9's, at Phase 9's measured operating point. What
 * is new here is only where the states live (see {@link StateStore}) and a
 * turn-angle term that Phase 9 named as its remaining gap.
 *
 * <h2>What bounds the search</h2>
 * Two prunes are exact and lose nothing admissible:
 * <ul>
 *   <li>a super-edge already spent is not offered as a move, which on a
 *       physical network is what the gate's {@code out-and-back-spur} rule
 *       amounts to;</li>
 *   <li>{@code distanceUsed + home[node] > maxMetres} discards a state whose
 *       best possible finish is already past the top of the band. {@code home}
 *       is the exploration's own Dijkstra distance, so it is the exact shortest
 *       walk home rather than an estimate of one.</li>
 * </ul>
 * Everything else that limits the search is beam selection, which is
 * approximate by construction.
 *
 * <h2>Why bands are drained rather than visited</h2>
 * Most super-edges are shorter than a band, so expanding a band produces states
 * belonging to the same band. Processing each band once would silently discard
 * most of the search, so each pass applies the beam to whatever is currently in
 * the band and the band is only finished when it empties. Termination is not in
 * doubt: no walk may spend an edge twice, so depth is bounded by the edge count.
 */
public final class WalkSearch {

    /** Phase 9's retained operating point. Not re-tuned here. */
    public static final int BEAM = 300;
    public static final double BAND_METRES = 100;
    public static final int PER_NODE = 3;
    /** The gate's own compactness floor; a closure below it is not a walk. */
    public static final double MIN_COMPACTNESS = 0.20;
    /** The gate's own turn allowance. */
    public static final int MAX_U_TURNS = 1;
    /** `INITIAL_BEARING_METRES` and `INITIAL_BEARING_FRACTION` from diversity.ts. */
    public static final double INITIAL_BEARING_METRES = 500;
    public static final double INITIAL_BEARING_FRACTION = 0.2;
    /**
     * A turn this sharp is the junction half of the gate's u-turn test — the
     * gate also asks whether the two arms come back within 20 m of each other,
     * which needs the whole walk and is therefore checked once, exactly, at
     * closure. This is only a ranking discouragement.
     */
    public static final double TIGHT_TURN_DEGREES = 150;

    public record Options(double targetMetres, double tolerance, int beam, double band, int perNode,
                          boolean diversityQuota, boolean turnAware, double turnPenalty,
                          double minCompactness, long budget, int wanted) {
        public static Options standard(double targetMetres, double tolerance) {
            return new Options(targetMetres, tolerance, BEAM, BAND_METRES, PER_NODE, true, true, 0.05,
                    MIN_COMPACTNESS, 4_000_000L, Integer.MAX_VALUE);
        }
    }

    /** One closed walk, as the arcs it is made of. */
    public record Walk(int[] arcs, double metres, double compactness, double bboxRatio,
                       double maxRadius, int family, double promise) {}

    public record Stats(long generated, long expanded, long prunedDistance, long prunedReuse,
                        long prunedBeam, long prunedDominated, int peakBand, long completed,
                        double searchMs, int storeSize, int chunksReleased, long retainedBytes,
                        long peakStoreBytes, long peakHeapDeltaBytes, double stemMetres, int root) {}

    public record Result(List<Walk> walks, Stats stats) {}

    private WalkSearch() {}

    public static Result run(SearchGraph graph, Options options) {
        long began = System.nanoTime();
        double minMetres = options.targetMetres * (1 - options.tolerance);
        double maxMetres = options.targetMetres * (1 + options.tolerance);
        int root = graph.rootOf()[0];
        if (root < 0) {
            return new Result(List.of(), new Stats(0, 0, 0, 0, 0, 0, 0, 0,
                    (System.nanoTime() - began) / 1e6, 0, 0, 0, 0, 0, 0, -1));
        }
        double stemMetres = root == graph.start ? 0 : graph.home[root];
        double commitAt = Math.min(INITIAL_BEARING_METRES, options.targetMetres * INITIAL_BEARING_FRACTION);
        double turnLimit = Math.cos(Math.toRadians(TIGHT_TURN_DEGREES));

        StateStore store = new StateStore();
        long[] spent = new long[(graph.edgeCount + 63) >> 6];
        int[] nodeCount = new int[graph.arcStart.length - 1];
        int[] nodeStamp = new int[nodeCount.length];
        int stamp = 0;
        int[] familyCount = new int[9];

        TreeMap<Integer, IntList> bands = new TreeMap<>();
        List<Walk> walks = new ArrayList<>();
        long generated = 0, expanded = 0, prunedDistance = 0, prunedReuse = 0, prunedBeam = 0, prunedDominated = 0, completed = 0;
        int peakBand = 0;
        // What the search itself costs. `peakStore` is the high-water mark of
        // the state store's own live columns and is exact: it does not move
        // when a garbage collection happens to run, which is what makes a JVM
        // heap reading unusable as a per-request budget. The heap delta is
        // sampled alongside it and reported as the noisy figure it is.
        long heapBaseline = Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory();
        long peakHeapDelta = 0;
        long peakStore = 0;

        // One seed per arc out of the root. Which family a walk belongs to is
        // not decided here: it is whichever octant the walk has committed to
        // once it is clear of the door, the axis the offer selector judges on.
        int seed = store.add(-1, -1, root, stemMetres, 0, 0, 0, 0, 0, 0, 0, 0, -1, 0,
                (int) Math.floor(stemMetres / options.band));
        for (int a = graph.arcStart[root]; a < graph.arcStart[root + 1]; a++) {
            double distance = stemMetres + graph.arcMetres[a];
            int to = graph.arcTo[a];
            if (distance + graph.home[to] > maxMetres) continue;
            int child = extend(graph, store, seed, a, distance, commitAt, options, -1, 0);
            bucket(bands, (int) Math.floor(distance / options.band)).add(child);
            generated++;
        }

        int[] arcsBuffer = new int[512];

        drain:
        for (;;) {
            java.util.Map.Entry<Integer, IntList> entry = bands.firstEntry();
            while (entry != null && entry.getValue().size == 0) {
                bands.remove(entry.getKey());
                entry = bands.firstEntry();
            }
            if (entry == null) break;
            int key = entry.getKey();
            IntList band = entry.getValue();
            int[] members = band.takeAll();
            if (members.length > peakBand) peakBand = members.length;
            // Everything behind the live band is only ever read again to
            // reconstruct a walk, and reconstruction needs the parent and the
            // arc alone. Everything else in those chunks goes now.
            store.releaseBelow(key);
            peakStore = Math.max(peakStore, store.retainedBytes());
            peakHeapDelta = Math.max(peakHeapDelta,
                    Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory() - heapBaseline);

            double[] score = new double[members.length];
            for (int i = 0; i < members.length; i++) score[i] = promise(graph, store, members[i], root, minMetres, options);
            sortDescending(members, score);

            // Beam selection with a family quota. Ranking on shape alone
            // converges: without the quota Phase 9 measured every closed walk
            // at Douglas 5 km sitting in one compass octant and overlapping the
            // best of them by 89%, so the offer selector could only ever take
            // one. Diversity has to be a property of the search.
            stamp++;
            java.util.Arrays.fill(familyCount, 0);
            int present = 0;
            boolean[] seen = new boolean[9];
            for (int index : members) {
                int slot = store.familyOf(index) + 1;
                if (!seen[slot]) { seen[slot] = true; present++; }
            }
            int quota = options.diversityQuota ? Math.max(1, options.beam / Math.max(1, present)) : Integer.MAX_VALUE;
            int[] kept = new int[Math.min(options.beam, members.length)];
            int keptCount = 0;
            boolean[] taken = new boolean[members.length];
            for (int pass = 0; pass < 2 && keptCount < kept.length; pass++) {
                int limit = pass == 0 ? quota : Integer.MAX_VALUE;
                for (int i = 0; i < members.length && keptCount < kept.length; i++) {
                    if (pass == 1 && taken[i]) continue;
                    int index = members[i];
                    int slot = store.familyOf(index) + 1;
                    if (familyCount[slot] >= limit) continue;
                    int node = store.nodeOf(index);
                    int onNode = nodeStamp[node] == stamp ? nodeCount[node] : 0;
                    if (onNode >= options.perNode) { if (pass == 0) prunedDominated++; continue; }
                    nodeStamp[node] = stamp;
                    nodeCount[node] = onNode + 1;
                    familyCount[slot]++;
                    kept[keptCount++] = index;
                    if (pass == 0) taken[i] = true;
                }
            }
            prunedBeam += members.length - keptCount;

            for (int k = 0; k < keptCount; k++) {
                int index = kept[k];
                expanded++;
                int depth = mark(graph, store, spent, index);
                int node = store.nodeOf(index);
                double distanceHere = store.distanceOf(index);
                int inArc = store.arcOf(index);
                int tight = store.tightTurnsOf(index);
                for (int a = graph.arcStart[node]; a < graph.arcStart[node + 1]; a++) {
                    int superEdge = graph.arcEdge[a];
                    if ((spent[superEdge >> 6] & (1L << superEdge)) != 0) { prunedReuse++; continue; }
                    int to = graph.arcTo[a];
                    double distance = distanceHere + graph.arcMetres[a];
                    if (distance + graph.home[to] > maxMetres) { prunedDistance++; continue; }
                    generated++;
                    int turns = tight;
                    if (options.turnAware && inArc >= 0 && isTightTurn(graph, inArc, a, turnLimit)) turns++;
                    int child = extend(graph, store, index, a, distance, commitAt, options, depth, turns);
                    if (to == root) {
                        double total = distance + stemMetres;
                        if (total >= minMetres && total <= maxMetres) {
                            Walk walk = walkOf(graph, store, child, stemMetres, root, minMetres, options, arcsBuffer);
                            if (walk != null && walk.compactness >= options.minCompactness) {
                                walks.add(walk);
                                completed++;
                            }
                        }
                        continue;
                    }
                    bucket(bands, (int) Math.floor(distance / options.band)).add(child);
                }
                unmark(graph, store, spent, index);
                if (expanded >= options.budget || walks.size() >= options.wanted) break drain;
            }
        }

        Stats stats = new Stats(generated, expanded, prunedDistance, prunedReuse, prunedBeam, prunedDominated,
                peakBand, completed, (System.nanoTime() - began) / 1e6, store.size(), store.releasedChunks(),
                store.retainedBytes(), Math.max(peakStore, store.retainedBytes()),
                Math.max(0, peakHeapDelta), stemMetres, root);
        return new Result(walks, stats);
    }

    // ------------------------------------------------------------- machinery

    private static int extend(SearchGraph graph, StateStore store, int parent, int arc, double distance,
                              double commitAt, Options options, int parentDepth, int tightTurns) {
        int edge = graph.arcEdge[arc];
        int to = graph.arcTo[arc];
        int parentFamily = parent < 0 ? -1 : store.familyOf(parent);
        int family = parentFamily >= 0 ? parentFamily : distance >= commitAt ? graph.octant[to] : -1;
        double area = (parent < 0 ? 0 : store.twiceAreaOf(parent)) + (graph.arcForward[arc] ? graph.edgeTwiceArea[edge] : -graph.edgeTwiceArea[edge]);
        double drawn = (parent < 0 ? 0 : store.drawnOf(parent)) + graph.edgeDrawn[edge];
        float lowX = (float) Math.min(parent < 0 ? 0 : store.minXOf(parent), graph.edgeMinX[edge]);
        float highX = (float) Math.max(parent < 0 ? 0 : store.maxXOf(parent), graph.edgeMaxX[edge]);
        float lowY = (float) Math.min(parent < 0 ? 0 : store.minYOf(parent), graph.edgeMinY[edge]);
        float highY = (float) Math.max(parent < 0 ? 0 : store.maxYOf(parent), graph.edgeMaxY[edge]);
        float radius = (float) Math.max(parent < 0 ? 0 : store.maxRadiusOf(parent), graph.edgeMaxRadius[edge]);
        int depth = (parentDepth < 0 ? (parent < 0 ? 0 : store.depthOf(parent)) : parentDepth) + 1;
        return store.add(parent, arc, to, distance, area, drawn, lowX, highX, lowY, highY, radius,
                depth, family, tightTurns, (int) Math.floor(distance / options.band));
    }

    /**
     * How promising a partial walk is: close it with a straight line home and
     * ask how round the result would be. The cheapest honest proxy for the
     * gate's own compactness, needing only the running shoelace and the drawn
     * length — and the quantity Phase 8 could not see, because it never held a
     * walk.
     */
    private static double promise(SearchGraph graph, StateStore store, int index, int root,
                                  double minMetres, Options options) {
        int node = store.nodeOf(index);
        double closing = graph.home[node] - graph.home[root];
        double perimeter = store.drawnOf(index) + Math.max(0, closing);
        double area = Math.abs(store.twiceAreaOf(index) / 2);
        double shape = perimeter > 0 ? Math.min(1, 4 * Math.PI * area / (perimeter * perimeter)) : 0;
        // A walk that can no longer reach the band is worthless however round.
        double shortfall = Math.max(0, minMetres - (store.distanceOf(index) + graph.home[node])) / options.targetMetres;
        double turns = options.turnAware ? options.turnPenalty * store.tightTurnsOf(index) : 0;
        return shape - shortfall - turns;
    }

    /**
     * The junction half of the gate's u-turn rule: did the walk turn back on
     * itself at this node. The gate's full test also asks whether the arms come
     * back within 20 m, which needs the drawn line and is applied at closure.
     */
    private static boolean isTightTurn(SearchGraph graph, int inArc, int outArc, double cosineLimit) {
        double incoming = Math.toRadians(graph.arcInBearing[inArc]);
        double outgoing = Math.toRadians(graph.arcOutBearing[outArc]);
        double dot = Math.sin(incoming) * Math.sin(outgoing) + Math.cos(incoming) * Math.cos(outgoing);
        return dot <= cosineLimit;
    }

    private static int mark(SearchGraph graph, StateStore store, long[] spent, int index) {
        int depth = 0;
        for (int at = index; at >= 0; at = store.parentOf(at)) {
            int arc = store.arcOf(at);
            if (arc < 0) continue;
            int edge = graph.arcEdge[arc];
            spent[edge >> 6] |= 1L << edge;
            depth++;
        }
        return depth;
    }

    private static void unmark(SearchGraph graph, StateStore store, long[] spent, int index) {
        for (int at = index; at >= 0; at = store.parentOf(at)) {
            int arc = store.arcOf(at);
            if (arc < 0) continue;
            int edge = graph.arcEdge[arc];
            spent[edge >> 6] &= ~(1L << edge);
        }
    }

    /** The arcs of the walk ending at `index`, root first. */
    public static int[] arcsOf(StateStore store, int index, int[] buffer) {
        int count = 0;
        for (int at = index; at >= 0; at = store.parentOf(at)) if (store.arcOf(at) >= 0) count++;
        int[] arcs = buffer != null && buffer.length >= count ? buffer : new int[count];
        int cursor = count;
        for (int at = index; at >= 0; at = store.parentOf(at)) {
            int arc = store.arcOf(at);
            if (arc >= 0) arcs[--cursor] = arc;
        }
        return java.util.Arrays.copyOf(arcs, count);
    }

    private static Walk walkOf(SearchGraph graph, StateStore store, int index, double stemMetres, int root,
                               double minMetres, Options options, int[] buffer) {
        int[] arcs = arcsOf(store, index, buffer);
        if (arcs.length == 0) return null;
        double drawn = store.drawnOf(index);
        double width = store.maxXOf(index) - store.minXOf(index);
        double height = store.maxYOf(index) - store.minYOf(index);
        double compactness = drawn > 0 ? Math.min(1, 4 * Math.PI * Math.abs(store.twiceAreaOf(index) / 2) / (drawn * drawn)) : 0;
        double bbox = Math.min(width, height) > 0 ? Math.max(width, height) / Math.min(width, height) : Double.POSITIVE_INFINITY;
        return new Walk(arcs, store.distanceOf(index) + stemMetres, compactness, bbox,
                store.maxRadiusOf(index), store.familyOf(index),
                promise(graph, store, index, root, minMetres, options));
    }

    // --------------------------------------------------------------- helpers

    private static IntList bucket(TreeMap<Integer, IntList> bands, int key) {
        IntList list = bands.get(key);
        if (list == null) { list = new IntList(); bands.put(key, list); }
        return list;
    }

    /** Sort `values` by `keys` descending, moving both. Small arrays, so heapsort-free. */
    static void sortDescending(int[] values, double[] keys) {
        quicksort(values, keys, 0, values.length - 1);
    }

    private static void quicksort(int[] values, double[] keys, int low, int high) {
        while (low < high) {
            if (high - low < 12) {
                for (int i = low + 1; i <= high; i++) {
                    double key = keys[i];
                    int value = values[i];
                    int j = i - 1;
                    while (j >= low && keys[j] < key) { keys[j + 1] = keys[j]; values[j + 1] = values[j]; j--; }
                    keys[j + 1] = key;
                    values[j + 1] = value;
                }
                return;
            }
            double pivot = keys[low + ((high - low) >> 1)];
            int i = low, j = high;
            while (i <= j) {
                while (keys[i] > pivot) i++;
                while (keys[j] < pivot) j--;
                if (i <= j) {
                    double keyTmp = keys[i]; keys[i] = keys[j]; keys[j] = keyTmp;
                    int valueTmp = values[i]; values[i] = values[j]; values[j] = valueTmp;
                    i++; j--;
                }
            }
            if (j - low < high - i) { quicksort(values, keys, low, j); low = i; }
            else { quicksort(values, keys, i, high); high = j; }
        }
    }

    /** A growable int array; the bands hold hundreds of thousands of these. */
    static final class IntList {
        int[] items = new int[16];
        int size = 0;

        void add(int value) {
            if (size == items.length) items = java.util.Arrays.copyOf(items, size * 2);
            items[size++] = value;
        }

        int[] takeAll() {
            int[] out = java.util.Arrays.copyOf(items, size);
            size = 0;
            if (items.length > 4096) items = new int[16];
            return out;
        }
    }
}
