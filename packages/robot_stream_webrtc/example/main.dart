import 'package:flutter/material.dart';
import 'package:robot_stream_webrtc/robot_stream_webrtc.dart';

void main() => runApp(const MaterialApp(home: WebrtcExamplePage()));

/// Minimal example streaming WebRTC/WHEP video from a MediaMTX server.
class WebrtcExamplePage extends StatefulWidget {
  const WebrtcExamplePage({super.key, this.host = '192.168.1.100', this.token});

  final String host;
  final String? token;

  @override
  State<WebrtcExamplePage> createState() => _WebrtcExamplePageState();
}

class _WebrtcExamplePageState extends State<WebrtcExamplePage> {
  final _source = WhepSource(robotId: 'robot1');

  @override
  void initState() {
    super.initState();
    _source.connect(
      mediamtxWhepUri(host: widget.host),
      token: widget.token == null ? null : mediamtxCredential(widget.token!),
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
      appBar: AppBar(title: const Text('WebRTC/WHEP Example')),
      body: Center(
        child: RobotVideoView(
          source: _source,
          placeholder: const CircularProgressIndicator(),
        ),
      ),
    );
  }
}
