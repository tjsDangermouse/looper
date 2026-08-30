package com.looper.routing.direct;

import com.looper.routing.LooperRoutingCore;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * The reduced, request-local graph a closed-walk search moves over.
 *
 * This is Phase 9's {@code bench/phase9/graph.mts} moved into the process that
 * owns the graph. Nothing about the reductions is new, and both are exact
 * rather than heuristic:
 *
 * <ol>
 *   <li><b>The 2-core.</b> A rooted circuit cannot enter a dead end and come
 *       back out without retracing that edge in reverse, and the acceptance
 *       gate's {@code out-and-back-spur} rule makes a reverse retrace outside
 *       the 75 m doorstep window fatal. So every leaf can be peeled,
 *       repeatedly, without removing one admissible walk. What is peeled is
 *       kept, because the stem out of the door may run through it.</li>
 *   <li><b>Degree-2 contraction.</b> A chain of degree-2 junctions offers no
 *       choice: entering it determines everything until the next real
 *       junction. Each chain becomes one super-edge carrying its metres, its
 *       geometry, the GraphHopper edge ids it is made of and the *physical*
 *       edge ids beneath those, so repeated-ground accounting is unchanged and
 *       search depth falls by the length of the chains.</li>
 * </ol>
 *
 * Two edge identities are kept and they are not the same thing. {@code graph}
 * ids address the {@link com.graphhopper.routing.querygraph.QueryGraph} the
 * exploration ran on and are what a {@link com.graphhopper.routing.Path} is
 * rebuilt from; {@code physical} ids are the real base-graph edges a virtual
 * edge is a piece of, and are what "this walk has already spent this ground"
 * is decided on. Phase 9 only ever needed the second.
 */
public final class SearchGraph {

    /** Metres east/north of the routing start; the frame every shape term uses. */
    public final double originLon, originLat, metricScale;
    public static final double EARTH_RADIUS_METRES = 6371008.8;

    /** Compacted node space. {@code node[i]} is the QueryGraph node. */
    public final int[] node;
    public final double[] lon, lat;
    /** Exact shortest walkable distance from the routing start, in metres. */
    public final double[] home;
    /** Compass octant of each node as seen from the start; the diversity axis. */
    public final byte[] octant;

    /** The routing start, in compacted node space. */
    public final int start;
    public final double startLon, startLat;

    // ---------------------------------------------------------- super-edges
    public final int edgeCount;
    public final int[] edgeFrom, edgeTo;
    public final double[] edgeMetres;
    public final boolean[] edgeForward, edgeBackward;
    /** Geometry, `from` end first, as flat lon/lat pairs. */
    public final double[][] edgeGeometry;
    /** The same line projected into the start's metric frame, flat x/y pairs. */
    public final double[][] edgeMetric;
    /** QueryGraph edge ids under this super-edge, in `from -> to` order. */
    public final int[][] edgeGraphIds;
    /** Physical base-graph edge ids under this super-edge, in `from -> to` order. */
    public final int[][] edgePhysicalIds;
    public final double[][] edgePhysicalMetres;

    // shape contributions, precomputed once per super-edge in the start's frame
    public final double[] edgeTwiceArea, edgeDrawn, edgeMinX, edgeMaxX, edgeMinY, edgeMaxY, edgeMaxRadius;

    // ----------------------------------------------------------------- arcs
    /** Oriented moves out of each node, as a CSR: {@code arcStart[n]..arcStart[n+1]}. */
    public final int[] arcStart;
    public final int[] arcEdge, arcTo;
    public final double[] arcMetres;
    public final boolean[] arcForward;
    /** Bearing leaving the arc's first point, and arriving at its last. */
    public final double[] arcOutBearing, arcInBearing;

    // ------------------------------------------------- the doorstep stem tree
    private final int[] parentNode, parentRaw;
    private final RawEdge[] rawEdges;

    public final Stats stats;

    public record Stats(int rawNodes, int rawEdges, int coreNodes, int coreEdges,
                        int nodes, int superEdges, int arcs, double buildMs) {}

    private record RawEdge(int a, int b, double metres, int graphId, int physicalId,
                           boolean forward, boolean backward, double[] geometry) {}

