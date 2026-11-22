import 'package:flutter_test/flutter_test.dart';
import 'package:robot_stream/robot_stream.dart';

void main() {
  test('re-exports core, mjpeg, webrtc, and rosbridge without collisions', () {
    // robot_stream_core
    const goal = NavGoal(x: 1.0, y: 2.0, yaw: 0.5);
    expect(goal.x, 1.0);

    // robot_stream_mjpeg
    final mjpegUri = webVideoServerUri(
      host: '192.168.1.100',
      topic: '/camera/color/image_raw',
    );
    expect(mjpegUri.port, 8080);

    // robot_stream_webrtc
    final whepUri = mediamtxWhepUri(host: '192.168.1.100');
    expect(whepUri.toString(), 'http://192.168.1.100:8889/robot_cam/whep');
    expect(mediamtxCredential('secret'), 'robot_stream:secret');

    // robot_stream_rosbridge
    final wsUri = rosbridgeUri(host: '192.168.1.100');
    expect(wsUri.toString(), 'ws://192.168.1.100:9091');
    expect(RobotProfile.nav2Standard.id, 'nav2');
  });
}
