import CryptoKit
import Foundation
import LooperKit
import MapKit
import SwiftUI
import WatchKit

struct WatchNavigationScene {
    let image: UIImage
    let projection: SnapshotProjection
    let route: [Point]
    let turn: Point

    /// Whether a position falls on the part of the picture the screen shows.
    /// The picture is larger than the screen so it can be turned without
    /// bare corners, and sits with its centre at the screen's centre; the
    /// walker is framed at the foot of that screen-sized middle, a few points
    /// from its edge, so there is no margin to ask for.
    func contains(_ position: Point) -> Bool {
        let screen = WKInterfaceDevice.current().screenBounds.size
        let width = min(screen.width, image.size.width), height = min(screen.height, image.size.height)
        let visible = CGRect(
            x: (image.size.width - width) / 2, y: (image.size.height - height) / 2, width: width, height: height
        )
        return visible.contains(projection.point(for: position))
    }
}

/// The saved half of a scene.
private struct StoredScene: Codable {
    var projection: SnapshotProjection
    var route: [Point]
    var turn: Point
    var scale: Double
}

/// Maps on disk, per route. A snapshot is a few hundred kilobytes and is cheap
/// to keep; fetching it needs the Watch's connection, which a walk shouldn't
/// depend on. A route's maps outlive the walk, so walking a saved route again
/// costs nothing. Each map is filed under a key: `t<step>` for the picture of a
/// turn, `a<metres>` for one saved partway along the route.
struct WatchMapStore {
    private let root: URL

