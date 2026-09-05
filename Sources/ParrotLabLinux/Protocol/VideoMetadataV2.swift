// Snapshot of mac/ParrotLab/Sources/ParrotLab/VideoMetadataV2.swift; see PORTING.md.
import Foundation

struct VideoMetadataQuaternion: Equatable {
    let w: Double
    let x: Double
    let y: Double
    let z: Double

    var norm: Double { sqrt(w * w + x * x + y * y + z * z) }

    var normalized: VideoMetadataQuaternion {
        let length = norm
        guard length.isFinite, length > 1e-12 else {
            return VideoMetadataQuaternion(w: 1, x: 0, y: 0, z: 0)
        }
        return VideoMetadataQuaternion(
            w: w / length,
            x: x / length,
            y: y / length,
            z: z / length
        )
    }

    var conjugated: VideoMetadataQuaternion {
        VideoMetadataQuaternion(w: w, x: -x, y: -y, z: -z)
    }

    /// Hamilton product. Metadata quaternions are active rotations and are
    /// serialized in (w, x, y, z) order.
    func multiplied(by other: VideoMetadataQuaternion) -> VideoMetadataQuaternion {
        VideoMetadataQuaternion(
            w: w * other.w - x * other.x - y * other.y - z * other.z,
            x: w * other.x + x * other.w + y * other.z - z * other.y,
            y: w * other.y - x * other.z + y * other.w + z * other.x,
            z: w * other.z + x * other.y - y * other.x + z * other.w
        )
    }

    func rotated(_ vector: SIMD3<Double>) -> SIMD3<Double> {
        let q = normalized
        let pure = VideoMetadataQuaternion(w: 0, x: vector.x, y: vector.y, z: vector.z)
        let value = q.multiplied(by: pure).multiplied(by: q.conjugated)
        return SIMD3<Double>(value.x, value.y, value.z)
    }

    static func slerp(
        from start: VideoMetadataQuaternion,
        to end: VideoMetadataQuaternion,
        fraction: Double
    ) -> VideoMetadataQuaternion {
        let a = start.normalized
        var b = end.normalized
        var cosine = a.dot(b)
        if cosine < 0 {
            b = b.negated
            cosine = -cosine
        }
        let t = max(0, min(1, fraction))
        if cosine > 0.9995 {
            return VideoMetadataQuaternion(
                w: a.w + (b.w - a.w) * t,
                x: a.x + (b.x - a.x) * t,
                y: a.y + (b.y - a.y) * t,
                z: a.z + (b.z - a.z) * t
            ).normalized
        }
        let angle = acos(max(-1, min(1, cosine)))
        let sine = sin(angle)
        let firstWeight = sin((1 - t) * angle) / sine
        let secondWeight = sin(t * angle) / sine
        return VideoMetadataQuaternion(
            w: a.w * firstWeight + b.w * secondWeight,
            x: a.x * firstWeight + b.x * secondWeight,
            y: a.y * firstWeight + b.y * secondWeight,
            z: a.z * firstWeight + b.z * secondWeight
        ).normalized
    }

    func dot(_ other: VideoMetadataQuaternion) -> Double {
        w * other.w + x * other.x + y * other.y + z * other.z
    }

    var negated: VideoMetadataQuaternion {
        VideoMetadataQuaternion(w: -w, x: -x, y: -y, z: -z)
    }

    func preservingSignContinuity(after previous: VideoMetadataQuaternion?) -> VideoMetadataQuaternion {
        guard let previous else { return self }
        return dot(previous) < 0 ? negated : self
    }
}

/// Public Parrot "VideoMetadataV2" base record carried as the Bebop RTP
/// header extension. The 56-byte network-order layout and fixed-point scales
/// follow Parrot's official libvideo-metadata v2 reader.
struct VideoMetadataV2: Equatable {
    static let identifier: UInt16 = 0x5032
    static let baseLength = 56

    let rtpTimestamp: UInt32
    let groundDistanceMeters: Double
    let latitude: Double
    let longitude: Double
    let altitudeEGM96Meters: Double
    let satelliteCount: UInt8
    let speedNorthMetersPerSecond: Double
    let speedEastMetersPerSecond: Double
    let speedDownMetersPerSecond: Double
    let airSpeedMetersPerSecond: Double
    let droneQuaternion: VideoMetadataQuaternion
    let frameQuaternion: VideoMetadataQuaternion
    let cameraPanRadians: Double
    let cameraTiltRadians: Double
    let exposureMilliseconds: Double
    let gain: UInt16
    let flyingState: UInt8
    let pilotingMode: UInt8
    let wifiRSSI: Int8
    let batteryPercentage: UInt8
    let sensorBinning: Bool
    let animationInProgress: Bool

