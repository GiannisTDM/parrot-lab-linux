// Snapshot of mac/ParrotLab/Sources/ParrotLab/ARSDKPhotoCapture.swift; see PORTING.md.
import Foundation

enum ARSDKPictureFormat: UInt32, Equatable {
    case raw = 0
    case jpeg = 1
    case snapshot = 2
    case jpegFisheye = 3
}

enum ARSDKPictureState: UInt32, Equatable {
    case ready = 0
    case busy = 1
    case notAvailable = 2
}

enum ARSDKPictureStateError: UInt32, Equatable {
    case ok = 0
    case unknown = 1
    case cameraKO = 2
    case memoryFull = 3
    case lowBattery = 4
}

enum ARSDKPictureEventKind: UInt32, Equatable {
    case taken = 0
    case failed = 1
}

enum ARSDKPictureEventError: UInt32, Equatable {
    case ok = 0
    case unknown = 1
    case busy = 2
    case notAvailable = 3
    case errorAssert = 4
}

enum ARSDKPhotoEvent: Equatable {
    case formatChanged(ARSDKPictureFormat)
    case pictureState(ARSDKPictureState, ARSDKPictureStateError)
    case pictureEvent(ARSDKPictureEventKind, ARSDKPictureEventError)
}

enum ARSDKMagnetometerAxis: UInt32, Equatable {
    case x = 0
    case y = 1
    case z = 2
    case none = 3

    var displayName: String {
        switch self {
        case .x: return "X axis"
        case .y: return "Y axis"
        case .z: return "Z axis"
        case .none: return "complete"
        }
    }
}

enum ARSDKTelemetryEvent: Equatable {
    case droneBattery(Int)
    case wifiSignal(Int)
    case jumpingSumoLinkQuality(Int)
    case controllerBattery(Int)
    case controllerBatteryState(UInt32)
    case flyingState(UInt32)
    case gpsPosition(latitude: Double, longitude: Double)
    case homePosition(latitude: Double, longitude: Double)
    case altitude(Double)
    case speed(north: Float, east: Float, down: Float)
    case attitude(roll: Float, pitch: Float, yaw: Float)
    case gpsFix(Bool)
    case satelliteCount(Int)
    case aircraftConnection(status: UInt32, deviceName: String, productID: UInt16)
    case productVersion(software: String, hardware: String)
    case flatTrimChanged
    case magnetometerCalibrationState(x: Bool, y: Bool, z: Bool, failed: Bool)
    case magnetometerCalibrationRequired(Bool)
    case magnetometerCalibrationAxis(ARSDKMagnetometerAxis)
    case magnetometerCalibrationStarted(Bool)
}

enum ARSDKPhotoCommand {
    enum JumpingSumoJumpType: UInt8 {
        case long = 0
        case high = 1
    }

    // ARCommands payloads are project, class, command (little-endian), args.
    static let setFisheye = Data([1, 19, 0, 0, 3, 0, 0, 0])
    static let takePictureV2 = Data([1, 7, 2, 0])
    static let requestAllStates = Data([0, 4, 0, 0])
    static let requestSkyControllerAllStates = Data([4, 6, 0, 0])
    static let requestAllSettings = Data([0, 2, 0, 0])
    static let takeOff = Data([1, 0, 1, 0])
    static let landing = Data([1, 0, 3, 0])
    static let emergency = Data([1, 0, 4, 0])
    static let flatTrim = Data([1, 0, 0, 0])

    static func magnetometerCalibration(start: Bool) -> Data {
        Data([0, 13, 0, 0, start ? 1 : 0])
    }

    static func navigateHome(start: Bool) -> Data {
        Data([1, 0, 5, 0, start ? 1 : 0])
    }

    static func videoEnable(_ enabled: Bool) -> Data {
        Data([1, 21, 0, 0, enabled ? 1 : 0])
    }

    static func cameraOrientation(tilt: Int8, pan: Int8) -> Data {
        Data([1, 1, 0, 0, UInt8(bitPattern: tilt), UInt8(bitPattern: pan)])
    }

