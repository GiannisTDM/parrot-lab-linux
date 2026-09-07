import Foundation
import CLinuxBridge
#if os(Linux)
import Glibc
#else
import Darwin
#endif

let help = """
Parrot Lab Linux — telemetry, video preview and basic Sumo ground driving

  parrot-lab                              Open the desktop, disconnected
  parrot-lab --demo                       Show simulated telemetry/test video
  parrot-lab --host 192.168.42.88 --connect --video
  parrot-lab --headless --connect --duration 10
  parrot-lab --headless --listen --video-port 55004 --archive capture.h264

Options:
  --host IP              SC2 IPv4 address (default 192.168.42.88)
  --ground               Direct Jumping Sumo Wi-Fi (default 192.168.2.1)
  --ground-sc2           Sumo through SC2; existing H.264 restream route
  --speed-limit PERCENT  Ground drive cap, 0–100 (default 30)
  --connect              Connect telemetry at startup
  --video                Start SC2 H.264 or direct Sumo MJPEG video
  --listen               Receive RTP only; skip restream negotiation
  --video-port PORT       Local RTP port (default 55004)
  --telnet-port PORT      Telnet port (default 23)
  --discovery-port PORT   ARDiscovery port (default 44444)
  --restream-port PORT    Override the default 7711/6007 probes
  --demo                 Local simulation; no network connection
  --headless             Print telemetry in the terminal
  --duration SECONDS     Stop automatically (0.1–86400)
  --archive PATH         Archive H.264 or direct Sumo MJPEG; refuses existing files
  --media-dir PATH       Where desktop PNGs and archives are saved
  --screenshot PATH      Save the desktop after two seconds (requires display)
  --self-test            Run protocol smoke tests without a display or drone
  --help                 Show this help

Includes telemetry, video, PNG capture and original H.264/MJPEG archives.
Flight controls, device installers and advanced image processing are not included.
Ground mode: arm explicitly (button/F6), then hold WASD/arrows or direction buttons.
Release stops motion; Space/Esc, focus loss, stale telemetry or disconnect disarms.
No jump actions. Headless mode never arms or drives.
"""

