import Foundation
import CLinuxBridge
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum LabError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

/// Each socket belongs to one worker for its entire lifetime. Cancellation
/// never closes a descriptor underneath another thread's read or write.
final class Cancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

final class Socket {
    let fd: Int32
    init(fd: Int32) throws {
        guard fd >= 0 else { throw LabError.message("Socket error: \(String(cString: strerror(errno)))") }
        self.fd = fd
    }
    deinit { pl_close(fd) }
    static func tcp(_ host: String, _ port: UInt16, timeout: Int32 = 2000) throws -> Socket {
        try Socket(fd: pl_tcp_open(host, port, timeout))
    }
    static func udp(_ port: UInt16 = 0) throws -> Socket { try Socket(fd: pl_udp_open(port)) }
    var port: UInt16 { pl_local_port(fd) }
    func peer(_ host: String, _ port: UInt16) throws {
        guard pl_socket_peer(fd, host, port) == 0 else { throw LabError.message("Could not select UDP peer") }
    }
    func send(_ data: Data) throws {
        let sent = data.withUnsafeBytes { pl_send(fd, $0.baseAddress, $0.count, 500) }
        guard sent == data.count else { throw LabError.message("Socket send failed") }
    }
    /// nil means a timeout, empty Data means the TCP peer closed.
    func receive(timeout: Int32 = 50) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = pl_receive(fd, &bytes, bytes.count, timeout)
        if count == -2 { return nil }
        guard count >= 0 else { throw LabError.message("Socket receive failed: \(String(cString: strerror(errno)))") }
        return Data(bytes.prefix(Int(count)))
    }
}

/// Handles Telnet negotiation even when IAC sequences cross TCP reads.
struct TelnetParser {
    private enum State { case text, iac, option(UInt8), suboption, suboptionIAC }
    private var state = State.text
    private var line = Data()
    mutating func consume(_ data: Data) -> (lines: [String], reply: Data) {
        var lines: [String] = [], reply = Data()
        for byte in data {
            switch state {
            case .text:
                if byte == 255 { state = .iac }
                else if byte == 10 {
                    lines.append(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines))
                    line.removeAll(keepingCapacity: true)
                } else if byte != 0 { line.append(byte) }
            case .iac:
                if byte == 255 { line.append(byte); state = .text }
                else if (251...254).contains(byte) { state = .option(byte) }
                else if byte == 250 { state = .suboption }
                else { state = .text }
            case .option(let command):
                if command == 251 { reply.append(contentsOf: [255, 254, byte]) }
                if command == 253 { reply.append(contentsOf: [255, 252, byte]) }
                state = .text
            case .suboption: if byte == 255 { state = .suboptionIAC }
            case .suboptionIAC: state = byte == 240 ? .text : .suboption
            }
            // A malformed peer cannot build an unbounded line buffer.
            if line.count > 65536 { line.removeAll(keepingCapacity: false) }
        }
        return (lines, reply)
    }
}

struct ARNetworkFrame: Equatable {
    let type: UInt8, id: UInt8, sequence: UInt8
    let payload: Data
    static func decode(_ data: Data) -> [ARNetworkFrame] {
        var frames: [ARNetworkFrame] = [], offset = 0
        while offset + 7 <= data.count {
            let size = Int(UInt32(data[offset + 3]) | UInt32(data[offset + 4]) << 8 |
                           UInt32(data[offset + 5]) << 16 | UInt32(data[offset + 6]) << 24)
            guard size >= 7, size <= data.count - offset else { break }
            frames.append(ARNetworkFrame(type: data[offset], id: data[offset + 1], sequence: data[offset + 2],
                payload: data.subdata(in: offset + 7..<offset + size)))
            offset += size
        }
        return frames
    }
}

enum Transport {
    static func telnet(host: String, port: UInt16, token: Cancellation,
                       onLine: @escaping (String) -> Void, log: @escaping (String) -> Void) {
        do {
            let socket = try Socket.tcp(host, port)
            guard !token.isCancelled else { return }
            log("Telnet connected to \(host):\(port)")
            try socket.send(Data("\r\nexport TERM=dumb; export PATH=/usr/bin:/bin:/usr/sbin:/sbin; ulogcat\r\n".utf8))
            var parser = TelnetParser()
            while !token.isCancelled {
                guard let data = try socket.receive() else { continue }
                if data.isEmpty { throw LabError.message("Telnet connection closed") }
                let result = parser.consume(data)
                if !result.reply.isEmpty { try socket.send(result.reply) }
                for line in result.lines { onLine(line) }
            }
        } catch { if !token.isCancelled { log("Telnet: \(error.localizedDescription)") } }
    }

