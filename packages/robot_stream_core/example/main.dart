import 'dart:math' as math;

import 'package:robot_stream_core/robot_stream_core.dart';

void main() {
  final pose = RobotPose.fromQuaternion(
    x: 1.25,
    y: -0.5,
    qx: 0,
    qy: 0,
    qz: math.sin(math.pi / 4),
    qw: math.cos(math.pi / 4),
    frameId: 'map',
  );
  print('Pose: $pose');

  const goal = NavGoal(x: 2.0, y: 0.0, yaw: 0.0);
  print('Goal: $goal');

  const battery = BatteryState(voltage: 12.1, percentage: 0.85);
  print('Battery: $battery');

  print('Normalized fingerprint: ${normalizeFingerprint('AB:CD:12:34')}');
}
