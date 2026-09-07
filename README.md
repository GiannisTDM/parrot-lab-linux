# Parrot Lab for Ubuntu

An initial native **Swift + GTK4 + GStreamer** Linux port for Ubuntu **26.04 LTS**.
It is a separate Swift package, built from the current macOS app's protocol code.

## Included

- Native desktop with controller address, connection status, telemetry and horizon.
- Local demo with generated video and simulated telemetry; works without hardware.
- SC2 Telnet telemetry and ARDiscovery/ARNetwork battery, navigation and attitude events.
- State requests, command acknowledgements, retries and ping replies.
- SC2 `/video` negotiation on TCP 7711/6007 and H.264 RTP reception on UDP 55004
  (or the port announced by SDP).
- FU-A/STAP-A assembly, RTP timestamp/sequence wraparound and VideoMetadataV2 parsing.
- Software H.264 decode through GStreamer/libav, bounded queues and a latest-frame display.
- PNG capture of the displayed video frame, without the HUD.
- Original Annex-B H.264 archiving, with a separate bounded disk queue.
- Basic Jumping Sumo ground mode: direct Wi-Fi telemetry/MJPEG preview and capped,
  explicitly armed hold-to-drive controls; optional SC2-routed ground controls.
- Blue air-mode styling fades to warm brown/amber for either ground route, matching
  the Mac palette. Video pixels and saved video frames are never tinted.
- Terminal mode, offline protocol tests and a local simulated-controller integration test.

This is an initial desktop/bench version. Live hardware compatibility and FPV latency
still need testing on the user's SC2, Bebop stream and Linux GPU. The demo and emulator
are explicitly simulated; they do not demonstrate a real drone connection.

## Build on Ubuntu 26.04

From this directory:

```sh
./scripts/install-ubuntu-deps.sh
./scripts/build.sh
.build/release/parrot-lab --demo
```

The dependency script installs Ubuntu's `swiftlang` package (the programming
language, not the unrelated OpenStack `swift` package), GTK4, GStreamer and FFmpeg.
Swift 6.0 or newer is required; Swift language mode 5 matches the macOS package.
There are no remotely fetched Swift package dependencies.

An optional per-user desktop installation is available:

```sh
./scripts/install-desktop.sh
```

This places the executable in `~/.local/bin` and the launcher under
`~/.local/share/applications`. Ensure `~/.local/bin` is in your desktop session's
PATH. The Ubuntu runtime packages must remain installed.

For a system-wide Ubuntu package, run `./scripts/package-deb.sh`, then install
the resulting `.deb` with `sudo apt install ./dist/parrot-lab_0.2.0-1_*.deb`.
Packages are architecture-specific: the provided initial build is **ARM64**, not
Intel/AMD x86-64. Build from source on an x86-64 Ubuntu machine for that architecture.
See [VALIDATION.md](VALIDATION.md) for the exact tested environment and limitations.

## Connect

Start `parrot-lab`, enter the SC2's current IPv4 address, then select **Connect**.
Select **Start video** to request the SC2 restream. CLI equivalent:

```sh
.build/release/parrot-lab --host 192.168.42.88 --connect --video
```

An existing IP route to the controller is required. The app does not configure USB,
Wi-Fi, routing or firewall rules. Allow the chosen UDP video port and ephemeral
ARSDK telemetry port on the controller-facing interface if your firewall blocks them.
The Apple-private NCM driver installer from the macOS app is not used by this port.
The legacy controller protocols are unencrypted; use a trusted, isolated controller
network rather than exposing these ports to the Internet.

SC2-routed H.264/Bebop 2 and direct Sumo ARStream1/MJPEG are implemented video routes.
Flight controls, jump actions, gamepads, automatic product discovery, Dragon/RF
installers, processed recording, MetalFX, temporal reconstruction and rolling-shutter
correction are not exposed in this version.

## Jumping Sumo ground mode

Join the Sumo's Wi-Fi first, then cycle **Mode** to **Sumo Wi-Fi**, or launch:

```sh
parrot-lab --ground --connect --video
```

The direct route defaults to `192.168.2.1` (override with `--host`). It uses
ARDiscovery/ARNetwork, fragment acknowledgements and GStreamer JPEG decoding,
without Telnet or SC2 restream negotiation. **Archive MJPEG** saves the original
concatenated JPEG frames. PNG capture works as in air mode. Use `--ground --demo`
to preview the brown interface without connecting; demo cannot arm the wheels.

