import Foundation

/// The on-disk form of one routing chunk.
///
/// A hand-rolled binary format rather than JSON, for one reason worth the
/// code: a chunk is mostly integers, and the same two dozen tag keys repeat on
/// every way in it. JSON stores `"highway"` in full several thousand times per
/// chunk; a string table stores it once. Measured on Douglas, the binary form
/// is roughly a fifth of the size of the equivalent JSON, which matters when
/// the whole premise of the design is that a 5 km walk needs a small download
/// rather than a regional dataset.
///
/// The format carries its own version. A chunk written by an older version is
/// not read and not migrated — it is simply treated as absent and fetched
/// again, which for cache data is the correct and much safer trade.
enum RoutingChunkCodec {
    static let magic: [UInt8] = [0x4C, 0x50, 0x52, 0x43] // "LPRC"
    static let version: UInt16 = 1

    enum CodecError: Error, Equatable {
        case notAChunk
        case unsupportedVersion(UInt16)
        case truncated
    }

    // MARK: - Encoding

    static func encode(_ data: OSMData) -> Data {
        var strings: [String: UInt32] = [:]
        var table: [String] = []
        func intern(_ value: String) -> UInt32 {
            if let existing = strings[value] { return existing }
            let index = UInt32(table.count)
            strings[value] = index
            table.append(value)
            return index
        }

        // Two passes: the table has to be written before the body that refers
        // into it, and interning while encoding the body is what builds it.
        var body = Data()
        body.reserveCapacity(data.nodes.count * 20 + data.ways.count * 40)

        var nodeBlock = Data()
        appendUInt32(&nodeBlock, UInt32(data.nodes.count))
        for node in data.nodes {
            appendInt64(&nodeBlock, node.id)
            appendInt32(&nodeBlock, scaled(node.lat))
            appendInt32(&nodeBlock, scaled(node.lon))
            nodeBlock.append(UInt8(min(255, node.tags.count)))
            for (key, value) in node.tags.prefix(255) {
                appendUInt32(&nodeBlock, intern(key))
                appendUInt32(&nodeBlock, intern(value))
            }
        }

        var wayBlock = Data()
        appendUInt32(&wayBlock, UInt32(data.ways.count))
        for way in data.ways {
            appendInt64(&wayBlock, way.id)
            appendUInt32(&wayBlock, UInt32(way.nodes.count))
            for id in way.nodes { appendInt64(&wayBlock, id) }
            wayBlock.append(UInt8(min(255, way.tags.count)))
            for (key, value) in way.tags.prefix(255) {
                appendUInt32(&wayBlock, intern(key))
                appendUInt32(&wayBlock, intern(value))
            }
        }

        var header = Data(magic)
        appendUInt16(&header, version)
        appendUInt32(&header, UInt32(table.count))
        for entry in table {
            let bytes = Array(entry.utf8)
            appendUInt16(&header, UInt16(min(bytes.count, Int(UInt16.max))))
            header.append(contentsOf: bytes.prefix(Int(UInt16.max)))
        }
        body.append(nodeBlock)
        body.append(wayBlock)
        header.append(body)
        return header
    }

    // MARK: - Decoding

    static func decode(_ data: Data) throws -> OSMData {
        var cursor = Cursor(data)
        guard try cursor.bytes(4).elementsEqual(magic) else { throw CodecError.notAChunk }
        let fileVersion = try cursor.uint16()
        guard fileVersion == version else { throw CodecError.unsupportedVersion(fileVersion) }

        let stringCount = Int(try cursor.uint32())
        var table: [String] = []
        table.reserveCapacity(stringCount)
        for _ in 0..<stringCount {
            let length = Int(try cursor.uint16())
            table.append(String(decoding: try cursor.bytes(length), as: UTF8.self))
        }
        func string(_ index: UInt32) throws -> String {
            guard Int(index) < table.count else { throw CodecError.truncated }
            return table[Int(index)]
        }

        let nodeCount = Int(try cursor.uint32())
        var nodes: [OSMNode] = []
        nodes.reserveCapacity(nodeCount)
        for _ in 0..<nodeCount {
            let id = try cursor.int64()
            let lat = unscaled(try cursor.int32())
            let lon = unscaled(try cursor.int32())
            let tagCount = Int(try cursor.byte())
            var tags: [String: String] = [:]
            if tagCount > 0 {
                tags.reserveCapacity(tagCount)
                for _ in 0..<tagCount {
                    let key = try string(cursor.uint32())
                    tags[key] = try string(cursor.uint32())
                }
            }
            nodes.append(OSMNode(id: id, lat: lat, lon: lon, tags: tags))
        }

        let wayCount = Int(try cursor.uint32())
        var ways: [OSMWay] = []
        ways.reserveCapacity(wayCount)
        for _ in 0..<wayCount {
            let id = try cursor.int64()
            let refCount = Int(try cursor.uint32())
            var refs: [Int64] = []
            refs.reserveCapacity(refCount)
            for _ in 0..<refCount { refs.append(try cursor.int64()) }
            let tagCount = Int(try cursor.byte())
            var tags: [String: String] = [:]
            tags.reserveCapacity(tagCount)
            for _ in 0..<tagCount {
                let key = try string(cursor.uint32())
                tags[key] = try string(cursor.uint32())
            }
            ways.append(OSMWay(id: id, nodes: refs, tags: tags))
        }
        return OSMData(nodes: nodes, ways: ways)
    }

    // MARK: - Primitives

    /// Coordinates to a tenth of a microdegree: about 1 cm, which is finer
    /// than OSM itself records and half the bytes of a Double.
    private static let coordinateScale = 1e7

    private static func scaled(_ degrees: Double) -> Int32 {
        Int32(max(Double(Int32.min), min(Double(Int32.max), (degrees * coordinateScale).rounded())))
    }

    private static func unscaled(_ value: Int32) -> Double { Double(value) / coordinateScale }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func appendInt32(_ data: inout Data, _ value: Int32) {
        appendUInt32(&data, UInt32(bitPattern: value))
    }

    private static func appendInt64(_ data: inout Data, _ value: Int64) {
        let bits = UInt64(bitPattern: value)
        appendUInt32(&data, UInt32(bits & 0xFFFF_FFFF))
        appendUInt32(&data, UInt32(bits >> 32))
    }

    private struct Cursor {
        let data: Data
        var offset: Int

        init(_ data: Data) {
            self.data = data
            self.offset = data.startIndex
        }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= data.endIndex else { throw CodecError.truncated }
            defer { offset += count }
            return Array(data[offset..<(offset + count)])
        }

        mutating func byte() throws -> UInt8 {
            guard offset < data.endIndex else { throw CodecError.truncated }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func uint16() throws -> UInt16 {
            let low = UInt16(try byte()), high = UInt16(try byte())
            return low | (high << 8)
        }

        mutating func uint32() throws -> UInt32 {
            let a = UInt32(try byte()), b = UInt32(try byte()), c = UInt32(try byte()), d = UInt32(try byte())
            return a | (b << 8) | (c << 16) | (d << 24)
        }

        mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }

        mutating func int64() throws -> Int64 {
            let low = UInt64(try uint32()), high = UInt64(try uint32())
            return Int64(bitPattern: low | (high << 32))
        }
    }
}
