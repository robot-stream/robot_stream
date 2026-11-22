# robot_stream_rosbridge

Pure-Dart ROS 2 telemetry, Nav2 navigation, teleoperation, and deadman heartbeat client over rosbridge v2 WebSockets. Part of the [`robot_stream`](https://github.com/robot-stream/robot_stream) package suite.

## Features

- **Resilient rosbridge v2 client (`RosbridgeClient`):** automatic reconnect with exponential backoff, automatic topic re-subscription and re-advertisement, ROS 2 actions (`send_action_goal`), service calls (`call_service`), bearer token authentication, and non-retrying `LinkRejected` handling on HTTP `401`/`403`.
- **Map + odometry SE(2) pose fusion (`RosbridgeTransport`):** composes the latest localization pose (`/amcl_pose` or `/pose`) with incremental odometry (`/odom`) to emit smooth map-frame poses even when localization publishes sparsely.
- **Non-blocking emergency stop (`stop()`):** runs Nav2 action goals on a dedicated WebSocket connection so `stop()` (`action_msgs/srv/CancelGoal` with zero UUID) executes immediately on the main connection even when `rosbridge_server` runs with `send_action_goals_in_new_thread: false`.
- **Per-session deadman heartbeat & teleop:** publishes periodic session heartbeats and claims active control before motion commands so a robot-side `deadman_node` stops the robot if the controlling client drops.
- **Standard ROS 2 + Nav2 defaults:** works out of the box with standard Nav2 topics via `RosbridgeTopics()` / `RobotProfile.nav2Standard`, with custom presets such as `RobotProfile.wheeltecR550`.

## Usage

```dart
import 'package:robot_stream_rosbridge/robot_stream_rosbridge.dart';

Future<void> main() async {
  final transport = RosbridgeTransport(
    robotId: 'robot1',
    topics: const RosbridgeTopics(), // Standard ROS 2 + Nav2
  );

  transport.link.listen((state) => print('Link: $state'));
  transport.pose.listen((pose) => print('Pose: $pose'));
  transport.battery.listen((battery) => print('Battery: $battery'));

  await transport.connect(
    rosbridgeUri(host: '192.168.1.100'),
    token: 'your-robot-token',
  );

  await Future<void>.delayed(const Duration(seconds: 5));
  await transport.dispose();
}
```

For self-signed `wss://` TLS connections, pass `pinnedHttpClient` from `robot_stream_core`:

```dart
import 'package:robot_stream_core/robot_stream_core.dart';
import 'package:robot_stream_rosbridge/robot_stream_rosbridge.dart';

final transport = RosbridgeTransport(
  robotId: 'robot1',
  httpClient: pinnedHttpClient(certSha256),
);
await transport.connect(
  rosbridgeUri(host: '192.168.1.100', secure: true),
  token: token,
);
```

See also `example/health_check.dart` for a read-only robot diagnostic CLI.
