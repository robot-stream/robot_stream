import 'rosbridge_transport.dart';

/// Application-side profile describing a robot's ROS topics and operational
/// safety limits.
///
/// Add support for another robot model by defining a new [RobotProfile] preset
/// (alongside a matching YAML profile in `robot_node/robot_stream_ros/config/profiles/`).
final class RobotProfile {
  /// Creates a [RobotProfile] with the given identifiers, topic mapping,
  /// battery thresholds, teleoperation speed limits, and MJPEG camera topics.
  const RobotProfile({
    required this.id,
    required this.name,
    this.topics = const RosbridgeTopics(),
    this.minBatteryV,
    this.minBatteryPercent,
    this.driveLinear = 0.2,
    this.driveAngular = 0.6,
    this.mjpegTopics = const [('/camera/image_raw', 'Camera')],
  });

  /// Example preset for the Wheeltec R550 Ultra (Jetson Orin Nano, AIUI, and
  /// `semantic_nav`).
  static const wheeltecR550 = RobotProfile(
    id: 'r550',
    name: 'Wheeltec R550',
    topics: RosbridgeTopics.wheeltecR550(),
    minBatteryV: 10.3, // semantic_nav rejects goals below this voltage
    mjpegTopics: [
      ('/camera/color/image_raw', 'Ảnh gốc'),
      ('/detected_image', 'Có khung YOLO'),
    ],
  );

  /// Standard ROS 2 + Nav2 preset (tested with simulated TurtleBot3).
  static const nav2Standard = RobotProfile(
    id: 'nav2',
    name: 'ROS 2 + Nav2 (TurtleBot3 sim)',
    minBatteryPercent: 0.15,
    driveLinear: 0.15, // TurtleBot3 Burger max linear speed is 0.22 m/s
    driveAngular: 1.0,
  );

  /// Built-in example presets.
  static const all = [wheeltecR550, nav2Standard];

  /// Looks up a built-in profile by [id], defaulting to [wheeltecR550].
  static RobotProfile byId(String id) =>
      all.firstWhere((p) => p.id == id, orElse: () => wheeltecR550);

  /// Short machine-readable profile identifier (for example, `'r550'` or `'nav2'`).
  final String id;

  /// Human-readable robot name.
  final String name;

  /// ROS 2 topic, service, and action names for this robot.
  final RosbridgeTopics topics;

  /// Minimum battery voltage (V) required before dispatching motion commands,
  /// or `null` to skip voltage checks.
  final double? minBatteryV;

  /// Minimum battery charge ratio (`0.0..1.0`) required before dispatching
  /// motion commands, or `null` to skip percentage checks.
  final double? minBatteryPercent;

  /// Default manual teleoperation linear speed in m/s (clamped again by
  /// robot-side `deadman_node`).
  final double driveLinear;

  /// Default manual teleoperation angular speed in rad/s (clamped again by
  /// robot-side `deadman_node`).
  final double driveAngular;

  /// Camera topics available over MJPEG (`web_video_server`) as `(topic, label)`
  /// pairs. WebRTC streams the topic configured on the robot's `stream_node`.
  final List<(String, String)> mjpegTopics;
}
