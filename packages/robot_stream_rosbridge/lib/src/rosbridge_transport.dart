import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:robot_stream_core/robot_stream_core.dart';

import 'rosbridge_client.dart';

/// ROS 2 topic, service, and action names used by [RosbridgeTransport].
///
/// The default constructor targets a standard **ROS 2 + Nav2** stack (AMCL
/// `/amcl_pose`, `/odom`, `sensor_msgs/BatteryState` on `/battery_state`, with
/// no vendor-specific topics). Use a named preset such as
/// [RosbridgeTopics.wheeltecR550] for custom robot stacks.
class RosbridgeTopics {
  /// Creates a [RosbridgeTopics] configuration for standard ROS 2 + Nav2 or
  /// custom topic overrides.
  const RosbridgeTopics({
    this.mapPose = '/amcl_pose',
    this.mapPoseType = 'geometry_msgs/msg/PoseWithCovarianceStamped',
    this.odom = '/odom',
    this.odomType = 'nav_msgs/msg/Odometry',
    this.battery = '/battery_state',
    this.batteryType = batteryStateType,
    this.navigateAction = '/navigate_to_pose',
    this.navigateActionType = 'nav2_msgs/action/NavigateToPose',
    this.waypointTopic,
    this.stopTopic,
    this.stopWord = '',
    this.navModeTopic,
    this.navigateCancelService = '/navigate_to_pose/_action/cancel_goal',
    this.navigateStatusTopic = '/navigate_to_pose/_action/status',
    this.heartbeatTopic = '/robot_stream/heartbeat',
    this.controlTopic = '/robot_stream/control',
    this.deadmanTopic = '/robot_stream/deadman',
    this.teleopTopic = '/robot_stream/cmd_vel',
    this.motionControlTopic,
    this.waypointsTopic = '/robot_stream/waypoints',
  });

  /// Preset for Wheeltec R550 (Jetson Orin Nano): `slam_toolbox` `/pose` +
  /// `/odom_combined`, `/PowerVoltage` (`Float32`, V), and `semantic_nav` / AIUI
  /// topics (`/navigation_target`, `/parsed_commands`, `/motion_msg`).
  const RosbridgeTopics.wheeltecR550()
    : this(
        mapPose: '/pose',
        odom: '/odom_combined',
        battery: '/PowerVoltage',
        batteryType: float32Type,
        waypointTopic: '/navigation_target',
        stopTopic: '/parsed_commands',
        stopWord: 'dừng lại',
        navModeTopic: '/semantic_nav_mode',
        motionControlTopic: '/motion_msg',
      );

  /// Standard ROS 2 battery message type (`sensor_msgs/msg/BatteryState`).
  static const batteryStateType = 'sensor_msgs/msg/BatteryState';

  /// Simple scalar voltage message type (`std_msgs/msg/Float32`).
  static const float32Type = 'std_msgs/msg/Float32';

  /// Map-frame pose topic (composed with [odom] for smooth updates between
  /// sparse localization updates).
  final String mapPose;

  /// ROS message type for [mapPose].
  final String mapPoseType;

  /// High-rate odometry topic used to extrapolate pose between map updates.
  final String odom;

  /// ROS message type for [odom].
  final String odomType;

  /// Battery telemetry topic.
  final String battery;

  /// ROS message type for [battery]: [batteryStateType] (voltage + percentage)
  /// or [float32Type] (voltage only).
  final String batteryType;

  /// Nav2 action name for coordinate goals.
  final String navigateAction;

  /// ROS 2 action type for [navigateAction].
  final String navigateActionType;

  /// Optional vendor-specific named waypoint topic (`std_msgs/msg/String`).
  ///
  /// When `null`, [RosbridgeTransport.goToWaypoint] looks up coordinates from
  /// [waypointsTopic] and dispatches a Nav2 goal directly.
  final String? waypointTopic;

  /// Optional vendor-specific stop topic (`std_msgs/msg/String`) to publish
  /// [stopWord] on. When `null`, only Nav2 goal cancellation and zero velocity
  /// are sent.
  final String? stopTopic;

