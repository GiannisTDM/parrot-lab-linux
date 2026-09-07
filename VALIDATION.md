# Linux Qt validation — 2026-09-07

## Environment

- Ubuntu 26.04.1 LTS, ARM64 (`aarch64-unknown-linux-gnu`).
- Lima/VZ VM on an Apple Silicon Mac; 4 CPUs, 4 GiB RAM.
- Ubuntu `swiftlang` 6.1.3-4build1, Qt 6.10.2, GStreamer 1.28.2.
- Desktop checks use Xvfb/X11, Qt's xcb plugin and Fusion style. Video uses
  GStreamer software H.264/JPEG decoding and QPainter presentation.
- A ground demo and PNG capture also passed with Qt's offscreen platform plugin.
- The Mac repository was mounted read-only; native builds used a guest-side copy.

## Passed

- Native Swift debug and optimized release builds, including the C/C++17 Qt bridge.
- All 14 XCTest methods: protocol reducers, metadata, Telnet byte boundaries, ARNetwork
  framing, FU-A/STAP-A handling, malformed/truncated packets, assembly limits and recovery,
  split HTTP/SDP, argument validation, non-overwriting recording, UDP loopback,
  ground input lease/caps and ARStream1 JPEG assembly/ACK wraparound.
- Built-in `--self-test` on Linux and the portable macOS executable.
- Local controller emulator: ARDiscovery, split Telnet negotiation, state requests,
  telemetry reduction, command acknowledgements and ping replies.
- Desktop integration: 130 displayed H.264 frames in a five-second run, 25 ACKs and
  25 pongs; window PNG produced; saved Annex-B recording decoded again by FFmpeg.
- Error-path integration: invalid options, occupied UDP port, existing archive
  preservation and rejection of JPEG SDP arriving after the video-port line.
- Complete `scripts/test.sh --desktop` run passed: 14 unit tests, smoke test,
  air and ground headless integration, failure paths and desktop integration.
- Direct Sumo emulator: ARStream1 JPEG with reordered fragments/frame wraparound,
  ACK-enabled and ACK-disabled negotiations, byte-exact MJPEG archive and video disable.
- Ground desktop: 144 displayed JPEG frames in a run exercising keyboard/mouse holds,
  release, Space-stop, focus loss, telemetry loss with video still flowing, explicit
  re-arm, SIGTERM and normal window-close neutral shutdown. Saved MJPEG decoded
  again with FFmpeg.
- The visible Save PNG button produces a 640 × 480 decoded-frame PNG, distinct
  from the full desktop screenshot.
- Headless/view-only sessions emit no drive commands; SC2 controls require confirmed
  Sumo product identity, stop on product change and never automatically re-arm.
- SC2 ground H.264 restream emulator passes the existing video/archive test.
- Live mode cycling checks the rendered background: blue air → brown direct Sumo →
  brown SC2 Sumo → blue air, including intermediate fade colours, rapid F7 cycling
  during transitions, and the explicit reduced-motion override.
- Version 0.3.0-1 installed over 0.2.0-1 successfully; installed-binary self-test,
  live theme cycling, ground drive/MJPEG/PNG and air H.264 integrations all passed.
- The executable dynamically links Qt6Widgets/Gui/Core and has no GTK/GDK library
  dependency. Package dependencies now include Qt's X11 and Wayland plugins.
- Separate non-executable-stack/code/data program segments verified in the Linux executable;
  no writable-and-executable LOAD segment after explicit linker configuration.
- Desktop screenshot inspected visually: video, telemetry, controls and logs visible
  without overlap or clipping at 1180 × 800.

The initial native run exposed a Foundation portability bug in the copied ANSI
escape regex. It now uses a literal ESC character, with regression assertions.
Qt desktop capture uses an event-loop-deferred QWidget::grab. Frame PNGs save the
owned QImage without the horizon or interface theme. The X11 test selector handles
Qt's Latin-1 legacy window title and ignores its hidden selection-owner window.

SwiftPM prints warnings about filtering Qt `-DQT_*_LIB` and GStreamer `-pthread`
pkg-config flags. Builds, threaded networking and decode tests pass with the
Ubuntu toolchain; those warnings are not suppressed.
The Qt offscreen plugin reports unsupported size-hint propagation; demo playback
and capture still pass. Earlier GTK validation is preserved in Git history.

## Not yet validated

- Intel/AMD x86-64 Ubuntu builds or a physical Linux GPU/Wayland session.
  Installing Qt's Wayland plugin is not itself a Wayland runtime test.
- A real SC2/Bebop connection, USB-NCM setup, actual RF loss and stock intra-refresh video.
- Flight use, measured end-to-end FPV latency, long recordings or device hot-plugging.
- Real Jumping Sumo transport/driving, actual stop behaviour and telemetry cadence.
- SC2 stock JPEG RTP restreaming, flight control and Apple GPU processing features.

All integration traffic was loopback simulation. No drone or controller was contacted.
Generated screenshots and binaries live in ignored `test-output/` and `dist/` directories.

## Local test VM

Lima was installed on the Mac and a dedicated `parrotlab-ubuntu` VM was created;
the existing Windows VM was not used. The Linux toolchain and packaged app remain
installed there. The Qt source copy is at `/home/giannis.guest/parrot-lab-qt`;
`/home/giannis.guest/parrot-lab-linux` remains the previous GTK baseline.
The host repository mount is read-only. Restart the VM with
`limactl start parrotlab-ubuntu`; its installed app is `/usr/bin/parrot-lab`.
Running the GUI still requires a graphical display (or Xvfb for automated tests).
