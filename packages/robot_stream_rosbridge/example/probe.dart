// Đọc thử pose + pin từ robot qua rosbridge (chỉ đọc, không gửi lệnh).
// dart run example/probe.dart [ip] [giây]
import 'dart:async';
import 'dart:io';

import 'package:robot_stream_core/robot_stream_core.dart';
import 'package:robot_stream_rosbridge/robot_stream_rosbridge.dart';

/// Token robot (`ros2 run robot_stream_ros show_token`), qua biến môi trường.
final robotToken = Platform.environment['ROBOT_TOKEN'];

/// Robot bật TLS: vân tay SHA-256 chứng chỉ (make_cert.sh in ra) → wss, ghim chứng chỉ.
final certSha256 = Platform.environment['ROBOT_CERT_SHA256'];
final secure = (certSha256 ?? '').isNotEmpty;
HttpClient? get pinned => secure ? pinnedHttpClient(certSha256!) : null;

Future<void> main(List<String> args) async {
  // probe.dart [host] [giây] [profile: r550|nav2]
  final host = args.isNotEmpty ? args[0] : '192.168.1.100';
  final seconds = args.length > 1 ? int.parse(args[1]) : 8;
  final profile = RobotProfile.byId(args.length > 2 ? args[2] : 'r550');
  final t = RosbridgeTransport(
    httpClient: pinned,
    robotId: profile.id,
    topics: profile.topics,
  );
  t.link.listen((s) => print('[link] $s'));
  var poses = 0;
  t.pose.listen((p) {
    if (poses++ % 10 == 0) print('[pose] $p');
  });
  t.battery.listen((b) => print('[pin] $b'));
  await t.connect(
    rosbridgeUri(host: host, secure: secure),
    token: robotToken,
  );
  await Future<void>.delayed(Duration(seconds: seconds));
  print('pose nhận được: $poses trong $seconds s');
  await t.dispose();
}
