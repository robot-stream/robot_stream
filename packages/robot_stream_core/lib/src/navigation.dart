/// A 2D navigation goal.
///
/// [yaw] is in radians (counter-clockwise from the x-axis), and [frameId] is
/// typically the map frame (`'map'`).
final class NavGoal {
  /// Creates a 2D navigation goal at ([x], [y]) with heading [yaw] in
  /// [frameId].
  const NavGoal({
    required this.x,
    required this.y,
    required this.yaw,
    this.frameId = 'map',
  });

  /// Target x-coordinate in meters.
  final double x;

  /// Target y-coordinate in meters.
  final double y;

  /// Target heading in radians.
  final double yaw;

  /// Coordinate frame ID (defaults to `'map'`).
  final String frameId;

  @override
  String toString() =>
      'NavGoal(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)}, ${yaw.toStringAsFixed(2)} rad @$frameId)';
}

/// Progress feedback reported by the robot during navigation
/// (for example, Nav2 `NavigateToPose` feedback).
final class NavProgress {
  /// Creates a navigation progress snapshot.
  const NavProgress({
    this.distanceRemaining,
    this.navigationTime,
    this.recoveries,
  });

  /// Remaining distance along the planned path in meters, if reported.
  final double? distanceRemaining;

  /// Elapsed navigation duration, if reported.
  final Duration? navigationTime;

  /// Number of recovery behaviors executed, if reported.
  final int? recoveries;

  @override
  String toString() =>
      'NavProgress(còn ${distanceRemaining?.toStringAsFixed(2) ?? '?'} m, '
      '${navigationTime?.inSeconds ?? '?'} s, recovery ${recoveries ?? '?'})';
}

/// Final outcome of a navigation goal submitted via [RobotTransport.navigateTo].
enum NavOutcome {
  /// The robot reached the target pose.
  succeeded,

  /// The goal was canceled (for example, via Stop or a newer goal).
  canceled,

  /// The robot aborted navigation (no valid path, blocked, stuck, etc.).
  aborted,

  /// The robot rejected the goal.
  rejected,

  /// The connection was lost before a result was received.
  ///
  /// The robot may still be moving unless a robot-side deadman stops it.
  connectionLost,
}

/// A handle to an active navigation goal.
///
/// Calling [cancel] requests cancellation; the final result is delivered via
/// [outcome].
abstract interface class NavHandle {
  /// The goal associated with this handle.
  NavGoal get goal;

  /// Stream of periodic progress updates while the goal is active.
  Stream<NavProgress> get progress;

  /// Completes with the final [NavOutcome] of this goal.
  Future<NavOutcome> get outcome;

  /// Requests cancellation of this goal.
  ///
  /// Returns `true` if the cancel request was sent while connected.
  bool cancel();
}

/// Navigation goal state reported by the robot, regardless of who initiated it
/// (app, voice command, or another node).
///
/// Unlike [NavHandle], which only tracks a goal sent by this client,
/// [NavActivityState] reflects the robot's overall navigation status.
enum NavActivityState {
  /// Goal accepted or currently executing.
  active,

  /// Goal cancellation is in progress.
  canceling,

  /// Goal completed successfully.
  succeeded,

  /// Goal was canceled.
  canceled,

  /// Robot aborted the goal (unreachable, outside map, blocked, etc.).
  aborted;

  /// Whether this state is terminal ([succeeded], [canceled], or [aborted]).
  bool get isDone => index >= succeeded.index;
}

/// The most recent navigation goal running on or completed by the robot.
final class NavActivity {
  /// Creates a [NavActivity] snapshot for [goalId] in [state].
  const NavActivity({required this.goalId, required this.state, this.since});

  /// Identifier of the goal (for example, hex or base64 UUID).
  final String goalId;

  /// Current state of the goal.
  final NavActivityState state;

  /// Timestamp when the robot accepted the goal (robot clock), if available.
  final DateTime? since;

  @override
  bool operator ==(Object other) =>
      other is NavActivity && other.goalId == goalId && other.state == state;

  @override
  int get hashCode => Object.hash(goalId, state);

  @override
  String toString() => 'NavActivity($goalId, ${state.name})';
}

/// A named waypoint defined by the robot, sent with [RobotTransport.goToWaypoint].
///
/// Coordinates ([x], [y], [yaw]) can be used for display or direct Nav2 goal
/// dispatch when the robot does not handle named waypoints natively.
final class NamedWaypoint {
  /// Creates a [NamedWaypoint] with its [name] and 2D pose ([x], [y], [yaw]).
  const NamedWaypoint({
    required this.name,
    required this.x,
    required this.y,
    required this.yaw,
  });

  /// Human-readable waypoint name.
  final String name;

  /// Waypoint x-coordinate in meters.
  final double x;

  /// Waypoint y-coordinate in meters.
  final double y;

  /// Waypoint heading in radians.
  final double yaw;

  @override
  bool operator ==(Object other) =>
      other is NamedWaypoint &&
      other.name == name &&
      other.x == x &&
      other.y == y &&
      other.yaw == yaw;

  @override
  int get hashCode => Object.hash(name, x, y, yaw);

  @override
  String toString() =>
      'NamedWaypoint($name, ${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})';
}
