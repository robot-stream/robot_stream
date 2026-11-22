import 'navigation.dart';
import 'robot_state.dart';

/// Telemetry and command transport channel to a robot (for example, rosbridge),
/// kept separate from video streaming.
///
/// Lifecycle matches [VideoSource]: call [connect], automatic reconnection runs
/// on transient drops, and call [dispose] when done.
///
/// Navigation and drive commands physically move the robot: applications should
/// require operator confirmation and always expose a [stop] control. Methods
/// return `false` or [NavOutcome.connectionLost] when a command could not be
/// delivered—surface this clearly and never assume the robot stopped.
abstract interface class RobotTransport {
  /// Identifier of the robot this transport communicates with.
  String get robotId;

  /// Most recent connection state.
  LinkState get currentLink;

  /// Stream of connection state transitions.
  Stream<LinkState> get link;

  /// Latest known robot pose, typically in the map frame.
  RobotPose? get currentPose;

  /// Stream of robot pose updates.
  Stream<RobotPose> get pose;

  /// Latest known battery state, or `null` if none received yet.
  BatteryState? get currentBattery;

  /// Stream of battery telemetry updates.
  Stream<BatteryState> get battery;

  /// Most recent navigation goal activity on the robot (including goals not
  /// sent by this app), or `null` if unknown.
  NavActivity? get currentNavActivity;

  /// Emits whenever a goal starts or changes state.
  Stream<NavActivity> get navActivity;

  /// Sends a 2D navigation [goal] (for example, Nav2 `NavigateToPose`).
  ///
  /// A new goal preempts any previously running goal.
  NavHandle navigateTo(NavGoal goal);

  /// Latest list of robot-defined named waypoints, or `null` if not received.
  List<NamedWaypoint>? get currentWaypoints;

  /// Stream of updated waypoint lists published by the robot.
  Stream<List<NamedWaypoint>> get waypoints;

  /// Commands the robot to navigate to a robot-defined waypoint by [name].
  ///
  /// Returns `true` if the command was sent.
  bool goToWaypoint(String name);

  /// Sends a manual teleoperation velocity command.
  ///
  /// [linear] is forward speed in m/s (positive = forward) and [angular] is
  /// yaw rate in rad/s (positive = counter-clockwise / left). Call when a
  /// drive control is pressed and call `drive(0, 0)` on release; the transport
  /// republishes periodically while held. Returns `false` if not sent.
  bool drive(double linear, double angular);

  /// Stops all active navigation and manual motion.
  ///
  /// Returns `true` if the stop command was sent; `false` means the robot was
  /// **not** stopped (disconnected).
  bool stop();

  /// Connects to the robot transport at [endpoint] with an optional bearer
  /// [token].
  Future<void> connect(Uri endpoint, {String? token});

  /// Closes connections and releases all resources.
  Future<void> dispose();
}
