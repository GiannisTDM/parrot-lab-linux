import Foundation
import CLinuxBridge
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct LabOptions {
    var mode = LabMode.air
    var speedLimit = 30
    var host = "192.168.42.88"
    var telnetPort: UInt16 = 23
    var discoveryPort: UInt16 = 44444
    var restreamPorts: [UInt16] = [7711, 6007]
    var videoPort: UInt16 = 55004
    var listenOnly = false
    var demo = false
    var headless = false
    var connect = false
    var video = false
    var duration: Double = 0
    var screenshot: String?
    var archive: String?
    var mediaDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Videos/Parrot Lab")

    static func parse(_ args: [String]) throws -> LabOptions {
        var result = LabOptions(), index = 0
        func next(_ option: String) throws -> String {
            index += 1
            guard index < args.count else { throw LabError.message("Missing value for \(option)") }
            return args[index]
        }
        func port(_ value: String) throws -> UInt16 {
            guard let p = UInt16(value), p > 0 else { throw LabError.message("Invalid port: \(value)") }; return p
        }
        while index < args.count {
            let option = args[index]
            switch option {
            case "--ground": result.mode = .sumoDirect
            case "--ground-sc2": result.mode = .sumoSC2
            case "--speed-limit":
                guard let value = Int(try next(option)), (0...100).contains(value) else { throw LabError.message("Speed limit must be 0–100") }
                result.speedLimit = value
            case "--host": result.host = try next(option)
            case "--telnet-port": result.telnetPort = try port(next(option))
            case "--discovery-port": result.discoveryPort = try port(next(option))
            case "--restream-port": result.restreamPorts = [try port(next(option))]
            case "--video-port": result.videoPort = try port(next(option))
            case "--listen": result.listenOnly = true; result.video = true
            case "--demo": result.demo = true
            case "--headless": result.headless = true
            case "--connect": result.connect = true
            case "--video": result.video = true
            case "--duration":
                let value = try next(option)
                guard let seconds = Double(value), seconds.isFinite, (0.1...86400).contains(seconds) else {
                    throw LabError.message("Duration must be between 0.1 and 86400 seconds")
                }
                result.duration = seconds
            case "--screenshot": result.screenshot = try next(option)
            case "--archive": result.archive = try next(option)
            case "--media-dir": result.mediaDirectory = URL(fileURLWithPath: try next(option), isDirectory: true)
            default: throw LabError.message("Unknown option: \(option). Use --help.")
            }
            index += 1
        }
        guard pl_ipv4_valid(result.host) == 1 else { throw LabError.message("Host must be an IPv4 address") }
        if !args.contains("--host") { result.host = result.mode.host }
        if args.contains("--ground") && args.contains("--ground-sc2") { throw LabError.message("Choose one ground connection route") }
        if result.mode == .sumoDirect && result.listenOnly { throw LabError.message("Direct Sumo video uses ARDiscovery, not an RTP listener") }
        if result.demo && (result.connect || result.video || result.archive != nil) {
            throw LabError.message("Demo cannot be combined with a connection, RTP listener, or archive")
        }
        if result.screenshot != nil && result.headless { throw LabError.message("--screenshot requires the desktop") }
        if result.archive != nil && !result.video { throw LabError.message("--archive requires --video or --listen") }
        return result
    }
}

struct EncodedFrame { let bytes: Data; let pts: UInt64 }

