/// Builds a MediaMTX WHEP endpoint URI, for example
/// `http://192.168.1.100:8889/robot_cam/whep`.
///
/// Set [secure] to `true` for `https://` when TLS is enabled on the robot.
Uri mediamtxWhepUri({
  required String host,
  String path = 'robot_cam',
  int port = 8889,
  bool secure = false,
}) => Uri(
  scheme: secure ? 'https' : 'http',
  host: host,
  port: port,
  path: '/$path/whep',
);

/// Formats a robot token into the Bearer credential expected by MediaMTX
/// internal auth (`user:pass` → `robot_stream:<token>`).
///
/// Pass the returned string to `WhepSource.connect(endpoint, token: ...)`.
String mediamtxCredential(String token) => 'robot_stream:$token';