final class DesktopController {
    let session: LabSession
    private let options: LabOptions
    private var started = false, video = false, captured = false
    private var captureRequested = false
    private let startTime = ProcessInfo.processInfo.systemUptime
    private var lastUpdate = 0.0
    private(set) var failed = false
    init(_ options: LabOptions) { self.options = options; session = LabSession(options: options) }
    func action(_ action: Int32, host: String) {
        do {
            switch action {
            case 1:
                stopVideo()
                if session.connected { session.disconnect() } else { try session.connect(host: host) }
            case 2:
                if video { stopVideo() }
                else {
                    guard pl_video_start(session.mode == .sumoDirect ? 2 : 0) != 0 else { throw LabError.message(String(cString: pl_video_error())) }
                    do { try session.startVideo(host: host); video = true }
                    catch { pl_video_stop(); throw error }
                }
            case 3:
                stopVideo(); session.startDemo()
                guard pl_video_start(1) != 0 else { throw LabError.message(String(cString: pl_video_error())) }
                video = true
            case 4:
                if session.recording { session.stopArchive() }
                else { try session.startArchive(path: session.mediaPath(extension: session.archiveExtension)) }
            case 5:
                let path = try session.mediaPath(extension: "png")
                guard pl_video_snapshot(path) != 0 else { throw LabError.message("No decoded frame available to save") }
                session.log("PNG saved: \(path)")
            case 6:
                stopVideo()
                let next = LabMode(rawValue: (session.mode.rawValue + 1) % 3)!
                session.setMode(next); pl_desktop_mode(next.rawValue, next.host)
            case 10:
                guard session.mode.ground, !session.demo else { return }
                let armed = session.groundControl.toggleArm()
                session.log(armed ? "Ground drive armed · hold a direction to move" : "Ground drive disarmed")
            case 11: session.groundControl.stop()
            case 12: if let limit = Int(host) { session.groundControl.setLimit(limit) }
            case 30:
                if session.mode.ground { session.groundControl.refresh(mask: Int(host) ?? 0) }
            default: break
            }
        } catch { session.log(error.localizedDescription); failed = true }
    }
    func stopVideo() { session.stopVideo(); pl_video_stop(); video = false }
    func tick() {
        if !started {
            started = true
            pl_desktop_mode(session.mode.rawValue, options.host)
            if options.demo { action(3, host: options.host) }
            else {
                if options.connect { action(1, host: options.host) }
                if options.video { action(2, host: options.host) }
                if let path = options.archive {
                    do { try session.startArchive(path: path) } catch { session.log(error.localizedDescription); failed = true }
                }
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        session.demoTick(elapsed)
        if let error = session.videoError { session.log(error); stopVideo(); failed = true }
        if session.recording, let error = session.archiveError { session.log(error); session.stopArchive(); failed = true }
        for frame in session.drainFrames() {
            let result = frame.bytes.withUnsafeBytes { pl_video_push($0.bindMemory(to: UInt8.self).baseAddress, $0.count, frame.pts) }
            if result == 0 { session.log(String(cString: pl_video_error())); stopVideo(); failed = true; break }
        }
        if video, !String(cString: pl_video_error()).isEmpty {
            session.log(String(cString: pl_video_error())); stopVideo(); failed = true
        }
        if elapsed - lastUpdate > 0.1 {
            lastUpdate = elapsed
            let view = session.display()
            let status = view.status + "  ·  \(pl_video_frames()) displayed frames"
            pl_desktop_update(status, view.telemetry, view.log, view.roll, view.pitch,
                              session.connected ? 1 : 0, video ? 1 : 0, session.recording ? 1 : 0)
            let control = session.groundControl.status
            pl_ground_update(control.armed ? 1 : 0, control.ready && !session.demo ? 1 : 0, Int32(control.limit))
        }
        if !captureRequested, elapsed >= 2, let path = options.screenshot {
            captureRequested = true
            if pl_desktop_capture(path) == 0 {
                captured = true; failed = true; session.log("Could not request desktop screenshot")
            }
        }
        if captureRequested, !captured, let path = options.screenshot {
            let status = pl_desktop_capture_status()
            if status == 2 { captured = true; print("Desktop screenshot saved: \(path)") }
            if status == -1 { captured = true; failed = true; session.log("Could not save desktop screenshot") }
        }
    }
    func finish() {
        if options.screenshot != nil && !captured { failed = true; fputs("Desktop closed before screenshot capture\n", stderr) }
        print("Displayed frames: \(pl_video_frames())")
        session.disconnect()
        if session.archiveError != nil { failed = true }
        print(session.display().log)
    }
}

func smokeTest() -> Bool {
    var parser = TelnetParser()
    let a = parser.consume(Data([255, 251]))
    let b = parser.consume(Data([1] + Array("hello\r\n".utf8)))
    var rtp = H264RTPAssembler()
    let bytes = Data([0x80, 0xe0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0x65, 0x42])
    guard let packet = RTPPacket(data: bytes) else { return false }
    let frame = rtp.consume(packet: packet)
    return a.reply.isEmpty && b.reply == Data([255, 254, 1]) && b.lines == ["hello"] &&
        ARSDKTelemetryReducer.selfTest() && VideoMetadataV2.selfTest() && frame.count == 1 &&
        ARSDKTelemetryProtocol.decode(Data([0, 5, 1, 0, 74])) == .droneBattery(74)
}

func run() throws -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") || args.contains("-h") { print(help); return 0 }
    if args == ["--self-test"] {
        let passed = smokeTest(); print(passed ? "Parrot Lab Linux self-test passed" : "Self-test failed"); return passed ? 0 : 1
    }
    let options = try LabOptions.parse(args)
    if options.headless {
        let session = LabSession(options: options)
        if options.demo { session.startDemo() }
        if options.connect { try session.connect(host: options.host) }
        if options.video { try session.startVideo(host: options.host) }
        if let path = options.archive { try session.startArchive(path: path) }
        // Signals are handled through Dispatch so archives can be finalized.
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let began = ProcessInfo.processInfo.systemUptime
        var lastPrint = -1.0
        let finish: (Int32) -> Void = { code in
            let view = session.display(); session.disconnect(); print(view.status); print(view.telemetry); print(session.display().log)
            exit(session.archiveError == nil ? code : 1)
        }
        interrupt.setEventHandler { finish(0) }; terminate.setEventHandler { finish(0) }
        interrupt.resume(); terminate.resume()
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler {
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            session.demoTick(elapsed)
            if let error = session.videoError { fputs("\(error)\n", stderr); finish(1) }
            if let error = session.archiveError { fputs("\(error)\n", stderr); finish(1) }
            if elapsed - lastPrint >= 1 {
                lastPrint = elapsed; let view = session.display(); print(view.status); print(view.telemetry); print(view.log); fflush(stdout)
            }
            if options.duration > 0 && elapsed >= options.duration { finish(0) }
        }
        timer.resume(); dispatchMain()
    }
    guard pl_desktop_available() != 0 else { throw LabError.message("The Qt desktop builds on Linux. Use --headless or --self-test on macOS.") }
    let controller = DesktopController(options)
    let pointer = Unmanaged.passUnretained(controller).toOpaque()
    let code = pl_desktop_run(pointer, { context, action, host in
        guard let context, let host else { return }
        Unmanaged<DesktopController>.fromOpaque(context).takeUnretainedValue().action(action, host: String(cString: host))
    }, { context in
        guard let context else { return }
        Unmanaged<DesktopController>.fromOpaque(context).takeUnretainedValue().tick()
    }, options.host, options.duration)
    controller.finish()
    return code == 0 && controller.failed ? 1 : code
}

do { exit(try run()) }
catch { fputs("Parrot Lab: \(error.localizedDescription)\n", stderr); exit(2) }