final class RawArchive {
    private let queue = DispatchQueue(label: "parrotlab.linux.archive")
    private let lock = NSLock()
    private var queuedBytes = 0
    private var accepting = true
    private var finished = false
    private var failure: String?
    private let handle: FileHandle
    let path: String
    init(path: String) throws {
        self.path = path
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Create atomically without replacing an existing recording.
        let fd = path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o644) }
        guard fd >= 0 else { throw LabError.message("Cannot create archive (file may already exist): \(path)") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
    func append(_ data: Data) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if queuedBytes + data.count > 16 * 1024 * 1024 {
            failure = "Archive stopped: disk queue exceeded 16 MiB"; accepting = false; lock.unlock(); return
        }
        queuedBytes += data.count
        // Submit before releasing the lock so finish cannot overtake a write.
        queue.async { [self] in
            do { try handle.write(contentsOf: data) }
            catch { lock.lock(); failure = "Archive write failed: \(error.localizedDescription)"; accepting = false; lock.unlock() }
            lock.lock(); queuedBytes -= data.count; lock.unlock()
        }
        lock.unlock()
    }
    func finish() {
        lock.lock(); accepting = false; lock.unlock()
        queue.sync {
            guard !finished else { return }
            finished = true
            do { try handle.synchronize(); try handle.close() }
            catch { lock.lock(); failure = "Archive finalization failed: \(error.localizedDescription)"; lock.unlock() }
        }
    }
}

final class LabSession {
    private let lock = NSRecursiveLock()
    private var snapshot = TelemetrySnapshot()
    private let parser = SC2TelemetryParser()
    private var reducer = ARSDKTelemetryReducer()
    private var connectionToken: Cancellation?
    private var connectionWorkers = 0
    private var videoToken: Cancellation?
    private var archive: RawArchive?
    private var frames: [EncodedFrame] = []
    private var frameBytes = 0
    private var logs: [String] = []
    private var stats = RTPVideoStats()
    private var updated: TimeInterval?
    private(set) var demo = false
    private var fatalVideoError: String?
    private var finalArchiveError: String?
    private let groundWorker = DispatchGroup()
    private var jpegStart = 0.0, jpegWindow = 0.0, jpegBytes = 0, jpegFrames = 0
    let groundControl = GroundControl()
    private(set) var mode: LabMode
    let options: LabOptions
    init(options: LabOptions) {
        self.options = options; mode = options.mode; groundControl.setLimit(options.speedLimit)
    }
    func setMode(_ mode: LabMode) { disconnect(); self.mode = mode }
    var archiveExtension: String { mode == .sumoDirect ? "mjpeg" : "h264" }
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    var connected: Bool { locked { connectionToken != nil } }
    var videoRunning: Bool { locked { videoToken != nil } }
    var recording: Bool { locked { archive != nil } }
    var archiveError: String? { locked { archive?.error ?? finalArchiveError } }
    var videoError: String? { locked { fatalVideoError } }
    func log(_ message: String) { locked { logs.append(message); if logs.count > 100 { logs.removeFirst(logs.count - 100) } } }

