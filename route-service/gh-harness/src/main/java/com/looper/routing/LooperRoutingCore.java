package com.looper.routing;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.dataformat.yaml.YAMLFactory;
import com.graphhopper.GHRequest;
import com.graphhopper.GHResponse;
import com.graphhopper.GraphHopper;
import com.graphhopper.GraphHopperConfig;
import com.graphhopper.ResponsePath;
import com.graphhopper.config.Profile;
import com.graphhopper.jackson.Jackson;
import com.graphhopper.routing.ev.BooleanEncodedValue;
import com.graphhopper.routing.ev.Subnetwork;
import com.graphhopper.routing.querygraph.QueryGraph;
import com.graphhopper.routing.util.DefaultSnapFilter;
import com.graphhopper.routing.ev.RoadClass;
import com.graphhopper.routing.ev.RoadEnvironment;
import com.graphhopper.routing.util.EdgeFilter;
import com.graphhopper.routing.util.SnapPreventionEdgeFilter;
import com.graphhopper.routing.weighting.Weighting;
import com.graphhopper.storage.index.Snap;
import com.graphhopper.storage.BaseGraph;
import com.graphhopper.storage.NodeAccess;
import com.graphhopper.util.EdgeExplorer;
import com.graphhopper.util.EdgeIterator;
import com.graphhopper.util.CustomModel;
import com.graphhopper.util.PMap;
import com.graphhopper.util.shapes.GHPoint;

import java.io.File;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.PriorityQueue;

/**
 * The narrow seam between Looper and GraphHopper.
 *
 * Everything behind this class is GraphHopper's own code, unmodified and used
 * as a library: its OSM import, its graph and location index, its query graph,
 * its custom-model weighting, its landmark preparation and its bidirectional
 * A*. Nothing here reimplements any of that. The point of the class is to be
 * the only place Looper has to know about, and to be small enough that the
 * engine underneath it could later be replaced without Looper noticing.
 *
 * The configuration is read from the same graphhopper/config.yml the container
 * runs, deserialised into GraphHopper's own {@link GraphHopperConfig} exactly
 * as Dropwizard does it, so there is no second copy of the settings to drift.
 */
public final class LooperRoutingCore implements AutoCloseable {

    private final GraphHopper hopper;
    private final ModelRegistry registry = new ModelRegistry();
    private final String profileName;
    private final List<String> snapPreventionsDefault;

    private LooperRoutingCore(GraphHopper hopper, String profileName, List<String> snapPreventionsDefault) {
        this.hopper = hopper;
        this.profileName = profileName;
        this.snapPreventionsDefault = snapPreventionsDefault;
    }

    /**
     * Load an already-imported graph. `graphDir` overrides `graph.location` so
     * the harness can point at the very bytes the running container imported,
     * rather than at a second import that might differ.
     */
    public static LooperRoutingCore open(Path configYml, Path graphDir, String profileName) throws Exception {
        return open(configYml, graphDir, profileName, java.util.Map.of());
    }

    /**
     * The same, with named overrides applied to the configuration after the
     * file is read and before the graph is opened.
     *
     * Settings GraphHopper consumes at load time — `routing.lm.active_landmarks`
     * is the one Phase 2 needs — cannot be moved by a request hint, so an
     * experiment on them has to open its own engine. The overrides are ordinary
     * `GraphHopperConfig` keys and nothing interprets them here: an unknown key
     * behaves exactly as it would in `config.yml`.
     */
    public static LooperRoutingCore open(Path configYml, Path graphDir, String profileName, java.util.Map<String, Object> overrides) throws Exception {
        ObjectMapper yaml = Jackson.initObjectMapper(new ObjectMapper(new YAMLFactory()));
        JsonNode root = yaml.readTree(configYml.toFile());
        JsonNode ghNode = root.get("graphhopper");
        if (ghNode == null) throw new IllegalArgumentException("no `graphhopper` key in " + configYml);
        GraphHopperConfig cfg = yaml.treeToValue(ghNode, GraphHopperConfig.class);

        // The container sets both of these on the command line at run time.
        cfg.putObject("graph.location", graphDir.toString());
        cfg.putObject("datareader.file", "");

        // `custom_model_files: [looper_foot.json]` is resolved relative to
        // this folder, the same way entrypoint.sh's working directory does it.
        cfg.putObject("custom_models.directory", configYml.toAbsolutePath().getParent().toString());

        overrides.forEach(cfg::putObject);

        // GraphHopper's own factory, wrapped so that a request naming a
        // registered model gets the weighting already built for it. Without a
        // handle in the hints the wrapper is the delegate, so every other
        // caller — the import, the landmark preparation, `snap` — is unchanged.
        GraphHopper hopper = new GraphHopper() {
            @Override
            protected com.graphhopper.routing.WeightingFactory createWeightingFactory() {
                return new LooperWeightingFactory(super.createWeightingFactory());
            }
        };
        hopper.init(cfg);
        hopper.setAllowWrites(false);
        if (!hopper.load())
            throw new IllegalStateException("No importable graph at " + graphDir + " — the harness never imports, it loads what the container built.");

        List<String> snapPreventions = Arrays.stream(cfg.getString("routing.snap_preventions_default", "").split(","))
                .map(String::trim).filter(s -> !s.isEmpty()).toList();

        return new LooperRoutingCore(hopper, profileName, snapPreventions);
    }

