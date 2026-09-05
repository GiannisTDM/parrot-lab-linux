// Snapshot of mac/ParrotLab/Sources/ParrotLab/RTPH264Receiver.swift; see PORTING.md.
import Foundation

struct RTPVideoStats: Equatable {
    var packets: UInt64 = 0
    var duplicatePackets: UInt64 = 0
    var packetsLost: UInt64 = 0
    var bitrateKbps: Int = 0
    var encodedAUFPS: Double = 0
    var uniqueTimestampFPS: Double = 0
    var jitterMs: Double = 0
}

struct H264AccessUnit: Equatable {
    let nalUnits: [Data]
    let rtpTimestamp: UInt32
    let rtpHeaderExtensions: [Data]
    let videoMetadata: VideoMetadataV2?

    init(
        nalUnits: [Data],
        rtpTimestamp: UInt32,
        rtpHeaderExtensions: [Data],
        videoMetadata: VideoMetadataV2? = nil
    ) {
        self.nalUnits = nalUnits
        self.rtpTimestamp = rtpTimestamp
        self.rtpHeaderExtensions = rtpHeaderExtensions
        self.videoMetadata = videoMetadata
    }
}

struct RTPPacket {
    let marker: Bool
    let payloadType: UInt8
    let sequence: UInt16
    let timestamp: UInt32
    let headerExtension: Data?
    let payload: Data

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return nil }
        let hasPadding = bytes[0] & 0x20 != 0
        let hasExtension = bytes[0] & 0x10 != 0
        let csrcCount = Int(bytes[0] & 0x0f)
        marker = bytes[1] & 0x80 != 0
        payloadType = bytes[1] & 0x7f
        sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])

        var offset = 12 + csrcCount * 4
        guard offset <= bytes.count else { return nil }
        if hasExtension {
            guard offset + 4 <= bytes.count else { return nil }
            let wordCount = Int(UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3]))
            let extensionEnd = offset + 4 + wordCount * 4
            guard extensionEnd <= bytes.count else { return nil }
            headerExtension = data.subdata(in: offset..<extensionEnd)
            offset = extensionEnd
        } else {
            headerExtension = nil
        }
        var end = bytes.count
        if hasPadding {
            let padding = Int(bytes.last ?? 0)
            guard padding > 0, padding <= end - offset else { return nil }
            end -= padding
        }
        guard end > offset else { return nil }
        payload = data.subdata(in: offset..<end)
    }
}

struct H264RTPAssembler {
    private var timestamp: UInt32?
    private var nalUnits: [Data] = []
    private var fragmentedNAL: Data?
    private var extensions: [Data] = []
    private var byteCount = 0
    private var damaged = false
    private var damageOnNextPacket = false
    static let maximumBytes = 4 * 1024 * 1024

    mutating func reset() { self = H264RTPAssembler() }
    mutating func discardCurrentAccessUnit() { damaged = true; damageOnNextPacket = true; fragmentedNAL = nil }

    mutating func consume(packet: RTPPacket) -> [H264AccessUnit] {
        var completed: [H264AccessUnit] = []
        if timestamp != packet.timestamp {
            if let frame = finish() { completed.append(frame) }
            nalUnits.removeAll(keepingCapacity: true)
            extensions.removeAll(keepingCapacity: true)
            fragmentedNAL = nil; byteCount = 0; damaged = false
            timestamp = packet.timestamp
        }
        if damageOnNextPacket { damaged = true; damageOnNextPacket = false }
        guard !damaged else { return completed }
        if let ext = packet.headerExtension, extensions.count < 64 {
            extensions.append(ext); byteCount += ext.count
        }
        byteCount += packet.payload.count
        guard byteCount <= Self.maximumBytes, nalUnits.count < 512 else {
            damaged = true; nalUnits.removeAll(); fragmentedNAL = nil; extensions.removeAll()
            return completed
        }
        let bytes = [UInt8](packet.payload)
        guard let first = bytes.first else { return completed }
        switch first & 0x1f {
        case 1...23:
            if fragmentedNAL != nil { damaged = true }
            nalUnits.append(packet.payload)
        case 24:
            var offset = 1
            while offset + 2 <= bytes.count {
                let size = Int(bytes[offset]) << 8 | Int(bytes[offset + 1]); offset += 2
                guard size > 0, size <= bytes.count - offset, nalUnits.count < 512 else {
                    damaged = true; break
                }
                nalUnits.append(packet.payload.subdata(in: offset..<offset + size)); offset += size
            }
            if offset != bytes.count { damaged = true }
        case 28:
            guard bytes.count >= 3 else { damaged = true; return completed }
            let start = bytes[1] & 0x80 != 0, end = bytes[1] & 0x40 != 0
            if start {
                if fragmentedNAL != nil || end { damaged = true; return completed }
                fragmentedNAL = Data([(first & 0xe0) | (bytes[1] & 0x1f)])
            }
            guard fragmentedNAL != nil else { damaged = true; return completed }
            fragmentedNAL?.append(packet.payload.dropFirst(2))
            if end { nalUnits.append(fragmentedNAL!); fragmentedNAL = nil }
        default:
            damaged = true
        }
        if packet.marker {
            if let frame = finish() { completed.append(frame) }
            nalUnits.removeAll(keepingCapacity: true); extensions.removeAll(keepingCapacity: true)
            fragmentedNAL = nil; byteCount = 0
        }
        return completed
    }

    private func finish() -> H264AccessUnit? {
        guard !damaged, fragmentedNAL == nil, let timestamp, !nalUnits.isEmpty else { return nil }
        return H264AccessUnit(nalUnits: nalUnits, rtpTimestamp: timestamp, rtpHeaderExtensions: extensions,
                              videoMetadata: extensions.lazy.compactMap { VideoMetadataV2.decode($0, rtpTimestamp: timestamp) }.first)
    }
}