  /// String payload published to [stopTopic] when stopping.
  final String stopWord;

  /// Optional vendor-specific navigation mode topic (`std_msgs/msg/String`).
  final String? navModeTopic;

  /// Nav2 cancel-goal service (`action_msgs/srv/CancelGoal`), called with a
  /// zero UUID and zero stamp to cancel all active goals.
  final String navigateCancelService;

  /// Nav2 goal status topic (`action_msgs/msg/GoalStatusArray`).
  final String navigateStatusTopic;

  /// Client-to-robot heartbeat topic (`std_msgs/msg/String` carrying
  /// [RosbridgeTransport.sessionId]) monitored by `deadman_node`.
  final String heartbeatTopic;

  /// Control claim topic (`std_msgs/msg/String` carrying the session ID) sent
  /// before motion commands so `deadman_node` tracks the active controller.
  final String controlTopic;

  /// Robot-to-client deadman state topic (`std_msgs/msg/String`:
  /// `idle`, `armed`, or `tripped`).
  final String deadmanTopic;

  /// Teleoperation velocity topic (`geometry_msgs/msg/Twist`) gated and
  /// speed-limited by `deadman_node` before forwarding to `/cmd_vel`.
  final String teleopTopic;

  /// Optional Wheeltec AIUI `motion_control` topic used to clear
  /// `cmd_vel_flag` before driving or navigating. `null` skips publishing.
  final String? motionControlTopic;

  /// Latched JSON waypoint list topic (`std_msgs/msg/String` containing
  /// `[{name, x, y, yaw}]`) published by `waypoints_node`.
  final String waypointsTopic;
}

/// [RobotTransport] implementation over rosbridge v2 WebSockets.
///
/// Emits fused map poses at odometry rate by composing the latest map pose with
/// the incremental odometry displacement since that anchor. Before a map pose
/// arrives, raw odometry poses are emitted with their original `frameId`.
class RosbridgeTransport implements RobotTransport {
  /// Creates a [RosbridgeTransport] for [robotId] with topic mapping [topics],
  /// throttling and safety intervals, and optional custom clients or TLS
  /// [httpClient].
  RosbridgeTransport({
    required this.robotId,
    this.topics = const RosbridgeTopics(),
    this.poseThrottle = const Duration(milliseconds: 100),
    this.heartbeatInterval = const Duration(milliseconds: 200),
    this.driveInterval = const Duration(milliseconds: 100),
    RosbridgeClient? client,
    RosbridgeClient? actionClient,
    HttpClient? httpClient,
  }) : _client = client ?? RosbridgeClient(httpClient: httpClient),
       _actionClient = actionClient ?? RosbridgeClient(httpClient: httpClient);

  @override
  final String robotId;

  /// Configured ROS 2 topic, service, and action names.
  final RosbridgeTopics topics;

  /// Minimum interval between odometry updates requested from rosbridge.
  final Duration poseThrottle;

  /// Interval for publishing heartbeats to robot-side `deadman_node`.
  final Duration heartbeatInterval;
  Timer? _heartbeat;

  /// Republish interval for active teleoperation velocity commands.
  final Duration driveInterval;
  Timer? _driveTimer;
  double _driveLin = 0, _driveAng = 0;