    /** The walk from the routing start out to a node, on the unreduced edges. */
    public record Stem(int[] graphIds, int[] physicalIds, double[] physicalMetres, double metres,
                       double[] line, double[] metric) {}

    public SearchGraph(LooperRoutingCore.Subgraph raw) {
        long began = System.nanoTime();
        List<LooperRoutingCore.ReachedNode> nodes = raw.nodes();
        int n = nodes.size();
        node = new int[n];
        lon = new double[n];
        lat = new double[n];
        home = new double[n];
        octant = new byte[n];
        Map<Integer, Integer> index = new HashMap<>(n * 2);
        for (int i = 0; i < n; i++) {
            LooperRoutingCore.ReachedNode reached = nodes.get(i);
            node[i] = reached.node();
            lon[i] = reached.lon();
            lat[i] = reached.lat();
            home[i] = reached.networkMetres();
            index.put(reached.node(), i);
        }
        start = index.getOrDefault(raw.startNode(), 0);
        startLon = raw.snappedLon();
        startLat = raw.snappedLat();
        originLon = startLon;
        originLat = startLat;
        metricScale = Math.cos(Math.toRadians(startLat));
        for (int i = 0; i < n; i++) octant[i] = (byte) bearingOctant(bearingBetween(startLon, startLat, lon[i], lat[i]));

        // Undirected adjacency over the raw edges. Parallel edges and self
        // loops are kept: a pair of parallel ways between the same junctions
        // is a genuine two-way-round, and a self loop is a genuine circuit.
        List<RawEdge> raws = new ArrayList<>(raw.edges().size());
        for (LooperRoutingCore.SubEdge edge : raw.edges()) {
            Integer a = index.get(edge.from()), b = index.get(edge.to());
            if (a == null || b == null) continue;
            double[] line = edge.geometry();
            if (line == null || line.length < 4) line = new double[]{lon[a], lat[a], lon[b], lat[b]};
            raws.add(new RawEdge(a, b, edge.metres(), edge.edge(), edge.origin(), edge.forward(), edge.backward(), line));
        }
        rawEdges = raws.toArray(new RawEdge[0]);

        int[][] incident = incidence(n, rawEdges, null);

        // The start-rooted shortest-path tree, read back out of the field
        // rather than searched for again: a node's parent is the neighbour
        // whose own distance plus the edge between them is the node's distance.
        parentNode = new int[n];
        parentRaw = new int[n];
        Arrays.fill(parentNode, -1);
        Arrays.fill(parentRaw, -1);
        for (int v = 0; v < n; v++) {
            if (v == start) continue;
            for (int e : incident[v]) {
                RawEdge edge = rawEdges[e];
                int other = edge.a == v ? edge.b : edge.a;
                boolean usable = edge.a == other ? edge.forward : edge.backward;
                if (!usable) continue;
                if (Math.abs(home[other] + edge.metres - home[v]) > 0.2) continue;
                parentNode[v] = other;
                parentRaw[v] = e;
                break;
            }
        }

        // ------------------------------------------------------- 2-core peel
        boolean[] alive = new boolean[rawEdges.length];
        Arrays.fill(alive, true);
        int[] degree = new int[n];
        for (int v = 0; v < n; v++) degree[v] = incident[v].length;
        int[] queue = new int[n];
        int head = 0;
        for (int v = 0; v < n; v++) if (degree[v] <= 1) queue[head++] = v;
        while (head > 0) {
            int v = queue[--head];
            if (degree[v] > 1) continue;
            for (int e : incident[v]) {
                if (!alive[e]) continue;
                alive[e] = false;
                int other = rawEdges[e].a == v ? rawEdges[e].b : rawEdges[e].a;
                degree[v]--;
                if (other != v) {
                    degree[other]--;
                    if (degree[other] <= 1) {
                        if (head == queue.length) queue = Arrays.copyOf(queue, head * 2 + 1);
                        queue[head++] = other;
                    }
                }
            }
        }
        int coreEdgeCount = 0;
        boolean[] inCore = new boolean[n];
        for (int e = 0; e < rawEdges.length; e++) {
            if (!alive[e]) continue;
            coreEdgeCount++;
            inCore[rawEdges[e].a] = true;
            inCore[rawEdges[e].b] = true;
        }
        int coreNodeCount = 0;
        for (boolean flag : inCore) if (flag) coreNodeCount++;

        // -------------------------------------------------- degree-2 contract
        int[][] coreIncident = incidence(n, rawEdges, alive);
        boolean[] used = new boolean[rawEdges.length];
        List<int[]> chains = new ArrayList<>();      // raw edge indices, in order
        List<Integer> chainFrom = new ArrayList<>();
        for (int v = 0; v < n; v++) {
            if (!inCore[v] || !isJunction(coreIncident, v)) continue;
            for (int e : coreIncident[v]) if (!used[e]) { chains.add(chain(coreIncident, used, e, v)); chainFrom.add(v); }
        }
        // A ring of degree-2 nodes touching no junction at all: rare, but a
        // perfectly good circuit and it must not be dropped.
        for (int e = 0; e < rawEdges.length; e++) {
            if (alive[e] && !used[e]) { chains.add(chain(coreIncident, used, e, rawEdges[e].a)); chainFrom.add(rawEdges[e].a); }
        }

        edgeCount = chains.size();
        edgeFrom = new int[edgeCount];
        edgeTo = new int[edgeCount];
        edgeMetres = new double[edgeCount];
        edgeForward = new boolean[edgeCount];
        edgeBackward = new boolean[edgeCount];
        edgeGeometry = new double[edgeCount][];
        edgeMetric = new double[edgeCount][];
        edgeGraphIds = new int[edgeCount][];
        edgePhysicalIds = new int[edgeCount][];
        edgePhysicalMetres = new double[edgeCount][];
        edgeTwiceArea = new double[edgeCount];
        edgeDrawn = new double[edgeCount];
        edgeMinX = new double[edgeCount];
        edgeMaxX = new double[edgeCount];
        edgeMinY = new double[edgeCount];
        edgeMaxY = new double[edgeCount];
        edgeMaxRadius = new double[edgeCount];

        for (int i = 0; i < edgeCount; i++) buildSuperEdge(i, chains.get(i), chainFrom.get(i));

        // ------------------------------------------------------------- arcs
        int[] outDegree = new int[n];
        for (int i = 0; i < edgeCount; i++) {
            if (edgeForward[i]) outDegree[edgeFrom[i]]++;
            if (edgeBackward[i]) outDegree[edgeTo[i]]++;
        }
        arcStart = new int[n + 1];
        for (int v = 0; v < n; v++) arcStart[v + 1] = arcStart[v] + outDegree[v];
        int total = arcStart[n];
        arcEdge = new int[total];
        arcTo = new int[total];
        arcMetres = new double[total];
        arcForward = new boolean[total];
        arcOutBearing = new double[total];
        arcInBearing = new double[total];
        int[] cursor = Arrays.copyOf(arcStart, n);
        for (int i = 0; i < edgeCount; i++) {
            double[] line = edgeGeometry[i];
            int last = line.length - 2;
            double out = bearingBetween(line[0], line[1], line[Math.min(2, last)], line[Math.min(3, last + 1)]);
            double in = bearingBetween(line[Math.max(0, last - 2)], line[Math.max(1, last - 1)], line[last], line[last + 1]);
            if (edgeForward[i]) {
                int at = cursor[edgeFrom[i]]++;
                arcEdge[at] = i; arcTo[at] = edgeTo[i]; arcMetres[at] = edgeMetres[i]; arcForward[at] = true;
                arcOutBearing[at] = out; arcInBearing[at] = in;
            }
            if (edgeBackward[i]) {
                int at = cursor[edgeTo[i]]++;
                arcEdge[at] = i; arcTo[at] = edgeFrom[i]; arcMetres[at] = edgeMetres[i]; arcForward[at] = false;
                arcOutBearing[at] = (in + 180) % 360; arcInBearing[at] = (out + 180) % 360;
            }
        }

        int liveNodes = 0;
        for (int v = 0; v < n; v++) if (arcStart[v + 1] > arcStart[v]) liveNodes++;
        stats = new Stats(n, rawEdges.length, coreNodeCount, coreEdgeCount, liveNodes, edgeCount, total,
                (System.nanoTime() - began) / 1e6);
    }

