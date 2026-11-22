import 'video_state.dart';
import 'video_stats.dart';

/// A live video source streaming from a robot (such as WebRTC/WHEP or MJPEG).
///
/// Lifecycle: call [connect], transient errors reconnect automatically with
/// backoff, and call [dispose] when finished.
abstract interface class VideoSource {
  /// Identifier of the robot that owns this video stream.
  String get robotId;

  /// Current connection state of the video stream.
  VideoState get currentState;

  /// Stream of connection state transitions.
  Stream<VideoState> get state;

  /// Periodic stream statistics emitted while connected.
  Stream<VideoStats> get stats;

  /// Opens the video stream at [endpoint] with an optional bearer [token].
  Future<void> connect(Uri endpoint, {String? token});

  /// Closes the video stream and releases all resources.
  Future<void> dispose();
}
