## 0.1.0

- Initial release of `robot_stream_rosbridge`.
- `RosbridgeClient` for rosbridge v2 WebSockets with bearer token authentication, `401`/`403` rejection handling, automatic reconnect with backoff, re-subscription, action goals, and service calls.
- `RosbridgeTransport` implementing `RobotTransport` with map + odometry SE(2) pose fusion, dedicated action-goal connection so `stop()` is never blocked, Nav2 `NavigateToPose` / cancel / status tracking, named waypoints, teleop velocity republishing, and per-session deadman heartbeats.
- `RosbridgeTopics` and `RobotProfile` presets for standard ROS 2 + Nav2 and Wheeltec R550.
