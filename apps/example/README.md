# robot_stream_example

Reference Flutter application for `robot_stream` (`publish_to: none`).

Demonstrates:
- Switching between WebRTC/WHEP (`robot_stream_webrtc`) and MJPEG (`robot_stream_mjpeg`) video streams
- Live FPS, bitrate, frame gap, RTT, jitter buffer, and packet-loss overlays
- Pose and battery telemetry (`robot_stream_rosbridge`)
- Nav2 coordinate goals, robot-published named waypoints, hold-to-drive teleop, deadman status, and non-blocking emergency stop
- On-device WebRTC latency measurement (`lib/latency_probe.dart`)

## Running

From the repository root:

```bash
flutter pub get
cd apps/example
flutter run --dart-define=PROFILE=nav2 --dart-define=ROBOT_TOKEN=<token>
```

Supported `--dart-define` options:
- `PROFILE=r550|nav2` (default: `r550`)
- `TRANSPORT=webrtc|mjpeg` (default: `webrtc`)
- `ROBOT_TOKEN=<token>`
- `ROBOT_CERT_SHA256=<sha256>` (enables `https://` and `wss://` with certificate pinning)
- `WIFI_LOCK=true|false` (Android low-latency WifiLock, default: `true`)
- `ZERO_PLAYOUT=true|false` (experimental WebRTC field trial, default: `false`)
