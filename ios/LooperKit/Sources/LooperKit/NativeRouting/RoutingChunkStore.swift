import Foundation

/// The routing data the phone owns.
///
/// This is the single place routing data lives, and it is deliberately
/// indifferent to how the data got here. A chunk fetched automatically because
/// somebody asked for a 5 km loop and a chunk fetched because somebody chose
/// "make this town available offline" are the same object in the same store,
/// differing in exactly one field: `Retention`. That is the whole of what the
/// future Offline Areas feature needs from this layer — it will populate and
/// pin this store, and the router will not be able to tell the difference,
/// because there is no difference to tell.
///
/// Concurrency: an actor, because a route request reads chunks while a
/// download writes them, and the index they share is small enough that
/// serialising access costs nothing measurable.
public actor RoutingChunkStore {
    /// Whether a chunk may be evicted to reclaim space.
    public enum Retention: String, Codable, Sendable {
        /// Fetched because a route needed it. May be evicted when cold.
        case automatic
        /// Fetched because the walker asked for this area offline. Never
        /// evicted automatically; only an explicit unpin or delete removes it.
        case pinned
    }

    /// What the store knows about one chunk without reading it.
    public struct ChunkMetadata: Codable, Equatable, Sendable {
        public var id: RoutingChunkID
        /// The format/policy generation this chunk was written under. A chunk
        /// from an older generation is refetched rather than migrated.
        public var dataVersion: Int
        public var downloadedAt: Date
        public var lastUsedAt: Date
        public var byteSize: Int
        public var retention: Retention
        /// Counts, kept for the download audit rather than for routing.
        public var nodeCount: Int
        public var wayCount: Int
    }

    /// The generation of the stored form. Bumped when the codec or the set of
    /// retained tags changes in a way that makes older chunks wrong rather
    /// than merely older.
    public static let currentDataVersion = 1

    /// How much automatically-acquired data the store keeps before evicting
    /// the coldest chunks. Pinned chunks are not counted against it and are
    /// never evicted by it.
    public static let defaultAutomaticByteBudget = 192 * 1024 * 1024

    private let directory: URL
    private let fileManager: FileManager
    private let automaticByteBudget: Int
    private var index: [RoutingChunkID: ChunkMetadata] = [:]
    private var indexLoaded = false
    /// A small read-through cache: consecutive route requests from the same
    /// spot want the same two dozen chunks, and decoding them again each time
    /// is the single largest avoidable cost in a warm request.
    private var memory: [RoutingChunkID: OSMData] = [:]
    private var memoryOrder: [RoutingChunkID] = []
    private let memoryLimit = 64

    public init(
        directory: URL,
        fileManager: FileManager = .default,
        automaticByteBudget: Int = RoutingChunkStore.defaultAutomaticByteBudget
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.automaticByteBudget = automaticByteBudget
    }

    /// The store the app uses: Application Support, excluded from iCloud
    /// backup because it is a cache of public data that can always be fetched
    /// again, and backing up a few hundred megabytes of it would be rude.
    public static func applicationDefault() -> RoutingChunkStore {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return RoutingChunkStore(directory: base.appendingPathComponent("RoutingChunks", isDirectory: true))
    }

    // MARK: - Reading

    public func metadata(for id: RoutingChunkID) -> ChunkMetadata? {
        loadIndexIfNeeded()
        return index[id]
    }

    public func allMetadata() -> [ChunkMetadata] {
        loadIndexIfNeeded()
        return index.values.sorted { $0.id < $1.id }
    }

    /// Present, current, and readable. Anything else is missing, and missing
    /// is always safe: it means "fetch it".
    public func contains(_ id: RoutingChunkID) -> Bool {
        loadIndexIfNeeded()
        guard let entry = index[id], entry.dataVersion == RoutingChunkStore.currentDataVersion else { return false }
        return fileManager.fileExists(atPath: url(for: id).path)
    }

    /// Which of these the store does not have. The order of `ids` is kept, so
    /// grouping downstream stays deterministic.
    public func missing(from ids: [RoutingChunkID]) -> [RoutingChunkID] {
        ids.filter { !contains($0) }
    }

    /// Read a chunk, touching its last-used date. Returns nil when absent or
    /// unreadable; an unreadable chunk is dropped from the index so the next
    /// request fetches it cleanly rather than failing the same way forever.
    public func chunk(_ id: RoutingChunkID) -> OSMData? {
        loadIndexIfNeeded()
        guard index[id]?.dataVersion == RoutingChunkStore.currentDataVersion else { return nil }
        if let cached = memory[id] {
            touch(id)
            return cached
        }
        guard let raw = try? Data(contentsOf: url(for: id)), let decoded = try? RoutingChunkCodec.decode(raw) else {
            index[id] = nil
            try? fileManager.removeItem(at: url(for: id))
            saveIndex()
            return nil
        }
        remember(id, decoded)
        touch(id)
        return decoded
    }

    /// Every requested chunk the store holds, merged. Chunks overlap at their
    /// boundaries by design, so the merge deduplicates by OSM id — which is
    /// also what makes a way crossing a chunk boundary come back as one way
    /// rather than two.
    public func merged(_ ids: [RoutingChunkID]) -> OSMData {
        OSMData.merged(ids.compactMap { chunk($0) })
    }

    // MARK: - Writing

    @discardableResult
    public func save(_ data: OSMData, for id: RoutingChunkID, retention: Retention = .automatic) -> ChunkMetadata? {
        loadIndexIfNeeded()
        let encoded = RoutingChunkCodec.encode(data)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoded.write(to: url(for: id), options: .atomic)
        } catch {
            return nil
        }
        // A pinned chunk that is refreshed stays pinned: an automatic refetch
        // must never silently downgrade an area somebody chose to keep.
        let existing = index[id]
        let entry = ChunkMetadata(
            id: id,
            dataVersion: RoutingChunkStore.currentDataVersion,
            downloadedAt: Date(),
            lastUsedAt: Date(),
            byteSize: encoded.count,
            retention: existing?.retention == .pinned ? .pinned : retention,
            nodeCount: data.nodes.count,
            wayCount: data.ways.count
        )
        index[id] = entry
        remember(id, data)
        saveIndex()
        return entry
    }

    /// Mark chunks as the walker's to keep. The future Offline Areas feature
    /// is this call plus a map rectangle; nothing else in the stack changes.
    public func pin(_ ids: [RoutingChunkID]) {
        loadIndexIfNeeded()
        for id in ids where index[id] != nil { index[id]?.retention = .pinned }
        saveIndex()
    }

    public func unpin(_ ids: [RoutingChunkID]) {
        loadIndexIfNeeded()
        for id in ids where index[id] != nil { index[id]?.retention = .automatic }
        saveIndex()
    }

    public func remove(_ ids: [RoutingChunkID]) {
        loadIndexIfNeeded()
        for id in ids {
            try? fileManager.removeItem(at: url(for: id))
            index[id] = nil
            memory[id] = nil
            memoryOrder.removeAll { $0 == id }
        }
        saveIndex()
    }

    public func removeAll() {
        try? fileManager.removeItem(at: directory)
        index = [:]
        memory = [:]
        memoryOrder = []
        indexLoaded = true
        saveIndex()
    }

    // MARK: - Eviction

    public func automaticBytes() -> Int {
        loadIndexIfNeeded()
        return index.values.filter { $0.retention == .automatic }.reduce(0) { $0 + $1.byteSize }
    }

    public func pinnedBytes() -> Int {
        loadIndexIfNeeded()
        return index.values.filter { $0.retention == .pinned }.reduce(0) { $0 + $1.byteSize }
    }

    /// Drop the coldest automatic chunks until the automatic total is inside
    /// the budget. Pinned chunks are not candidates and are not counted.
    @discardableResult
    public func evictIfNeeded(budget: Int? = nil) -> [RoutingChunkID] {
        loadIndexIfNeeded()
        let limit = budget ?? automaticByteBudget
        var total = automaticBytes()
        guard total > limit else { return [] }
        let candidates = index.values
            .filter { $0.retention == .automatic }
            .sorted { $0.lastUsedAt < $1.lastUsedAt }
        var evicted: [RoutingChunkID] = []
        for entry in candidates {
            guard total > limit else { break }
            try? fileManager.removeItem(at: url(for: entry.id))
            index[entry.id] = nil
            memory[entry.id] = nil
            memoryOrder.removeAll { $0 == entry.id }
            total -= entry.byteSize
            evicted.append(entry.id)
        }
        saveIndex()
        return evicted
    }

    // MARK: - Internals

    private func url(for id: RoutingChunkID) -> URL {
        directory.appendingPathComponent("\(id.key).lprc")
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func touch(_ id: RoutingChunkID) {
        index[id]?.lastUsedAt = Date()
        // The index is written on save and eviction rather than on every read:
        // a route request touches two dozen chunks, and rewriting the index
        // two dozen times to record that they were read would be the most
        // expensive thing about reading them. Last-used dates are therefore
        // approximate between writes, which is all eviction needs.
    }

    private func remember(_ id: RoutingChunkID, _ data: OSMData) {
        if memory[id] == nil {
            memoryOrder.append(id)
            if memoryOrder.count > memoryLimit {
                let dropped = memoryOrder.removeFirst()
                memory[dropped] = nil
            }
        }
        memory[id] = data
    }

    private func loadIndexIfNeeded() {
        guard !indexLoaded else { return }
        indexLoaded = true
        guard let raw = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder.chunkIndex.decode([ChunkMetadata].self, from: raw) else { return }
        for entry in entries { index[entry.id] = entry }
    }

    private func saveIndex() {
        guard let encoded = try? JSONEncoder.chunkIndex.encode(index.values.sorted { $0.id < $1.id }) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoded.write(to: indexURL, options: .atomic)
    }
}

private extension JSONDecoder {
    static let chunkIndex: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

private extension JSONEncoder {
    static let chunkIndex: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}