  /// Random 8-hex-character session ID for this transport instance, used by
  /// `deadman_node` to distinguish the active controller from passive viewers.
  final String sessionId = _newSessionId();
  static String _newSessionId() {
    final r = math.Random();
    return List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  final RosbridgeClient _client;

  /// Dedicated WebSocket connection for action goals.
  ///
  /// When rosbridge runs with `send_action_goals_in_new_thread: false`,
  /// `send_action_goal` blocks that socket's reader until the goal finishes.
  /// Keeping goals on [_actionClient] ensures [stop] on [_client] is never
  /// blocked behind an in-flight goal.
  final RosbridgeClient _actionClient;

  /// Acknowledgement future from the most recent [stop] call: `true` if Nav2
  /// returned `ERROR_NONE`, `false` if rejected, or `null` if no reply arrived.
  Future<bool?>? lastStopAck;

  final _poseCtl = StreamController<RobotPose>.broadcast();
  final _navModeCtl = StreamController<String>.broadcast();
  final _activityCtl = StreamController<NavActivity>.broadcast();
  final _deadmanCtl = StreamController<String>.broadcast();
  final _waypointsCtl = StreamController<List<NamedWaypoint>>.broadcast();

  @override
  late final Stream<List<NamedWaypoint>> waypoints = _waypointsCtl.stream;
  @override
  List<NamedWaypoint>? get currentWaypoints => _waypoints;
  List<NamedWaypoint>? _waypoints;

  /// Stream of robot deadman states (`idle`, `armed`, `tripped`).
  late final Stream<String> deadman = _deadmanCtl.stream;

  /// Current deadman state, or `null` when disconnected or when `deadman_node`
  /// is not running.
  String? get currentDeadman =>
      _client.currentLink is LinkConnected ? _deadman : null;
  String? _deadman;

  @override
  late final Stream<NavActivity> navActivity = _activityCtl.stream;
  @override
  NavActivity? get currentNavActivity => _activity;
  NavActivity? _activity;

  /// Stream of vendor-specific navigation modes (when [RosbridgeTopics.navModeTopic]
  /// is configured).
  late final Stream<String> navMode = _navModeCtl.stream;

  /// Latest vendor-specific navigation mode, or `null` if none received.
  String? get currentNavMode => _navMode;
  String? _navMode;
  _NavHandle? _active;
  final _batteryCtl = StreamController<BatteryState>.broadcast();
  @override
  late final Stream<RobotPose> pose = _poseCtl.stream;
  @override
  late final Stream<BatteryState> battery = _batteryCtl.stream;
  @override
  Stream<LinkState> get link => _client.link;
  @override
  LinkState get currentLink => _client.currentLink;

  RobotPose? _pose;
  BatteryState? _battery;
  @override
  RobotPose? get currentPose => _pose;
  @override
  BatteryState? get currentBattery => _battery;

  _Se2? _mapAnchor;
  _Se2? _odomAtAnchor;
  _Se2? _odomLast;
  String? _mapFrame;
  final _subs = <StreamSubscription<Object?>>[];
  bool _started = false;

  @override
  Future<void> connect(Uri endpoint, {String? token}) async {
    if (!_started) {
      _started = true;
      _subs
        ..add(
          _client
              .subscribe(topics.mapPose, topics.mapPoseType)
              .listen(_onMapPose),
        )
        ..add(
          _client
              .subscribe(
                topics.odom,
                topics.odomType,
                throttleMs: poseThrottle.inMilliseconds,
              )
              .listen(_onOdom),
        )
        ..add(
          _client
              .subscribe(
                topics.navigateStatusTopic,
                'action_msgs/msg/GoalStatusArray',
              )
              .listen(_onGoalStatus),
        )
        ..add(
          _client
              .subscribe(topics.deadmanTopic, 'std_msgs/msg/String')
              .listen(_onDeadman),
        )
        ..add(
          _client
              .subscribe(topics.waypointsTopic, 'std_msgs/msg/String')
              .listen(_onWaypoints),
        )
        ..add(
          _client.link.listen((l) {
            if (l is! LinkConnected) _deadman = null;
          }),
        )
        ..add(
          _client
              .subscribe(topics.battery, topics.batteryType, throttleMs: 1000)
              .listen(_onBattery),
        );
      final navMode = topics.navModeTopic;
      if (navMode != null) {
        _subs.add(
          _client.subscribe(navMode, 'std_msgs/msg/String').listen(_onNavMode),
        );
      }
    }
    _client.connect(endpoint, token: token);
    _actionClient.connect(endpoint, token: token);
    _heartbeat ??= Timer.periodic(heartbeatInterval, (_) {
      if (_client.currentLink is! LinkConnected) return;
      _client.publish(topics.heartbeatTopic, 'std_msgs/msg/String', {
        'data': sessionId,
      });
    });
  }

  @override
  Future<void> dispose() async {
    _heartbeat?.cancel();
    _driveTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await _client.dispose();
    await _actionClient.dispose();
    await _poseCtl.close();
    await _batteryCtl.close();
    await _navModeCtl.close();
    await _activityCtl.close();
    await _deadmanCtl.close();
    await _waypointsCtl.close();
  }

  /// Claims active control with `deadman_node` before sending motion commands.
  void _claimControl() => _client.publish(
    topics.controlTopic,
    'std_msgs/msg/String',
    {'data': sessionId},
  );

  /// Clears Wheeltec `motion_control` `cmd_vel_flag` when configured.
  void _releaseMotionControl() {
    final topic = topics.motionControlTopic;
    if (topic == null) return;
    _client.publish(topic, 'wheeltec_mic_msg/msg/MotionControl', {
      'cmd_vel_flag': 0,
    });
  }

  @override
  NavHandle navigateTo(NavGoal goal) {
    _claimControl();
    _releaseMotionControl();
    final g = _actionClient.sendActionGoal(
      topics.navigateAction,
      topics.navigateActionType,
      {
        'pose': {
          'header': {
            'frame_id': goal.frameId,
            'stamp': {'sec': 0, 'nanosec': 0},
          },
          'pose': {
            'position': {'x': goal.x, 'y': goal.y, 'z': 0.0},
            'orientation': {
              'x': 0.0,
              'y': 0.0,
              'z': math.sin(goal.yaw / 2),
              'w': math.cos(goal.yaw / 2),
            },
          },
        },
        'behavior_tree': '',
      },
    );
    return _active = _NavHandle(goal, g);
  }

  @override
  bool goToWaypoint(String name) {
    final topic = topics.waypointTopic;
    if (topic != null) {
      _claimControl();
      return _client.publish(topic, 'std_msgs/msg/String', {'data': name});
    }
    // Look up waypoint coordinates from the robot-published list and dispatch a Nav2 goal.
    final w = _waypoints?.where((w) => w.name == name).firstOrNull;
    if (w == null || _actionClient.currentLink is! LinkConnected) return false;
    navigateTo(NavGoal(x: w.x, y: w.y, yaw: w.yaw));
    return true;
  }

  @override
  bool drive(double linear, double angular) {
    final starting = _driveTimer == null && (linear != 0 || angular != 0);
    if (starting) {
      _claimControl();
      _releaseMotionControl();
    }
    _driveLin = linear;
    _driveAng = angular;
    final sent = _publishDrive();
    if (linear == 0 && angular == 0) {
      _driveTimer?.cancel();
      _driveTimer = null;
    } else {
      _driveTimer ??= Timer.periodic(driveInterval, (_) => _publishDrive());
    }
    return sent;
  }

  bool _publishDrive() =>
      _client.publish(topics.teleopTopic, 'geometry_msgs/msg/Twist', {
        'linear': {'x': _driveLin, 'y': 0.0, 'z': 0.0},
        'angular': {'x': 0.0, 'y': 0.0, 'z': _driveAng},
      });

  @override
  bool stop() {
    if (_driveTimer != null) drive(0, 0);
    // 1) Cancel all Nav2 goals via service on the non-blocked main socket.
    final sent = _client.currentLink is LinkConnected;
    final ack = _client.callService(
      topics.navigateCancelService,
      'action_msgs/srv/CancelGoal',
      {
        'goal_info': {
          'goal_id': {'uuid': List.filled(16, 0)},
          'stamp': {'sec': 0, 'nanosec': 0},
        },
      },
    );
    // return_code 0 = ERROR_NONE.
    lastStopAck = ack.then(
      (v) => v == null ? null : (v['return_code'] as num?)?.toInt() == 0,
    );
    // 2) Publish optional vendor-specific stop string.
    final stopTopic = topics.stopTopic;
    final said =
        stopTopic != null &&
        _client.publish(stopTopic, 'std_msgs/msg/String', {
          'data': topics.stopWord,
        });
    // 3) Also send goal-scoped cancel (effective when rosbridge uses threads).
    _active?.cancel();
    return sent || said;
  }

  void _onGoalStatus(Map<String, dynamic> msg) {
    final list = msg['status_list'];
    if (list is! List) return;
    Map? latest;
    var latestUs = -1.0;
    for (final e in list) {
      if (e is! Map) continue;
      final s = e['goal_info']?['stamp'];
      final us = s is Map ? _d(s['sec']) * 1e6 + _d(s['nanosec']) / 1e3 : 0.0;
      if (us >= latestUs) {
        latestUs = us;
        latest = e;
      }
    }
    if (latest == null) return;
    // action_msgs/GoalStatus: 1 accepted, 2 executing, 3 canceling, 4 succeeded,
    // 5 canceled, 6 aborted.
    final state = switch ((latest['status'] as num?)?.toInt()) {
      1 || 2 => NavActivityState.active,
      3 => NavActivityState.canceling,
      4 => NavActivityState.succeeded,
      5 => NavActivityState.canceled,
      6 => NavActivityState.aborted,
      _ => null,
    };
    if (state == null) return;
    final a = NavActivity(
      goalId: _uuidOf(latest['goal_info']?['goal_id']?['uuid']),
      state: state,
      since: latestUs > 0
          ? DateTime.fromMicrosecondsSinceEpoch(latestUs.round())
          : null,
    );
    if (a == _activity) return;
    _activity = a;
    if (!_activityCtl.isClosed) _activityCtl.add(a);
  }

  static String _uuidOf(Object? u) => switch (u) {
    List() =>
      u
          .map(
            (b) =>
                ((b as num).toInt() & 0xff).toRadixString(16).padLeft(2, '0'),
          )
          .join(),
    String() => u,
    _ => '?',
  };

  void _onWaypoints(Map<String, dynamic> msg) {
    final s = msg['data'];
    if (s is! String) return;
    final List<Object?> raw;
    try {
      final v = jsonDecode(s);
      if (v is! List) return;
      raw = v;
    } on FormatException {
      return;
    }
    final list = [
      for (final e in raw)
        if (e is Map && e['name'] is String)
          NamedWaypoint(
            name: e['name'] as String,
            x: _d(e['x']),
            y: _d(e['y']),
            yaw: _d(e['yaw']),
          ),
    ];
    _waypoints = list;
    if (!_waypointsCtl.isClosed) _waypointsCtl.add(list);
  }

  void _onDeadman(Map<String, dynamic> msg) {
    final s = msg['data'];
    if (s is! String) return;
    _deadman = s;
    if (!_deadmanCtl.isClosed) _deadmanCtl.add(s);
  }

  void _onNavMode(Map<String, dynamic> msg) {
    final m = msg['data'];
    if (m is! String) return;
    _navMode = m;
    if (!_navModeCtl.isClosed) _navModeCtl.add(m);
  }

  void _onMapPose(Map<String, dynamic> msg) {
    final p = _poseOf(msg['pose']?['pose']);
    if (p == null) return;
    _mapAnchor = p;
    _odomAtAnchor = _odomLast;
    _mapFrame = (msg['header']?['frame_id'] as String?) ?? 'map';
    _emit(p, _mapFrame!, _stampOf(msg));
  }

  void _onOdom(Map<String, dynamic> msg) {
    final o = _poseOf(msg['pose']?['pose']);
    if (o == null) return;
    _odomLast = o;
    final anchor = _mapAnchor, at = _odomAtAnchor;
    if (anchor == null) {
      _emit(
        o,
        (msg['header']?['frame_id'] as String?) ?? 'odom',
        _stampOf(msg),
      );
    } else if (at != null) {
      // map_T_base = map_T_anchor · (odom_T_anchor⁻¹ · odom_T_now)
      _emit(anchor.compose(at.inverse().compose(o)), _mapFrame!, _stampOf(msg));
    } else {
      // Map pose arrived before odometry: anchor odometry on the first sample.
      _odomAtAnchor = o;
    }
  }

  void _onBattery(Map<String, dynamic> msg) {
    final BatteryState b;
    if (topics.batteryType == RosbridgeTopics.batteryStateType) {
      // sensor_msgs/BatteryState: NaN indicates unknown (null or "NaN" in JSON).
      final v = msg['voltage'], p = msg['percentage'];
      final volts = v is num && v.isFinite && v > 0 ? v.toDouble() : null;
      final pct = p is num && p.isFinite && p >= 0 ? p.toDouble() : null;
      if (volts == null && pct == null) return;
      b = BatteryState(voltage: volts, percentage: pct);
    } else {
      final v = msg['data'];
      if (v is! num) return;
      b = BatteryState(voltage: v.toDouble());
    }
    _battery = b;
    if (!_batteryCtl.isClosed) _batteryCtl.add(_battery!);
  }

  void _emit(_Se2 p, String frame, DateTime? stamp) {
    _pose = RobotPose(x: p.x, y: p.y, yaw: p.yaw, frameId: frame, stamp: stamp);
    if (!_poseCtl.isClosed) _poseCtl.add(_pose!);
  }

  static _Se2? _poseOf(Object? pose) {
    if (pose is! Map) return null;
    final pos = pose['position'], q = pose['orientation'];
    if (pos is! Map || q is! Map) return null;
    final rp = RobotPose.fromQuaternion(
      x: _d(pos['x']),
      y: _d(pos['y']),
      qx: _d(q['x']),
      qy: _d(q['y']),
      qz: _d(q['z']),
      qw: _d(q['w']),
      frameId: '',
    );
    return _Se2(rp.x, rp.y, rp.yaw);
  }

  static DateTime? _stampOf(Map<String, dynamic> msg) {
    final s = msg['header']?['stamp'];
    if (s is! Map) return null;
    final us = _d(s['sec']) * 1e6 + _d(s['nanosec']) / 1e3;
    return us > 0 ? DateTime.fromMicrosecondsSinceEpoch(us.round()) : null;
  }

  static double _d(Object? v) => v is num ? v.toDouble() : 0;
}

class _Se2 {
  const _Se2(this.x, this.y, this.yaw);

