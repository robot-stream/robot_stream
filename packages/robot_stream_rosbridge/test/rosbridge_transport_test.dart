import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:robot_stream_core/robot_stream_core.dart';
import 'package:robot_stream_rosbridge/robot_stream_rosbridge.dart';
import 'package:test/test.dart';

/// rosbridge giả: ghi lại các op nhận được, cho phép đẩy `publish` xuống client.
class FakeRosbridge {
  FakeRosbridge._(this._server);

  final HttpServer _server;
  final ops = <Map<String, dynamic>>[];
  final _sockets = <WebSocket>[];
  final _connected = StreamController<void>.broadcast();

  /// Header Authorization của từng lần client mở kết nối.
  final authHeaders = <String?>[];

  /// Khác null → như cổng gác robot_stream: sai / thiếu `Bearer <token>` → 401.
  String? requiredToken;

  static Future<FakeRosbridge> start({String? requiredToken}) async {
    final fake = FakeRosbridge._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    )..requiredToken = requiredToken;
    fake._server.listen((req) async {
      final auth = req.headers.value('authorization');
      fake.authHeaders.add(auth);
      final want = fake.requiredToken;
      if (want != null && auth != 'Bearer $want') {
        req.response.statusCode = 401;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      fake._sockets.add(ws);
      fake._connected.add(null);
      ws.listen((data) {
        final op = jsonDecode(data as String) as Map<String, dynamic>;
        // Ghi kèm kết nối nào gửi (transport dùng 2 kết nối: chính + action).
        fake.ops.add({...op, '_conn': fake._sockets.indexOf(ws)});
      });
    });
    return fake;
  }

  Uri get uri => Uri.parse('ws://127.0.0.1:${_server.port}');
  Future<void> get nextConnection =>
      _connected.stream.first.timeout(const Duration(seconds: 5));

  void send(Map<String, dynamic> op) {
    for (final ws in _sockets) {
      ws.add(jsonEncode(op));
    }
  }

  void publish(String topic, Map<String, dynamic> msg) {
    for (final ws in _sockets) {
      ws.add(jsonEncode({'op': 'publish', 'topic': topic, 'msg': msg}));
    }
  }

  Future<void> dropClients() async {
    for (final ws in _sockets) {
      await ws.close();
    }
    _sockets.clear();
  }

  Future<void> close() async {
    await dropClients();
    await _server.close(force: true);
  }

  List<String> subscribedTopics() => [
    for (final o in ops)
      if (o['op'] == 'subscribe') o['topic'] as String,
  ];
}

Map<String, dynamic> poseMsg(
  double x,
  double y,
  double yawDeg, {
  String frame = 'map',
}) {
  final yaw = yawDeg * math.pi / 180;
  return {
    'header': {
      'frame_id': frame,
      'stamp': {'sec': 1700000000, 'nanosec': 0},
    },
    'pose': {
      'pose': {
        'position': {'x': x, 'y': y, 'z': 0.0},
        'orientation': {
          'x': 0.0,
          'y': 0.0,
          'z': math.sin(yaw / 2),
          'w': math.cos(yaw / 2),
        },
      },
    },
  };
}

Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  group('token (cổng gác)', tokenTests);
  group('robot ROS 2 + Nav2 chuẩn', standardTests);
  group('điều hướng', navigationTests);
  telemetryTests();
}

