// Kiểm robot CHỈ ĐỌC (robot không chạy) – dùng cho mọi hồ sơ, an toàn với robot thật.
//
//   dart run example/health_check.dart <host> <profile: r550|nav2> [giây]
//
// In từng mục OK/LỖI, mã thoát 0 khi tất cả OK. Dùng trong tools/check_all.sh.
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
  final host = args.isNotEmpty ? args[0] : '192.168.1.100';
  final profile = RobotProfile.byId(args.length > 1 ? args[1] : 'r550');
  final seconds = args.length > 2 ? int.parse(args[2]) : 6;
  // heartbeatInterval rất dài: không giữ deadman 'armed' thay cho app thật.
  final t = RosbridgeTransport(
    httpClient: pinned,
    robotId: profile.id,
    topics: profile.topics,
    heartbeatInterval: const Duration(hours: 1),
  );
  var poses = 0;
  final sub = t.pose.listen((_) => poses++);
  final watch = RosbridgeClient(httpClient: pinned)
    ..connect(
      rosbridgeUri(host: host, secure: secure),
      token: robotToken,
    );
  String? deadman;
  final dm = watch
      .subscribe(profile.topics.deadmanTopic, 'std_msgs/msg/String')
      .listen((m) => deadman = m['data'] as String?);
  await t.connect(
    rosbridgeUri(host: host, secure: secure),
    token: robotToken,
  );
  await Future<void>.delayed(Duration(seconds: seconds));

  final p = t.currentPose, b = t.currentBattery, w = t.currentWaypoints;
  final checks = <String, (bool, String)>{
    'rosbridge': (t.currentLink is LinkConnected, '${t.currentLink}'),
    'pose': (
      poses >= seconds * 3,
      '$poses pose / $seconds s, ${p?.frameId ?? '?'} '
          '(${p?.x.toStringAsFixed(2)}, ${p?.y.toStringAsFixed(2)})',
    ),
    'pose bản đồ': (p?.frameId == 'map', 'frame ${p?.frameId}'),
    'pin': (b != null, '$b'),
    'deadman_node': (
      deadman != null,
      deadman ?? 'không thấy /robot_stream/deadman',
    ),
    'waypoint': (
      (w?.length ?? 0) > 0,
      '${w?.length ?? 0} điểm: ${w?.map((e) => e.name).join(', ')}',
    ),
  };
  for (final e in checks.entries) {
    print(
      '${e.value.$1 ? 'OK  ' : 'LỖI '} ${e.key.padRight(12)} ${e.value.$2}',
    );
  }
  await sub.cancel();
  await dm.cancel();
  await t.dispose();
  await watch.dispose();
  exit(checks.values.every((c) => c.$1) ? 0 : 1);
}
