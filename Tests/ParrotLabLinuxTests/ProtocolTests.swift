import XCTest
@testable import ParrotLabLinux

final class ProtocolTests: XCTestCase {
    func testTelemetryAndMetadataFromMacCore() {
        XCTAssertTrue(ARSDKTelemetryReducer.selfTest())
        XCTAssertTrue(VideoMetadataV2.selfTest())
        let parser = SC2TelemetryParser(); var state = TelemetrySnapshot()
        XCTAssertTrue(parser.consume(line: "rssi_mpp:-42, rssi:-48, state:LANDED, altitude:500, latitude:500, longitude:500, roll:0, pitch:0, yaw:0", into: &state))
        XCTAssertNil(state.altitude); XCTAssertNil(state.latitude)
        XCTAssertEqual(state.sc2RSSI, -42)
        XCTAssertEqual(SC2TelemetryParser.stripANSI(from: "plain text"), "plain text")
        XCTAssertEqual(SC2TelemetryParser.stripANSI(from: "\u{001B}[31mred\u{001B}[0m"), "red")
    }
    func testTelnetNegotiationAtEveryByteBoundary() {
        var parser = TelnetParser(); var lines: [String] = []; var reply = Data()
        let stream = Data([255, 251, 1, 255, 253, 3, 255, 250, 24, 1, 255, 240]) + Data("battery\r\n".utf8)
        for byte in stream {
            let result = parser.consume(Data([byte])); lines += result.lines; reply.append(result.reply)
        }
        XCTAssertEqual(reply, Data([255, 254, 1, 255, 252, 3])); XCTAssertEqual(lines, ["battery"])
    }
    func testARNetworkMultipleFramesAndMalformedLength() {
        let a = ARSDKPhotoProtocol.frame(type: 4, id: 126, sequence: 255, payload: Data([0, 5, 1, 0, 74]))
        let b = ARSDKPhotoProtocol.frame(type: 2, id: 0, sequence: 0, payload: Data([1, 2]))
        XCTAssertEqual(ARNetworkFrame.decode(a + b).count, 2)
        XCTAssertEqual(ARNetworkFrame.decode(a + b.dropLast()).count, 1)
        XCTAssertTrue(ARNetworkFrame.decode(Data([4, 126, 1, 255, 255, 255, 255])).isEmpty)
        XCTAssertEqual(ARSDKPhotoProtocol.nextSequence(after: 255), 0)
    }
    private func packet(_ payload: [UInt8], timestamp: UInt32 = 1, marker: Bool = true) -> RTPPacket {
        let bytes: [UInt8] = [0x80, marker ? 0xe0 : 0x60, 0, 1,
            UInt8(truncatingIfNeeded: timestamp >> 24), UInt8(truncatingIfNeeded: timestamp >> 16),
            UInt8(truncatingIfNeeded: timestamp >> 8), UInt8(truncatingIfNeeded: timestamp), 0, 0, 0, 1] + payload
        return RTPPacket(data: Data(bytes))!
    }
    func testFUAreassemblyAndMissingFragments() {
        var assembler = H264RTPAssembler()
        XCTAssertTrue(assembler.consume(packet: packet([0x7c, 0x85, 1, 2], marker: false)).isEmpty)
        let good = assembler.consume(packet: packet([0x7c, 0x45, 3, 4]))
        XCTAssertEqual(good.first?.nalUnits, [Data([0x65, 1, 2, 3, 4])])
        assembler.reset()
        _ = assembler.consume(packet: packet([0x7c, 0x85, 1, 2], marker: false))
        assembler.discardCurrentAccessUnit()
        XCTAssertTrue(assembler.consume(packet: packet([0x7c, 0x45, 9])).isEmpty)
        XCTAssertEqual(assembler.consume(packet: packet([0x65, 7], timestamp: 2)).count, 1)
    }
    func testOrphanFUAAndMalformedSTAPA() {
        var assembler = H264RTPAssembler()
        XCTAssertTrue(assembler.consume(packet: packet([0x7c, 0x45, 9])).isEmpty)
        assembler.reset()
        XCTAssertTrue(assembler.consume(packet: packet([0x78, 0, 10, 0x65, 1])).isEmpty)
        assembler.reset()
        XCTAssertEqual(assembler.consume(packet: packet([0x78, 0, 2, 0x67, 1, 0, 2, 0x68, 2])).first?.nalUnits,
                       [Data([0x67, 1]), Data([0x68, 2])])
    }
    func testRTPHeaderRejectsTruncationAndBadPadding() {
        XCTAssertNil(RTPPacket(data: Data([0x80, 96])))
        XCTAssertNil(RTPPacket(data: Data([0xb0, 96, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 255, 255])))
        XCTAssertNil(RTPPacket(data: Data([0xa0, 96, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0])))
    }
    func testSDPWaitsForCompleteBody() {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/sdp\r\n\r\n"
        XCTAssertNil(Transport.parseSDP(Data(header.utf8)))
        XCTAssertNil(Transport.parseSDP(Data((header + "m=video 550").utf8)))
        XCTAssertEqual(Transport.parseSDP(Data((header + "m=video 55004 RTP/AVP 96\r\n").utf8)), 55004)
        XCTAssertNil(Transport.parseSDP(Data((header + "m=video 0 RTP/AVP 96\r\n").utf8)))
        XCTAssertNil(Transport.parseSDP(Data("HTTP/1.1 404 Missing\r\n\r\nm=video 55004 RTP/AVP 96\r\n".utf8)))
        let body = "m=video 55004 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"
        let lengthHeader = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        XCTAssertNil(Transport.parseSDP(Data((lengthHeader + "m=video 55004 RTP/AVP 96\r\n").utf8)))
        XCTAssertEqual(Transport.parseSDP(Data((lengthHeader + body).utf8)), 55004)
        XCTAssertNil(Transport.parseSDP(Data((header + body.replacingOccurrences(of: "H264", with: "JPEG")).utf8)))
        XCTAssertNil(Transport.parseSDP(Data((header + body.replacingOccurrences(of: "H264", with: "H265")).utf8)))
    }
    func testOptionsAndArchiveDoNotOverwrite() throws {
        XCTAssertThrowsError(try LabOptions.parse(["--duration", "nan"]))
        XCTAssertThrowsError(try LabOptions.parse(["--video-port", "65536"]))
        XCTAssertThrowsError(try LabOptions.parse(["--host", "localhost; reboot"]))
        XCTAssertThrowsError(try LabOptions.parse(["--demo", "--connect"]))
        XCTAssertThrowsError(try LabOptions.parse(["--demo", "--video"]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.h264").path
        let archive = try RawArchive(path: path)
        archive.append(Data([0, 0, 0, 1, 0x65])); archive.finish()
        archive.finish()
        XCTAssertNil(archive.error)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data([0, 0, 0, 1, 0x65]))
        XCTAssertThrowsError(try RawArchive(path: path))
    }
    func testUDPTransportLoopback() throws {
        let receiver = try Socket.udp(), sender = try Socket.udp()
        try sender.peer("127.0.0.1", receiver.port)
        try sender.send(Data([1, 2, 3, 4]))
        XCTAssertEqual(try receiver.receive(timeout: 500), Data([1, 2, 3, 4]))
        XCTAssertNil(try receiver.receive(timeout: 10))
    }
    func testAssemblerBoundsAndRecovery() {
        var assembler = H264RTPAssembler()
        let fragment = [UInt8](repeating: 7, count: 60000)
        _ = assembler.consume(packet: packet([0x7c, 0x85] + fragment, marker: false))
        for _ in 0..<75 {
            XCTAssertTrue(assembler.consume(packet: packet([0x7c, 0x05] + fragment, marker: false)).isEmpty)
        }
        XCTAssertTrue(assembler.consume(packet: packet([0x7c, 0x45, 7])).isEmpty)
        XCTAssertEqual(assembler.consume(packet: packet([0x65, 7], timestamp: 2)).count, 1)
    }
    func testMalformedDatagramsDoNotCrashDecoders() {
        // Deterministic corpus, including truncated RTP/ARNetwork/ARCommands.
        var seed: UInt64 = 0x504152524f54
        for length in 0..<256 {
            var bytes: [UInt8] = []
            for _ in 0..<length {
                seed = seed &* 6364136223846793005 &+ 1
                bytes.append(UInt8(truncatingIfNeeded: seed >> 32))
            }
            let data = Data(bytes)
            _ = RTPPacket(data: data)
            _ = ARNetworkFrame.decode(data)
            _ = ARSDKTelemetryProtocol.decode(data)
            _ = VideoMetadataV2.decode(data, rtpTimestamp: 0)
        }
    }
}
