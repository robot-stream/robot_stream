# robot_stream_mjpeg

HTTP MJPEG video source and Flutter widget for ROS 2 `web_video_server` streams. Part of the [`robot_stream`](https://github.com/robot-stream/robot_stream) package suite.

Use `robot_stream_mjpeg` as a simple LAN fallback or baseline alongside [`robot_stream_webrtc`](https://pub.dev/packages/robot_stream_webrtc).

## Features

- **Marker-based JPEG framing (`MjpegFrameDecoder` / `MjpegScanner`):** extracts frames by scanning JPEG SOI (`FF D8`) and EOI (`FF D9`) markers without depending on multipart boundary header quirks.
- **Automatic recovery (`MjpegSource`):** reconnects with exponential backoff on network drops, server closes, or frame stalls (`stallTimeout`, default 3 s); stops retrying on HTTP `4xx` configuration errors (`VideoFailed`).
- **Live stream metrics:** emits `VideoStats` (FPS, bitrate, `maxFrameGap`, total frames).
- **ROS `web_video_server` helper (`webVideoServerUri`):** preserves unencoded `/` characters in the `topic` query parameter (which `web_video_server` requires) and supports `quality`, `width`, and `height` downscaling.
- **Flutter widget (`MjpegView`):** renders frames with `gaplessPlayback: true`.

## Usage

```dart
import 'package:flutter/material.dart';
import 'package:robot_stream_mjpeg/robot_stream_mjpeg.dart';

class MjpegCameraWidget extends StatefulWidget {
  const MjpegCameraWidget({super.key, required this.host});

  final String host;

  @override
  State<MjpegCameraWidget> createState() => _MjpegCameraWidgetState();
}

class _MjpegCameraWidgetState extends State<MjpegCameraWidget> {
  final _source = MjpegSource(robotId: 'robot1');

  @override
  void initState() {
    super.initState();
    _source.connect(
      webVideoServerUri(
        host: widget.host,
        topic: '/camera/color/image_raw',
        quality: 50,
        width: 640,
        height: 480,
      ),
    );
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MjpegView(source: _source);
  }
}
```

## Notes

- On Android and iOS, plain HTTP on a local network requires cleartext/local networking configuration (`android:usesCleartextTraffic="true"` on Android; `NSAllowsLocalNetworking` on iOS).
- For lower bandwidth, lower latency, and multi-viewer scalability on ROS 2 robots, see [`robot_stream_webrtc`](https://pub.dev/packages/robot_stream_webrtc).
