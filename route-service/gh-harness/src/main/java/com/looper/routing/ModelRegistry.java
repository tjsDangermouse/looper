package com.looper.routing;

import com.graphhopper.json.Statement;
import com.graphhopper.routing.weighting.Weighting;
import com.graphhopper.util.CustomModel;
import com.graphhopper.util.JsonFeature;
import com.graphhopper.util.JsonFeatureCollection;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Supplier;

/**
 * Somewhere for Looper to leave a corridor, so it does not have to describe one
 * again on every call.
 *
 * The registry holds nothing GraphHopper would not otherwise be handed. It
 * holds the same {@link CustomModel} the request body used to carry, built from
 * the same GeoJSON by the same Jackson module, and — once GraphHopper has built
 * a {@link Weighting} from it — that weighting too, so the second call under a
 * corridor set does not recompile a class and re-prepare polygons that have not
 * changed.
 *
 * <h2>Scope</h2>
 * Everything is owned by a generation: one {@code POST /v1/loops}, one
 * generation, and {@code DELETE} at the end of it drops every corridor that
 * request drew. Nothing here grows without a bound even if a client never says
 * goodbye — {@link #begin} evicts generations older than the idle timeout and
 * trims the oldest when there are too many.
 *
 * <h2>Concurrency</h2>
 * A generation is shared by all six of a request's in-flight legs. Everything
 * reachable from a registered model is immutable once published, so the only
 * synchronisation needed is the map's own, plus the single-flight that
 * {@code computeIfAbsent} gives the weighting build.
 *
 * <h2>Failure</h2>
 * A handle that is not known is an error and never a fallback: routing under a
 * different custom model than the caller asked for would be a wrong walk
 * returned as a right one.
 */
public final class ModelRegistry {

    /** An unknown, expired or already-released handle. Answered as 400, never routed around. */
    public static final class UnknownHandle extends IllegalArgumentException {
        UnknownHandle(String message) { super(message); }
    }

    /** One custom model, plus whatever GraphHopper has already built from it. */
    public static final class Registered {
        final Generation owner;
        final CustomModel model;
        /** Keyed by profile: one profile today, but a weighting is only valid for the one it was built for. */
        private final Map<String, Weighting> weightings = new ConcurrentHashMap<>();

        Registered(Generation owner, CustomModel model) { this.owner = owner; this.model = model; }

        public CustomModel model() { return model; }

        /**
         * The weighting for this model, built once.
         *
         * {@code computeIfAbsent} is the single-flight: two legs arriving
         * together on a new corridor set compile the class once between them.
         */
        public Weighting weighting(String profile, Supplier<Weighting> build) {
            return weightings.computeIfAbsent(profile, key -> {
                Weighting built = build.get();
                owner.weightingBuilds.incrementAndGet();
                return built;
            });
        }

        public boolean hasWeighting(String profile) { return weightings.containsKey(profile); }
    }

    /** One {@code generateLoops} request's worth of corridors and models. */
    public static final class Generation {
        public final String id;
        volatile long touchedAtNanos;
        final Map<String, JsonFeature> areas = new ConcurrentHashMap<>();
        final Map<String, Registered> models = new ConcurrentHashMap<>();
        final AtomicLong areaRegistrations = new AtomicLong();
        final AtomicLong modelRegistrations = new AtomicLong();
        final AtomicLong modelReferences = new AtomicLong();
        final AtomicLong weightingBuilds = new AtomicLong();

        Generation(String id) { this.id = id; this.touchedAtNanos = System.nanoTime(); }

        /**
         * Remember one corridor polygon under the caller's own content hash.
         *
         * Idempotent on purpose: two legs can reach the same new corridor at
         * the same moment, and both will have carried the geometry. The first
         * one wins and the second costs a map lookup.
         */
        public void putArea(String areaId, JsonFeature feature) {
            if (areas.putIfAbsent(areaId, feature) == null) areaRegistrations.incrementAndGet();
        }

        public Registered model(String modelId) {
            Registered registered = models.get(modelId);
            if (registered == null)
                throw new UnknownHandle("unknown model handle '" + modelId + "' in generation '" + id + "'");
            modelReferences.incrementAndGet();
            return registered;
        }

