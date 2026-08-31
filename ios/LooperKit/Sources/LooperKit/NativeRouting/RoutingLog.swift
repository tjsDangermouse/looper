import Foundation
import os

/// Where the on-device routing stack says what it is doing.
///
/// This exists because of a failure it would have caught in seconds. The
/// configured Overpass endpoint stopped answering — a public instance decides
/// it has heard enough from an address by dropping connections, not by
/// refusing politely — and from inside the app the only visible symptom was
/// that no routing data appeared. `RoutingAudit` was collecting exactly the
/// right numbers and showing them to nobody.
///
/// So the audit is now also written to the unified log, where it can be read
/// live from a device or a simulator:
///
/// ```console
/// xcrun simctl spawn booted log stream --predicate 'subsystem == "com.woollams.Looper"' --level info
/// log collect --device --last 10m      # from a real iPhone
/// ```
///
/// Categories are split so one question can be asked at a time: `data` for
/// acquisition, `search` for what the router did, `remote` for calls to
/// Looper's own service — which in On-device mode must produce no lines at all.
public enum RoutingLog {
    public static let subsystem = "com.woollams.Looper"

    /// Acquiring OSM data: providers, bounding boxes, bytes, chunks.
    public static let data = Logger(subsystem: subsystem, category: "routing.data")
    /// Building the graph and searching it.
    public static let search = Logger(subsystem: subsystem, category: "routing.search")
    /// Calls to Looper's own routing service. Silence here is the point in
    /// On-device mode, and silence is only meaningful if the line would
    /// otherwise have been written.
    public static let remote = Logger(subsystem: subsystem, category: "routing.remote")

    /// A bounding box, short enough to read in a log line.
    public static func box(_ bounds: GeographicBounds) -> String {
        String(format: "%.4f,%.4f,%.4f,%.4f", bounds.south, bounds.west, bounds.north, bounds.east)
    }
}
