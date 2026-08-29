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
import com.graphhopper.util.CustomModel;
import com.graphhopper.util.PMap;
import com.graphhopper.util.shapes.GHPoint;

import java.io.File;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

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

        GraphHopper hopper = new GraphHopper();
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

    public ResponsePath best(GHResponse response) {
        return response.getBest();
    }

    @Override
    public void close() {
        hopper.close();
    }
}
