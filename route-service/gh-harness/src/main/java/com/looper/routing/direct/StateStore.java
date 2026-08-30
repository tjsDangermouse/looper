package com.looper.routing.direct;

import java.util.Arrays;

/**
 * Where partial walks live during the search.
 *
 * Phase 9's prototype pushed a twelve-field JavaScript object per generated
 * state into one array and never freed it, which is why it peaked at 137 MB on
 * Douglas 5 km. Nothing about that is a property of the search: only the
 * current and pending distance bands are ever read for ranking, and everything
 * behind them is needed for one thing only — walking a parent chain back to
 * recover the arcs of a walk that closed.
 *
 * So the columns are split in two, and they have different lifetimes:
 *
 * <ul>
 *   <li><b>Reconstruction columns</b> — {@code parent}, {@code arc} — 8 bytes a
 *       state, and live for the whole search because a walk that closes in the
 *       last band may descend from a state generated in the first.</li>
 *   <li><b>Ranking columns</b> — distance, the running shoelace, the drawn
 *       length, the bounding box, the radius, the depth, the family, the turn
 *       count — 44 bytes a state, needed only while the state's own band is
 *       still live. They are held in chunks, and a chunk is released the moment
 *       the band it was filled during is behind the search.</li>
 * </ul>
 *
 * States are appended in expansion order and bands are drained in increasing
 * order, so a state generated while band <i>k</i> was draining belongs to band
 * <i>k</i> or later. Each chunk therefore records the highest band key it
 * holds, and can be dropped whole once the search has passed it — which is the
 * whole of the lifecycle management, in one comparison per chunk.
 */
final class StateStore {

    static final int CHUNK_BITS = 12;
    static final int CHUNK = 1 << CHUNK_BITS;
    private static final int CHUNK_MASK = CHUNK - 1;

    // ------------------------------------------------- reconstruction columns
    private int[] parent = new int[CHUNK];
    private int[] arc = new int[CHUNK];
    private int size = 0;

    // ------------------------------------------------------- ranking columns
    private double[][] distance = new double[8][];
    private double[][] twiceArea = new double[8][];
    private double[][] drawn = new double[8][];
    private float[][] minX = new float[8][];
    private float[][] maxX = new float[8][];
    private float[][] minY = new float[8][];
    private float[][] maxY = new float[8][];
    private float[][] maxRadius = new float[8][];
    private int[][] nodeAt = new int[8][];
    private short[][] depth = new short[8][];
    private byte[][] family = new byte[8][];
    private byte[][] tightTurns = new byte[8][];
    /** Highest band key any state in the chunk belongs to. */
    private int[] chunkBand = new int[8];
    private int chunks = 0;
    private int releasedChunks = 0;

    int size() { return size; }
    int releasedChunks() { return releasedChunks; }
    int chunks() { return chunks; }

    /** Bytes still held, counting only the columns this store allocated. */
    long retainedBytes() {
        long live = (long) (chunks - releasedChunks) * CHUNK * (8 + 8 + 8 + 4 + 4 + 4 + 4 + 4 + 4 + 2 + 1 + 1);
        return (long) parent.length * 8 + live;
    }

    int add(int parentIndex, int arcIndex, int node, double distanceMetres, double area, double drawnMetres,
            float lowX, float highX, float lowY, float highY, float radius, int depthValue, int familyValue,
            int tightValue, int bandKey) {
        int index = size++;
        if (index >= parent.length) {
            parent = Arrays.copyOf(parent, parent.length * 2);
            arc = Arrays.copyOf(arc, arc.length * 2);
        }
        parent[index] = parentIndex;
        arc[index] = arcIndex;
        int chunk = index >> CHUNK_BITS;
        if (chunk >= chunks) grow(chunk);
        int slot = index & CHUNK_MASK;
        distance[chunk][slot] = distanceMetres;
        twiceArea[chunk][slot] = area;
        drawn[chunk][slot] = drawnMetres;
        minX[chunk][slot] = lowX;
        maxX[chunk][slot] = highX;
        minY[chunk][slot] = lowY;
        maxY[chunk][slot] = highY;
        maxRadius[chunk][slot] = radius;
        nodeAt[chunk][slot] = node;
        depth[chunk][slot] = (short) Math.min(Short.MAX_VALUE, depthValue);
        family[chunk][slot] = (byte) familyValue;
        tightTurns[chunk][slot] = (byte) Math.min(127, tightValue);
        if (bandKey > chunkBand[chunk]) chunkBand[chunk] = bandKey;
        return index;
    }

