import Foundation

/// Where partial walks live during the search.
///
/// A port of the route service's `StateStore.java`, and the reason it exists
/// matters more on a phone than it did on a server. Phase 9's prototype kept a
/// twelve-field object per generated state and never freed it, peaking at
/// 137 MB on Douglas 5 km. Nothing about that is a property of the search:
/// only the current and pending distance bands are ever read for ranking, and
/// everything behind them is needed for one thing only — walking a parent
/// chain back to recover the arcs of a walk that closed.
///
/// So the columns are split in two, with different lifetimes:
///
/// - **Reconstruction columns** — `parent`, `arc` — eight bytes a state, live
///   for the whole search, because a walk that closes in the last band may
///   descend from a state generated in the first.
/// - **Ranking columns** — distance, the running shoelace, the drawn length,
///   the bounding box, the radius, the depth, the family, the turn count —
///   needed only while the state's own band is still live. They are held in
///   chunks, and a chunk is released the moment the band it was filled during
///   is behind the search.
///
/// States are appended in expansion order and bands are drained in increasing
/// order, so a state generated while band *k* was draining belongs to band *k*
/// or later. Each chunk records the highest band key it holds and can be
/// dropped whole once the search has passed it, which is the whole of the
/// lifecycle management in one comparison per chunk.
final class WalkStateStore {
    static let chunkBits = 12
    static let chunkSize = 1 << chunkBits
    private static let chunkMask = chunkSize - 1

    // Reconstruction columns.
    private var parent: [Int32] = []
    private var arc: [Int32] = []
    private(set) var count = 0

    // Ranking columns, one array per chunk, released when the band passes.
    private var distance: [[Double]?] = []
    private var twiceArea: [[Double]?] = []
    private var drawn: [[Double]?] = []
    private var minX: [[Float]?] = []
    private var maxX: [[Float]?] = []
    private var minY: [[Float]?] = []
    private var maxY: [[Float]?] = []
    private var maxRadius: [[Float]?] = []
    private var nodeAt: [[Int32]?] = []
    private var depth: [[Int16]?] = []
    private var family: [[Int8]?] = []
    private var tightTurns: [[Int8]?] = []
    /// Highest band key any state in the chunk belongs to.
    private var chunkBand: [Int] = []
    private(set) var releasedChunks = 0

    init() {
        parent.reserveCapacity(WalkStateStore.chunkSize)
        arc.reserveCapacity(WalkStateStore.chunkSize)
    }

    var chunks: Int { chunkBand.count }

    /// Bytes still held, counting only the columns this store allocated. Exact
    /// rather than sampled: an allocator's own high-water mark moves when a
    /// collection happens to run, which makes it useless as a per-request
    /// budget, and a per-request budget is what this is for.
    var retainedBytes: Int {
        let perState = 8 + 8 + 8 + 4 + 4 + 4 + 4 + 4 + 4 + 2 + 1 + 1
        return (chunks - releasedChunks) * WalkStateStore.chunkSize * perState + count * 8
    }

    @discardableResult
    func add(
        parent parentIndex: Int32, arc arcIndex: Int32, node: Int32, distance distanceMetres: Double,
        area: Double, drawn drawnMetres: Double, lowX: Float, highX: Float, lowY: Float, highY: Float,
        radius: Float, depth depthValue: Int, family familyValue: Int, tightTurns tightValue: Int, band: Int
    ) -> Int32 {
        let index = count
        count += 1
        parent.append(parentIndex)
        arc.append(arcIndex)
        let chunk = index >> WalkStateStore.chunkBits
        if chunk >= chunks { grow(to: chunk) }
        let slot = index & WalkStateStore.chunkMask
        distance[chunk]![slot] = distanceMetres
        twiceArea[chunk]![slot] = area
        self.drawn[chunk]![slot] = drawnMetres
        minX[chunk]![slot] = lowX
        maxX[chunk]![slot] = highX
        minY[chunk]![slot] = lowY
        maxY[chunk]![slot] = highY
        maxRadius[chunk]![slot] = radius
        nodeAt[chunk]![slot] = node
        depth[chunk]![slot] = Int16(Swift.min(Int(Int16.max), depthValue))
        family[chunk]![slot] = Int8(Swift.max(-1, Swift.min(127, familyValue)))
        tightTurns[chunk]![slot] = Int8(Swift.min(127, tightValue))
        if band > chunkBand[chunk] { chunkBand[chunk] = band }
        return Int32(index)
    }