    func connect(host: String) throws {
        guard pl_ipv4_valid(host) == 1 else { throw LabError.message("Enter a valid IPv4 address") }
        disconnect()
        let mode = self.mode
        let token = Cancellation()
        locked {
            demo = false; snapshot = TelemetrySnapshot(); parser.reset(); reducer.reset(); updated = nil
            connectionToken = token; connectionWorkers = mode == .sumoDirect ? 1 : 2; snapshot.connectionLabel = "Connecting to \(host)"
        }
        let updateLine: (String) -> Void = { [weak self] line in
            self?.locked {
                guard !token.isCancelled, let self else { return }
                if self.parser.consume(line: line, into: &self.snapshot) { self.updated = ProcessInfo.processInfo.systemUptime }
            }
        }
        let updateEvent: (ARSDKTelemetryEvent) -> Void = { [weak self] event in
            self?.locked {
                guard !token.isCancelled, let self else { return }
                if self.reducer.consume(event, into: &self.snapshot) { self.updated = ProcessInfo.processInfo.systemUptime }
            }
        }
        let logger: (String) -> Void = { [weak self] message in
            self?.locked { if !token.isCancelled { self?.log(message) } }
        }
        if mode != .sumoDirect { DispatchQueue(label: "parrotlab.linux.telnet").async {
            Transport.telnet(host: host, port: self.options.telnetPort, token: token, onLine: updateLine, log: logger)
            self.connectionWorkerFinished(token)
        } }
        groundWorker.enter()
        DispatchQueue(label: "parrotlab.linux.arsdk").async {
            defer { self.groundWorker.leave() }
            Transport.arsdk(host: host, port: self.options.discoveryPort, token: token,
                mode: mode, ground: mode.ground ? self.groundControl : nil,
                videoRequested: { self.locked { self.connectionToken === token && self.videoToken != nil } },
                jpeg: { image in self.receiveJPEG(image, token: token) }, event: updateEvent, log: logger)
            self.connectionWorkerFinished(token)
        }
    }
    private func connectionWorkerFinished(_ token: Cancellation) {
        locked {
            guard connectionToken === token, !token.isCancelled else { return }
            connectionWorkers -= 1
            if connectionWorkers == 0 {
                connectionToken = nil; updated = nil; snapshot = TelemetrySnapshot()
                if mode == .sumoDirect, videoToken != nil { fatalVideoError = "Sumo connection ended; reconnect to restart video" }
                log("Telemetry disconnected; Connect to retry")
            }
        }
    }
    func disconnect() {
        groundControl.setAvailable(false)
        locked { connectionToken?.cancel(); connectionToken = nil; demo = false; updated = nil; snapshot = TelemetrySnapshot() }
        stopVideo()
        if mode.ground { _ = groundWorker.wait(timeout: .now() + .milliseconds(800)) }
    }
    func startDemo() {
        disconnect()
        locked { demo = true; snapshot = TelemetrySnapshot(); snapshot.connectionLabel = "DEMO · simulated telemetry" }
        log("Demo uses local generated telemetry and video; no controller connection")
    }
    func demoTick(_ time: Double) {
        locked {
            guard demo else { return }
            snapshot.droneBatteryPercent = 74; snapshot.sc2BatteryPercent = 83
            snapshot.flightState = "DEMO"; snapshot.altitude = 12.5 + sin(time) * 2
            snapshot.horizontalSpeed = 3.4; snapshot.satelliteCount = 12
            snapshot.chain0RSSI = -43; snapshot.chain1RSSI = -46; snapshot.noise = -92
            snapshot.roll = sin(time * 0.4) * 0.12; snapshot.pitch = cos(time * 0.3) * 0.04
            snapshot.distanceFromHome = 42; snapshot.gpsFixed = true; updated = ProcessInfo.processInfo.systemUptime
        }
    }
    func startVideo(host: String) throws {
        guard pl_ipv4_valid(host) == 1 else { throw LabError.message("Enter a valid IPv4 address") }
        stopVideo()
        if mode == .sumoDirect {
            if !connected { try connect(host: host) }
            locked {
                demo = false; videoToken = Cancellation(); fatalVideoError = nil; stats = RTPVideoStats()
                jpegStart = ProcessInfo.processInfo.systemUptime; jpegWindow = jpegStart; jpegBytes = 0; jpegFrames = 0
            }
            log("Sumo video will arrive over the direct ARNetwork connection")
            return
        }
        // Open first: some controllers begin transmitting immediately after GET /video.
        let initialSocket = try Socket.udp(options.videoPort)
        let token = Cancellation()
        locked {
            if demo { snapshot = TelemetrySnapshot(); updated = nil }
            demo = false; videoToken = token; fatalVideoError = nil; stats = RTPVideoStats()
        }
        log("Video listener opened on UDP \(initialSocket.port)")
        DispatchQueue(label: "parrotlab.linux.rtp", qos: .userInitiated).async { [self] in
            do {
                var socket = initialSocket
                if !options.listenOnly {
                    let port = try Transport.restream(host: host, ports: options.restreamPorts, token: token)
                    if port != socket.port { socket = try Socket.udp(port) }
                    log("SC2 H.264 restream announced UDP \(port)")
                }
                var assembler = H264RTPAssembler()
                var previous: UInt16?, lastTimestamp: UInt32?, firstTimestamp: UInt32?
                var timestampEpoch: UInt64 = 0
                var bytes = 0, units = 0
                var window = ProcessInfo.processInfo.systemUptime
                while !token.isCancelled {
                    guard let data = try socket.receive(), let packet = RTPPacket(data: data), packet.payloadType == 96 else { continue }
                    var lost = 0
                    if let previous {
                        let delta = packet.sequence &- previous
                        if delta == 0 || delta >= 0x8000 {
                            locked { stats.duplicatePackets += 1 }; continue
                        }
                        lost = Int(delta - 1)
                        if lost > 0 { assembler.discardCurrentAccessUnit() }
                    }
                    previous = packet.sequence; bytes += data.count
                    locked { stats.packets += 1; stats.packetsLost += UInt64(lost) }
                    for unit in assembler.consume(packet: packet) {
                        if unit.rtpTimestamp == lastTimestamp { continue }
                        if let lastTimestamp, unit.rtpTimestamp < lastTimestamp,
                           lastTimestamp &- unit.rtpTimestamp > 0x80000000 { timestampEpoch += 1 << 32 }
                        lastTimestamp = unit.rtpTimestamp
                        if firstTimestamp == nil { firstTimestamp = unit.rtpTimestamp }
                        let ticks = timestampEpoch + UInt64(unit.rtpTimestamp)
                        let origin = UInt64(firstTimestamp!)
                        let pts = ticks >= origin ? (ticks - origin) * 1_000_000_000 / 90_000 : 0
                        var annexB = Data()
                        for nal in unit.nalUnits { annexB.append(contentsOf: [0, 0, 0, 1]); annexB.append(nal) }
                        try locked {
                            guard !token.isCancelled else { return }
                            archive?.append(annexB)
                            if !options.headless {
                                guard frameBytes + annexB.count <= 4 * 1024 * 1024 else {
                                    throw LabError.message("Video stopped: display queue exceeded 4 MiB")
                                }
                                frames.append(EncodedFrame(bytes: annexB, pts: pts)); frameBytes += annexB.count
                            }
                            snapshot.videoLastRTPTimestamp = unit.rtpTimestamp
                        }
                        units += 1
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - window >= 1 {
                        locked { stats.bitrateKbps = Int(Double(bytes) * 8 / 1000 / (now - window)); stats.encodedAUFPS = Double(units) / (now - window) }
                        bytes = 0; units = 0; window = now
                    }
                }
            } catch {
                locked { if !token.isCancelled { fatalVideoError = error.localizedDescription; log(error.localizedDescription) } }
            }
        }
    }
    func stopVideo() {
        groundControl.stop()
        locked { videoToken?.cancel(); videoToken = nil; frames.removeAll(); frameBytes = 0; fatalVideoError = nil }
        stopArchive()
    }
    private func receiveJPEG(_ image: Data, token: Cancellation) {
        locked {
            guard connectionToken === token, !token.isCancelled, videoToken != nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            archive?.append(image)
            if !options.headless {
                // JPEG frames are independent: retain only the latest complete image.
                frames = [EncodedFrame(bytes: image, pts: UInt64(max(0, now - jpegStart) * 1_000_000_000))]
                frameBytes = image.count
            }
            jpegBytes += image.count; jpegFrames += 1; stats.packets += 1
            if now - jpegWindow >= 1 {
                stats.bitrateKbps = Int(Double(jpegBytes) * 8 / 1000 / (now - jpegWindow))
                stats.encodedAUFPS = Double(jpegFrames) / (now - jpegWindow)
                jpegWindow = now; jpegBytes = 0; jpegFrames = 0
            }
        }
    }
    func drainFrames() -> [EncodedFrame] { locked { defer { frames.removeAll(keepingCapacity: true); frameBytes = 0 }; return frames } }
    func startArchive(path: String) throws {
        guard videoRunning && !demo else { throw LabError.message("Start live video before archiving") }
        guard !recording else { throw LabError.message("An archive is already recording") }
        let recorder = try RawArchive(path: path)
        locked { archive = recorder; finalArchiveError = nil }
        log("Archiving original \(archiveExtension.uppercased()) to \(path)")
    }
    func stopArchive() {
        let recorder = locked { let value = archive; archive = nil; return value }
        recorder?.finish()
        if let recorder {
            locked { finalArchiveError = recorder.error }
            log(recorder.error ?? "Archive saved: \(recorder.path)")
        }
    }
    func mediaPath(extension ext: String) throws -> String {
        try FileManager.default.createDirectory(at: options.mediaDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return options.mediaDirectory.appendingPathComponent("ParrotLab-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6)).\(ext)").path
    }
    func display() -> (status: String, telemetry: String, log: String, roll: Double, pitch: Double) {
        locked {
            let age = updated.map { ProcessInfo.processInfo.systemUptime - $0 }
            let status = demo ? "DEMO · simulated telemetry and video" :
                connectionToken == nil ? "Disconnected" :
                age == nil ? "Connecting · awaiting telemetry" :
                age! > 3 ? "STALE TELEMETRY · \(Int(age!)) seconds since last update" : "Connected · receiving telemetry"
            func integer(_ value: Int?, suffix: String = "") -> String { value.map { "\($0)\(suffix)" } ?? "—" }
            func number(_ value: Double?, suffix: String = "") -> String { value.map { String(format: "%.1f", $0) + suffix } ?? "—" }
            if mode.ground {
                let control = groundControl.status, input = groundControl.input()
                let body = """
                GROUND · JUMPING SUMO
                \(demo ? "DEMO" : !control.ready ? "WAITING FOR SUMO LINK" : control.armed ? "DRIVE ARMED" : "DRIVE DISARMED")
                Speed limit   \(control.limit)%
                Command       \(input.speed) / \(input.turn)

                BATTERY
                Sumo          \(integer(snapshot.droneBatteryPercent, suffix: "%"))
                Controller    \(integer(snapshot.sc2BatteryPercent, suffix: "%"))

                LINK
                RSSI          \(integer(snapshot.reportedRSSI ?? snapshot.chain0RSSI, suffix: " dBm"))
                Quality       \(integer(snapshot.rxQuality, suffix: "%"))

                VIDEO · \(archiveExtension.uppercased())
                \(stats.bitrateKbps) kbps
                \(String(format: "%.1f", stats.encodedAUFPS)) frames/s
                \(mode == .sumoDirect ? "\(stats.packets) JPEG frames" : "\(stats.packets) packets · \(stats.packetsLost) lost")

                Hold WASD / arrows
                Space / Esc = stop
                """
                return ("\(mode.title) · \(status)", body, logs.suffix(4).joined(separator: "\n"), .nan, .nan)
            }
            let body = """
            FLIGHT
            \(snapshot.flightState)
            Altitude    \(number(snapshot.altitude, suffix: " m"))
            Speed       \(number(snapshot.horizontalSpeed, suffix: " m/s"))
            Home        \(number(snapshot.distanceFromHome, suffix: " m"))
            Satellites  \(integer(snapshot.satelliteCount))

            BATTERY
            Drone       \(integer(snapshot.droneBatteryPercent, suffix: "%"))
            Controller  \(integer(snapshot.sc2BatteryPercent, suffix: "%"))

            RADIO
            Chain A0    \(integer(snapshot.chain0RSSI, suffix: " dBm"))
            Chain A1    \(integer(snapshot.chain1RSSI, suffix: " dBm"))
            SNR         \(integer(snapshot.snr, suffix: " dB"))

            VIDEO
            \(stats.bitrateKbps) kbps · \(String(format: "%.1f", stats.encodedAUFPS)) AU/s
            \(stats.packets) packets · \(stats.packetsLost) lost
            """
            let fresh = age.map { $0 <= 3 } ?? false
            return (status, body, logs.suffix(4).joined(separator: "\n"),
                    fresh ? snapshot.roll ?? .nan : .nan, fresh ? snapshot.pitch ?? .nan : .nan)
        }
    }
}