    private boolean isJunction(int[][] coreIncident, int v) {
        return coreIncident[v].length != 2 || v == start;
    }

    /** Follow a degree-2 chain from `first` leaving `from` until a junction. */
    private int[] chain(int[][] coreIncident, boolean[] used, int first, int from) {
        List<Integer> steps = new ArrayList<>();
        int current = first, at = from;
        for (;;) {
            RawEdge edge = rawEdges[current];
            used[current] = true;
            steps.add(current);
            int next = edge.a == at ? edge.b : edge.a;
            at = next;
            if (isJunction(coreIncident, next)) break;
            int onward = -1;
            for (int candidate : coreIncident[next]) if (candidate != current && !used[candidate]) { onward = candidate; break; }
            if (onward < 0) break;
            current = onward;
        }
        int[] out = new int[steps.size()];
        for (int i = 0; i < out.length; i++) out[i] = steps.get(i);
        return out;
    }

    private void buildSuperEdge(int i, int[] steps, int from) {
        int at = from;
        double metres = 0;
        boolean forward = true, backward = true;
        List<double[]> lines = new ArrayList<>(steps.length);
        int[] graphIds = new int[steps.length];
        int[] physicalIds = new int[steps.length];
        double[] physicalMetres = new double[steps.length];
        for (int s = 0; s < steps.length; s++) {
            RawEdge edge = rawEdges[steps[s]];
            boolean runsForward = edge.a == at;
            double[] line = runsForward ? edge.geometry : reverseLine(edge.geometry);
            lines.add(line);
            graphIds[s] = edge.graphId;
            physicalIds[s] = edge.physicalId;
            physicalMetres[s] = edge.metres;
            metres += edge.metres;
            forward &= runsForward ? edge.forward : edge.backward;
            backward &= runsForward ? edge.backward : edge.forward;
            at = runsForward ? edge.b : edge.a;
        }
        edgeFrom[i] = from;
        edgeTo[i] = at;
        edgeMetres[i] = metres;
        edgeForward[i] = forward;
        edgeBackward[i] = backward;
        edgeGraphIds[i] = graphIds;
        edgePhysicalIds[i] = physicalIds;
        edgePhysicalMetres[i] = physicalMetres;
        edgeGeometry[i] = joinLines(lines);
        edgeMetric[i] = project(edgeGeometry[i]);
        shapeOf(i);
    }

