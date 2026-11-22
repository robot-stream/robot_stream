/// All-in-one Flutter umbrella package for `robot_stream`.
///
/// Re-exports `robot_stream_core`, `robot_stream_mjpeg`, `robot_stream_webrtc`,
/// and `robot_stream_rosbridge` so Flutter apps can add a single dependency for
/// low-latency ROS 2 robot video streaming, telemetry, Nav2 navigation, and
/// teleoperation.
///
/// Because this package depends on `robot_stream_webrtc` (`flutter_webrtc`) and
/// `robot_stream_core` (`dart:io`), it targets **Android, iOS, and macOS** (not
/// web). For lighter apps or pure-Dart CLI tools, depend on the individual
/// `robot_stream_*` packages directly.
library;

export 'package:robot_stream_core/robot_stream_core.dart';
export 'package:robot_stream_mjpeg/robot_stream_mjpeg.dart';
export 'package:robot_stream_rosbridge/robot_stream_rosbridge.dart';
export 'package:robot_stream_webrtc/robot_stream_webrtc.dart';
