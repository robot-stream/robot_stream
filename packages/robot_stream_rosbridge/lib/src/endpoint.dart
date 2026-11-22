/// Builds a rosbridge WebSocket URI targeting the `robot_stream` guard port
/// (`ws://<host>:9091` by default, which enforces token auth and audit logging).
///
/// Set [secure] to `true` for `wss://` when TLS is enabled on the robot. The
/// underlying rosbridge server (`:9090`) is intended to listen on localhost.
Uri rosbridgeUri({
  required String host,
  int port = 9091,
  bool secure = false,
}) => Uri(scheme: secure ? 'wss' : 'ws', host: host, port: port);