    init(fileManager: FileManager = .default) {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Maps saved before they faced the way the route runs were framed for
        // a walker heading straight at the turn; they are dropped and fetched
        // again.
        // Maps saved at exactly the screen's size left bare corners once turned;
        // they are dropped for ones drawn larger.
        for old in ["Looper/maps", "Looper/maps2", "Looper/maps3"] {
            try? fileManager.removeItem(at: base.appendingPathComponent(old, isDirectory: true))
        }
        root = base.appendingPathComponent("Looper/maps4", isDirectory: true)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func directory(_ routeID: String) -> URL {
        let digest = SHA256.hash(data: Data(routeID.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    func save(_ scene: WatchNavigationScene, routeID: String, key: String, jpeg: Data? = nil) {
        let folder = directory(routeID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let image = jpeg ?? scene.image.jpegData(compressionQuality: 0.72),
              let meta = try? JSONEncoder().encode(StoredScene(
                  projection: scene.projection, route: scene.route, turn: scene.turn, scale: Double(scene.image.scale)
              )) else { return }
        // The picture last: a scene is only complete when its image exists.
        try? meta.write(to: folder.appendingPathComponent("\(key).json"), options: .atomic)
        try? image.write(to: folder.appendingPathComponent("\(key).jpg"), options: .atomic)
    }

    func load(routeID: String, key: String) -> WatchNavigationScene? {
        let folder = directory(routeID)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(key).jpg")),
              let metaData = try? Data(contentsOf: folder.appendingPathComponent("\(key).json")),
              let meta = try? JSONDecoder().decode(StoredScene.self, from: metaData),
              let image = UIImage(data: data, scale: CGFloat(meta.scale)) else { return nil }
        return WatchNavigationScene(image: image, projection: meta.projection, route: meta.route, turn: meta.turn)
    }

    func has(routeID: String, key: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(routeID).appendingPathComponent("\(key).jpg").path)
    }

    /// Drops every route's maps except those still wanted.
    func prune(keeping routeIDs: Set<String>) {
        let keep = Set(routeIDs.map { directory($0).lastPathComponent })
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !keep.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// One map to save: where its camera sits, and what is drawn over the picture.
struct MapJob {
    let key: String
    /// Set for the picture of a turn.
    var stepIndex: Int?
    let center: Point
    let distance: CLLocationDistance
    let heading: CLLocationDirection
    let route: [Point]
    let turn: Point
}

/// The maps behind the guidance screen.
///
/// While the Watch has a connection it asks for a fresh map as the walker
/// moves, so the map follows them. Without one it falls back to maps saved
/// beforehand: one for each turn and one every 100 m along the route, each the
/// picture the live map would have asked for from that spot. They sit on disk,
/// so a relaunch or a lost signal costs nothing, and the screen looks the same
/// either way.
///
/// The saved maps come from the iPhone: the Watch asks for the ones it is
/// missing and counts them in as they arrive, which is the progress the start
/// screen shows. If the phone stays silent the Watch downloads them itself.
@MainActor
final class WatchNavigationMapCache: ObservableObject {
    /// The picture of each turn, by step.
    @Published private(set) var scenes: [Int: WatchNavigationScene] = [:]
    @Published private(set) var liveScene: WatchNavigationScene?
    @Published private(set) var liveStepIndex: Int?
    @Published private(set) var isPreparing = false
    /// The chosen route's maps are coming from the iPhone, not being downloaded here.
    @Published private(set) var receivingFromPhone = false
    /// How many of the chosen route's maps are on the Watch, and how many it needs.
    @Published private(set) var savedCount = 0
    @Published private(set) var totalCount = 0
    /// Routes with every turn's map and the full run along the route saved.
    @Published private(set) var fullyReadyRouteIDs: Set<String> = []
    /// How much of each route's maps are on the Watch, from 0 to 1.
    @Published private(set) var savedFractions: [String: Double] = [:]
    /// The visible state of each route currently requested for offline use.
    @Published private(set) var routeTransferStates: [String: WatchRouteTransferStatusPayload.State] = [:]
    var onDiagnostic: ((String, [String: String]) -> Void)?
    var onRouteTransferStatus: ((WatchRouteTransferStatusPayload) -> Void)?
    /// Asks the iPhone for maps. Returns whether there is a phone to ask.
    var requestFromPhone: ((WatchMapRequestPayload) -> Bool)?

    private let store = WatchMapStore()
    private var plan: LoopPlanPayload?
    private var anchors: [MapAnchor] = []
    private var anchorScenes: [String: WatchNavigationScene] = [:]
    private var jobs: [MapJob] = []
    private var wantsDownload = false
    /// The saved route being filled in behind the chosen one.
    private var background: (plan: LoopPlanPayload, jobs: [MapJob])?
    private var backgroundReceived = Date.distantPast
    private var savedPlans: [LoopPlanPayload] = []
    private var lastReceived = Date.distantPast
    /// A phone that has sent nothing for this long isn't going to; the Watch
    /// downloads what is left itself.
    private static let phoneSilenceSeconds: TimeInterval = 25
    private var task: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var liveAnchor: Point?
    /// The way up on the live map last asked for.
    private var liveHeading: CLLocationDirection?
    private var requestedLiveStepIndex: Int?
    private var lastLiveAttempt = Date.distantPast
    private static let retryDelays: [UInt64] = [2, 6, 15]
    /// A failed live request is tried again no sooner than this.
    private static let liveRetrySeconds: TimeInterval = 10
    /// A walker who has turned this far from the way the live map faces gets
    /// a new one facing their way; until it arrives the old one is drawn
    /// turned, with nothing in the corners it doesn't reach.
    private static let liveTurnDegrees = 30.0

    private var routeID: String? { plan?.routeID }

    /// Makes `plan` the route on screen and loads whatever maps it already
    /// has. Its missing maps are fetched only when `download` is set — for a
    /// route being walked or one that has been saved. A route merely being
    /// looked at on the phone changes with every tap, and fetching a full set
    /// of maps for each would be work thrown away.
    func prepare(_ plan: LoopPlanPayload, download: Bool) {
        if routeID != plan.routeID {
            task?.cancel()
            liveTask?.cancel()
            self.plan = plan
            scenes = [:]
            anchorScenes = [:]
            jobs = []
            liveScene = nil
            liveStepIndex = nil
            liveAnchor = nil
            liveHeading = nil
            requestedLiveStepIndex = nil
            isPreparing = false
            receivingFromPhone = false
            savedCount = 0
            totalCount = 0
        }
        self.plan = plan
        let geometry = plan.plannedGeometry ?? []
        let maneuvers = plan.plannedManeuvers ?? []
        // A route with no turns still has the run to its finish to save.
        guard geometry.count > 1 else { return }
        anchors = mapAnchors(geometry: geometry, maneuvers: maneuvers)
        jobs = Self.jobs(geometry: geometry, maneuvers: maneuvers, anchors: anchors)

        for maneuver in maneuvers where scenes[maneuver.stepIndex] == nil {
            if let scene = store.load(routeID: plan.routeID, key: "t\(maneuver.stepIndex)") {
                scenes[maneuver.stepIndex] = scene
            }
        }
        refreshProgress()
        refreshReadiness(plan)
        wantsDownload = download
        let missing = jobs.filter { !store.has(routeID: plan.routeID, key: $0.key) }
        guard download else { return }
        if missing.isEmpty {
            publishTransferStatus(plan, state: .ready)
            return
        }
        guard !isPreparing else { return }

        isPreparing = true
        publishTransferStatus(plan, state: .receiving)
        onDiagnostic?("mapPreloadStarted", ["maps": String(missing.count), "of": String(jobs.count)])
        let planID = plan.routeID
        guard requestFromPhone?(Self.request(planID, missing)) == true else {
            task = Task { [weak self] in await self?.download(planID) }
            return
        }
        receivingFromPhone = true
        lastReceived = Date()
        task = Task { [weak self] in
            while let self, Date().timeIntervalSince(self.lastReceived) < Self.phoneSilenceSeconds {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled, self.routeID == planID else { return }
            self.receivingFromPhone = false
            self.onDiagnostic?("mapUploadStalled", ["saved": String(self.savedCount), "of": String(self.totalCount)])
            await self.download(planID)
        }
    }

    /// The iPhone has come into reach. Maps being downloaded here are handed
    /// over to it: the phone is quicker and doesn't need the Watch's own
    /// connection. Also how a launch gets its maps from the phone — the route
    /// is prepared before the link to the phone is up.
    func phoneBecameAvailable() {
        if let plan, wantsDownload, !receivingFromPhone, !fullyReadyRouteIDs.contains(plan.routeID) {
            task?.cancel()
            task = nil
            isPreparing = false
            prepare(plan, download: true)
        }
        if prefetchTask != nil { prefetch(savedPlans) }
    }

    /// Downloads whatever the route still needs over the Watch's own
    /// connection — the only way when there is no phone, and the fallback
    /// when the phone stops sending.
    private func download(_ planID: String) async {
        #if DEBUG
        // Leaves the iPhone as the only source of maps, to exercise the upload.
        if ProcessInfo.processInfo.environment["LOOPER_WATCH_NO_DOWNLOAD"] == "1" { return finishPreparing() }
        #endif
        for job in jobs where !store.has(routeID: planID, key: job.key) {
            guard !Task.isCancelled, routeID == planID else { return }
            guard let scene = await Self.fetch(job, onFailure: { [weak self] attempt, error in
                self?.logFailure("download", job.key, attempt, error)
            }) else { continue }
            guard !Task.isCancelled, routeID == planID else { return }
            store.save(scene, routeID: planID, key: job.key)
            noteSaved(job, scene)
        }
        guard !Task.isCancelled, routeID == planID else { return }
        finishPreparing()
    }

    /// A map from the iPhone. It carries only the picture and how coordinates
    /// fall on it; what is drawn over it the Watch already knows.
    func receive(mapAt url: URL, details: [String: Any]) {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let fileRoute = details["routeID"] as? String,
              let key = details["key"] as? String,
              let projectionData = details["projection"] as? Data,
              let projection = try? JSONDecoder().decode(SnapshotProjection.self, from: projectionData),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data, scale: CGFloat(details["scale"] as? Double ?? 2)) else { return }
        let chosen = fileRoute == routeID
        let known = chosen ? jobs : (background?.plan.routeID == fileRoute ? background?.jobs ?? [] : [])
        guard let job = known.first(where: { $0.key == key }) else { return }
        let scene = WatchNavigationScene(image: image, projection: projection, route: job.route, turn: job.turn)
        store.save(scene, routeID: fileRoute, key: key, jpeg: data)
        guard chosen else {
            backgroundReceived = Date()
            if let plan = background?.plan { publishTransferStatus(plan, state: .receiving) }
            return
        }
        lastReceived = Date()
        noteSaved(job, scene)
        if let plan { publishTransferStatus(plan, state: .receiving) }
        if receivingFromPhone, savedCount >= totalCount {
            task?.cancel()
            finishPreparing()
        }
    }

    private func noteSaved(_ job: MapJob, _ scene: WatchNavigationScene) {
        if let step = job.stepIndex { scenes[step] = scene }
        refreshProgress()
    }

    private func finishPreparing() {
        isPreparing = false
        receivingFromPhone = false
        task = nil
        refreshProgress()
        if let plan {
            refreshReadiness(plan)
            publishTransferStatus(plan, state: isReady(plan) ? .ready : .failed)
        }
        onDiagnostic?("mapPreloadFinished", ["saved": String(savedCount), "of": String(totalCount)])
    }

    private func refreshProgress() {
        guard let routeID else { return }
        totalCount = jobs.count
        savedCount = jobs.filter { store.has(routeID: routeID, key: $0.key) }.count
    }

    private static func request(_ routeID: String, _ missing: [MapJob]) -> WatchMapRequestPayload {
        let screen = WKInterfaceDevice.current().screenBounds.size
        return WatchMapRequestPayload(
            routeID: routeID,
            widthPoints: Double(screen.width), heightPoints: Double(screen.height),
            scale: Double(WKInterfaceDevice.current().screenScale),
            // Route order: the first map needed arrives first.
            items: missing.map {
                .init(key: $0.key, center: $0.center, distanceMeters: $0.distance, headingDegrees: $0.heading)
            }
        )
    }

    /// Every map a route needs: the picture of each turn, then the run along
    /// the route, both in the order they are walked.
    private static func jobs(geometry: [Point], maneuvers: [ManeuverPayload], anchors: [MapAnchor]) -> [MapJob] {
        let turns = maneuvers.compactMap { maneuver in
            maneuver.coordinate.map { turnJob(step: maneuver.stepIndex, turn: $0, geometry: geometry) }
        }
        let along = anchors.compactMap { anchor in
            anchor.maneuver.coordinate.map {
                liveJob(
                    key: anchor.key, position: anchor.position, turn: $0,
                    distanceToTurn: anchor.distanceToTurn, heading: anchor.courseDegrees, geometry: geometry
                )
            }
        }
        return turns + along
    }

    private static func turnJob(step: Int, turn: Point, geometry: [Point]) -> MapJob {
        let route = routeWindow(around: turn, in: geometry)
        let approach = pointBeforeTurn(70, turn: turn, route: route)
        return MapJob(
            key: "t\(step)", stepIndex: step, center: approach, distance: 600,
            heading: bearing(from: approach, to: turn), route: route, turn: turn
        )
    }

    /// Fills in every map for the saved routes that aren't the chosen one, a
    /// route at a time while the Watch is idle, so any of them can be picked
    /// and walked with the phone already left behind. The chosen route always
    /// goes first.
    func prefetch(_ plans: [LoopPlanPayload]) {
        prefetchTask?.cancel()
        savedPlans = plans
        let wanted = Set(plans.map(\.routeID))
        routeTransferStates = routeTransferStates.filter { wanted.contains($0.key) }
        savedFractions = savedFractions.filter { wanted.contains($0.key) }
        fullyReadyRouteIDs.formIntersection(wanted)
        store.prune(keeping: Set(plans.map(\.routeID)).union(routeID.map { [$0] } ?? []))
        for plan in plans {
            refreshReadiness(plan)
            publishTransferStatus(plan, state: isReady(plan) ? .ready : .queued)
        }
        let pending = plans.filter { !fullyReadyRouteIDs.contains($0.routeID) && $0.routeID != routeID }
        guard !pending.isEmpty else { return }
        prefetchTask = Task { [weak self] in
            for plan in pending {
                await self?.fill(plan)
                if Task.isCancelled { return }
            }
            self?.prefetchTask = nil
        }
    }

    /// One saved route's maps: from the iPhone while it keeps sending, then
    /// whatever is left over the Watch's own connection.
    private func fill(_ plan: LoopPlanPayload) async {
        let geometry = plan.plannedGeometry ?? []
        let maneuvers = plan.plannedManeuvers ?? []
        guard geometry.count > 1 else { return }
        let planID = plan.routeID
        let jobs = Self.jobs(
            geometry: geometry, maneuvers: maneuvers,
            anchors: mapAnchors(geometry: geometry, maneuvers: maneuvers)
        )
        publishTransferStatus(plan, state: .receiving)
        background = (plan, jobs)
        defer {
            if background?.plan.routeID == planID { background = nil }
            refreshReadiness(plan)
            publishTransferStatus(plan, state: isReady(plan) ? .ready : .failed)
        }
        func missing() -> [MapJob] { jobs.filter { !store.has(routeID: planID, key: $0.key) } }
        func pause() async { try? await Task.sleep(nanoseconds: 2_000_000_000) }

        var askPhone = true
        while askPhone {
            // The chosen route has the phone's attention until it is done.
            while isPreparing, !Task.isCancelled { await pause() }
            let need = missing()
            guard !Task.isCancelled, routeID != planID, !need.isEmpty else { return }
            guard requestFromPhone?(Self.request(planID, need)) == true else { break }
            backgroundReceived = Date()
            askPhone = false
            while !Task.isCancelled, !missing().isEmpty {
                // A newly chosen route takes the phone over; ask again after it.
                if isPreparing { askPhone = true; break }
                if Date().timeIntervalSince(backgroundReceived) >= Self.phoneSilenceSeconds { break }
                await pause()
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["LOOPER_WATCH_NO_DOWNLOAD"] == "1" { return }
        #endif
        for job in jobs where !store.has(routeID: planID, key: job.key) {
            while isPreparing, !Task.isCancelled { await pause() }
            guard !Task.isCancelled, routeID != planID else { return }
            guard let scene = await Self.fetch(job, onFailure: { [weak self] attempt, error in
                self?.logFailure("prefetch", job.key, attempt, error)
            }) else { continue }
            store.save(scene, routeID: planID, key: job.key)
            publishTransferStatus(plan, state: .receiving)
        }
    }

    /// A walk has the Watch's full attention; background downloads wait.
    func pausePrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    func release() {
        task?.cancel()
        liveTask?.cancel()
        task = nil
        liveTask = nil
        plan = nil
        anchors = []
        jobs = []
        scenes = [:]
        anchorScenes = [:]
        liveScene = nil
        liveStepIndex = nil
        liveAnchor = nil
        liveHeading = nil
        requestedLiveStepIndex = nil
        isPreparing = false
        receivingFromPhone = false
        savedCount = 0
        totalCount = 0
    }

    // MARK: Following the walker

    /// watchOS maps are static snapshots. Refresh one after meaningful
    /// movement so the basemap follows the full walk without continuously
    /// downloading and rendering a new image for every one-second fix. The
    /// map faces the way the walker is going, so one is also fetched when they
    /// turn well away from the last.
    func prepareLive(position: Point, course: Double?, next: ManeuverPayload, geometry: [Point]) {
        guard let turn = next.coordinate, geometry.count > 1 else { return }
        let heading = course.map { ($0.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
            ?? Self.bearing(from: position, to: turn)
        let turned = liveHeading.map { abs(Self.turn(from: $0, to: heading)) >= Self.liveTurnDegrees } ?? false
        if requestedLiveStepIndex == next.stepIndex,
           let liveAnchor,
           haversine(liveAnchor, position) < 60,
           !turned { return }
        guard Date().timeIntervalSince(lastLiveAttempt) >= Self.liveRetrySeconds || requestedLiveStepIndex != next.stepIndex
                || liveAnchor.map({ haversine($0, position) >= 60 }) == true else { return }

        liveTask?.cancel()
        liveAnchor = position
        liveHeading = heading
        requestedLiveStepIndex = next.stepIndex
        lastLiveAttempt = Date()
        onDiagnostic?("mapSnapshotRequested", ["kind": "live", "step": String(next.stepIndex)])
        liveTask = Task { [weak self] in
            do {
                let scene = try await Self.liveScene(
                    position: position, turn: turn, distanceToTurn: next.distanceMeters,
                    heading: heading, geometry: geometry
                )
                guard !Task.isCancelled else { return }
                self?.liveScene = scene
                self?.liveStepIndex = next.stepIndex
                self?.liveTask = nil
                self?.onDiagnostic?("mapSnapshotReady", ["kind": "live", "step": String(next.stepIndex)])
            } catch {
                guard !Task.isCancelled else { return }
                self?.liveTask = nil
                // Forgotten, so the next fix tries again rather than waiting
                // for the walker to move another 60 m with no map.
                self?.liveAnchor = nil
                self?.liveHeading = nil
                self?.onDiagnostic?("mapSnapshotFailed", [
                    "kind": "live", "step": String(next.stepIndex), "error": error.localizedDescription
                ])
            }
        }
    }

    /// The map to draw for where the walker is: the live one if it is current,
    /// else a saved one from along the route, else the picture of the turn —
    /// whichever first has the walker on it. Failing all of those, the nearest
    /// saved map even though the walker has strayed off its edge: a map with
    /// the route on it still beats none. Nil — the plain route line — only when
    /// nothing is saved near them.
    func scene(position: Point?, next: ManeuverPayload) -> WatchNavigationScene? {
        func covers(_ scene: WatchNavigationScene) -> Bool {
            position.map { scene.contains($0) } ?? true
        }
        if liveStepIndex == next.stepIndex, let live = liveScene, covers(live) { return live }
        let saved = position.map { savedScenes(near: $0, step: next.stepIndex) } ?? []
        if let scene = saved.first(where: covers) { return scene }
        if let turnScene = scenes[next.stepIndex], covers(turnScene) { return turnScene }
        return saved.first
    }

    /// The saved maps for this stretch around the walker, nearest first. The
    /// nearest is often the one just ahead, framed for a walker who has reached
    /// it; the one just passed is the picture they are actually standing on.
    private func savedScenes(near position: Point, step: Int) -> [WatchNavigationScene] {
        guard let routeID else { return [] }
        let nearby = anchors
            .filter { $0.maneuver.stepIndex == step }
            .map { (anchor: $0, distance: haversine($0.position, position)) }
            .filter { $0.distance < 150 }
            .sorted { $0.distance < $1.distance }
            .prefix(3)
        return nearby.compactMap { candidate in
            let key = candidate.anchor.key
            if let cached = anchorScenes[key] { return cached }
            guard let scene = store.load(routeID: routeID, key: key) else { return nil }
            if anchorScenes.count >= 8 { anchorScenes.removeAll(keepingCapacity: true) }
            anchorScenes[key] = scene
            return scene
        }
    }

    // MARK: Readiness

    private func refreshReadiness(_ plan: LoopPlanPayload) {
        let counts = transferCounts(plan)
        let routeReady = counts.total > 0 && counts.saved == counts.total
        savedFractions[plan.routeID] = counts.total == 0 ? 0 : Double(counts.saved) / Double(counts.total)
        if routeReady { fullyReadyRouteIDs.insert(plan.routeID) } else { fullyReadyRouteIDs.remove(plan.routeID) }
    }

    private func transferCounts(_ plan: LoopPlanPayload) -> (saved: Int, total: Int) {
        let steps = (plan.plannedManeuvers ?? []).filter { $0.coordinate != nil }.map(\.stepIndex)
        let routeAnchors = mapAnchors(geometry: plan.plannedGeometry ?? [], maneuvers: plan.plannedManeuvers ?? [])
        let keys = steps.map { "t\($0)" } + routeAnchors.map(\.key)
        let saved = keys.filter { store.has(routeID: plan.routeID, key: $0) }.count
        return (saved, keys.count)
    }

    private func publishTransferStatus(
        _ plan: LoopPlanPayload,
        state: WatchRouteTransferStatusPayload.State
    ) {
        refreshReadiness(plan)
        let counts = transferCounts(plan)
        let resolved: WatchRouteTransferStatusPayload.State = isReady(plan) ? .ready : state
        routeTransferStates[plan.routeID] = resolved
        onRouteTransferStatus?(WatchRouteTransferStatusPayload(
            routeID: plan.routeID,
            state: resolved,
            completedItems: counts.saved,
            totalItems: counts.total
        ))
    }

    /// Every map for this route is on the Watch, so it can be walked with no
    /// connection and still look the same.
    func isReady(_ plan: LoopPlanPayload) -> Bool { fullyReadyRouteIDs.contains(plan.routeID) }

    /// How much of this route's maps are on the Watch, while it is the chosen one.
    func progress(_ plan: LoopPlanPayload) -> (saved: Int, total: Int)? {
        plan.routeID == routeID && totalCount > 0 ? (savedCount, totalCount) : nil
    }

    private func logFailure(_ kind: String, _ key: String, _ attempt: Int, _ error: Error) {
        onDiagnostic?("mapSnapshotFailed", [
            "kind": kind, "map": key, "attempt": String(attempt), "error": error.localizedDescription
        ])
    }

    // MARK: Fetching

    /// One map, retried a few times: a Watch moving between its phone's
    /// connection and Wi-Fi fails a request now and then.
    private static func fetch(
        _ job: MapJob,
        onFailure: @escaping (Int, Error) -> Void
    ) async -> WatchNavigationScene? {
        for (attempt, delay) in ([0] + retryDelays).enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
            if Task.isCancelled { return nil }
            do {
                return try await makeScene(job)
            } catch {
                onFailure(attempt + 1, error)
            }
        }
        return nil
    }

    /// The picture for a walker at `position` heading for `turn`.
    private static func liveScene(
        position: Point,
        turn: Point,
        distanceToTurn: Double,
        heading: CLLocationDirection,
        geometry: [Point]
    ) async throws -> WatchNavigationScene {
        #if DEBUG
        // Simulates a Watch with no connection once its maps are saved.
        if ProcessInfo.processInfo.environment["LOOPER_WATCH_OFFLINE"] == "1" {
            throw URLError(.notConnectedToInternet)
        }
        #endif
        return try await makeScene(liveJob(
            key: "live", position: position, turn: turn, distanceToTurn: distanceToTurn,
            heading: heading, geometry: geometry
        ))
    }

    /// How the map frames a walker at `position` facing `heading`, with
    /// `turn` next. The top of the map is the way they are going: the route's
    /// own direction for a saved map, the walker's for the live one. The zoom
    /// follows the turn, so on a straight run to it the junction sits in the
    /// upper-middle of the image, not against the rounded top edge of the
    /// physical display.
    private static func liveJob(
        key: String,
        position: Point,
        turn: Point,
        distanceToTurn: Double,
        heading: CLLocationDirection,
        geometry: [Point]
    ) -> MapJob {
        let frame = framing(position: position, turn: turn, distanceToTurn: distanceToTurn, heading: heading)
        return MapJob(
            key: key, center: frame.center, distance: frame.distance, heading: heading,
            route: routeWindow(from: position, through: turn, in: geometry), turn: turn
        )
    }

    /// Where the camera sits and how far back. The picture looks ahead 60% of
    /// the way to the turn, which keeps the walker near its foot while the zoom
    /// follows the turn. Past the widest zoom that would slide the walker off
    /// the bottom, so the look-ahead stops growing there (at `lookAheadCap` of
    /// the zoom distance) and a long stretch keeps them at the same spot.
    static func framing(
        position: Point,
        turn: Point,
        distanceToTurn: Double,
        heading: CLLocationDirection,
        lookAheadCap: Double = 0.25
    ) -> (center: Point, distance: CLLocationDistance) {
        let direct = haversine(position, turn)
        let distance = min(1_000, max(180, distanceToTurn * 2.4))
        let ahead = min(direct * 0.6, distance * lookAheadCap)
        let radians = heading * Double.pi / 180
        let center = Point(
            position.lng + ahead * sin(radians) / (111_320 * cos(position.lat * Double.pi / 180)),
            position.lat + ahead * cos(radians) / 111_320
        )
        return (center, distance)
    }

    private static func makeScene(_ job: MapJob) async throws -> WatchNavigationScene {
        #if DEBUG
        // Simulator-only stand-in for Apple's tiles, to exercise saving and
        // choosing maps when the tile service isn't answering.
        if ProcessInfo.processInfo.environment["LOOPER_WATCH_FAKE_MAPS"] == "1" {
            return fakeScene(
                center: job.center, distance: job.distance, heading: job.heading, route: job.route, turn: job.turn
            )
        }
        #endif
        let rendered = try await MapSnapshotRenderer.render(
            center: job.center, distance: job.distance, heading: job.heading,
            size: WKInterfaceDevice.current().screenBounds.size,
            scale: WKInterfaceDevice.current().screenScale
        )
        return WatchNavigationScene(image: rendered.image, projection: rendered.projection, route: job.route, turn: job.turn)
    }

    #if DEBUG
    private static func fakeScene(
        center: Point, distance: CLLocationDistance, heading: CLLocationDirection, route: [Point], turn: Point
    ) -> WatchNavigationScene {
        let screen = WKInterfaceDevice.current().screenBounds.size
        let size = CGSize(
            width: screen.width * MapSnapshotRenderer.overscan, height: screen.height * MapSnapshotRenderer.overscan
        )
        let distance = distance * MapSnapshotRenderer.overscan
        let scale = WKInterfaceDevice.current().screenScale
        let pixelsPerMeter = Double(size.height) / (distance * 0.8)
        let theta = heading * Double.pi / 180
        func point(for p: Point) -> CGPoint {
            let east = (p.lng - center.lng) * 111_320 * cos(center.lat * Double.pi / 180)
            let north = (p.lat - center.lat) * 111_320
            let right = east * cos(theta) - north * sin(theta)
            let up = east * sin(theta) + north * cos(theta)
            return CGPoint(x: Double(size.width) / 2 + right * pixelsPerMeter, y: Double(size.height) / 2 - up * pixelsPerMeter)
        }
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Draw in the same top-left coordinates as the points above.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(CGColor(red: 0.16, green: 0.22, blue: 0.3, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        let metersPerLng = 111_320 * cos(center.lat * Double.pi / 180)
        // A grid every 100 m so movement between maps is visible.
        for i in -20...20 {
            let a = point(for: Point(center.lng + Double(i) * 100 / metersPerLng, center.lat - 0.01))
            let b = point(for: Point(center.lng + Double(i) * 100 / metersPerLng, center.lat + 0.01))
            let c = point(for: Point(center.lng - 0.02, center.lat + Double(i) * 100 / 111_320))
            let d = point(for: Point(center.lng + 0.02, center.lat + Double(i) * 100 / 111_320))
            context.move(to: a); context.addLine(to: b)
            context.move(to: c); context.addLine(to: d)
        }
        context.strokePath()
        let image = UIImage(cgImage: context.makeImage()!, scale: scale, orientation: .up)
        let projection = SnapshotProjection(origin: center, pointFor: point(for:))
        return WatchNavigationScene(image: image, projection: projection, route: route, turn: turn)
    }
    #endif

    /// About 260 m of approach and 100 m beyond the corner gives junction
    /// context without turning this into a whole-route overview.
    static func routeWindow(around turn: Point, in geometry: [Point]) -> [Point] {
        guard geometry.count > 1 else { return geometry }
        let pivot = geometry.indices.min {
            haversine(geometry[$0], turn) < haversine(geometry[$1], turn)
        } ?? 0
        var first = pivot
        var distance = 0.0
        while first > 0, distance < 260 {
            distance += haversine(geometry[first], geometry[first - 1])
            first -= 1
        }
        var last = pivot
        distance = 0
        while last < geometry.count - 1, distance < 100 {
            distance += haversine(geometry[last], geometry[last + 1])
            last += 1
        }
        return Array(geometry[first...last])
    }

    /// The route still ahead of the live fix, through the next junction and
    /// briefly beyond it. A closed loop can legitimately wrap past the end
    /// of its geometry, so that case joins the tail and head without ever
    /// switching to a whole-route overview. Heading for the finish, the line
    /// stops there: running on into the loop's start would read as more walk.
    static func routeWindow(from position: Point, through turn: Point, in geometry: [Point]) -> [Point] {
        guard geometry.count > 1 else { return [position, turn] }
        let toFinish = turn == geometry.last
        var start = geometry.indices.min {
            haversine(geometry[$0], position) < haversine(geometry[$1], position)
        } ?? 0
        // Beside the finish of a closed loop the nearest vertex can be the
        // start, which sits on the same spot; that is the end, not the loop.
        if toFinish, let end = geometry.last, haversine(geometry[start], end) < 1 {
            start = geometry.count - 1
        }
        let pivot = toFinish ? geometry.count - 1 : geometry.indices.min {
            haversine(geometry[$0], turn) < haversine(geometry[$1], turn)
        } ?? start

        var result: [Point]
        if start <= pivot {
            result = Array(geometry[start...pivot])
        } else {
            result = Array(geometry[start...]) + Array(geometry[...pivot])
        }

        var distance = toFinish ? .infinity : 0.0
        var index = pivot
        while distance < 100, index < geometry.count - 1 {
            distance += haversine(geometry[index], geometry[index + 1])
            index += 1
            result.append(geometry[index])
        }
        // The live fix normally lies between two geometry vertices. Keep the
        // exact point at the head of the window so both the route line and
        // the vector fallback move continuously rather than waiting for the
        // nearest vertex to change.
        if result.first.map({ haversine($0, position) > 0.5 }) ?? true {
            result.insert(position, at: 0)
        } else {
            result[0] = position
        }
        return result.count > 1 ? result : [position, turn]
    }

    static func pointBeforeTurn(_ metres: Double, turn: Point, route: [Point]) -> Point {
        guard route.count > 1 else { return turn }
        let pivot = route.indices.min {
            haversine(route[$0], turn) < haversine(route[$1], turn)
        } ?? route.count - 1
        var remaining = metres
        var index = pivot
        while index > 0 {
            let segment = haversine(route[index - 1], route[index])
            if segment >= remaining, segment > 0 {
                let fraction = remaining / segment
                return Point(
                    route[index].lng + (route[index - 1].lng - route[index].lng) * fraction,
                    route[index].lat + (route[index - 1].lat - route[index].lat) * fraction
                )
            }
            remaining -= segment
            index -= 1
        }
        return route[0]
    }

    static func bearing(from: Point, to: Point) -> CLLocationDirection {
        let radians = Double.pi / 180
        let lat1 = from.lat * radians, lat2 = to.lat * radians
        let delta = (to.lng - from.lng) * radians
        let y = sin(delta) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(delta)
        return (atan2(y, x) / radians + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The shorter way round from one direction to another, in degrees:
    /// positive clockwise, never more than half a turn.
    static func turn(from: Double, to: Double) -> Double {
        let delta = (to - from).truncatingRemainder(dividingBy: 360)
        return delta > 180 ? delta - 360 : (delta < -180 ? delta + 360 : delta)
    }
}

extension Point {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
