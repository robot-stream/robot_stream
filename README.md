# robot_stream

Flutter and Dart libraries for low-latency ROS 2 robot video streaming (WebRTC/WHEP and MJPEG), telemetry, Nav2 navigation, teleoperation, and robot-side deadman safety.

## Packages

| Directory | Package | Description |
|---|---|---|
| `packages/robot_stream` | `robot_stream` | All-in-one Flutter umbrella package re-exporting all four `robot_stream_*` packages (Android, iOS, macOS). |
| `packages/robot_stream_core` | `robot_stream_core` | Pure-Dart models, `VideoSource` / `RobotTransport` interfaces, and SHA-256 TLS certificate pinning (`dart:io`, non-web). |
| `packages/robot_stream_webrtc` | `robot_stream_webrtc` | Low-latency receive-only WebRTC/WHEP video (`WhepSource`, `WhepSignaling`, `RobotVideoView`) on `flutter_webrtc`, with Android `WIFI_MODE_FULL_LOW_LATENCY` plugin and iOS/macOS stubs. |
| `packages/robot_stream_mjpeg` | `robot_stream_mjpeg` | HTTP MJPEG fallback video (`MjpegSource`, `MjpegView`, `webVideoServerUri`) with JPEG marker framing, reconnect backoff, and stall detection. |
| `packages/robot_stream_rosbridge` | `robot_stream_rosbridge` | Pure-Dart ROS 2 rosbridge v2 client (`RosbridgeClient`, `RosbridgeTransport`, `RosbridgeTopics`, `RobotProfile`): map+odom SE(2) pose fusion, non-blocking emergency stop, Nav2 goals, waypoints, teleop, and per-session deadman heartbeats. |
| `apps/example` | `robot_stream_example` | Reference Flutter app (`publish_to: none`) demonstrating WebRTC/MJPEG switching, telemetry overlay, Nav2 goals, teleoperation, and latency measurement. |
| `robot_node/` | `robot_stream_ros` | ROS 2 Humble gateway package (Python `ament_python`): `stream_node` (GStreamer `x264enc` + MediaMTX WHEP), `deadman_node`, `waypoints_node`, `rosbridge_guard`, and systemd/install scripts. |

## Measured Performance

Measured on a **Wheeltec R550 Ultra** (Jetson Orin Nano, JetPack 6.2, Ubuntu 22.04, ROS 2 Humble, Orbbec Astra 640×480 camera) over 5 GHz Wi-Fi (ping 2–5 ms).

| Stream / Client | FPS | Bandwidth | Latency / Jitter Buffer |
|---|---|---|---|
| **WebRTC/WHEP** (`RTP + vbv100/sliced`) → Chrome (Mac) | ~30 fps | ~1.3–1.5 Mbps | Driver `header.stamp` → display: **p50 66–69 ms / p95 93 ms**; jitter buffer **11 ms** |
| **WebRTC/WHEP** → Samsung A33 (Android 15, WifiLock on) | 29–30 fps | ~1.3–1.5 Mbps | `header.stamp` → decoded: **≈ 33–43 ms p50** (~110–120 ms est. glass-to-glass incl. 63 ms p50 camera+USB); jitter buffer **10–20 ms** (85–150 ms without WifiLock) |
| **WebRTC/WHEP** → iPad 5th gen (iPadOS 16.7) | 25–29 fps | ~1.3–1.5 Mbps | `header.stamp` → decoded: **≈ 41 ms p50**; jitter buffer **p50 17 ms / p95 19 ms** |
| **MJPEG** (`web_video_server`, `/camera/color/image_raw`, 640×480 q50) | 28.1–30 fps | 5.6 Mbps | Glass-to-glass on Mac Chrome: **median 229 ms** (min 175, max 330 ms) |
| **MJPEG** (`web_video_server`, `/detected_image`, 640×480 q50) | ~16 fps (app) | 3.6–4.7 Mbps | Glass-to-glass on Mac Chrome: **median 420 ms** |

Additional findings on Jetson Orin Nano:
- **Multi-viewer scaling:** `web_video_server` re-encodes JPEG per viewer (4 viewers dropped raw camera from 29.5 fps to 18 fps), whereas MediaMTX encodes H.264 once for all viewers.
- **CPU impact:** In alternating A/B tests with YOLO11m running on GPU, enabling CPU H.264 streaming did not slow YOLO (~18 fps vs. 12.6–14.4 fps baseline). With on-demand viewer detection, idle `stream_node` CPU drops to **1–1.5%**.

## Quick Start

### 1. Robot Side (`robot_node/`)