    static func decode(_ data: Data, rtpTimestamp: UInt32) -> VideoMetadataV2? {
        guard data.count >= baseLength,
              readUInt16(data, 0) == identifier else { return nil }
        let wordLength = Int(readUInt16(data, 2))
        guard wordLength >= 13,
              wordLength * 4 + 4 <= data.count else { return nil }

        let altitudeAndSatellites = readInt32(data, 16)
        let altitudeFixed = altitudeAndSatellites >> 8
        let state = data[52]
        let mode = data[53]
        let metadata = VideoMetadataV2(
            rtpTimestamp: rtpTimestamp,
            groundDistanceMeters: fixed32(data, 4, shift: 16),
            latitude: fixed32(data, 8, shift: 22),
            longitude: fixed32(data, 12, shift: 22),
            altitudeEGM96Meters: Double(altitudeFixed) / 256,
            satelliteCount: UInt8(truncatingIfNeeded: altitudeAndSatellites),
            speedNorthMetersPerSecond: fixed16(data, 20, shift: 8),
            speedEastMetersPerSecond: fixed16(data, 22, shift: 8),
            speedDownMetersPerSecond: fixed16(data, 24, shift: 8),
            airSpeedMetersPerSecond: fixed16(data, 26, shift: 8),
            droneQuaternion: VideoMetadataQuaternion(
                w: fixed16(data, 28, shift: 14),
                x: fixed16(data, 30, shift: 14),
                y: fixed16(data, 32, shift: 14),
                z: fixed16(data, 34, shift: 14)
            ),
            frameQuaternion: VideoMetadataQuaternion(
                w: fixed16(data, 36, shift: 14),
                x: fixed16(data, 38, shift: 14),
                y: fixed16(data, 40, shift: 14),
                z: fixed16(data, 42, shift: 14)
            ),
            cameraPanRadians: fixed16(data, 44, shift: 12),
            cameraTiltRadians: fixed16(data, 46, shift: 12),
            exposureMilliseconds: fixed16(data, 48, shift: 8),
            gain: readUInt16(data, 50),
            flyingState: state & 0x7f,
            pilotingMode: mode & 0x7f,
            wifiRSSI: Int8(bitPattern: data[54]),
            batteryPercentage: data[55],
            sensorBinning: state & 0x80 != 0,
            animationInProgress: mode & 0x80 != 0
        )
        guard metadata.droneQuaternion.norm.isFinite,
              metadata.frameQuaternion.norm.isFinite,
              metadata.cameraPanRadians.isFinite,
              metadata.cameraTiltRadians.isFinite else { return nil }
        return metadata
    }

    static func selfTest() -> Bool {
        var data = Data(count: baseLength)
        putUInt16(identifier, at: 0, into: &data)
        putUInt16(13, at: 2, into: &data)
        putInt16(16_384, at: 28, into: &data)
        putInt16(16_384, at: 36, into: &data)
        putInt16(-929, at: 46, into: &data)
        putUInt16(285, at: 50, into: &data)
        data[54] = UInt8(bitPattern: -27)
        data[55] = 99
        guard let decoded = decode(data, rtpTimestamp: 90_000) else { return false }
        let positive = VideoMetadataQuaternion(w: 1, x: 0, y: 0, z: 0)
        let equivalentNegative = positive.negated
        let yaw90 = VideoMetadataQuaternion(
            w: cos(.pi / 4), x: 0, y: 0, z: sin(.pi / 4)
        )
        let east = yaw90.rotated(SIMD3<Double>(1, 0, 0))
        let halfway = VideoMetadataQuaternion.slerp(from: positive, to: yaw90, fraction: 0.5)
        return decoded.rtpTimestamp == 90_000 &&
            abs(decoded.droneQuaternion.w - 1) < 0.000_001 &&
            abs(decoded.frameQuaternion.w - 1) < 0.000_001 &&
            abs(decoded.cameraTiltRadians - (-929.0 / 4_096.0)) < 0.000_001 &&
            decoded.gain == 285 && decoded.wifiRSSI == -27 &&
            decoded.batteryPercentage == 99 &&
            equivalentNegative.preservingSignContinuity(after: positive) == positive &&
            abs(east.x) < 0.000_001 && abs(east.y - 1) < 0.000_001 &&
            abs(halfway.norm - 1) < 0.000_001
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readInt16(_ data: Data, _ offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16(data, offset))
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 |
            UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 |
            UInt32(data[offset + 3])
    }

    private static func readInt32(_ data: Data, _ offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(data, offset))
    }

    private static func fixed16(_ data: Data, _ offset: Int, shift: Int) -> Double {
        Double(readInt16(data, offset)) / Double(1 << shift)
    }

    private static func fixed32(_ data: Data, _ offset: Int, shift: Int) -> Double {
        Double(readInt32(data, offset)) / Double(Int64(1) << shift)
    }

    private static func putUInt16(_ value: UInt16, at offset: Int, into data: inout Data) {
        data[offset] = UInt8(value >> 8)
        data[offset + 1] = UInt8(value & 0xff)
    }

    private static func putInt16(_ value: Int16, at offset: Int, into data: inout Data) {
        putUInt16(UInt16(bitPattern: value), at: offset, into: &data)
    }
}