    static func discovery(host: String, port: UInt16, udp: Socket, token: Cancellation) throws -> UInt16 {
        let tcp = try Socket.tcp(host, port)
        let body: [String: Any] = ["controller_name": "Parrot Lab Linux", "controller_type": "computer",
                                  "d2c_port": Int(udp.port), "qos_mode": 0]
        try tcp.send(JSONSerialization.data(withJSONObject: body))
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var response = Data()
        while !token.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
            guard let data = try tcp.receive() else { continue }
            if data.isEmpty { break }
            response.append(data)
            guard response.count <= 65536 else { throw LabError.message("Discovery reply too large") }
            if let object = ARSDKDiscoveryProtocol.responseObject(from: response) {
                guard (object["status"] as? Int ?? -1) == 0 else { throw LabError.message("Controller rejected ARDiscovery") }
                guard let value = object["c2d_port"] as? Int, let port = UInt16(exactly: value), port > 0 else {
                    throw LabError.message("Discovery reply has no valid command port")
                }
                return port
            }
        }
        throw LabError.message("ARDiscovery timed out or returned incomplete JSON")
    }

    static func arsdk(host: String, port: UInt16, token: Cancellation,
                      event: @escaping (ARSDKTelemetryEvent) -> Void, log: @escaping (String) -> Void) {
        do {
            let udp = try Socket.udp()
            let remotePort = try discovery(host: host, port: port, udp: udp, token: token)
            guard !token.isCancelled else { return }
            try udp.peer(host, remotePort)
            log("ARSDK connected · command UDP \(remotePort) · telemetry UDP \(udp.port)")
            var sequences: [UInt8: UInt8] = [:]
            var pending: [UInt8: (packet: Data, sent: TimeInterval, retries: Int)] = [:]
            func send(type: UInt8, id: UInt8, payload: Data) throws {
                let seq = ARSDKPhotoProtocol.nextSequence(after: sequences[id]); sequences[id] = seq
                let packet = ARSDKPhotoProtocol.frame(type: type, id: id, sequence: seq, payload: payload)
                try udp.send(packet)
                if type == 4 { pending[seq] = (packet, ProcessInfo.processInfo.systemUptime, 0) }
            }
            try send(type: 4, id: 11, payload: ARSDKPhotoCommand.requestAllStates)
            try send(type: 4, id: 11, payload: ARSDKPhotoCommand.requestSkyControllerAllStates)
            var lastReceived: [UInt8: UInt8] = [:]
            var lastData = ProcessInfo.processInfo.systemUptime
            while !token.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastData > 10 { throw LabError.message("ARSDK telemetry timed out; reconnect to retry") }
                if let data = try udp.receive(), !data.isEmpty {
                    lastData = now
                    for frame in ARNetworkFrame.decode(data) {
                        if frame.type == 1, frame.id == 139, let sequence = frame.payload.first {
                            pending.removeValue(forKey: sequence); continue
                        }
                        if frame.type == 4 { try send(type: 1, id: frame.id &+ 128, payload: Data([frame.sequence])) }
                        if frame.type == 2, frame.id == 0 { try send(type: 2, id: 1, payload: frame.payload) }
                        guard frame.id == 126 || frame.id == 127 else { continue }
                        if lastReceived[frame.id] == frame.sequence { continue }
                        lastReceived[frame.id] = frame.sequence
                        if let telemetry = ARSDKTelemetryProtocol.decode(frame.payload) { event(telemetry) }
                    }
                }
                for key in Array(pending.keys) {
                    guard var command = pending[key], now - command.sent >= 0.15 else { continue }
                    if command.retries >= 5 {
                        pending.removeValue(forKey: key); log("State request acknowledgement timed out"); continue
                    }
                    try udp.send(command.packet); command.retries += 1; command.sent = now; pending[key] = command
                }
            }
        } catch { if !token.isCancelled { log("ARSDK: \(error.localizedDescription)") } }
    }

    static func restream(host: String, ports: [UInt16], token: Cancellation) throws -> UInt16 {
        var failures: [String] = []
        for port in ports {
            if token.isCancelled { break }
            do {
                let tcp = try Socket.tcp(host, port)
                try tcp.send(Data("GET /video HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8))
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                var data = Data()
                while !token.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                    guard let chunk = try tcp.receive() else { continue }
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    guard data.count <= 65536 else { throw LabError.message("Restream reply too large") }
                    // With a declared length, wait for the whole body. Without
                    // one, wait for EOF/deadline so a later codec line is not missed.
                    if completeHTTPBody(data), let announced = parseSDP(data) { return announced }
                }
                if let announced = parseSDP(data) { return announced }
                failures.append("\(port): incomplete or unsupported SDP (\(data.count) bytes)")
            } catch { failures.append("\(port): \(error.localizedDescription)"); continue }
        }
        throw LabError.message("No H.264 SDP from SC2 /video: \(failures.joined(separator: "; "))")
    }

    static func parseSDP(_ data: Data) -> UInt16? {
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("HTTP/1.0 200 ") || text.hasPrefix("HTTP/1.1 200 ") else { return nil }
        guard let separator = text.range(of: "\r\n\r\n") else { return nil }
        let headers = text[..<separator.lowerBound].lowercased()
        guard !headers.contains("transfer-encoding:") else { return nil }
        if headers.contains("content-length:"), !completeHTTPBody(data) { return nil }
        let body = String(text[separator.upperBound...])
        // A complete m= line is required so split TCP replies never yield a partial port.
        let pattern = #"(?m)^m=video\s+(\d+)\s+RTP/AVP\s+96\s*\r?$"#
        guard body.utf8.last == 10,
              let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body), let port = UInt16(body[range]), port > 0 else { return nil }
        if let mapping = body.range(of: #"(?im)^a=rtpmap:96\s+[^\r\n]+"#, options: .regularExpression) {
            guard body[mapping].range(of: #"(?i)^a=rtpmap:96\s+H264/90000\s*$"#, options: .regularExpression) != nil else { return nil }
        }
        return port
    }

    static func completeHTTPBody(_ data: Data) -> Bool {
        let delimiter = Data([13, 10, 13, 10])
        guard let separator = data.range(of: delimiter) else { return false }
        let headers = String(decoding: data[..<separator.lowerBound], as: UTF8.self)
        for line in headers.components(separatedBy: "\r\n") {
            guard line.lowercased().hasPrefix("content-length:") else { continue }
            guard let count = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)),
                  (0...65536).contains(count) else { return false }
            return data.count - separator.upperBound == count
        }
        return false
    }
}