void telemetryTests() {
  late FakeRosbridge server;
  late RosbridgeTransport transport;

  setUp(() async {
    server = await FakeRosbridge.start();
    transport = RosbridgeTransport(
      robotId: 'r550',
      topics: const RosbridgeTopics.wheeltecR550(),
      client: RosbridgeClient(
        minBackoff: const Duration(milliseconds: 50),
        maxBackoff: const Duration(milliseconds: 100),
      ),
    );
  });

  tearDown(() async {
    await transport.dispose();
    await server.close();
  });

  test('connect: subscribe đúng topic / kiểu / throttle', () async {
    final conn = server.nextConnection;
    await transport.connect(server.uri);
    await conn;
    await settle();

    final byTopic = {for (final o in server.ops) o['topic']: o};
    expect(
      byTopic['/pose']?['type'],
      'geometry_msgs/msg/PoseWithCovarianceStamped',
    );
    expect(byTopic['/odom_combined']?['type'], 'nav_msgs/msg/Odometry');
    expect(byTopic['/odom_combined']?['throttle_rate'], 100);
    expect(byTopic['/PowerVoltage']?['type'], 'std_msgs/msg/Float32');
    expect(transport.currentLink, isA<LinkConnected>());
  });

  test('pin: Float32 → BatteryState', () async {
    final conn = server.nextConnection;
    await transport.connect(server.uri);
    await conn;
    await settle();

    final got = transport.battery.first.timeout(const Duration(seconds: 2));
    server.publish('/PowerVoltage', {'data': 11.37});
    expect((await got).voltage, closeTo(11.37, 1e-9));
    expect(transport.currentBattery?.voltage, closeTo(11.37, 1e-9));
  });

  test('chỉ có odometry → pose frame odom', () async {
    final conn = server.nextConnection;
    await transport.connect(server.uri);
    await conn;
    await settle();

    final got = transport.pose.first.timeout(const Duration(seconds: 2));
    server.publish(
      '/odom_combined',
      poseMsg(0.5, -0.2, 30, frame: 'odom_combined'),
    );
    final p = await got;
    expect(p.frameId, 'odom_combined');
    expect(p.x, closeTo(0.5, 1e-9));
    expect(p.yawDegrees, closeTo(30, 1e-6));
    expect(p.stamp, DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
  });

  test('pose bản đồ ⊕ quãng odometry sau đó', () async {
    final conn = server.nextConnection;
    await transport.connect(server.uri);
    await conn;
    await settle();

    // Odometry tại (0,0,0°); slam đặt robot ở (1,2,90°) trên bản đồ.
    server.publish('/odom_combined', poseMsg(0, 0, 0, frame: 'odom'));
    await settle();
    server.publish('/pose', poseMsg(1, 2, 90));
    await settle();
    // Robot đi thẳng 1 m theo odometry → trên bản đồ là theo hướng 90°: (1, 3).
    final got = transport.pose.first.timeout(const Duration(seconds: 2));
    server.publish('/odom_combined', poseMsg(1, 0, 0, frame: 'odom'));
    final p = await got;
    expect(p.frameId, 'map');
    expect(p.x, closeTo(1, 1e-9));
    expect(p.y, closeTo(3, 1e-9));
    expect(p.yawDegrees, closeTo(90, 1e-6));
  });

  test('rớt kết nối → reconnecting → kết nối lại và subscribe lại', () async {
    var conn = server.nextConnection;
    await transport.connect(server.uri);
    await conn;
    await settle();
    expect(server.subscribedTopics(), hasLength(7));

    final reconnecting = transport.link
        .firstWhere((s) => s is LinkReconnecting)
        .timeout(const Duration(seconds: 2));
    conn = server.nextConnection;
    await server.dropClients();
    expect(await reconnecting, isA<LinkReconnecting>());
    await conn;
    await settle();
    expect(server.subscribedTopics(), hasLength(14));
    expect(transport.currentLink, isA<LinkConnected>());
  });

  test('dispose → LinkClosed', () async {
    final conn = server.nextConnection;
    await transport.connect(server.uri);
    await conn;
    await transport.dispose();
    expect(transport.currentLink, isA<LinkClosed>());
  });

  test('rosbridgeUri', () {
    expect(
      rosbridgeUri(host: '192.168.1.100').toString(),
      'ws://192.168.1.100:9091',
    );
  });
}

void navigationTests() {
  late FakeRosbridge server;
  late RosbridgeTransport transport;

  setUp(() async {
    server = await FakeRosbridge.start();
    transport = RosbridgeTransport(
      robotId: 'r550',
      topics: const RosbridgeTopics.wheeltecR550(),
      client: RosbridgeClient(
        minBackoff: const Duration(milliseconds: 50),
        maxBackoff: const Duration(milliseconds: 100),
      ),
    );
  });

  tearDown(() async {
    await transport.dispose();
    await server.close();
  });

  Future<void> connected() async {
    final conn = server.nextConnection;
    await transport.connect(server.uri);
    await conn;
    await settle();
  }

  Map<String, dynamic>? lastOp(String op) =>
      server.ops.lastWhere((o) => o['op'] == op, orElse: () => {});

  test(
    'goToWaypoint: advertise + publish chuỗi tên; false khi chưa kết nối',
    () async {
      expect(transport.goToWaypoint('phòng bếp'), isFalse);
      await connected();
      expect(transport.goToWaypoint('phòng bếp'), isTrue);
      await settle();
      bool target(Map o) => o['topic'] == '/navigation_target';
      final adv = server.ops.firstWhere(
        (o) => o['op'] == 'advertise' && target(o),
      );
      expect(adv['type'], 'std_msgs/msg/String');
      final pub = server.ops.lastWhere(
        (o) => o['op'] == 'publish' && target(o),
      );
      expect(pub['msg'], {'data': 'phòng bếp'});
    },
  );

  test(
    'navigateTo: goal NavigateToPose đúng định dạng, feedback, succeeded',
    () async {
      await connected();
      final h = transport.navigateTo(
        const NavGoal(x: 1.5, y: -0.5, yaw: math.pi / 2),
      );
      await settle();
      final op = lastOp('send_action_goal')!;
      expect(op['action'], '/navigate_to_pose');
      expect(op['action_type'], 'nav2_msgs/action/NavigateToPose');
      final pose = op['args']['pose'];
      expect(pose['header']['frame_id'], 'map');
      expect(pose['pose']['position'], {'x': 1.5, 'y': -0.5, 'z': 0.0});
      expect(
        pose['pose']['orientation']['z'],
        closeTo(math.sin(math.pi / 4), 1e-9),
      );
      expect(
        pose['pose']['orientation']['w'],
        closeTo(math.cos(math.pi / 4), 1e-9),
      );

      final progress = h.progress.first.timeout(const Duration(seconds: 2));
      server.send({
        'op': 'action_feedback',
        'id': op['id'],
        'action': '/navigate_to_pose',
        'values': {
          'distance_remaining': 1.25,
          'navigation_time': {'sec': 3, 'nanosec': 500000000},
          'number_of_recoveries': 0,
        },
      });
      final p = await progress;
      expect(p.distanceRemaining, 1.25);
      expect(p.navigationTime, const Duration(milliseconds: 3500));

      server.send({
        'op': 'action_result',
        'id': op['id'],
        'status': 4,
        'values': {},
        'result': true,
      });
      expect(
        await h.outcome.timeout(const Duration(seconds: 2)),
        NavOutcome.succeeded,
      );
    },
  );

  test('mất kết nối giữa goal → connectionLost (không báo là xong)', () async {
    await connected();
    final h = transport.navigateTo(const NavGoal(x: 1, y: 0, yaw: 0));
    await settle();
    await server.dropClients();
    expect(
      await h.outcome.timeout(const Duration(seconds: 2)),
      NavOutcome.connectionLost,
    );
  });

  test('navigateTo khi chưa kết nối → connectionLost ngay', () async {
    final h = transport.navigateTo(const NavGoal(x: 1, y: 0, yaw: 0));
    expect(
      await h.outcome.timeout(const Duration(seconds: 1)),
      NavOutcome.connectionLost,
    );
  });

  test(
    'stop: gọi service hủy mọi goal Nav2 trên kết nối chính (không phải kết nối goal) + "dừng lại"',
    () async {
      expect(transport.stop(), isFalse);
      await connected();
      transport.navigateTo(const NavGoal(x: 1, y: 0, yaw: 0));
      await settle();
      final goalOp = lastOp('send_action_goal')!;
      expect(transport.stop(), isTrue);
      await settle();

      final call = lastOp('call_service')!;
      expect(call['service'], '/navigate_to_pose/_action/cancel_goal');
      expect(call['type'], 'action_msgs/srv/CancelGoal');
      expect(call['args']['goal_info']['goal_id']['uuid'], List.filled(16, 0));
      expect(call['args']['goal_info']['stamp'], {'sec': 0, 'nanosec': 0});
      // rosbridge chặn kết nối đang chạy goal → DỪNG phải đi kết nối khác.
      expect(call['_conn'], isNot(goalOp['_conn']));

      final pub = server.ops.lastWhere(
        (o) => o['op'] == 'publish' && o['topic'] == '/parsed_commands',
      );
      expect(pub['msg'], {'data': 'dừng lại'});
      expect(pub['_conn'], call['_conn']);
    },
  );

  test(
    'stop: Nav2 trả return_code 0 → lastStopAck true; không phản hồi → null',
    () async {
      await connected();
      transport.stop();
      await settle();
      final call = lastOp('call_service')!;
      server.send({
        'op': 'service_response',
        'id': call['id'],
        'service': call['service'],
        'result': true,
        'values': {'return_code': 0, 'goals_canceling': []},
      });
      expect(await transport.lastStopAck, isTrue);

      await server.dropClients(); // mất kết nối trước khi có phản hồi
      await settle();
      transport.stop();
      expect(await transport.lastStopAck, isNull);
    },
  );

  test(
    'navActivity: goal mới nhất trong GoalStatusArray, chỉ phát khi đổi',
    () async {
      await connected();
      Map<String, dynamic> st(int id, int sec, int status) => {
        'goal_info': {
          'goal_id': {'uuid': List.filled(16, id)},
          'stamp': {'sec': sec, 'nanosec': 0},
        },
        'status': status,
      };
      final got = <NavActivity>[];
      transport.navActivity.listen(got.add);
      const topic = '/navigate_to_pose/_action/status';
      // Goal 1 đã xong từ trước, goal 2 (mới hơn) đang chạy.
      server.publish(topic, {
        'status_list': [st(2, 200, 2), st(1, 100, 4)],
      });
      await settle();
      server.publish(topic, {
        'status_list': [st(1, 100, 4), st(2, 200, 2)],
      });
      await settle();
      server.publish(topic, {
        'status_list': [st(1, 100, 4), st(2, 200, 6)],
      });
      await settle();
      expect(got.map((a) => a.state), [
        NavActivityState.active,
        NavActivityState.aborted,
      ]);
      expect(got.first.goalId, '02' * 16);
      expect(got.first.since, DateTime.fromMillisecondsSinceEpoch(200000));
      expect(transport.currentNavActivity?.state, NavActivityState.aborted);
      expect(transport.currentNavActivity!.state.isDone, isTrue);
    },
  );

  test(
    'heartbeat (mã phiên) đều đặn khi đã kết nối, dừng khi dispose',
    () async {
      await connected();
      await Future<void>.delayed(const Duration(milliseconds: 650));
      List<Map<String, dynamic>> beats() => [
        for (final o in server.ops)
          if (o['op'] == 'publish' && o['topic'] == '/robot_stream/heartbeat')
            o,
      ];
      final n = beats().length;
      expect(n, inInclusiveRange(2, 4)); // nhịp 200 ms
      // Mã phiên, không đổi giữa các nhịp (deadman phân biệt app – plan #9).
      expect(beats().map((o) => o['msg']['data']).toSet(), {
        transport.sessionId,
      });
      expect(transport.sessionId, matches(RegExp(r'^[0-9a-f]{8}$')));
      expect(
        server.ops.any(
          (o) =>
              o['op'] == 'advertise' &&
              o['topic'] == '/robot_stream/heartbeat' &&
              o['type'] == 'std_msgs/msg/String',
        ),
        isTrue,
      );
      await transport.dispose();
      final after = beats().length;
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(beats().length, after);
    },
  );

  test('deadman: trạng thái từ robot; null khi mất kết nối', () async {
    await connected();
    expect(transport.currentDeadman, isNull);
    final got = transport.deadman.first.timeout(const Duration(seconds: 2));
    server.publish('/robot_stream/deadman', {'data': 'armed'});
    expect(await got, 'armed');
    expect(transport.currentDeadman, 'armed');
    await server.dropClients();
    await settle();
    expect(transport.currentDeadman, isNull);
  });

  test('drive: Twist lặp lại khi giữ, lệnh 0 một lần khi nhả', () async {
    await connected();
    List<Map<String, dynamic>> drives() => [
      for (final o in server.ops)
        if (o['op'] == 'publish' && o['topic'] == '/robot_stream/cmd_vel') o,
    ];
    expect(transport.drive(0.2, -0.5), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final held = drives();
    expect(held.length, inInclusiveRange(3, 5)); // ngay + mỗi 100 ms
    expect(held.last['msg'], {
      'linear': {'x': 0.2, 'y': 0.0, 'z': 0.0},
      'angular': {'x': 0.0, 'y': 0.0, 'z': -0.5},
    });
    expect(
      server.ops.any(
        (o) =>
            o['op'] == 'advertise' &&
            o['topic'] == '/robot_stream/cmd_vel' &&
            o['type'] == 'geometry_msgs/msg/Twist',
      ),
      isTrue,
    );
    final release = server.ops.where(
      (o) => o['op'] == 'publish' && o['topic'] == '/motion_msg',
    );
    expect(release, hasLength(1)); // chỉ khi bắt đầu lượt lái
    expect(release.single['msg'], {'cmd_vel_flag': 0});
    transport.drive(0, 0);
    await settle();
    final n = drives().length;
    expect(drives().last['msg']['linear']['x'], 0.0);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(drives().length, n); // nhả rồi thì không gửi nữa
  });

  test('stop() khi đang lái tay → gửi lệnh 0', () async {
    await connected();
    transport.drive(0.2, 0);
    await settle();
    transport.stop();
    await settle();
    final last = server.ops.lastWhere(
      (o) => o['op'] == 'publish' && o['topic'] == '/robot_stream/cmd_vel',
    );
    expect(last['msg']['linear']['x'], 0.0);
  });

  test('waypoints: JSON từ robot → NamedWaypoint, bỏ mục hỏng', () async {
    await connected();
    expect(transport.currentWaypoints, isNull);
    final got = transport.waypoints.first.timeout(const Duration(seconds: 2));
    server.publish('/robot_stream/waypoints', {
      'data':
          '[{"name":"trạm sạc","x":-0.12,"y":0.25,"yaw":1.03},'
          '{"x":1},{"name":"tủ lạnh","x":3.52,"y":-0.75,"yaw":1}]',
    });
    final list = await got;
    expect(list, const [
      NamedWaypoint(name: 'trạm sạc', x: -0.12, y: 0.25, yaw: 1.03),
      NamedWaypoint(name: 'tủ lạnh', x: 3.52, y: -0.75, yaw: 1),
    ]);
    server.publish('/robot_stream/waypoints', {'data': 'không phải json'});
    await settle();
    expect(transport.currentWaypoints, hasLength(2)); // giữ danh sách cũ
  });

  test(
    'nhận quyền điều khiển trước khi làm robot chạy (goal, waypoint, lái tay)',
    () async {
      await connected();
      List<Object?> claims() => [
        for (final o in server.ops)
          if (o['op'] == 'publish' && o['topic'] == '/robot_stream/control')
            o['msg']['data'],
      ];
      transport.navigateTo(const NavGoal(x: 1, y: 0, yaw: 0));
      transport.goToWaypoint('trạm sạc');
      transport.drive(0.1, 0);
      transport.drive(0.1, 0); // vẫn đang giữ → không gửi lại
      transport.drive(0, 0);
      await settle();
      expect(claims(), List.filled(3, transport.sessionId));
    },
  );

  test('navMode: /semantic_nav_mode → stream chuỗi', () async {
    await connected();
    final got = transport.navMode.first.timeout(const Duration(seconds: 2));
    server.publish('/semantic_nav_mode', {'data': 'STATIC_NAV'});
    expect(await got, 'STATIC_NAV');
  });
}

/// Preset mặc định (robot ROS 2 + Nav2 chuẩn, vd TurtleBot3) – không có phần riêng
/// của Wheeltec.
void standardTests() {
  late FakeRosbridge server;
  late RosbridgeTransport transport;

  setUp(() async {
    server = await FakeRosbridge.start();
    transport = RosbridgeTransport(
      robotId: 'tb3',
      client: RosbridgeClient(
        minBackoff: const Duration(milliseconds: 50),
        maxBackoff: const Duration(milliseconds: 100),
      ),
    );
  });

  tearDown(() async {
    await transport.dispose();
    await server.close();
  });

  Future<void> connected() async {
    final conn = server.nextConnection;
    await transport.connect(server.uri);
    await conn;
    await settle();
  }

  test('subscribe topic chuẩn, không subscribe topic riêng của hãng', () async {
    await connected();
    final byTopic = {
      for (final o in server.ops)
        if (o['op'] == 'subscribe') o['topic']: o['type'],
    };
    expect(
      byTopic['/amcl_pose'],
      'geometry_msgs/msg/PoseWithCovarianceStamped',
    );
    expect(byTopic['/odom'], 'nav_msgs/msg/Odometry');
    expect(byTopic['/battery_state'], 'sensor_msgs/msg/BatteryState');
    expect(byTopic.keys, isNot(contains('/semantic_nav_mode')));
    expect(byTopic.keys, isNot(contains('/PowerVoltage')));
  });

  test(
    'pin sensor_msgs/BatteryState: voltage + percentage, NaN bỏ qua',
    () async {
      await connected();
      final got = transport.battery.first.timeout(const Duration(seconds: 2));
      server.publish('/battery_state', {'voltage': 12.1, 'percentage': 0.8});
      final b = await got;
      expect(b.voltage, closeTo(12.1, 1e-9));
      expect(b.percentage, closeTo(0.8, 1e-9));

      final next = transport.battery.first.timeout(const Duration(seconds: 2));
      server.publish('/battery_state', {'voltage': null, 'percentage': 0.5});
      final b2 = await next;
      expect(b2.voltage, isNull);
      expect(b2.percentage, closeTo(0.5, 1e-9));
    },
  );

  test(
    'goToWaypoint: không có topic theo tên → goal Nav2 theo tọa độ',
    () async {
      await connected();
      expect(transport.goToWaypoint('bếp'), isFalse); // chưa có danh sách
      server.publish('/robot_stream/waypoints', {
        'data': '[{"name":"bếp","x":1.5,"y":-0.5,"yaw":0}]',
      });
      await settle();
      expect(transport.goToWaypoint('bếp'), isTrue);
      expect(transport.goToWaypoint('không có'), isFalse);
      await settle();
      final goal = server.ops.lastWhere((o) => o['op'] == 'send_action_goal');
      expect(goal['args']['pose']['pose']['position'], {
        'x': 1.5,
        'y': -0.5,
        'z': 0.0,
      });
      expect(
        server.ops.any((o) => o['op'] == 'advertise' && o['topic'] == null),
        isFalse,
      );
    },
  );

  test('stop: chỉ hủy goal Nav2, không gửi lệnh dừng riêng của hãng', () async {
    await connected();
    expect(transport.stop(), isTrue);
    await settle();
    expect(
      server.ops.lastWhere((o) => o['op'] == 'call_service')['service'],
      '/navigate_to_pose/_action/cancel_goal',
    );
    expect(server.ops.where((o) => o['topic'] == '/parsed_commands'), isEmpty);
  });

  test('drive: không gửi /motion_msg (không phải R550)', () async {
    await connected();
    transport.drive(0.1, 0);
    await settle();
    transport.drive(0, 0);
    expect(server.ops.where((o) => o['topic'] == '/motion_msg'), isEmpty);
  });
}

void tokenTests() {
  late FakeRosbridge server;
  late RosbridgeTransport transport;

  setUp(() async {
    server = await FakeRosbridge.start(requiredToken: 'tok123');
    RosbridgeClient client() => RosbridgeClient(
      minBackoff: const Duration(milliseconds: 20),
      maxBackoff: const Duration(milliseconds: 40),
    );
    transport = RosbridgeTransport(
      robotId: 'sim',
      client: client(),
      actionClient: client(),
    );
  });

  tearDown(() async {
    await transport.dispose();
    await server.close();
  });

  test('gửi Authorization: Bearer <token> trên cả 2 kết nối', () async {
    transport.connect(server.uri, token: 'tok123');
    await transport.link.firstWhere((l) => l is LinkConnected);
    await settle();
    expect(server.authHeaders, everyElement('Bearer tok123'));
    expect(server.authHeaders.length, 2); // kết nối chính + kết nối goal
  });

  test('sai token → LinkRejected(401), không thử lại liên tục', () async {
    transport.connect(server.uri, token: 'sai');
    final l = await transport.link.firstWhere((l) => l is LinkRejected);
    expect((l as LinkRejected).statusCode, 401);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // Backoff 20–40 ms: nếu còn thử lại thì đã có hàng chục lần.
    expect(server.authHeaders.length, 2);
    expect(transport.currentLink, isA<LinkRejected>());
  });

  test('không token → bị từ chối; connect lại với token đúng → chạy', () async {
    transport.connect(server.uri);
    await transport.link.firstWhere((l) => l is LinkRejected);
    expect(server.authHeaders.first, isNull);
    transport.connect(server.uri, token: 'tok123');
    await transport.link.firstWhere((l) => l is LinkConnected);
  });

  test('handshakeStatus đọc mã HTTP từ lỗi dart:io', () {
    expect(
      RosbridgeClient.handshakeStatus(
        "WebSocketException: Connection to 'http://x:9091#' was not upgraded "
        'to websocket, HTTP status code: 401',
      ),
      401,
    );
    expect(RosbridgeClient.handshakeStatus('Connection refused'), isNull);
  });

  test('rosbridgeUri mặc định là cổng gác 9091; secure → wss', () {
    expect(rosbridgeUri(host: 'r').toString(), 'ws://r:9091');
    expect(rosbridgeUri(host: 'r', secure: true).toString(), 'wss://r:9091');
  });
}