    /** Shoelace, drawn length, bounding box and radius, in the start's frame. */
    private void shapeOf(int i) {
        double[] points = edgeMetric[i];
        double twiceArea = 0, drawn = 0, maxRadius = 0;
        double minX = Double.POSITIVE_INFINITY, maxX = Double.NEGATIVE_INFINITY;
        double minY = Double.POSITIVE_INFINITY, maxY = Double.NEGATIVE_INFINITY;
        for (int p = 0; p + 1 < points.length; p += 2) {
            double x = points[p], y = points[p + 1];
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
            double radius = Math.hypot(x, y);
            if (radius > maxRadius) maxRadius = radius;
            if (p + 3 < points.length) {
                double nx = points[p + 2], ny = points[p + 3];
                twiceArea += x * ny - nx * y;
                drawn += Math.hypot(nx - x, ny - y);
            }
        }
        edgeTwiceArea[i] = twiceArea;
        edgeDrawn[i] = drawn;
        edgeMinX[i] = minX; edgeMaxX[i] = maxX; edgeMinY[i] = minY; edgeMaxY[i] = maxY;
        edgeMaxRadius[i] = maxRadius;
    }

    /**
     * The doorstep stem: the walk from the routing start out to `node`, on the
     * unreduced edges. Empty where the start is already in the 2-core.
     */
    public Stem stemTo(int to) {
        List<Integer> steps = new ArrayList<>();
        List<Integer> nodes = new ArrayList<>();
        int at = to;
        int guard = 0;
        while (at != start && parentRaw[at] >= 0 && guard++ < rawEdges.length + 2) {
            steps.add(parentRaw[at]);
            nodes.add(parentNode[at]);
            at = parentNode[at];
        }
        java.util.Collections.reverse(steps);
        java.util.Collections.reverse(nodes);
        int[] graphIds = new int[steps.size()];
        int[] physicalIds = new int[steps.size()];
        double[] physicalMetres = new double[steps.size()];
        double metres = 0;
        List<double[]> lines = new ArrayList<>(steps.size());
        for (int i = 0; i < steps.size(); i++) {
            RawEdge edge = rawEdges[steps.get(i)];
            graphIds[i] = edge.graphId;
            physicalIds[i] = edge.physicalId;
            physicalMetres[i] = edge.metres;
            metres += edge.metres;
            lines.add(edge.a == nodes.get(i) ? edge.geometry : reverseLine(edge.geometry));
        }
        double[] line = joinLines(lines);
        return new Stem(graphIds, physicalIds, physicalMetres, metres, line, project(line));
    }

