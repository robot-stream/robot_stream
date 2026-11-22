import 'dart:math' as math;

/// Connection state of a telemetry and command channel to a robot.
sealed class LinkState {
  /// Base constructor for [LinkState] subclasses.
  const LinkState();
}

/// Initial state before [RobotTransport.connect] is called.
final class LinkIdle extends LinkState {
  /// Creates an idle link state.
  const LinkIdle();

  @override
  String toString() => 'LinkIdle';
}

/// Actively establishing the initial connection to the robot.
final class LinkConnecting extends LinkState {
  /// Creates a connecting link state.
  const LinkConnecting();

  @override
  String toString() => 'LinkConnecting';
}

/// Connected to the robot transport.
final class LinkConnected extends LinkState {
  /// Creates a connected link state.
  const LinkConnected();

  @override
  String toString() => 'LinkConnected';
}

/// Connection dropped; waiting [retryIn] before attempting to reconnect.
final class LinkReconnecting extends LinkState {
  /// Creates a reconnecting link state with backoff metadata.
  const LinkReconnecting({
    required this.attempt,
    required this.retryIn,
    required this.reason,
  });

  /// 1-based reconnection attempt counter since the last successful session.
  final int attempt;

  /// Backoff delay before the next connection attempt.
  final Duration retryIn;

  /// Human-readable reason the previous connection failed or closed.
  final String reason;

  @override
  String toString() =>
      'LinkReconnecting(attempt: $attempt, retryIn: $retryIn, reason: $reason)';
}

/// Connection rejected by the robot (HTTP 401/403: missing or invalid token).
///
/// Reconnection stops automatically; fix credentials and call `connect` again.
final class LinkRejected extends LinkState {
  /// Creates a rejected link state with the HTTP [statusCode] and [reason].
  const LinkRejected({required this.statusCode, required this.reason});

  /// HTTP status code returned during handshake (for example, `401` or `403`).
  final int statusCode;

  /// Human-readable rejection message.
  final String reason;

  @override
  String toString() => 'LinkRejected($statusCode, $reason)';
}

/// Transport has been disposed and can no longer be used.
final class LinkClosed extends LinkState {
  /// Creates a closed link state.
  const LinkClosed();

  @override
  String toString() => 'LinkClosed';
}

/// 2D pose of a ground robot.
///
/// [yaw] is in radians, counter-clockwise from the positive x-axis.
final class RobotPose {
  /// Creates a 2D [RobotPose] in [frameId].
  const RobotPose({
    required this.x,
    required this.y,
    required this.yaw,
    required this.frameId,
    this.stamp,
  });

  /// Creates a [RobotPose] from a 3D orientation quaternion.
  ///
  /// Only rotation around the z-axis (yaw) is extracted for ground robots.
  factory RobotPose.fromQuaternion({
    required double x,
    required double y,
    required double qx,
    required double qy,
    required double qz,
    required double qw,
    required String frameId,
    DateTime? stamp,
  }) {
    final yaw = math.atan2(
      2 * (qw * qz + qx * qy),
      1 - 2 * (qy * qy + qz * qz),
    );
    return RobotPose(x: x, y: y, yaw: yaw, frameId: frameId, stamp: stamp);
  }

  /// X-coordinate in meters.
  final double x;

  /// Y-coordinate in meters.
  final double y;

  /// Heading angle in radians.
  final double yaw;

  /// Coordinate frame ID (for example, `'map'` or `'odom'`).
  final String frameId;

  /// Robot-side measurement timestamp (`header.stamp`), if available.
  final DateTime? stamp;

  /// Heading angle [yaw] converted to degrees.
  double get yawDegrees => yaw * 180 / math.pi;

  @override
  String toString() =>
      'RobotPose(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)}, '
      '${yawDegrees.toStringAsFixed(0)}° @$frameId)';
}

/// Battery telemetry reported by the robot.
final class BatteryState {
  /// Creates a [BatteryState] with optional [voltage] and [percentage].
  const BatteryState({this.voltage, this.percentage});

  /// Battery voltage in volts, or `null` if not reported.
  final double? voltage;

  /// Charge level in the range `0.0..1.0`, or `null` if not reported.
  final double? percentage;

  @override
  String toString() =>
      'BatteryState(${voltage?.toStringAsFixed(2) ?? '?'} V'
      '${percentage == null ? '' : ', ${(percentage! * 100).round()}%'})';
}