  final double x, y, yaw;

  _Se2 compose(_Se2 o) {
    final c = math.cos(yaw), s = math.sin(yaw);
    return _Se2(
      x + c * o.x - s * o.y,
      y + s * o.x + c * o.y,
      _wrap(yaw + o.yaw),
    );
  }

  _Se2 inverse() {
    final c = math.cos(yaw), s = math.sin(yaw);
    return _Se2(-c * x - s * y, s * x - c * y, _wrap(-yaw));
  }

  static double _wrap(double a) => math.atan2(math.sin(a), math.cos(a));
}

class _NavHandle implements NavHandle {
  _NavHandle(this.goal, this._g)
    : progress = _g.feedback.map(_progressOf),
      outcome = _g.result.then(_outcomeOf);

  @override
  final NavGoal goal;
  final RosbridgeActionGoal _g;
  @override
  final Stream<NavProgress> progress;
  @override
  final Future<NavOutcome> outcome;

  @override
  bool cancel() => _g.cancel();

  static NavProgress _progressOf(Map<String, dynamic> v) {
    final t = v['navigation_time'];
    return NavProgress(
      distanceRemaining: (v['distance_remaining'] as num?)?.toDouble(),
      navigationTime: t is Map
          ? Duration(
              microseconds:
                  ((t['sec'] as num? ?? 0) * 1e6 +
                          (t['nanosec'] as num? ?? 0) / 1e3)
                      .round(),
            )
          : null,
      recoveries: (v['number_of_recoveries'] as num?)?.toInt(),
    );
  }

  static NavOutcome _outcomeOf(RosbridgeActionResult r) {
    if (r.lost) return NavOutcome.connectionLost;
    return switch (r.status) {
      RosbridgeActionResult.succeeded => NavOutcome.succeeded,
      RosbridgeActionResult.canceled => NavOutcome.canceled,
      RosbridgeActionResult.aborted => NavOutcome.aborted,
      _ => NavOutcome.rejected,
    };
  }
}
