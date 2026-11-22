// Thử điều hướng / lái tay / deadman với robot MÔ PHỎNG (robot di chuyển thật nếu chạy
// với robot thật – chỉ dùng với sim, vd robot_node/scripts/sim_tb3_up.sh).
//
//   dart run example/nav_check.dart [host] [profile: nav2|r550] [waypoint]
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:robot_stream_core/robot_stream_core.dart';
import 'package:robot_stream_rosbridge/robot_stream_rosbridge.dart';

/// Token robot (`ros2 run robot_stream_ros show_token`), qua biến môi trường.
final robotToken = Platform.environment['ROBOT_TOKEN'];

/// Robot bật TLS: vân tay SHA-256 chứng chỉ (make_cert.sh in ra) → wss, ghim chứng chỉ.
final certSha256 = Platform.environment['ROBOT_CERT_SHA256'];
final secure = (certSha256 ?? '').isNotEmpty;
HttpClient? get pinned => secure ? pinnedHttpClient(certSha256!) : null;

Future<T?> waitFor<T>(Stream<T> s, bool Function(T) ok, Duration d) =>
    s.where(ok).first.then<T?>((v) => v).timeout(d, onTimeout: () => null);

String fmt(RobotPose? p) => p == null
    ? '?'
    : '(${p.x.toStringAsFixed(2)}, ${p.y.toStringAsFixed(2)}, '
          '${p.yawDegrees.toStringAsFixed(0)}°)';

RobotTransport connect(String host, RobotProfile profile) =>
    RosbridgeTransport(
      httpClient: pinned,
      robotId: profile.id,
      topics: profile.topics,
    )..connect(
      rosbridgeUri(host: host, secure: secure),
      token: robotToken,
    );

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : '192.168.1.100';
  final profile = RobotProfile.byId(args.length > 1 ? args[1] : 'nav2');
  final target = args.length > 2 ? args[2] : 'giữa';
  final t = connect(host, profile) as RosbridgeTransport;
  final ok = <String, bool>{};

  final armed = await waitFor(
    t.deadman,
    (s) => s == 'armed',
    const Duration(seconds: 10),
  );
  print('deadman: ${armed ?? t.currentDeadman}');
  await waitFor(t.waypoints, (w) => w.isNotEmpty, const Duration(seconds: 5));
  print('waypoint: ${t.currentWaypoints?.map((w) => w.name).join(', ')}');
  print('pose đầu: ${fmt(t.currentPose)}');

  // 1) Waypoint theo tên → goal Nav2.
  final sw = Stopwatch()..start();
  print('\n1) goToWaypoint("$target") gửi=${t.goToWaypoint(target)}');
  final done = await waitFor(
    t.navActivity,
    (a) => a.state.isDone,
    const Duration(seconds: 120),
  );
  final w = t.currentWaypoints?.firstWhere((w) => w.name == target);
  final p = t.currentPose;
  final err = (w == null || p == null)
      ? null
      : math.sqrt(math.pow(p.x - w.x, 2) + math.pow(p.y - w.y, 2));
  print(
    '   kết quả ${done?.state.name ?? 'HẾT GIỜ'} sau ${sw.elapsed.inSeconds} s, pose ${fmt(p)}, '
    'lệch ${err?.toStringAsFixed(2) ?? '?'} m',
  );
  ok['waypoint'] =
      done?.state == NavActivityState.succeeded && (err ?? 9) < 0.35;

  // 2) Goal tọa độ rồi DỪNG giữa đường.
  final start = t.currentPose!;
  final h = t.navigateTo(const NavGoal(x: -2.0, y: -0.5, yaw: 0));
  await waitFor(
    t.navActivity,
    (a) => a.state == NavActivityState.active,
    const Duration(seconds: 10),
  );
  await Future<void>.delayed(const Duration(seconds: 4));
  print(
    '\n2) navigateTo về xuất phát, DỪNG sau 4 s: stop()=${t.stop()}, ack=${await t.lastStopAck}',
  );
  final out = await h.outcome.timeout(
    const Duration(seconds: 10),
    onTimeout: () => NavOutcome.connectionLost,
  );
  final moved = await _settle(t);
  print(
    '   outcome $out, đi được ${_dist(start, moved).toStringAsFixed(2)} m rồi đứng ${fmt(moved)}',
  );
  ok['dừng'] = out == NavOutcome.canceled;

  // 3) Lái tay 2 s.
  final before = t.currentPose!;
  print('\n3) drive(${profile.driveLinear}, 0) 2 s');
  t.drive(profile.driveLinear, 0);
  await Future<void>.delayed(const Duration(seconds: 2));
  t.drive(0, 0);
  final after = await _settle(t);
  final d = _dist(before, after);
  print(
    '   đi ${d.toStringAsFixed(2)} m (kỳ vọng ~${(profile.driveLinear * 2).toStringAsFixed(2)})',
  );
  ok['lái tay'] = d > profile.driveLinear * 2 * 0.6;

  // 4) Deadman: app "mất" giữa goal → robot phải tự hủy.
  // #9: một app khác "chỉ xem" vẫn mở và gửi heartbeat – không được giữ robot chạy.
  final viewer = connect(host, profile);
  await Future<void>.delayed(const Duration(seconds: 2));
  print(
    '\n4) có app xem đang mở; navigateTo xa rồi NGẮT app lái (dispose) giữa đường',
  );
  t.navigateTo(const NavGoal(x: 0.55, y: -1.6, yaw: 0));
  await waitFor(
    t.navActivity,
    (a) => a.state == NavActivityState.active,
    const Duration(seconds: 10),
  );
  await Future<void>.delayed(const Duration(seconds: 3));
  await t.dispose();
  // Theo dõi bằng RosbridgeClient trần: KHÔNG gửi heartbeat (transport thì có, sẽ giữ
  // deadman 'armed'). App khác đang mở cũng giữ – đóng hết trước khi thử.
  final watch = RosbridgeClient(httpClient: pinned)
    ..connect(
      rosbridgeUri(host: host, secure: secure),
      token: robotToken,
    );
  final dm = watch.subscribe(
    profile.topics.deadmanTopic,
    'std_msgs/msg/String',
  );
  final status = watch.subscribe(
    profile.topics.navigateStatusTopic,
    'action_msgs/msg/GoalStatusArray',
  );
  final canceledF = waitFor(
    status,
    (m) => (m['status_list'] as List).any((e) => e['status'] == 5),
    const Duration(seconds: 10),
  );
  final tripped = await waitFor(
    dm,
    (m) => m['data'] == 'tripped',
    const Duration(seconds: 10),
  );
  final canceled = await canceledF;
  print(
    '   deadman ${tripped?['data'] ?? 'không tripped'}, '
    'goal ${canceled != null ? 'canceled' : 'không hủy'}',
  );
  ok['deadman'] = tripped != null && canceled != null;
  await watch.dispose();
  await viewer.dispose();

  print(
    '\nKẾT QUẢ: ${ok.entries.map((e) => '${e.key} ${e.value ? 'OK' : 'LỖI'}').join(' · ')}',
  );
  exit(ok.values.every((v) => v) ? 0 : 1);
}

double _dist(RobotPose a, RobotPose? b) =>
    b == null ? 0 : math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));

/// Chờ robot đứng yên (pose không đổi 1 s) rồi trả pose.
Future<RobotPose?> _settle(RobotTransport t) async {
  RobotPose? last;
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final p = t.currentPose;
    if (last != null && p != null && _dist(last, p) < 0.005) return p;
    last = p;
  }
  return t.currentPose;
}
