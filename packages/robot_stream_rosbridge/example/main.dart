import 'dart:io';

import 'package:robot_stream_rosbridge/robot_stream_rosbridge.dart';

/// Minimal read-only example: connects to a robot's rosbridge guard and prints
/// link state, fused pose, and battery telemetry for 5 seconds.
///
/// Usage:
/// `ROBOT_TOKEN=<token> dart run example/main.dart [host]`
Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args.first : '192.168.1.100';
  final token = Platform.environment['ROBOT_TOKEN'];

  final transport = RosbridgeTransport(
    robotId: 'robot1',
    topics: const RosbridgeTopics(),
  );

  final subs = [
    transport.link.listen((s) => print('[link] $s')),
    transport.pose.listen((p) => print('[pose] $p')),
    transport.battery.listen((b) => print('[battery] $b')),
  ];

  await transport.connect(rosbridgeUri(host: host), token: token);
  await Future<void>.delayed(const Duration(seconds: 5));

  for (final sub in subs) {
    await sub.cancel();
  }
  await transport.dispose();
}