    public GraphHopper raw() {
        return hopper;
    }

    /**
     * Where a caller may leave a corridor set rather than restating it on every
     * request. Empty, and costing nothing, unless a caller uses it.
     */
    public ModelRegistry registry() {
        return registry;
    }

    /** What Looper asks for on a leg. Anything GraphHopper offers and Looper does not use is deliberately absent. */
    public static final class RoutingOptions {
        public CustomModel customModel;
        public boolean instructions = true;
        public boolean calcPoints = true;
        public List<String> pathDetails = List.of("street_name", "road_class", "edge_id");
        public List<String> snapPreventions = List.of("ferry");
        public String locale = "en";
    }

    public static final class SnapResult {
        public final boolean found;
        public final double lat, lon;
        public final int edgeId;
        public final double queryDistanceMetres;

        SnapResult(boolean found, double lat, double lon, int edgeId, double queryDistanceMetres) {
            this.found = found; this.lat = lat; this.lon = lon;
            this.edgeId = edgeId; this.queryDistanceMetres = queryDistanceMetres;
        }
    }

    /**
     * GraphHopper's own snapping, through its own location index and the same
     * filters {@link com.graphhopper.routing.ViaRouting#lookup} builds — not a
     * reimplementation, and not an approximation of one.
     *
     * The snap-prevention wrapper matters and is easy to leave off: without it
     * a point beside a bridge or a ferry pier snaps onto the structure rather
     * than onto the street under it, and then the whole leg starts in the
     * wrong place. The router applies it; so must anything claiming to answer
     * the same question.
     */
    public SnapResult snap(double lat, double lon, List<String> snapPreventions) {
        Profile profile = hopper.getProfile(profileName);
        Weighting weighting = hopper.createWeighting(profile, new PMap());
        BooleanEncodedValue subnetworkEnc = hopper.getEncodingManager().getBooleanEncodedValue(Subnetwork.key(profileName));
        EdgeFilter filter = new DefaultSnapFilter(weighting, subnetworkEnc);
        List<String> preventions = snapPreventions == null ? snapPreventionsDefault : snapPreventions;
        if (!preventions.isEmpty())
            filter = new SnapPreventionEdgeFilter(filter,
                    hopper.getEncodingManager().getEnumEncodedValue(RoadClass.KEY, RoadClass.class),
                    hopper.getEncodingManager().getEnumEncodedValue(RoadEnvironment.KEY, RoadEnvironment.class),
                    preventions);
        Snap snap = hopper.getLocationIndex().findClosest(lat, lon, filter);
        if (!snap.isValid()) return new SnapResult(false, Double.NaN, Double.NaN, -1, Double.NaN);
        // Building the query graph is what creates the virtual node, and it is
        // the virtual node's position that a route actually starts from.
        QueryGraph.create(hopper.getBaseGraph(), snap);
        GHPoint p = snap.getSnappedPoint();
        return new SnapResult(true, p.lat, p.lon, snap.getClosestEdge().getEdge(), snap.getQueryDistance());
    }

    public record ReachedNode(int node, double lat, double lon, double networkMetres, int degree,
                             int parent, int parentEdge) {}
    public record NetworkField(List<ReachedNode> nodes, long nodesVisited, long edgesVisited,
                               double wallMs, long heapDeltaBytes, double snappedLat, double snappedLon,
                               int startNode) {}

