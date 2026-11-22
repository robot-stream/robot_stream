/// Video stream metrics measured over a sampling window (typically 1 second).
final class VideoStats {
  /// Creates a [VideoStats] sample.
  const VideoStats({
    required this.fps,
    required this.bitrateKbps,
    required this.maxFrameGap,
    required this.framesTotal,
    this.rttMs,
    this.packetLoss,
    this.jitterBufferMs,
  });

  /// Zeroed initial statistics.
  static const zero = VideoStats(
    fps: 0,
    bitrateKbps: 0,
    maxFrameGap: Duration.zero,
    framesTotal: 0,
  );

  /// Frames received or decoded per second in the window.
  final double fps;

  /// Incoming bitrate in kilobits per second.
  final double bitrateKbps;

  /// Longest gap between consecutive frames in the window.
  ///
  /// Useful for detecting video freezes (for example, gaps exceeding 500 ms).
  final Duration maxFrameGap;

  /// Cumulative frames received since `connect`.
  final int framesTotal;

  /// Estimated network round-trip time in milliseconds (WebRTC only).
  final double? rttMs;

  /// Packet loss ratio in `0.0..1.0` (WebRTC only).
  final double? packetLoss;

  /// Average receiver jitter buffer delay in milliseconds over the last window
  /// (WebRTC only).
  ///
  /// Values well above ~50 ms on a local network typically indicate bursty
  /// packet arrival or Wi-Fi power saving.
  final double? jitterBufferMs;

  @override
  String toString() =>
      'VideoStats(fps: ${fps.toStringAsFixed(1)}, '
      'kbps: ${bitrateKbps.toStringAsFixed(0)}, '
      'maxGap: ${maxFrameGap.inMilliseconds} ms, total: $framesTotal)';
}