    private func grow(to chunk: Int) {
        while chunks <= chunk {
            distance.append([Double](repeating: 0, count: WalkStateStore.chunkSize))
            twiceArea.append([Double](repeating: 0, count: WalkStateStore.chunkSize))
            drawn.append([Double](repeating: 0, count: WalkStateStore.chunkSize))
            minX.append([Float](repeating: 0, count: WalkStateStore.chunkSize))
            maxX.append([Float](repeating: 0, count: WalkStateStore.chunkSize))
            minY.append([Float](repeating: 0, count: WalkStateStore.chunkSize))
            maxY.append([Float](repeating: 0, count: WalkStateStore.chunkSize))
            maxRadius.append([Float](repeating: 0, count: WalkStateStore.chunkSize))
            nodeAt.append([Int32](repeating: 0, count: WalkStateStore.chunkSize))
            depth.append([Int16](repeating: 0, count: WalkStateStore.chunkSize))
            family.append([Int8](repeating: 0, count: WalkStateStore.chunkSize))
            tightTurns.append([Int8](repeating: 0, count: WalkStateStore.chunkSize))
            chunkBand.append(Int.min)
        }
    }

    /// Drop the ranking columns of every chunk whose states all belong to
    /// bands the search has finished with. The reconstruction columns stay.
    func releaseBelow(_ liveBand: Int) {
        let filling = count >> WalkStateStore.chunkBits
        for chunk in 0..<chunks {
            guard distance[chunk] != nil, chunkBand[chunk] < liveBand else { continue }
            // The chunk currently being filled is never complete, so never freed.
            if chunk == filling { continue }
            distance[chunk] = nil
            twiceArea[chunk] = nil
            drawn[chunk] = nil
            minX[chunk] = nil
            maxX[chunk] = nil
            minY[chunk] = nil
            maxY[chunk] = nil
            maxRadius[chunk] = nil
            nodeAt[chunk] = nil
            depth[chunk] = nil
            family[chunk] = nil
            tightTurns[chunk] = nil
            releasedChunks += 1
        }
    }

    @inline(__always) func parentOf(_ i: Int32) -> Int32 { parent[Int(i)] }
    @inline(__always) func arcOf(_ i: Int32) -> Int32 { arc[Int(i)] }
    @inline(__always) func distanceOf(_ i: Int32) -> Double { distance[Int(i) >> WalkStateStore.chunkBits]![Int(i) & WalkStateStore.chunkMask] }
    @inline(__always) func twiceAreaOf(_ i: Int32) -> Double { twiceArea[Int(i) >> WalkStateStore.chunkBits]![Int(i) & WalkStateStore.chunkMask] }
    @inline(__always) func drawnOf(_ i: Int32) -> Double { drawn[Int(i) >> WalkStateStore.chunkBits]![Int(i) & WalkStateStore.chunkMask] }
    @inline(__always) func minXOf(_ i: Int32) -> Float { minX[Int(i) >> WalkStateStore.chunkBits]![Int(i) & WalkStateStore.chunkMask] }
    @inline(__always) func maxXOf(_ i: Int32) -> Float { maxX[Int(i) >> WalkStateStore.chunkBits]![Int(i) & WalkStateStore.chunkMask] }
    @inline(__always) func minYOf(_ i: Int32) -> Float { minY[Int(i) >> WalkStateStore.chunkBits]![Int(i) & WalkStateStore.chunkMask] }
    @inline(__always) func maxYOf(_ i: Int32) -> Float { maxY[Int(i) >> WalkStateStore.chunkBits]![Int(i) & WalkStateStore.chunkMask] }
    @inline(__always) func maxRadiusOf(_ i: Int32) -> Float { maxRadius[Int(i) >> WalkStateStore.chunkBits]![Int(i) & WalkStateStore.chunkMask] }
    @inline(__always) func nodeOf(_ i: Int32) -> Int32 { nodeAt[Int(i) >> WalkStateStore.chunkBits]![Int(i) & WalkStateStore.chunkMask] }
    @inline(__always) func depthOf(_ i: Int32) -> Int { Int(depth[Int(i) >> WalkStateStore.chunkBits]![Int(i) & WalkStateStore.chunkMask]) }
    @inline(__always) func familyOf(_ i: Int32) -> Int { Int(family[Int(i) >> WalkStateStore.chunkBits]![Int(i) & WalkStateStore.chunkMask]) }
    @inline(__always) func tightTurnsOf(_ i: Int32) -> Int { Int(tightTurns[Int(i) >> WalkStateStore.chunkBits]![Int(i) & WalkStateStore.chunkMask]) }
}