    static func pcmd(
        flag: Bool,
        roll: Int8,
        pitch: Int8,
        yaw: Int8,
        gaz: Int8,
        timestampAndSequence: UInt32
    ) -> Data {
        var result = Data([
            1, 0, 2, 0,
            flag ? 1 : 0,
            UInt8(bitPattern: roll), UInt8(bitPattern: pitch),
            UInt8(bitPattern: yaw), UInt8(bitPattern: gaz)
        ])
        result.append(contentsOf: (0..<4).map {
            UInt8((timestampAndSequence >> UInt32($0 * 8)) & 0xff)
        })
        return result
    }

    /// Jumping Sumo project 3, Piloting class 0, PCMD command 0.
    /// The installed Sumo firmware's libarcommands generator defines the wire
    /// arguments as flag, signed speed and signed turn.
    static func jumpingSumoPCMD(flag: Bool, speed: Int8, turn: Int8) -> Data {
        Data([3, 0, 0, 0, flag ? 1 : 0, UInt8(bitPattern: speed), UInt8(bitPattern: turn)])
    }

    /// JumpingSumo.Animations.Jump (project 3, class 2, command 3).
    static func jumpingSumoJump(_ type: JumpingSumoJumpType) -> Data {
        Data([3, 2, 3, 0, type.rawValue])
    }

    /// Jumping Sumo project 3, MediaStreaming class 18, VideoEnable command 0.
    static func jumpingSumoVideoEnable(_ enabled: Bool) -> Data {
        Data([3, 18, 0, 0, enabled ? 1 : 0])
    }
}

enum ARSDKConnectionRoute: Equatable {
    case skyController
    case directProduct

    var displayName: String {
        switch self {
        case .skyController: return "SkyController 2"
        case .directProduct: return "Parrot product direct"
        }
    }
}

struct BebopPilotingInput: Equatable {
    var roll: Int8 = 0
    var pitch: Int8 = 0
    var yaw: Int8 = 0
    var gaz: Int8 = 0

    var flag: Bool { roll != 0 || pitch != 0 }
    static let neutral = BebopPilotingInput()
}

struct JumpingSumoPilotingInput: Equatable {
    let speed: Int8
    let turn: Int8

    var flag: Bool { speed != 0 || turn != 0 }

    init(speed: Int8, turn: Int8) {
        self.speed = speed
        self.turn = turn
    }

    init(sharedInput: BebopPilotingInput) {
        // The existing right-stick / WASD mapping is forward/turn in ground
        // mode. Left-stick yaw/gaz deliberately has no effect on a car.
        speed = sharedInput.pitch
        turn = sharedInput.roll
    }
}

enum ARSDKPhotoProtocol {
    static func decode(_ data: Data) -> ARSDKPhotoEvent? {
        guard data.count >= 4 else { return nil }
        let project = data[0]
        let commandClass = data[1]
        let command = UInt16(data[2]) | UInt16(data[3]) << 8

        if project == 1, commandClass == 20, command == 0,
           let raw = uint32(data, at: 4), let format = ARSDKPictureFormat(rawValue: raw) {
            return .formatChanged(format)
        }
        if project == 1, commandClass == 8, command == 2,
           let rawState = uint32(data, at: 4), let rawError = uint32(data, at: 8),
           let state = ARSDKPictureState(rawValue: rawState),
           let error = ARSDKPictureStateError(rawValue: rawError) {
            return .pictureState(state, error)
        }
        if project == 1, commandClass == 3, command == 0,
           let rawEvent = uint32(data, at: 4), let rawError = uint32(data, at: 8),
           let event = ARSDKPictureEventKind(rawValue: rawEvent),
           let error = ARSDKPictureEventError(rawValue: rawError) {
            return .pictureEvent(event, error)
        }
        return nil
    }

    static func frame(type: UInt8, id: UInt8, sequence: UInt8, payload: Data) -> Data {
        let size = UInt32(7 + payload.count)
        var result = Data([type, id, sequence])
        result.append(contentsOf: [
            UInt8(size & 0xff), UInt8((size >> 8) & 0xff),
            UInt8((size >> 16) & 0xff), UInt8((size >> 24) & 0xff)
        ])
        result.append(payload)
        return result
    }

