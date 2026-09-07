# Linux validation — 2026-09-07

## Environment

- Ubuntu 26.04.1 LTS, ARM64 (`aarch64-unknown-linux-gnu`).
- Lima/VZ VM on an Apple Silicon Mac; 4 CPUs, 4 GiB RAM.
- Ubuntu `swiftlang` 6.1.3-4build1, GTK 4.22.4, GStreamer 1.28.2.
- Desktop checks use Xvfb/X11 and GTK's Cairo renderer. H.264 uses software libav.
- The Mac repository was mounted read-only; native builds used a guest-side copy.

## Passed

- Native Swift debug and optimized release builds, including the GTK/GStreamer C bridge.
- All 14 XCTest methods: protocol reducers, metadata, Telnet byte boundaries, ARNetwork
  framing, FU-A/STAP-A handling, malformed/truncated packets, assembly limits and recovery,
  split HTTP/SDP, argument validation, non-overwriting recording, UDP loopback,
  ground input lease/caps and ARStream1 JPEG assembly/ACK wraparound.
- Built-in `--self-test` on Linux and the portable macOS executable.
- Local controller emulator: ARDiscovery, split Telnet negotiation, state requests,
  telemetry reduction, command acknowledgements and ping replies.
- Desktop integration: 128 displayed H.264 frames in a five-second run, 25 ACKs and
  25 pongs; window PNG produced; saved Annex-B recording decoded again by FFmpeg.
- Error-path integration: invalid options, occupied UDP port, existing archive
  preservation and rejection of JPEG SDP arriving after the video-port line.
- Complete `scripts/test.sh --desktop` run passed: 14 unit tests, smoke test,
  air and ground headless integration, failure paths and desktop integration.
- Direct Sumo emulator: ARStream1 JPEG with reordered fragments/frame wraparound,
  ACK-enabled and ACK-disabled negotiations, byte-exact MJPEG archive and video disable.
- Ground desktop: 140 displayed JPEG frames in a run exercising keyboard/mouse holds,
  release, Space-stop, focus loss, telemetry loss with video still flowing, explicit
  re-arm and SIGTERM neutral shutdown. Saved MJPEG decoded again with FFmpeg.
- Headless/view-only sessions emit no drive commands; SC2 controls require confirmed
  Sumo product identity, stop on product change and never automatically re-arm.
- SC2 ground H.264 restream emulator passes the existing video/archive test.
- Live mode cycling checks the rendered background: blue air → brown direct Sumo →
  brown SC2 Sumo → blue air. Air and ground screenshots inspected for layout/colours.
- Release demo: 120 displayed generated-video frames in four seconds.
- Ubuntu `.deb` installation and the installed executable's self-test and desktop
  integration passed (127 displayed frames in the first installed-release run).
- Version 0.2.0-1 installed over 0.1.0-1 successfully; installed-binary self-test,
  live theme cycling, ground drive/MJPEG (138 displayed frames) and air H.264
  (128 displayed frames) integrations all passed.
- Separate non-executable-stack/code/data program segments verified in the Linux executable;
  no writable-and-executable LOAD segment after explicit linker configuration.
- Desktop screenshot inspected visually: video, telemetry, controls and logs visible
  without overlap or clipping at 1180 × 780 (air) and 1180 × 792 (ground).

The initial native run exposed a Foundation portability bug in the copied ANSI
escape regex. It now uses a literal ESC character, with regression assertions.
The GTK capture path snapshots the window's child after the frame clock's
`after-paint` signal, avoiding blank images during a pending layout pass.

SwiftPM prints repeated warnings about filtering `-pthread` from system-library
pkg-config flags. Builds, threaded networking and decode tests pass with the
Ubuntu toolchain; those warnings are not suppressed.
The desktop-capture helper also uses GTK's deprecated-but-supported GTK4 style
background snapshot API so captures include the actual theme and transition state.

## Not yet validated

- Intel/AMD x86-64 Ubuntu builds or a physical Linux GPU/Wayland session.
- A real SC2/Bebop connection, USB-NCM setup, actual RF loss and stock intra-refresh video.
- Flight use, measured end-to-end FPV latency, long recordings or device hot-plugging.
- Real Jumping Sumo transport/driving, actual stop behaviour and telemetry cadence.
- SC2 stock JPEG RTP restreaming, flight control and Apple GPU processing features.

All integration traffic was loopback simulation. No drone or controller was contacted.
Generated screenshots and binaries live in ignored `test-output/` and `dist/` directories.

## Local test VM

Lima was installed on the Mac and a dedicated `parrotlab-ubuntu` VM was created;
the existing Windows VM was not used. The Linux toolchain and packaged app remain
installed there. A persistent source copy is at `/home/giannis.guest/parrot-lab-linux`.
The host repository mount is read-only. Restart the VM with
`limactl start parrotlab-ubuntu`; its installed app is `/usr/bin/parrot-lab`.
Running the GUI still requires a graphical display (or Xvfb for automated tests).