    /**
     * Analysis-only bounded distance field over GraphHopper's loaded foot graph.
     * This is not a route implementation: it emits reachable graph locations
     * for candidate construction, while every candidate leg is still routed by
     * GraphHopper. The profile weighting is used solely as its access filter;
     * accumulated scale is the edge's own network distance in metres.
     *
     * The exploration runs on the same {@link QueryGraph} a route would run
     * on, seeded at the virtual node the router actually starts from, so both
     * endpoints of the snapped edge are entered at their true partial-edge
     * distance rather than one tower node being entered at zero.
     *
     * Each settled node keeps the predecessor and the edge it was reached by,
     * so the result is a rooted shortest-path tree and not only a distance
     * field. Settle order is a topological order of that tree.
     */
    public NetworkField explore(double lat, double lon, double limitMetres) {
        long began = System.nanoTime();
        Runtime runtime = Runtime.getRuntime();
        long heapBefore = runtime.totalMemory() - runtime.freeMemory();
        BaseGraph base = hopper.getBaseGraph();
        Profile profile = hopper.getProfile(profileName);
        Weighting weighting = hopper.createWeighting(profile, new PMap());
        BooleanEncodedValue subnetworkEnc = hopper.getEncodingManager().getBooleanEncodedValue(Subnetwork.key(profileName));
        EdgeFilter filter = new DefaultSnapFilter(weighting, subnetworkEnc);
        if (!snapPreventionsDefault.isEmpty())
            filter = new SnapPreventionEdgeFilter(filter,
                    hopper.getEncodingManager().getEnumEncodedValue(RoadClass.KEY, RoadClass.class),
                    hopper.getEncodingManager().getEnumEncodedValue(RoadEnvironment.KEY, RoadEnvironment.class),
                    snapPreventionsDefault);
        Snap snap = hopper.getLocationIndex().findClosest(lat, lon, filter);
        if (!snap.isValid())
            return new NetworkField(List.of(), 0, 0, 0, 0, Double.NaN, Double.NaN, -1);
        QueryGraph graph = QueryGraph.create(base, snap);
        GHPoint snapped = snap.getSnappedPoint();
        int start = snap.getClosestNode();
        NodeAccess access = graph.getNodeAccess();
        int nodes = graph.getNodes();
        double[] best = new double[nodes];
        int[] parent = new int[nodes];
        int[] parentEdge = new int[nodes];
        Arrays.fill(best, Double.POSITIVE_INFINITY);
        Arrays.fill(parent, -1);
        Arrays.fill(parentEdge, -1);
        boolean[] settled = new boolean[nodes];
        record Entry(int node, double metres) {}
        PriorityQueue<Entry> queue = new PriorityQueue<>(java.util.Comparator.comparingDouble(Entry::metres));
        best[start] = 0;
        queue.add(new Entry(start, 0));
        EdgeExplorer explorer = graph.createEdgeExplorer();
        List<ReachedNode> reached = new ArrayList<>();
        long edgesVisited = 0;
        while (!queue.isEmpty()) {
            Entry entry = queue.poll();
            if (settled[entry.node] || entry.metres > limitMetres) continue;
            settled[entry.node] = true;
            EdgeIterator edges = explorer.setBaseNode(entry.node);
            int degree = 0;
            while (edges.next()) {
                edgesVisited++;
                if (!Double.isFinite(weighting.calcEdgeWeight(edges, false))) continue;
                degree++;
                int next = edges.getAdjNode();
                double candidate = entry.metres + edges.getDistance();
                if (candidate <= limitMetres && candidate < best[next]) {
                    best[next] = candidate;
                    parent[next] = entry.node;
                    parentEdge[next] = edges.getEdge();
                    queue.add(new Entry(next, candidate));
                }
            }
            reached.add(new ReachedNode(entry.node, access.getLat(entry.node), access.getLon(entry.node),
                    entry.metres, degree, parent[entry.node], parentEdge[entry.node]));
        }
        long heapAfter = runtime.totalMemory() - runtime.freeMemory();
        return new NetworkField(reached, reached.size(), edgesVisited,
                (System.nanoTime() - began) / 1e6, heapAfter - heapBefore, snapped.lat, snapped.lon, start);
    }

    /** The narrow route call: ordered via points in, one path out. */
    public GHResponse route(List<GHPoint> points, RoutingOptions options) {
        return hopper.route(toRequest(points, options));
    }

    /**
     * The request Looper's HTTP body turns into. Kept separate from
     * {@link #route} so the harness can assert that the narrow API builds the
     * same request the service sends over the wire.
     */
    public GHRequest toRequest(List<GHPoint> points, RoutingOptions options) {
        GHRequest request = new GHRequest(new ArrayList<>(points));
        request.setProfile(profileName);
        request.setLocale(options.locale);
        request.setPathDetails(options.pathDetails);
        request.setSnapPreventions(options.snapPreventions.isEmpty() ? snapPreventionsDefault : options.snapPreventions);
        if (options.customModel != null) request.setCustomModel(options.customModel);
        request.getHints().putObject("ch.disable", true);
        request.getHints().putObject("instructions", options.instructions);
        request.getHints().putObject("calc_points", options.calcPoints);
        request.getHints().putObject("elevation", false);
        return request;
    }

    /**
     * Route a request that arrived as the service's own JSON body.
     *
     * This is the equivalence path: the body is deserialised by GraphHopper's
     * own Jackson module into the very {@link GHRequest} the HTTP resource
     * would have built, the same snap-prevention default is applied, and the
     * same {@code hopper.route} is called. Everything that differs from the
     * container is therefore HTTP and JSON, and nothing else.
     */
    public GHResponse routeJsonBody(GHRequest request) {
        if (!request.hasSnapPreventions()) request.setSnapPreventions(snapPreventionsDefault);
        return hopper.route(request);
    }

    /**
     * The same, for a request whose custom model arrived as a handle.
     *
     * The model is put on the request exactly as if the body had carried it —
     * so the LM constraint check, the profile merge and the search all see what
     * they saw before — and the handle rides alongside in the hints, where
     * {@link LooperWeightingFactory} can use it to skip rebuilding a weighting
     * that has not changed.
     */
    public GHResponse routeRegistered(GHRequest request, ModelRegistry.Registered registered) {
        request.setCustomModel(registered.model());
        request.getHints().putObject(LooperWeightingFactory.HANDLE, registered);
        return routeJsonBody(request);
    }

    public ResponsePath best(GHResponse response) {
        return response.getBest();
    }

    @Override
    public void close() {
        hopper.close();
    }
}
