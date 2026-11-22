# robot_stream_webrtc

Low-latency WebRTC/WHEP video source and Flutter widget for ROS 2 robots, built on [`flutter_webrtc`](https://pub.dev/packages/flutter_webrtc). Part of the [`robot_stream`](https://github.com/robot-stream/robot_stream) package suite.

## Features

- **Standard WHEP signaling (`WhepSignaling`):** pure-HTTP `POST` SDP offer expecting `201 Created`, `Location`-based session teardown via `DELETE`, optional bearer authentication (`mediamtxCredential`), and optional SHA-256 TLS certificate pinning (`WhepSignaling.pinned`) for self-signed robot certificates.
- **Resilient receive-only sessions (`WhepSource`):** bounded ICE gathering timeout, automatic reconnect with exponential backoff on ICE failure, prolonged disconnect, `404` (robot stream not yet online), or decoded-frame stall; stops retrying on HTTP `401`/`403` (`VideoFailed`).
- **Per-window WebRTC stats:** emits `VideoStats` every second with decoded FPS, bitrate, RTT, packet loss, and per-interval receiver jitter buffer delay.
- **Android low-latency `WifiLock` (`LowLatencyWifi`):** automatically acquires `WIFI_MODE_FULL_LOW_LATENCY` while connected on Android (no-op on iOS and macOS) and merges required Android permissions (`ACCESS_NETWORK_STATE`, `CHANGE_NETWORK_STATE`, `WAKE_LOCK`) so consuming apps do not have to declare them.
- **Flutter widget (`RobotVideoView`):** hardware-decoded video surface that clears its placeholder on `onFirstFrameRendered`.

## Measured Performance (LAN)

Measured on a Wheeltec R550 (Jetson Orin Nano, Orbbec Astra 640×480 camera) streaming H.264 over MediaMTX WHEP on 5 GHz Wi-Fi (ping 2–5 ms):

- **Bandwidth:** ~1.3–1.5 Mbps (compared to 5.6 Mbps for 640×480 q50 MJPEG).
- **Android (Samsung A33, Android 15):** 29–30 fps, receiver jitter buffer 10–20 ms with `LowLatencyWifi` enabled (vs. 85–150 ms without it), ~33–43 ms p50 from ROS `header.stamp` to decoded frame.
- **iOS (iPad 5th gen, iPadOS 16.7):** 25–29 fps, jitter buffer p50 17 ms / p95 19 ms, ~41 ms p50 from ROS `header.stamp` to decoded frame.

## Usage

```dart
import 'package:flutter/material.dart';
import 'package:robot_stream_webrtc/robot_stream_webrtc.dart';

class RobotCameraWidget extends StatefulWidget {
  const RobotCameraWidget({
    super.key,
    required this.host,
    required this.token,
  });

  final String host;
  final String token;

  @override
  State<RobotCameraWidget> createState() => _RobotCameraWidgetState();
}

class _RobotCameraWidgetState extends State<RobotCameraWidget> {
  final _source = WhepSource(robotId: 'robot1');

  @override
  void initState() {
    super.initState();
    _source.connect(
      mediamtxWhepUri(host: widget.host),
      token: mediamtxCredential(widget.token),
    );
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RobotVideoView(source: _source);
  }
}
```

For self-signed HTTPS TLS certificates on the robot, pass a pinned signaling factory:

```dart
final source = WhepSource(
  robotId: 'robot1',
  signalingFactory: () => WhepSignaling.pinned(certSha256),
);
source.connect(
  mediamtxWhepUri(host: host, secure: true),
  token: mediamtxCredential(token),
);
```

## Platform Support

- **Android:** full WebRTC playback + automatic `WIFI_MODE_FULL_LOW_LATENCY` WifiLock plugin.
- **iOS (13.0+) & macOS (10.14+):** full WebRTC playback via `flutter_webrtc` (no-op plugin stub; low-latency WifiLock is not needed on Apple platforms).
- **Web:** not supported because `WhepSignaling.pinned` and `robot_stream_core` depend on `dart:io`.