Requirements on the robot: ROS 2 Humble, GStreamer 1.20 (`x264enc`, `rtph264pay`, `h264parse`, `videoconvert`, `appsrc`), `python3-gi`, `python3-tornado`, and `rosbridge_server`. Full setup details are in [robot_node/README.md](robot_node/README.md).

1. Build `robot_node/robot_stream_ros` in a colcon workspace on the robot (or deploy from your dev machine via `robot_node/scripts/deploy.sh <ssh-host>`).
2. Download MediaMTX on the robot:
   ```bash
   bash ~/robot_stream/scripts/install_mediamtx.sh
   ```
3. Launch the gateway (use `profile:=nav2_standard` for a standard ROS 2 + Nav2 robot, or `profile:=wheeltec_r550` for Wheeltec R550):
   ```bash
   source /opt/ros/humble/setup.bash
   source ~/robot_stream/ws/install/setup.bash
   ros2 launch robot_stream_ros stream.launch.py profile:=nav2_standard
   ```
4. Print the robot's auto-generated bearer token:
   ```bash
   ros2 run robot_stream_ros show_token
   ```
5. *(Optional)* Install the user-level systemd service for auto-start on boot:
   ```bash
   bash ~/robot_stream/scripts/install_autostart.sh
   ```

Open ports on the robot LAN interface: `8889/tcp` (WHEP, token-protected), `8189/udp` (WebRTC ICE), and `9091/tcp` (`rosbridge_guard`, token-protected).

### 2. Flutter Workspace & Example App

Requires Flutter >= 3.32 (Dart >= 3.8). The monorepo uses a Dart pub workspace with Melos 7 (installed as a dev dependency).

```bash
flutter pub get
dart run melos analyze
dart run melos test
```

Run the example app on Android or iOS:

```bash
cd apps/example
flutter run --dart-define=PROFILE=nav2 --dart-define=ROBOT_TOKEN=<token>
```

Available `--dart-define` flags for `apps/example`:
- `PROFILE=r550|nav2` – selects robot topic profile (default: `r550`).
- `TRANSPORT=webrtc|mjpeg` – initial video transport (default: `webrtc`).
- `ROBOT_TOKEN=<token>` – pre-fills the bearer token (otherwise entered in the UI and saved via `shared_preferences`).
- `ROBOT_CERT_SHA256=<sha256>` – enables `https://` / `wss://` with SHA-256 certificate pinning when the robot runs with `tls:=true`.

> **Android build note:** Gradle 8.12 does not support Java 25. If `flutter build apk` fails with a Java version error, point Flutter to JDK 17:
> ```bash
> flutter config --jdk-dir /Library/Java/JavaVirtualMachines/jdk-17.jdk/Contents/Home
> ```

## Security & Known Limitations

The Free edition enables basic LAN security by default:
- **Per-robot bearer token** (`~/.config/robot_stream/token`, mode `0600`) checked on `rosbridge_guard` (`:9091`) and MediaMTX WHEP (`:8889`).
- **Audit log** (`~/robot_stream/audit.log`, rotating JSON lines) recording connections, auth rejections, goals, cancellations, service calls, command publishes, and teleop sessions.
- **Optional self-signed TLS** (`robot_node/scripts/make_cert.sh` + `tls:=true`) with SHA-256 certificate pinning (`pinnedHttpClient`, `WhepSignaling.pinned`).

**Known limitations in the Free edition:**
1. **Unencrypted tokens without TLS:** When `tls:=false` (default), bearer tokens travel in plaintext over Wi-Fi. Enable `tls:=true` with certificate pinning outside trusted private networks.
2. **ROS 2 DDS on the LAN:** Any ROS 2 host on the same LAN can still publish directly over DDS (for example, `ros2 topic pub /cmd_vel`), bypassing `rosbridge_guard`. For single-host robots, set `ROS_LOCALHOST_ONLY=1`; topic-level access control requires SROS2.
3. **Pre-existing vendor rosbridge (`:9090`):** On robots that launch their own unauthenticated rosbridge on all interfaces (such as Wheeltec R550's AIUI stack on port `9090`), that vendor port remains open without token auth unless rebound to `127.0.0.1`.
4. **LAN only:** Do **not** expose ports `8889`, `8189`, or `9091` directly to the public internet. Remote access requires a VPN or authenticated TURN/relay infrastructure.

See [SECURITY.md](SECURITY.md) for security details and vulnerability reporting.

## Contributing & License

Contributions are welcome—see [CONTRIBUTING.md](CONTRIBUTING.md).

The Dart/Flutter packages (`robot_stream_core`, `robot_stream_mjpeg`, `robot_stream_webrtc`, `robot_stream_rosbridge`) are licensed under the **BSD-3-Clause** license (see [LICENSE](LICENSE)).
