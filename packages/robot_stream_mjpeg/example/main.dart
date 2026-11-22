import 'package:flutter/material.dart';
import 'package:robot_stream_mjpeg/robot_stream_mjpeg.dart';

void main() => runApp(const MaterialApp(home: MjpegExamplePage()));

/// Minimal example connecting [MjpegSource] to a ROS `web_video_server`.
class MjpegExamplePage extends StatefulWidget {
  const MjpegExamplePage({super.key, this.host = '192.168.1.100'});

  final String host;

  @override
  State<MjpegExamplePage> createState() => _MjpegExamplePageState();
}

class _MjpegExamplePageState extends State<MjpegExamplePage> {
  final _source = MjpegSource(robotId: 'robot1');

  @override
  void initState() {
    super.initState();
    _source.connect(
      webVideoServerUri(
        host: widget.host,
        topic: '/camera/color/image_raw',
        quality: 50,
        width: 640,
        height: 480,
      ),
    );
  }

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MJPEG Example')),
      body: Center(
        child: MjpegView(
          source: _source,
          placeholder: const CircularProgressIndicator(),
        ),
      ),
    );
  }
}
