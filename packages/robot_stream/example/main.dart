import 'package:flutter/material.dart';
import 'package:robot_stream/robot_stream.dart';

void main() => runApp(const MaterialApp(home: RobotMonitorExamplePage()));

/// Minimal example combining WebRTC/WHEP video and rosbridge pose telemetry
/// via the single `robot_stream` umbrella package.
class RobotMonitorExamplePage extends StatefulWidget {
  const RobotMonitorExamplePage({
    super.key,
    this.host = '192.168.1.100',
    this.token,
  });

  final String host;
  final String? token;

  @override
  State<RobotMonitorExamplePage> createState() =>
      _RobotMonitorExamplePageState();
}

class _RobotMonitorExamplePageState extends State<RobotMonitorExamplePage> {
  final _video = WhepSource(robotId: 'robot1');
  final _transport = RosbridgeTransport(
    robotId: 'robot1',
    topics: const RosbridgeTopics(),
  );

  @override
  void initState() {
    super.initState();
    _video.connect(
      mediamtxWhepUri(host: widget.host),
      token: widget.token == null ? null : mediamtxCredential(widget.token!),
    );
    _transport.connect(rosbridgeUri(host: widget.host), token: widget.token);
  }

  @override
  void dispose() {
    _video.dispose();
    _transport.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('robot_stream Example')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          RobotVideoView(
            source: _video,
            placeholder: const Center(child: CircularProgressIndicator()),
          ),
          Positioned(
            top: 16,
            right: 16,
            child: StreamBuilder<RobotPose>(
              stream: _transport.pose,
              builder: (context, snapshot) {
                final pose = snapshot.data;
                final label = pose == null
                    ? 'Waiting for pose…'
                    : 'x=${pose.x.toStringAsFixed(2)} '
                          'y=${pose.y.toStringAsFixed(2)}';
                return Chip(label: Text(label));
              },
            ),
          ),
        ],
      ),
    );
  }
}
