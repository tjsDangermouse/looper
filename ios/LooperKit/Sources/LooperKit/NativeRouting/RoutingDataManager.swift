import Foundation

/// Getting the right routing data onto the phone, and no more than that.
///
/// The whole architecture rests on this being small: a 5 km walk from Douglas
/// must cost a download measured in a few hundred kilobytes of the streets
/// around Douglas, not a regional or national extract. So the work here is
/// arithmetic before it is networking — decide exactly which chunks the walk
/// could possibly need, subtract the ones already stored, and fetch only what
/// is left.
///
/// The one judgement call is how to ask for what is left. A route needing five
/// missing chunks could be five requests, which is rude to a volunteer-run
/// endpoint and slow besides; or one request over their bounding box, which
/// re-downloads whatever cached chunks sit inside it. So adjacent missing
/// chunks are grouped into rectangles, and a rectangle is only used when it is
/// mostly missing.
public actor RoutingDataManager {
    public struct Coverage: Sendable, Equatable {
        public var requiredChunks: [RoutingChunkID]
        public var cachedChunks: [RoutingChunkID]
        public var missingChunks: [RoutingChunkID]
        public var requiredRadiusMetres: Double
        public var bounds: GeographicBounds

        public var isComplete: Bool { missingChunks.isEmpty }
    }

    /// What one acquisition actually did. Reported so the download audit can
    /// be read off a real request rather than estimated.
    public struct AcquisitionReport: Sendable, Equatable {
        public var coverage: Coverage
        public var overpassRequests: Int
        public var downloadedBytes: Int
        public var waysReceived: Int
        public var nodesReceived: Int
        public var chunksPopulated: Int
        public var storedBytes: Int
        public var durationMs: Double
    }

    /// Progress for the "Downloading walking paths for this area…" state.
    public struct Progress: Sendable, Equatable {
        public var completedRequests: Int
        public var totalRequests: Int
        public var downloadedBytes: Int
    }

    public enum AcquisitionError: Error, LocalizedError, Equatable {
        /// Local mode, data absent, and no way to fetch it. Deliberately its
        /// own case: the app must say so rather than quietly falling back to
        /// the remote router, because a comparison test in which the engine
        /// silently changes is not a comparison.
        case dataUnavailableOffline
        case source(RoutingDataSourceError)

        public var errorDescription: String? {
            switch self {
            case .dataUnavailableOffline:
                return "Routing data for this area isn’t available offline yet. Connect to download it, or switch to Remote routing."
            case .source(let error):
                return error.errorDescription
            }
        }
    }

    /// A rectangle is only worth one request when it is at least this much
    /// missing. Below it, the request would spend most of its bytes on chunks
    /// already stored.
    static let minimumRequestFill = 0.6
    /// A ceiling on one Overpass request, so a very large offline-area
    /// download becomes several polite requests rather than one enormous one.
    static let maximumChunksPerRequest = 48

    private let store: RoutingChunkStore
    private let source: RoutingDataSource
    private let grid: RoutingChunkGrid
    private let audit: RoutingAudit?

    public init(
        store: RoutingChunkStore,
        source: RoutingDataSource,
        grid: RoutingChunkGrid = .standard,
        audit: RoutingAudit? = .shared
    ) {
        self.store = store
        self.source = source
        self.grid = grid
        self.audit = audit
    }

    // MARK: - Coverage

    public func coverage(lat: Double, lon: Double, targetMetres: Double) async -> Coverage {
        let bounds = RoutingCoverage.requiredBounds(lat: lat, lon: lon, targetMetres: targetMetres)
        let required = grid.chunks(covering: bounds)
        let missing = await store.missing(from: required)
        let missingSet = Set(missing)
        return Coverage(
            requiredChunks: required,
            cachedChunks: required.filter { !missingSet.contains($0) },
            missingChunks: missing,
            requiredRadiusMetres: RoutingCoverage.explorationRadiusMetres(targetMetres: targetMetres),
            bounds: bounds
        )
    }

    /// Make sure the data for this walk is on the phone, fetching what is
    /// missing when that is allowed.
    ///
    /// `allowDownload: false` is the offline case and the honest one: it
    /// throws rather than routing on a partial graph, because a loop searched
    /// over half a town is not a shorter answer, it is a wrong one.
    @discardableResult
    public func ensureCoverage(
        lat: Double,
        lon: Double,
        targetMetres: Double,
        retention: RoutingChunkStore.Retention = .automatic,
        allowDownload: Bool = true,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> AcquisitionReport {
        let began = Date()
        var coverage = await coverage(lat: lat, lon: lon, targetMetres: targetMetres)
        guard !coverage.isComplete else {
            return AcquisitionReport(
                coverage: coverage, overpassRequests: 0, downloadedBytes: 0, waysReceived: 0,
                nodesReceived: 0, chunksPopulated: 0, storedBytes: 0,
                durationMs: Date().timeIntervalSince(began) * 1000
            )
        }
        guard allowDownload else {
            RoutingLog.data.notice("coverage refused: offline and \(coverage.missingChunks.count) chunk(s) missing")
            throw AcquisitionError.dataUnavailableOffline
        }

        let groups = RoutingDataManager.groups(for: coverage.missingChunks)
        RoutingLog.data.info("coverage target=\(Int(targetMetres))m radius=\(Int(coverage.requiredRadiusMetres))m required=\(coverage.requiredChunks.count) cached=\(coverage.cachedChunks.count) missing=\(coverage.missingChunks.count) requests=\(groups.count)")
        var requests = 0, downloadedBytes = 0, ways = 0, nodes = 0, populated = 0, storedBytes = 0
        onProgress?(Progress(completedRequests: 0, totalRequests: groups.count, downloadedBytes: 0))

        for group in groups {
            let bounds = RoutingDataManager.bounds(of: group)
            let data: OSMData
            do {
                data = try await source.fetchArea(bounds)
            } catch let error as RoutingDataSourceError {
                RoutingLog.data.error("coverage failed reason=\(error.terseReason, privacy: .public)")
                throw AcquisitionError.source(error)
            }
            requests += 1
            ways += data.ways.count
            nodes += data.nodes.count
            downloadedBytes += RoutingDataManager.approximateBytes(of: data)

            for (id, chunkData) in split(data, into: group) {
                if let entry = await store.save(chunkData, for: id, retention: retention) {
                    populated += 1
                    storedBytes += entry.byteSize
                } else {
                    RoutingLog.data.error("chunk \(id.key, privacy: .public) could not be written")
                }
            }
            onProgress?(Progress(completedRequests: requests, totalRequests: groups.count, downloadedBytes: downloadedBytes))
        }

        RoutingLog.data.info("coverage done requests=\(requests) ways=\(ways) nodes=\(nodes) chunksPopulated=\(populated) storedBytes=\(storedBytes) ms=\(Int(Date().timeIntervalSince(began) * 1000))")
        await audit?.recordChunksPopulated(populated)
        await store.evictIfNeeded()
        coverage = await self.coverage(lat: lat, lon: lon, targetMetres: targetMetres)
        return AcquisitionReport(
            coverage: coverage,
            overpassRequests: requests,
            downloadedBytes: downloadedBytes,
            waysReceived: ways,
            nodesReceived: nodes,
            chunksPopulated: populated,
            storedBytes: storedBytes,
            durationMs: Date().timeIntervalSince(began) * 1000
        )
    }

    /// The graph data for a walk, read from the store. No network, ever: by
    /// the time this is called the data is either present or the request has
    /// already failed with `dataUnavailableOffline`.
    public func storedData(lat: Double, lon: Double, targetMetres: Double) async -> OSMData {
        let bounds = RoutingCoverage.requiredBounds(lat: lat, lon: lon, targetMetres: targetMetres)
        return await store.merged(grid.chunks(covering: bounds))
    }

    /// Fill and pin an area for offline use. The future Offline Areas screen
    /// is this method and a rectangle on a map; nothing below it changes,
    /// which is the point of the retention flag existing before the UI does.
    @discardableResult
    public func downloadOfflineArea(
        _ bounds: GeographicBounds,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> AcquisitionReport {
        let began = Date()
        let required = grid.chunks(covering: bounds)
        let missing = await store.missing(from: required)
        let groups = RoutingDataManager.groups(for: missing)
        var requests = 0, downloadedBytes = 0, ways = 0, nodes = 0, populated = 0, storedBytes = 0

        for group in groups {
            let data: OSMData
            do {
                data = try await source.fetchArea(RoutingDataManager.bounds(of: group))
            } catch let error as RoutingDataSourceError {
                throw AcquisitionError.source(error)
            }
            requests += 1
            ways += data.ways.count
            nodes += data.nodes.count
            downloadedBytes += RoutingDataManager.approximateBytes(of: data)
            for (id, chunkData) in split(data, into: group) {
                if let entry = await store.save(chunkData, for: id, retention: .pinned) {
                    populated += 1
                    storedBytes += entry.byteSize
                }
            }
            onProgress?(Progress(completedRequests: requests, totalRequests: groups.count, downloadedBytes: downloadedBytes))
        }
        // Chunks already present before this call are pinned too: the walker
        // asked for the area, not for the part of it they happened not to
        // have visited yet.
        await store.pin(required)
        let remaining = await store.missing(from: required)
        let missingSet = Set(remaining)
        return AcquisitionReport(
            coverage: Coverage(
                requiredChunks: required,
                cachedChunks: required.filter { !missingSet.contains($0) },
                missingChunks: remaining,
                requiredRadiusMetres: 0,
                bounds: bounds
            ),
            overpassRequests: requests,
            downloadedBytes: downloadedBytes,
            waysReceived: ways,
            nodesReceived: nodes,
            chunksPopulated: populated,
            storedBytes: storedBytes,
            durationMs: Date().timeIntervalSince(began) * 1000
        )
    }

    // MARK: - Splitting a response into chunks

    /// File one response into the chunks it was fetched for.
    ///
    /// Each chunk gets every way with at least one node inside it, *and every
    /// node those ways reference* — including nodes belonging to neighbouring
    /// chunks. That halo is what makes a chunk self-contained: a lane crossing
    /// the boundary can be drawn to its far junction from either side, so
    /// loading one chunk never invents a dead end, and loading both produces
    /// one continuous way rather than two stubs meeting at a seam.
    func split(_ data: OSMData, into chunks: [RoutingChunkID]) -> [(RoutingChunkID, OSMData)] {
        guard !chunks.isEmpty else { return [] }
        var nodeByID: [Int64: OSMNode] = [:]
        nodeByID.reserveCapacity(data.nodes.count)
        for node in data.nodes { nodeByID[node.id] = node }

        let wanted = Set(chunks)
        var waysByChunk: [RoutingChunkID: [OSMWay]] = [:]
        var nodeIDsByChunk: [RoutingChunkID: Set<Int64>] = [:]

        for way in data.ways {
            var touched: Set<RoutingChunkID> = []
            for id in way.nodes {
                guard let node = nodeByID[id] else { continue }
                let chunk = grid.chunk(lat: node.lat, lon: node.lon)
                if wanted.contains(chunk) { touched.insert(chunk) }
            }
            guard !touched.isEmpty else { continue }
            for chunk in touched {
                waysByChunk[chunk, default: []].append(way)
                nodeIDsByChunk[chunk, default: []].formUnion(way.nodes)
            }
        }

        // Every requested chunk is written, including one with nothing in it:
        // an empty chunk is a fact about the world (open sea, moorland with no
        // mapped paths) and recording it stops the same fruitless request being
        // made again on every walk from that beach.
        return chunks.map { chunk in
            let ids = nodeIDsByChunk[chunk] ?? []
            let nodes = ids.compactMap { nodeByID[$0] }
            return (chunk, OSMData(nodes: nodes, ways: waysByChunk[chunk] ?? []))
        }
    }

    // MARK: - Request grouping

    /// The bounding box of a set of chunks.
    static func bounds(of chunks: [RoutingChunkID]) -> GeographicBounds {
        var box = chunks[0].bounds
        for chunk in chunks.dropFirst() { box = box.union(chunk.bounds) }
        return box
    }

    /// Adjacent missing chunks, gathered into as few rectangles as are worth
    /// asking for.
    ///
    /// Connected components first, so two clusters either side of a cached
    /// town centre stay two requests rather than one request that re-fetches
    /// the middle. Then each component is used whole if its bounding box is
    /// mostly missing, and split down its longer axis if it is not — a
    /// diagonal string of chunks would otherwise ask for the whole square it
    /// spans.
    static func groups(
        for missing: [RoutingChunkID],
        minimumFill: Double = RoutingDataManager.minimumRequestFill,
        maximumChunks: Int = RoutingDataManager.maximumChunksPerRequest
    ) -> [[RoutingChunkID]] {
        guard !missing.isEmpty else { return [] }
        var groups: [[RoutingChunkID]] = []
        for component in components(of: missing) {
            split(component, minimumFill: minimumFill, maximumChunks: maximumChunks, into: &groups)
        }
        return groups
    }

    private static func components(of chunks: [RoutingChunkID]) -> [[RoutingChunkID]] {
        var remaining = Set(chunks)
        var out: [[RoutingChunkID]] = []
        while let seed = remaining.first {
            var component: [RoutingChunkID] = []
            var queue = [seed]
            remaining.remove(seed)
            while let current = queue.popLast() {
                component.append(current)
                for neighbour in [
                    RoutingChunkID(z: current.z, x: current.x + 1, y: current.y),
                    RoutingChunkID(z: current.z, x: current.x - 1, y: current.y),
                    RoutingChunkID(z: current.z, x: current.x, y: current.y + 1),
                    RoutingChunkID(z: current.z, x: current.x, y: current.y - 1),
                ] where remaining.contains(neighbour) {
                    remaining.remove(neighbour)
                    queue.append(neighbour)
                }
            }
            out.append(component.sorted())
        }
        return out
    }

    private static func split(
        _ chunks: [RoutingChunkID],
        minimumFill: Double,
        maximumChunks: Int,
        into groups: inout [[RoutingChunkID]]
    ) {
        guard chunks.count > 1 else {
            groups.append(chunks)
            return
        }
        let minX = chunks.map(\.x).min()!, maxX = chunks.map(\.x).max()!
        let minY = chunks.map(\.y).min()!, maxY = chunks.map(\.y).max()!
        let cells = (maxX - minX + 1) * (maxY - minY + 1)
        let fill = Double(chunks.count) / Double(cells)
        if fill >= minimumFill && chunks.count <= maximumChunks && cells <= maximumChunks {
            groups.append(chunks)
            return
        }
        let splitOnX = (maxX - minX) >= (maxY - minY)
        let pivot = splitOnX ? (minX + maxX) / 2 : (minY + maxY) / 2
        let low = chunks.filter { (splitOnX ? $0.x : $0.y) <= pivot }
        let high = chunks.filter { (splitOnX ? $0.x : $0.y) > pivot }
        // A split that separates nothing would recurse forever; take the group
        // as it stands instead.
        guard !low.isEmpty, !high.isEmpty else {
            groups.append(chunks)
            return
        }
        split(low, minimumFill: minimumFill, maximumChunks: maximumChunks, into: &groups)
        split(high, minimumFill: minimumFill, maximumChunks: maximumChunks, into: &groups)
    }

    /// A stand-in for "how much came over the wire", since the parsed form is
    /// what this layer sees. Close enough for the audit's purpose, which is
    /// orders of magnitude rather than exact accounting.
    static func approximateBytes(of data: OSMData) -> Int {
        RoutingChunkCodec.encode(data).count
    }
}
