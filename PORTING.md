# Port notes

## Source baseline

Created 2026-09-05 on `codex/parrot-lab-linux`, starting from the working tree on
`codex/jumping-sumo-ground-mode`. Most current macOS functionality is uncommitted
or untracked, so the first Linux package uses explicit snapshots of portable code.
The macOS source files are not edited by the Linux port. A later shared-core
extraction should replace these snapshots once that baseline is committed.

| Linux protocol file | Original source in `mac/ParrotLab/Sources/ParrotLab` | Changes |
| --- | --- | --- |
| `Telemetry.swift` | `Telemetry.swift` | Replace Metal calibration dependency with an unavailable status; use a literal ESC in the ANSI regex for Linux Foundation |
| `VideoMetadataV2.swift` | `VideoMetadataV2.swift` | Unchanged math and wire layout |
| `ARSDKProtocol.swift` | `ARSDKPhotoCapture.swift` | Keep protocol definitions/codecs; remove Apple networking client |
| `AircraftSupport.swift` | `AircraftSupport.swift` | Keep product/routing models; omit Apple Bonjour discovery |
| `H264RTP.swift` | `RTPH264Receiver.swift` | Keep RTP/access-unit layouts; replace assembler with bounded, loss-aware implementation |

SHA-256 of original source files when copied, in the order above:

```text
6387622b06a25d3874d898a6cb350d09ce8972e0b88828d907989e590489800c
6f9f64712962c894b8f8decab1e6a4c9ea03ef53bbf95c7834f71a36beed4191
2826d5e33e2c156922e949f6c5ad685e88ebf3d799f23dc657bcfdfc9f5a29c6
a06b0d5b0627f247c66419de5798024565571c24499aa8504df2e8116fe23bc2
f6a04139d84837990eea29004a0251e5201ce4202edfdbdca2cc44123b80684b
```

## Platform boundaries

- Swift owns models, protocol decoding, connection state, RTP assembly, timestamps
  and recording. `CLinuxBridge/network.c` wraps the small POSIX socket surface with
  nonblocking operations and deadlines. Each socket is closed by its owning worker.
- GTK4 controls and Cairo horizon drawing live in `CLinuxBridge/desktop.c`. A small
  C ABI avoids exposing GTK's macros/GObject ownership rules to every Swift caller.
- The GTK thread polls shared Swift state; background workers never touch widgets.
- GStreamer receives complete Annex-B access units through `appsrc`, decodes with
  `avdec_h264`, and returns BGRA frames through an `appsink` holding at most one frame.
  This first cut copies pixels into GTK memory textures. Hardware decode/zero-copy
  integration can follow measurements on target hardware.
- Encoded queues are capped at 4 MiB each; overload stops video explicitly instead
  of silently accumulating latency or dropping arbitrary reference pictures.
- Original-stream recording uses a separate queue capped at 16 MiB. Overload or
  write failure stops accepting data and is reported. Recordings are finalized on
  normal close or SIGINT/SIGTERM in terminal mode.
- Unsupported Apple GPU features are omitted, not simulated as working controls.

## Next work

1. Validate the actual SC2 restream and stock cyclic-intra-refresh H.264 on Ubuntu.
2. Measure loss recovery, end-to-end latency, disconnect/reconnect and long recordings.
3. Add direct ARDiscovery/product detection and legacy ARStream1/MJPEG transport.
4. Extract stable protocol code into a package shared with the Mac app.
5. Evaluate hardware decode, GPU scaling and image correction on Intel/AMD/NVIDIA.

No real drone or controller was contacted while implementing the port. See
`VALIDATION.md` for the actual build and test results from this implementation.
