import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'whep_source.dart';

/// Displays hardware-decoded WebRTC video from a [WhepSource] via
/// `flutter_webrtc`.
///
/// This widget does not own [source]; callers manage `connect` and `dispose`.
class RobotVideoView extends StatefulWidget {
  /// Creates a [RobotVideoView] rendering frames from [source].
  const RobotVideoView({
    super.key,
    required this.source,
    this.fit = RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    this.placeholder,
  });

  /// WebRTC/WHEP video source supplying the remote [MediaStream].
  final WhepSource source;

  /// How the video surface fits inside the widget bounds.
  final RTCVideoViewObjectFit fit;

  /// Widget shown until the first video frame renders.
  final Widget? placeholder;

  @override
  State<RobotVideoView> createState() => _RobotVideoViewState();
}

class _RobotVideoViewState extends State<RobotVideoView> {
  final _renderer = RTCVideoRenderer();
  StreamSubscription<MediaStream?>? _sub;
  bool _ready = false;
  bool _hasVideo = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _renderer.initialize();
    if (!mounted) return;
    // Hide placeholder on first rendered frame rather than only onResize: after
    // reconnect with the same resolution, onResize may not fire again.
    _renderer.onFirstFrameRendered = () {
      if (mounted) setState(() => _hasVideo = true);
    };
    _renderer.onResize = () {
      if (mounted && _renderer.videoWidth > 0) setState(() => _hasVideo = true);
    };
    _attach(widget.source);
    setState(() => _ready = true);
  }

  void _attach(WhepSource source) {
    _sub?.cancel();
    _setStream(source.currentStream);
    _sub = source.remoteStream.listen(_setStream);
  }

  void _setStream(MediaStream? stream) {
    _renderer.srcObject = stream;
    if (stream == null && mounted) setState(() => _hasVideo = false);
  }

  @override
  void didUpdateWidget(RobotVideoView old) {
    super.didUpdateWidget(old);
    if (_ready && !identical(old.source, widget.source)) _attach(widget.source);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _renderer.srcObject = null;
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_ready) RTCVideoView(_renderer, objectFit: widget.fit),
        if (!_hasVideo) widget.placeholder ?? const SizedBox.expand(),
      ],
    );
  }
}