    static func nextSequence(after previous: UInt8?) -> UInt8 {
        (previous ?? 0) &+ 1
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        return UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }
}

enum ARSDKDiscoveryProtocol {
    static func responseObject(from data: Data) -> [String: Any]? {
        guard let incoming = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = incoming.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        guard let json = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    }

    static func arstream1Negotiation(from object: [String: Any]) -> ARStream1Negotiation {
        ARStream1Negotiation(
            fragmentSize: integer(object["arstream_fragment_size"]),
            fragmentMaximumNumber: integer(object["arstream_fragment_maximum_number"]),
            maximumAcknowledgementInterval: integer(object["arstream_max_ack_interval"])
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

struct ARStream1Negotiation: Equatable {
    let fragmentSize: Int?
    let fragmentMaximumNumber: Int?
    let maximumAcknowledgementInterval: Int?

    var sendsVideoAcknowledgements: Bool {
        maximumAcknowledgementInterval != -1
    }
}

struct ARStream1VideoFragmentResult {
    let acknowledgement: Data
    let frame: ARStream1CompletedFrame?
}

struct ARStream1CompletedFrame: Equatable {
    let frameNumber: UInt64
    let payload: Data
}

struct ARStream1AssemblyStatistics: Equatable {
    let receivedFragments: UInt64
    let completedFrames: UInt64
    let incompleteFrames: UInt64
    let missingFragments: UInt64
    let lastFrameNumber: UInt64?
    let lastAssembledBytes: Int?
}

struct ARStream1VideoDiagnostics: Equatable {
    let fragmentReceiveRate: Double
    let assembledFrameRate: Double
    let assembly: ARStream1AssemblyStatistics
    let negotiation: ARStream1Negotiation
}

/// Reassembles the legacy ARStream 1 video carried inside ARNetwork buffer 125.
/// The transport is codec-neutral: BB1 completes Annex-B H.264 frames while
/// Jumping Sumo completes JPEG payloads through the same fragment/ACK protocol.
struct ARStream1VideoAssembler {
    private static let dataHeaderSize = 5
    private static let maximumFragments = 128
    private static let maximumPendingFrames = 4

    private struct PendingFrame {
        let fragmentCount: Int
        var fragments: [Data?]
        var highAcknowledgementMask: UInt64
        var lowAcknowledgementMask: UInt64
        var receivedCount = 0

        init(fragmentCount: Int) {
            self.fragmentCount = fragmentCount
            fragments = [Data?](repeating: nil, count: fragmentCount)
            if fragmentCount < 64 {
                lowAcknowledgementMask = UInt64.max << UInt64(fragmentCount)
                highAcknowledgementMask = UInt64.max
            } else if fragmentCount == 64 {
                lowAcknowledgementMask = 0
                highAcknowledgementMask = UInt64.max
            } else if fragmentCount < ARStream1VideoAssembler.maximumFragments {
                lowAcknowledgementMask = 0
                highAcknowledgementMask = UInt64.max << UInt64(fragmentCount - 64)
            } else {
                lowAcknowledgementMask = 0
                highAcknowledgementMask = 0
            }
        }

        mutating func insert(_ payload: Data, fragmentNumber: Int) {
            guard fragments[fragmentNumber] == nil else { return }
            fragments[fragmentNumber] = payload
            receivedCount += 1
            if fragmentNumber < 64 {
                lowAcknowledgementMask |= UInt64(1) << UInt64(fragmentNumber)
            } else {
                highAcknowledgementMask |= UInt64(1) << UInt64(fragmentNumber - 64)
            }
        }

        var isComplete: Bool { receivedCount == fragmentCount }

        var payload: Data {
            var result = Data()
            result.reserveCapacity(fragments.reduce(0) { $0 + ($1?.count ?? 0) })
            for fragment in fragments {
                if let fragment { result.append(fragment) }
            }
            return result
        }
    }

    private var pendingFrames: [UInt16: PendingFrame] = [:]
    private var pendingOrder: [UInt16] = []
    private var lastDeliveredFrameNumber: UInt64?
    private var negotiatedFragmentSize: Int?
    private var negotiatedMaximumFragments = Self.maximumFragments
    private var receivedFragmentCount: UInt64 = 0
    private var completedFrameCount: UInt64 = 0
    private var incompleteFrameCount: UInt64 = 0
    private var missingFragmentCount: UInt64 = 0
    private var lastCompletedFrameNumber: UInt64?
    private var lastCompletedFrameBytes: Int?

    mutating func configure(fragmentSize: Int?, maximumFragments: Int?) {
        negotiatedFragmentSize = fragmentSize.flatMap { $0 > 0 ? $0 : nil }
        negotiatedMaximumFragments = min(
            Self.maximumFragments,
            max(1, maximumFragments ?? Self.maximumFragments)
        )
        reset()
    }

    mutating func reset() {
        pendingFrames.removeAll(keepingCapacity: false)
        pendingOrder.removeAll(keepingCapacity: false)
        lastDeliveredFrameNumber = nil
        receivedFragmentCount = 0
        completedFrameCount = 0
        incompleteFrameCount = 0
        missingFragmentCount = 0
        lastCompletedFrameNumber = nil
        lastCompletedFrameBytes = nil
    }

    var statistics: ARStream1AssemblyStatistics {
        ARStream1AssemblyStatistics(
            receivedFragments: receivedFragmentCount,
            completedFrames: completedFrameCount,
            incompleteFrames: incompleteFrameCount,
            missingFragments: missingFragmentCount,
            lastFrameNumber: lastCompletedFrameNumber,
            lastAssembledBytes: lastCompletedFrameBytes
        )
    }

    mutating func consume(_ payload: Data) -> ARStream1VideoFragmentResult? {
        guard payload.count >= Self.dataHeaderSize else { return nil }
        let incomingFrameNumber = UInt16(payload[0]) | UInt16(payload[1]) << 8
        let fragmentNumber = Int(payload[3])
        let fragmentCount = Int(payload[4])
        let fragmentPayloadSize = payload.count - Self.dataHeaderSize
        guard (1...negotiatedMaximumFragments).contains(fragmentCount),
              fragmentNumber < fragmentCount,
              negotiatedFragmentSize.map({ fragmentPayloadSize <= $0 }) ?? true else { return nil }
        receivedFragmentCount &+= 1

        var pending: PendingFrame
        if let existing = pendingFrames[incomingFrameNumber],
           existing.fragmentCount == fragmentCount {
            pending = existing
        } else {
            if let existing = pendingFrames[incomingFrameNumber] {
                recordIncomplete(existing)
            }
            pending = PendingFrame(fragmentCount: fragmentCount)
            pendingOrder.removeAll { $0 == incomingFrameNumber }
            pendingOrder.append(incomingFrameNumber)
        }
        pending.insert(
            Data(payload.dropFirst(Self.dataHeaderSize)),
            fragmentNumber: fragmentNumber
        )
        pendingFrames[incomingFrameNumber] = pending
        prunePendingFrames()

        let acknowledgement = makeAcknowledgement(
            frameNumber: incomingFrameNumber,
            highMask: pending.highAcknowledgementMask,
            lowMask: pending.lowAcknowledgementMask
        )
        guard pending.isComplete else {
            return ARStream1VideoFragmentResult(acknowledgement: acknowledgement, frame: nil)
        }

        let extended = extendedFrameNumber(for: incomingFrameNumber)
        guard lastDeliveredFrameNumber.map({ extended > $0 }) ?? true else {
            return ARStream1VideoFragmentResult(acknowledgement: acknowledgement, frame: nil)
        }
        lastDeliveredFrameNumber = extended
        let completedPayload = pending.payload
        pendingFrames.removeValue(forKey: incomingFrameNumber)
        pendingOrder.removeAll { $0 == incomingFrameNumber }
        completedFrameCount &+= 1
        lastCompletedFrameNumber = extended
        lastCompletedFrameBytes = completedPayload.count
        return ARStream1VideoFragmentResult(
            acknowledgement: acknowledgement,
            frame: ARStream1CompletedFrame(
                frameNumber: extended,
                payload: completedPayload
            )
        )
    }

    private mutating func prunePendingFrames() {
        while pendingOrder.count > Self.maximumPendingFrames {
            if let discarded = pendingFrames.removeValue(forKey: pendingOrder.removeFirst()) {
                recordIncomplete(discarded)
            }
        }
    }

    private mutating func recordIncomplete(_ frame: PendingFrame) {
        guard !frame.isComplete else { return }
        incompleteFrameCount &+= 1
        missingFragmentCount &+= UInt64(max(0, frame.fragmentCount - frame.receivedCount))
    }

    private func extendedFrameNumber(for rawValue: UInt16) -> UInt64 {
        guard let lastDeliveredFrameNumber else { return UInt64(rawValue) }
        let wrap = UInt64(UInt16.max) + 1
        let halfWrap = wrap / 2
        let base = lastDeliveredFrameNumber & ~(wrap - 1)
        var candidate = base | UInt64(rawValue)
        if candidate + halfWrap < lastDeliveredFrameNumber {
            candidate += wrap
        } else if candidate > lastDeliveredFrameNumber + halfWrap, candidate >= wrap {
            candidate -= wrap
        }
        return candidate
    }

    private func makeAcknowledgement(frameNumber: UInt16, highMask: UInt64, lowMask: UInt64) -> Data {
        var result = Data()
        Self.appendLittleEndian(frameNumber, to: &result)
        Self.appendLittleEndian(highMask, to: &result)
        Self.appendLittleEndian(lowMask, to: &result)
        return result
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var startCodes: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                startCodes.append((index, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                startCodes.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }

        var nalUnits: [Data] = []
        for (position, startCode) in startCodes.enumerated() {
            let start = startCode.offset + startCode.length
            var end = position + 1 < startCodes.count ? startCodes[position + 1].offset : bytes.count
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            if end > start { nalUnits.append(data.subdata(in: start..<end)) }
        }
        return nalUnits
    }

    static func jpegPayload(in data: Data) -> Data? {
        guard data.count >= 4,
              data[data.startIndex] == 0xff,
              data[data.startIndex + 1] == 0xd8,
              data[data.endIndex - 2] == 0xff,
              data[data.endIndex - 1] == 0xd9 else { return nil }
        return data
    }
}

enum ARSDKTelemetryProtocol {
    static func decode(_ data: Data) -> ARSDKTelemetryEvent? {
        guard data.count >= 4 else { return nil }
        let project = data[0]
        let commandClass = data[1]
        let command = UInt16(data[2]) | UInt16(data[3]) << 8

        if project == 0, commandClass == 5, command == 1, data.count >= 5 {
            return .droneBattery(Int(data[4]))
        }
        if project == 0, commandClass == 5, command == 7,
           let rawRSSI = int16(data, at: 4) {
            return .wifiSignal(Int(rawRSSI))
        }
        if project == 3, commandClass == 11, command == 4, data.count >= 5 {
            return .jumpingSumoLinkQuality(Int(data[4]))
        }
        if project == 1, commandClass == 4, command == 0 {
            return .flatTrimChanged
        }
        if project == 0, commandClass == 14, command == 0, data.count >= 8 {
            return .magnetometerCalibrationState(
                x: data[4] != 0,
                y: data[5] != 0,
                z: data[6] != 0,
                failed: data[7] != 0
            )
        }
        if project == 0, commandClass == 14, command == 1, data.count >= 5 {
            return .magnetometerCalibrationRequired(data[4] != 0)
        }
        if project == 0, commandClass == 14, command == 2,
           let rawAxis = uint32(data, at: 4),
           let axis = ARSDKMagnetometerAxis(rawValue: rawAxis) {
            return .magnetometerCalibrationAxis(axis)
        }
        if project == 0, commandClass == 14, command == 3, data.count >= 5 {
            return .magnetometerCalibrationStarted(data[4] != 0)
        }
        if project == 4, commandClass == 8, command == 0, data.count >= 5 {
            return .controllerBattery(Int(data[4]))
        }
        if project == 4, commandClass == 8, command == 3, let state = uint32(data, at: 4) {
            return .controllerBatteryState(state)
        }
        if project == 1, commandClass == 4, command == 1, let state = uint32(data, at: 4) {
            return .flyingState(state)
        }
        if project == 1, commandClass == 4, command == 4,
           let latitude = double(data, at: 4), let longitude = double(data, at: 12) {
            return .gpsPosition(latitude: latitude, longitude: longitude)
        }
        if project == 1, commandClass == 4, command == 8, let altitude = double(data, at: 4) {
            return .altitude(altitude)
        }
        if project == 1, commandClass == 4, command == 9,
           let latitude = double(data, at: 4), let longitude = double(data, at: 12) {
            return .gpsPosition(latitude: latitude, longitude: longitude)
        }
        if project == 1, commandClass == 4, command == 5,
           let north = float(data, at: 4), let east = float(data, at: 8), let down = float(data, at: 12) {
            return .speed(north: north, east: east, down: down)
        }
        if project == 1, commandClass == 4, command == 6,
           let roll = float(data, at: 4), let pitch = float(data, at: 8), let yaw = float(data, at: 12) {
            return .attitude(roll: roll, pitch: pitch, yaw: yaw)
        }
        if project == 1, commandClass == 24, command == 2, data.count >= 5 {
            return .gpsFix(data[4] != 0)
        }
        if project == 1, commandClass == 24, command == 0,
           let latitude = double(data, at: 4), let longitude = double(data, at: 12) {
            return .homePosition(latitude: latitude, longitude: longitude)
        }
        if project == 1, commandClass == 31, command == 0, data.count >= 5 {
            return .satelliteCount(Int(data[4]))
        }
        if project == 4, commandClass == 3, command == 1,
           let status = uint32(data, at: 4),
           let name = cString(data, at: 8),
           let productID = uint16(data, at: name.nextOffset) {
            return .aircraftConnection(
                status: status,
                deviceName: name.value,
                productID: productID
            )
        }
        if project == 0, commandClass == 3, command == 3,
           let software = cString(data, at: 4),
           let hardware = cString(data, at: software.nextOffset) {
            return .productVersion(software: software.value, hardware: hardware.value)
        }
        return nil
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16? {
        guard data.count >= offset + 2 else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func int16(_ data: Data, at offset: Int) -> Int16? {
        uint16(data, at: offset).map { Int16(bitPattern: $0) }
    }

    private static func cString(_ data: Data, at offset: Int) -> (value: String, nextOffset: Int)? {
        guard offset < data.count,
              let end = data[offset...].firstIndex(of: 0) else { return nil }
        let bytes = data[offset..<end]
        guard let value = String(data: bytes, encoding: .utf8) else { return nil }
        return (value, end + 1)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        return UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }

    private static func float(_ data: Data, at offset: Int) -> Float? {
        uint32(data, at: offset).map(Float.init(bitPattern:))
    }

    private static func double(_ data: Data, at offset: Int) -> Double? {
        guard data.count >= offset + 8 else { return nil }
        var bits: UInt64 = 0
        for index in 0..<8 {
            bits |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return Double(bitPattern: bits)
    }
}

enum ARSDKPhotoConnectionError: LocalizedError {
    case invalidHost
    case socket(String)
    case discovery(String)
    case discoveryTimeout
    case connectionRejected(Int)
    case missingCommandPort

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "The ARSDK host is not a valid IPv4 address."
        case .socket(let detail): return "Could not open the ARSDK command socket: \(detail)"
        case .discovery(let detail): return "ARDiscovery failed: \(detail)"
        case .discoveryTimeout: return "ARDiscovery timed out."
        case .connectionRejected(let status): return "The ARSDK endpoint rejected the connection (status \(status))."
        case .missingCommandPort: return "The discovery reply did not contain a command port."
        }
    }
}
