# robot_stream

All-in-one Flutter umbrella package for low-latency ROS 2 robot video streaming (WebRTC/WHEP and MJPEG), telemetry, Nav2 navigation, teleoperation, and deadman safety. Part of the [`robot_stream`](https://github.com/robot-stream/robot_stream) suite.

## Installation

```bash
flutter pub add robot_stream
```

> **Want a smaller app or pure-Dart CLI?** This umbrella package pulls in Flutter and `flutter_webrtc` (native WebRTC SDK + Android/iOS/macOS setup). If you only need MJPEG, rosbridge telemetry/control, or pure-Dart models, install the individual `robot_stream_*` packages below instead.

## Included Packages

| Package | What it provides |
|---|---|
| [`robot_stream_core`](https://pub.dev/packages/robot_stream_core) | Pure-Dart models (`RobotPose`, `BatteryState`, `NavGoal`, `VideoStats`), `VideoSource` / `RobotTransport` interfaces, and SHA-256 TLS pinning (`dart:io`). |
| [`robot_stream_webrtc`](https://pub.dev/packages/robot_stream_webrtc) | Low-latency receive-only WebRTC/WHEP video (`WhepSource`, `WhepSignaling`, `RobotVideoView`) with Android low-latency `WifiLock` plugin. |
| [`robot_stream_mjpeg`](https://pub.dev/packages/robot_stream_mjpeg) | HTTP MJPEG video fallback (`MjpegSource`, `MjpegView`, `webVideoServerUri`) with JPEG marker framing, backoff reconnect, and stall detection. |
| [`robot_stream_rosbridge`](https://pub.dev/packages/robot_stream_rosbridge) | Pure-Dart ROS 2 rosbridge v2 client (`RosbridgeClient`, `RosbridgeTransport`, `RobotProfile`): SE(2) map+odom pose fusion, non-blocking stop, Nav2 goals, teleop, and per-session deadman heartbeats. |

## Quick Example (WebRTC Video + Live Pose)

```dart
import 'package:flutter/material.dart';
import 'package:robot_stream/robot_stream.dart';

class RobotMonitorPage extends StatefulWidget {
  const RobotMonitorPage({super.key, this.host = '192.168.1.100', this.token});

  final String host;
  final String? token;

  @override
  State<RobotMonitorPage> createState() => _RobotMonitorPageState();
}

class _RobotMonitorPageState extends State<RobotMonitorPage> {
  final _video = WhepSource(robotId: 'robot1');
  final _transport = RosbridgeTransport(
    robotId: 'robot1',
    topics: const RosbridgeTopics(),
  );

  @override
  void initState() {
    super.initState();
    _video.connect(
      mediamtxWhepUri(host: widget.host),
      token: widget.token == null ? null : mediamtxCredential(widget.token!),
    );
    _transport.connect(rosbridgeUri(host: widget.host), token: widget.token);
  }

  @override
  void dispose() {
    _video.dispose();
    _transport.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          RobotVideoView(source: _video),
          Positioned(
            top: 16,
            right: 16,
            child: StreamBuilder<RobotPose>(
              stream: _transport.pose,
              builder: (context, snapshot) {
                final p = snapshot.data;
                final text = p == null
                    ? 'Waiting for pose…'
                    : 'x=${p.x.toStringAsFixed(2)} y=${p.y.toStringAsFixed(2)}';
                return Chip(label: Text(text));
              },
            ),
          ),
        ],
      ),
    );
  }
}
```

## Platform Support

Supported on the common intersection of all four packages:
- **Android, iOS (13.0+), and macOS (10.14+)**
- **Web is not supported** because `robot_stream_core` and `robot_stream_webrtc` depend on `dart:io` for TLS certificate pinning.

For the ROS 2 robot-side gateway (`stream_node`, MediaMTX WHEP, `rosbridge_guard`, `deadman_node`) and full reference app, see the [GitHub repository](https://github.com/robot-stream/robot_stream).
