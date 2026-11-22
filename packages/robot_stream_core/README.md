# robot_stream_core

Core pure-Dart models, interfaces, and TLS certificate pinning helpers for the [`robot_stream`](https://github.com/robot-stream/robot_stream) ROS 2 streaming and teleoperation suite.

This package has no dependency on Flutter or ROS and is shared by:

- [`robot_stream_webrtc`](https://pub.dev/packages/robot_stream_webrtc) – low-latency WebRTC/WHEP video
- [`robot_stream_mjpeg`](https://pub.dev/packages/robot_stream_mjpeg) – HTTP MJPEG fallback video
- [`robot_stream_rosbridge`](https://pub.dev/packages/robot_stream_rosbridge) – ROS 2 telemetry, Nav2 navigation, teleop, and deadman heartbeats over rosbridge v2

## Features

- **Video abstractions:** `VideoSource`, sealed `VideoState` hierarchy (`VideoIdle`, `VideoConnecting`, `VideoPlaying`, `VideoReconnecting`, `VideoFailed`, `VideoClosed`), `VideoError`, and `VideoStats` (FPS, bitrate, `maxFrameGap`, RTT, packet loss, jitter buffer delay).
- **Transport abstractions:** `RobotTransport`, sealed `LinkState` hierarchy (including `LinkRejected` for HTTP `401`/`403`), `RobotPose` (with quaternion-to-yaw conversion), `BatteryState`, `NavGoal`, `NavProgress`, `NavOutcome`, `NavHandle`, `NavActivity`, and `NamedWaypoint`.
- **Self-signed TLS pinning:** `pinnedHttpClient`, `certFingerprint`, and `normalizeFingerprint` for pinning robot TLS certificates by SHA-256 fingerprint.

## Platform Support

Because `pinnedHttpClient` uses `dart:io`, `robot_stream_core` supports native Dart and Flutter targets (Android, iOS, macOS, Linux, Windows) and **does not support Flutter Web**.

## Usage

```dart
import 'package:robot_stream_core/robot_stream_core.dart';

void main() {
  final pose = RobotPose.fromQuaternion(
    x: 1.2,
    y: -0.5,
    qx: 0,
    qy: 0,
    qz: 0.7071,
    qw: 0.7071,
    frameId: 'map',
  );
  print(pose); // RobotPose(1.20, -0.50, 90° @map)

  const goal = NavGoal(x: 2.0, y: 0.0, yaw: 0.0);
  print(goal);

  final normalized = normalizeFingerprint('AB:CD:12:34');
  print(normalized); // abcd1234
}
```