    private void grow(int chunk) {
        if (chunk >= chunkBand.length) {
            int capacity = Math.max(chunk + 1, chunkBand.length * 2);
            distance = Arrays.copyOf(distance, capacity);
            twiceArea = Arrays.copyOf(twiceArea, capacity);
            drawn = Arrays.copyOf(drawn, capacity);
            minX = Arrays.copyOf(minX, capacity);
            maxX = Arrays.copyOf(maxX, capacity);
            minY = Arrays.copyOf(minY, capacity);
            maxY = Arrays.copyOf(maxY, capacity);
            maxRadius = Arrays.copyOf(maxRadius, capacity);
            nodeAt = Arrays.copyOf(nodeAt, capacity);
            depth = Arrays.copyOf(depth, capacity);
            family = Arrays.copyOf(family, capacity);
            tightTurns = Arrays.copyOf(tightTurns, capacity);
            chunkBand = Arrays.copyOf(chunkBand, capacity);
        }
        distance[chunk] = new double[CHUNK];
        twiceArea[chunk] = new double[CHUNK];
        drawn[chunk] = new double[CHUNK];
        minX[chunk] = new float[CHUNK];
        maxX[chunk] = new float[CHUNK];
        minY[chunk] = new float[CHUNK];
        maxY[chunk] = new float[CHUNK];
        maxRadius[chunk] = new float[CHUNK];
        nodeAt[chunk] = new int[CHUNK];
        depth[chunk] = new short[CHUNK];
        family[chunk] = new byte[CHUNK];
        tightTurns[chunk] = new byte[CHUNK];
        chunkBand[chunk] = Integer.MIN_VALUE;
        chunks = chunk + 1;
    }

    /**
     * Drop the ranking columns of every chunk whose states all belong to bands
     * the search has finished with. The reconstruction columns stay.
     */
    void releaseBelow(int liveBandKey) {
        for (int chunk = 0; chunk < chunks; chunk++) {
            if (distance[chunk] == null || chunkBand[chunk] >= liveBandKey) continue;
            // The chunk currently being filled is never complete, so never freed.
            if (chunk == (size >> CHUNK_BITS)) continue;
            distance[chunk] = null;
            twiceArea[chunk] = null;
            drawn[chunk] = null;
            minX[chunk] = null;
            maxX[chunk] = null;
            minY[chunk] = null;
            maxY[chunk] = null;
            maxRadius[chunk] = null;
            nodeAt[chunk] = null;
            depth[chunk] = null;
            family[chunk] = null;
            tightTurns[chunk] = null;
            releasedChunks++;
        }
    }

    int parentOf(int index) { return parent[index]; }
    int arcOf(int index) { return arc[index]; }

    double distanceOf(int i) { return distance[i >> CHUNK_BITS][i & CHUNK_MASK]; }
    double twiceAreaOf(int i) { return twiceArea[i >> CHUNK_BITS][i & CHUNK_MASK]; }
    double drawnOf(int i) { return drawn[i >> CHUNK_BITS][i & CHUNK_MASK]; }
    float minXOf(int i) { return minX[i >> CHUNK_BITS][i & CHUNK_MASK]; }
    float maxXOf(int i) { return maxX[i >> CHUNK_BITS][i & CHUNK_MASK]; }
    float minYOf(int i) { return minY[i >> CHUNK_BITS][i & CHUNK_MASK]; }
    float maxYOf(int i) { return maxY[i >> CHUNK_BITS][i & CHUNK_MASK]; }
    float maxRadiusOf(int i) { return maxRadius[i >> CHUNK_BITS][i & CHUNK_MASK]; }
    int nodeOf(int i) { return nodeAt[i >> CHUNK_BITS][i & CHUNK_MASK]; }
    int depthOf(int i) { return depth[i >> CHUNK_BITS][i & CHUNK_MASK]; }
    int familyOf(int i) { return family[i >> CHUNK_BITS][i & CHUNK_MASK]; }
    int tightTurnsOf(int i) { return tightTurns[i >> CHUNK_BITS][i & CHUNK_MASK]; }
    void setFamily(int i, int value) { family[i >> CHUNK_BITS][i & CHUNK_MASK] = (byte) value; }
}