For a Sumo already bridged through an SC2, use **Sumo SC2** or:

```sh
parrot-lab --ground-sc2 --host 192.168.42.88 --connect --video
```

SC2 driving is gated on the controller reporting a connected Jumping Sumo product.
This route currently supports only an existing **H.264** SC2 restream; stock JPEG
RTP restreaming through SC2 is not implemented. Direct Sumo JPEG commands are never
sent to an SC2. Neither route installs or changes device firmware.

Driving requires **Arm drive** / **F6**, then holding **WASD**, **arrow keys** or the
on-screen direction buttons. Speed/turn are capped at **30%** by default; change
the slider or launch with `--speed-limit 20`. Release sends neutral. Space, Escape,
STOP, focus loss, editing the host/speed, stopping video, switching mode or
disconnecting disarms. A 250 ms input-refresh timeout or one second without decoded
telemetry also disarms; reconnecting does not automatically re-arm. Headless mode
never sends drive commands. Closing normally or with SIGINT/SIGTERM sends best-effort
neutral packets before closing the connection.

These are software safeguards, not a guaranteed physical stop: a failed network or
killed process cannot deliver a stop command. Real Sumo operation and its telemetry
cadence still need validation. First test with the wheels safely raised, at a low cap.

MJPEG archives contain no timestamps. For example, convert a known 20 FPS capture
to H.264 MP4 (choose the actual capture rate):

```sh
ffmpeg -f mjpeg -framerate 20 -i capture.mjpeg -c:v libx264 -pix_fmt yuv420p capture.mp4
```

## Recording and standalone RTP

For an already configured RTP sender, skip negotiation:

```sh
.build/release/parrot-lab --listen --video-port 55004
```

Headless recording and telemetry:

```sh
.build/release/parrot-lab --headless --host 192.168.42.88 --connect --video \
  --archive capture.h264 --duration 30
```

Existing recording files are never overwritten. Desktop media defaults to
`~/Videos/Parrot Lab`; override with `--media-dir /path/to/folder`.
Raw archives preserve received NAL units, but incomplete/damaged access units are
rejected. Starting midstream may require waiting for parameter sets/recovery.
Raw H.264 does not retain container timestamps or RTP header extensions.

Optional MP4 remux (assumes 30 FPS, copies H.264 without re-encoding):

```sh
./scripts/remux.sh capture.h264 capture.mp4
```

## Tests

Run `./scripts/test.sh` for unit and headless integration tests, or
`./scripts/test.sh --desktop` to include the virtual-display video test. Individual
commands are:

```sh
swift test -j 4
.build/debug/parrot-lab --self-test
python3 scripts/test-integration.py .build/debug/parrot-lab
python3 scripts/test-errors.py .build/debug/parrot-lab
sudo apt-get install -y xvfb xauth libxtst6
python3 scripts/test-integration.py .build/debug/parrot-lab --desktop --output /tmp/parrot-lab.png
python3 scripts/test-ground.py .build/debug/parrot-lab --desktop --output /tmp/parrot-lab-ground.png
python3 scripts/test-theme.py .build/debug/parrot-lab
```

The integration test only uses `127.0.0.1`. It creates a local SC2 emulator, sends
split TCP responses and RTP video, verifies telemetry/state requests/ACKs/pongs,
and checks archived bytes. The desktop variant generates actual H.264 with FFmpeg,
uses a virtual X display, verifies at least 30 displayed frames, saves a screenshot,
and decodes the saved archive again.

Ground tests additionally cover MJPEG fragment reordering/wraparound and optional
ACKs, capped keyboard/mouse drive, release/stop/focus-loss/stale-link neutral commands,
SC2 product gating and shutdown. The theme test cycles both ground routes and back
to air and checks the actual rendered background colours. Desktop input tests also
require `libxtst6` (normally present on an Ubuntu desktop).

For an automated demo screenshot:

```sh
xvfb-run -a env GSK_RENDERER=cairo .build/release/parrot-lab --demo --duration 4 --screenshot /tmp/parrot-lab-demo.png
```

The portable executable and POSIX transport can also be built on macOS with
`swift build`. GTK/GStreamer compile only on Linux; macOS runs the terminal and
smoke-test modes. A Mac toolchain without XCTest cannot run `swift test`.

See [PORTING.md](PORTING.md) for source provenance, design boundaries and remaining work.