        /**
         * Build the model this handle names, or return the one already built.
         *
         * The areas are named {@code looper_avoid_<n>} in the order the caller
         * listed them and the condition names all of them in one statement,
         * which is exactly the model the request body used to carry — see
         * {@code src/loops/avoidance.ts}. The geometry objects are the ones
         * already parsed for {@link #putArea}, so a corridor set used at both
         * avoidance strengths parses its polygons once.
         */
        public Registered define(String modelId, List<String> areaIds, String multiplyBy, Double distanceInfluence) {
            Registered existing = models.get(modelId);
            if (existing != null) { modelReferences.incrementAndGet(); return existing; }

            CustomModel model = new CustomModel();
            if (areaIds != null && !areaIds.isEmpty()) {
                if (multiplyBy == null || multiplyBy.isEmpty())
                    throw new IllegalArgumentException("a model with areas must state its multiply_by");
                JsonFeatureCollection collection = new JsonFeatureCollection();
                List<String> conditions = new ArrayList<>(areaIds.size());
                for (int i = 0; i < areaIds.size(); i++) {
                    JsonFeature stored = areas.get(areaIds.get(i));
                    if (stored == null)
                        throw new UnknownHandle("unknown area handle '" + areaIds.get(i) + "' in generation '" + id + "'");
                    String name = "looper_avoid_" + i;
                    collection.getFeatures().add(new JsonFeature(name, "Feature", null, stored.getGeometry(),
                            stored.getProperties() == null ? Map.of() : stored.getProperties()));
                    conditions.add("in_" + name);
                }
                model.setAreas(collection);
                model.addToPriority(Statement.If(String.join(" || ", conditions), Statement.Op.MULTIPLY, multiplyBy));
            }
            if (distanceInfluence != null) model.setDistanceInfluence(distanceInfluence);

            Registered created = new Registered(this, model);
            Registered raced = models.putIfAbsent(modelId, created);
            if (raced != null) { modelReferences.incrementAndGet(); return raced; }
            modelRegistrations.incrementAndGet();
            modelReferences.incrementAndGet();
            return created;
        }

        public Map<String, Object> stats() {
            return Map.of(
                    "areas", areas.size(),
                    "models", models.size(),
                    "areaRegistrations", areaRegistrations.get(),
                    "modelRegistrations", modelRegistrations.get(),
                    "modelReferences", modelReferences.get(),
                    "weightingBuilds", weightingBuilds.get());
        }
    }

    private final ConcurrentHashMap<String, Generation> generations = new ConcurrentHashMap<>();
    private final int maxGenerations;
    private final long idleTimeoutNanos;

    public ModelRegistry() {
        this(Integer.getInteger("looper.registry.max_generations", 64),
                Long.getLong("looper.registry.idle_timeout_ms", 300_000L));
    }

    public ModelRegistry(int maxGenerations, long idleTimeoutMillis) {
        this.maxGenerations = maxGenerations;
        this.idleTimeoutNanos = idleTimeoutMillis * 1_000_000L;
    }

    /**
     * Open a scope. The id is minted here rather than accepted from the caller
     * so that two callers cannot collide on one, and so that "unknown
     * generation" stays a real answer rather than an accident of naming.
     */
    public Generation begin() {
        sweep();
        Generation generation = new Generation(UUID.randomUUID().toString());
        generations.put(generation.id, generation);
        return generation;
    }

    public Generation get(String id) {
        Generation generation = generations.get(id);
        if (generation == null) throw new UnknownHandle("unknown generation handle '" + id + "'");
        generation.touchedAtNanos = System.nanoTime();
        return generation;
    }

    /**
     * Drop a scope and everything in it.
     *
     * A leg still in flight keeps working: it is holding the model and the
     * weighting already. A leg that arrives afterwards is told the handle is
     * gone, which is the honest answer.
     */
    public Generation end(String id) {
        return generations.remove(id);
    }

    public int size() { return generations.size(); }

    /** Nothing here outlives a request that never said goodbye. */
    private void sweep() {
        long now = System.nanoTime();
        generations.values().removeIf(generation -> now - generation.touchedAtNanos > idleTimeoutNanos);
        while (generations.size() >= maxGenerations) {
            Generation oldest = generations.values().stream()
                    .min((a, b) -> Long.compare(a.touchedAtNanos, b.touchedAtNanos)).orElse(null);
            if (oldest == null) return;
            generations.remove(oldest.id);
        }
    }
}
