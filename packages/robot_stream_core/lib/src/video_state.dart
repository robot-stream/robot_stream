/// Connection state of a [VideoSource].
sealed class VideoState {
  /// Base constructor for [VideoState] subclasses.
  const VideoState();
}

/// Initial state before `connect` has been called.
final class VideoIdle extends VideoState {
  /// Creates an idle video state.
  const VideoIdle();

  @override
  String toString() => 'VideoIdle';
}

/// Opening the initial connection; no frames have arrived yet.
final class VideoConnecting extends VideoState {
  /// Creates a connecting video state.
  const VideoConnecting();

  @override
  String toString() => 'VideoConnecting';
}

/// Actively receiving video frames.
final class VideoPlaying extends VideoState {
  /// Creates a playing video state.
  const VideoPlaying();

  @override
  String toString() => 'VideoPlaying';
}

/// Stream disconnected or stalled; retrying after [retryIn].
final class VideoReconnecting extends VideoState {
  /// Creates a reconnecting state with retry metadata.
  const VideoReconnecting({
    required this.attempt,
    required this.retryIn,
    required this.error,
  });

  /// 1-based reconnection attempt counter; resets when frames resume.
  final int attempt;

  /// Delay before the next reconnection attempt.
  final Duration retryIn;

  /// Error that triggered this reconnection.
  final VideoError error;

  @override
  String toString() =>
      'VideoReconnecting(attempt: $attempt, retryIn: $retryIn, error: $error)';
}

/// Unrecoverable error (for example, HTTP 401/403 invalid token or bad topic).
final class VideoFailed extends VideoState {
  /// Creates a terminal failed video state with [error].
  const VideoFailed(this.error);

  /// The unrecoverable error that stopped the stream.
  final VideoError error;

  @override
  String toString() => 'VideoFailed($error)';
}

/// Stream has been disposed and cannot be reused.
final class VideoClosed extends VideoState {
  /// Creates a closed video state.
  const VideoClosed();

  @override
  String toString() => 'VideoClosed';
}

/// Classification of a [VideoError].
enum VideoErrorKind {
  /// Unable to connect, network dropped, or server closed the stream.
  network,

  /// Server returned an unexpected HTTP error status code.
  http,

  /// Connection remained open but no new frames arrived within the timeout.
  stalled,

  /// Received data did not match the expected wire format or protocol.
  protocol,
}

/// Structured error reported by a [VideoSource].
final class VideoError {
  /// Creates a [VideoError] with a [kind], human-readable [message], and
  /// optional HTTP [statusCode].
  const VideoError(this.kind, this.message, {this.statusCode});

  /// Category of the failure.
  final VideoErrorKind kind;

  /// Diagnostic error message.
  final String message;

  /// HTTP status code if [kind] is [VideoErrorKind.http], otherwise `null`.
  final int? statusCode;

  @override
  String toString() =>
      'VideoError(${kind.name}${statusCode == null ? '' : ' $statusCode'}: $message)';
}