    /** Where the walk actually starts searching, and what the doorstep costs. */
    public int[] rootOf() {
        if (arcStart[start + 1] > arcStart[start]) return new int[]{start};
        int root = -1;
        double best = Double.POSITIVE_INFINITY;
        for (int v = 0; v < home.length; v++) {
            if (arcStart[v + 1] == arcStart[v]) continue;
            if (home[v] < best) { best = home[v]; root = v; }
        }
        return new int[]{root};
    }

    // ------------------------------------------------------------- helpers

    private static int[][] incidence(int n, RawEdge[] edges, boolean[] alive) {
        int[] counts = new int[n];
        for (int e = 0; e < edges.length; e++) {
            if (alive != null && !alive[e]) continue;
            counts[edges[e].a]++;
            if (edges[e].b != edges[e].a) counts[edges[e].b]++;
        }
        int[][] out = new int[n][];
        for (int v = 0; v < n; v++) out[v] = new int[counts[v]];
        int[] cursor = new int[n];
        for (int e = 0; e < edges.length; e++) {
            if (alive != null && !alive[e]) continue;
            out[edges[e].a][cursor[edges[e].a]++] = e;
            if (edges[e].b != edges[e].a) out[edges[e].b][cursor[edges[e].b]++] = e;
        }
        return out;
    }

    private static double[] reverseLine(double[] line) {
        double[] out = new double[line.length];
        for (int i = 0, j = line.length - 2; i < line.length; i += 2, j -= 2) {
            out[i] = line[j];
            out[i + 1] = line[j + 1];
        }
        return out;
    }

    /** Concatenate consecutive lines, dropping the duplicated join points. */
    private static double[] joinLines(List<double[]> lines) {
        int size = 0;
        for (double[] line : lines) size += line.length;
        double[] out = new double[size];
        int at = 0;
        for (double[] line : lines) {
            int from = 0;
            if (at >= 2 && line.length >= 2 && out[at - 2] == line[0] && out[at - 1] == line[1]) from = 2;
            System.arraycopy(line, from, out, at, line.length - from);
            at += line.length - from;
        }
        return Arrays.copyOf(out, at);
    }

    public double[] project(double[] line) {
        double[] out = new double[line.length];
        for (int i = 0; i + 1 < line.length; i += 2) {
            out[i] = EARTH_RADIUS_METRES * Math.toRadians(normaliseLongitude(line[i] - originLon)) * metricScale;
            out[i + 1] = EARTH_RADIUS_METRES * Math.toRadians(line[i + 1] - originLat);
        }
        return out;
    }

    public static double normaliseLongitude(double degrees) { return ((degrees + 540) % 360) - 180; }

    public static double bearingBetween(double lonA, double latA, double lonB, double latB) {
        double lat1 = Math.toRadians(latA), lat2 = Math.toRadians(latB);
        double dLon = Math.toRadians(lonB - lonA);
        double y = Math.sin(dLon) * Math.cos(lat2);
        double x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(dLon);
        double degrees = Math.toDegrees(Math.atan2(y, x));
        return ((degrees % 360) + 360) % 360;
    }

    public static int bearingOctant(double bearing) {
        return (int) (Math.round((((bearing % 360) + 360) % 360) / 45.0) % 8);
    }
}
