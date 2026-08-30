package com.looper.routing;

import com.graphhopper.config.Profile;
import com.graphhopper.routing.WeightingFactory;
import com.graphhopper.routing.weighting.Weighting;
import com.graphhopper.util.CustomModel;
import com.graphhopper.util.PMap;
import com.graphhopper.util.Parameters;

/**
 * GraphHopper's own weighting factory, with one thing remembered.
 *
 * Phase 2 measured turning Looper's avoidance model into a
 * {@code CustomWeighting} at roughly 0.65 ms on a cold model and 0.22 ms on a
 * warm one — more, across the workload, than the graph search itself. Almost
 * none of that is avoidable inside GraphHopper: the compiled-class cache is
 * keyed on {@code CustomModel.toString()}, which prints every corridor vertex,
 * so building the key is itself proportional to the corridor set, and
 * {@code CustomWeightingHelper.init} builds a fresh {@code PreparedPolygon} per
 * area on a cache hit as readily as on a miss.
 *
 * What GraphHopper cannot know, and Looper does, is that the model is the same
 * one. So this factory keys on Looper's own handle instead: given
 * {@code looper.registered} in the hints it asks the registry for the weighting
 * it built last time, and only calls the delegate when there isn't one.
 *
 * <h2>Why the cached weighting is the same weighting</h2>
 * {@link com.graphhopper.routing.weighting.custom.CustomWeighting} is final and
 * every field is set in its constructor. Behind it, the Janino-compiled helper
 * sets its encoded-value and polygon fields in {@code init} and only reads them
 * while routing, and JTS documents {@code PreparedPolygon} as thread-safe and
 * immutable — its two lazy indexes are built under {@code synchronized}. None
 * of it is per-request, per-query-graph or per-thread: the request-scoped
 * things in a GraphHopper route are the {@code QueryGraph}, the {@code Snap}s
 * and the algorithm, and this is none of them. GraphHopper itself shares one
 * weighting across every landmark-preparation thread on the same grounds.
 *
 * The one thing that must not be shared is a weighting built for different
 * inputs, so anything that could feed the build and is not the model handle —
 * a heading penalty, {@code cm_version}, turn costs — declines the cache and
 * takes the ordinary path.
 */
final class LooperWeightingFactory implements WeightingFactory {

    /** The resolved {@link ModelRegistry.Registered} for this request, or absent. */
    static final String HANDLE = "looper.registered";

    /**
     * Off, this factory is the delegate and a handle buys only the bytes it
     * saves on the wire. It exists so that the payload win and the weighting
     * win can be measured apart rather than asserted together.
     */
    private static final boolean REUSE = !"false".equals(System.getProperty("looper.registry.reuse_weighting"));

    private final WeightingFactory delegate;

    LooperWeightingFactory(WeightingFactory delegate) {
        this.delegate = delegate;
    }

    @Override
    public Weighting createWeighting(Profile profile, PMap hints, boolean disableTurnCosts) {
        ModelRegistry.Registered registered = REUSE ? hints.getObject(HANDLE, null) : null;
        if (registered == null || !cacheable(profile, hints, disableTurnCosts))
            return delegate.createWeighting(profile, hints, disableTurnCosts);

        // The delegate still does the building, and it is handed exactly the
        // hints it would have been handed — including the very CustomModel the
        // request body used to carry. What is skipped is doing it twice.
        return registered.weighting(profile.getName(),
                () -> delegate.createWeighting(profile, hints, disableTurnCosts));
    }

    /**
     * Whether the built weighting depends on nothing but the profile and the
     * handle. Looper sets none of these; a caller that starts to would get the
     * uncached path rather than the wrong weighting.
     */
    private boolean cacheable(Profile profile, PMap hints, boolean disableTurnCosts) {
        if (disableTurnCosts || profile.hasTurnCosts()) return false;
        if (hints.has(Parameters.Routing.HEADING_PENALTY) || hints.has("cm_version")) return false;
        // The handle names the model, so the model on the request must be the
        // one the handle resolved to. Anything else means a caller built the
        // request by hand and the handle is stale.
        CustomModel onRequest = hints.getObject(CustomModel.KEY, null);
        return onRequest == registeredModel(hints);
    }

    private static CustomModel registeredModel(PMap hints) {
        ModelRegistry.Registered registered = hints.getObject(HANDLE, null);
        return registered == null ? null : registered.model();
    }
}
