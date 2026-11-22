import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:robot_stream_core/robot_stream_core.dart';

import 'mjpeg_frame_decoder.dart';

/// HTTP MJPEG [VideoSource] (for example, ROS `web_video_server`).
///
/// Reconnects automatically with exponential backoff on network failures,
/// server disconnects, or frame stalls longer than [stallTimeout]. HTTP 4xx
/// responses are treated as unrecoverable configuration errors ([VideoFailed]).
class MjpegSource implements VideoSource {
  /// Creates an [MjpegSource] for [robotId] with optional HTTP client factory
  /// and reconnect/stall tuning parameters.
  MjpegSource({
    required this.robotId,
    http.Client Function()? clientFactory,
    this.connectTimeout = const Duration(seconds: 5),
    this.stallTimeout = const Duration(seconds: 3),
    this.minBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 5),
    this.statsInterval = const Duration(seconds: 1),
  }) : _clientFactory = clientFactory ?? http.Client.new;

  @override
  final String robotId;

  /// Timeout for the initial HTTP response headers.
  final Duration connectTimeout;

  /// Maximum time without a new frame before the stream is considered stalled.
  final Duration stallTimeout;

  /// Initial backoff delay before reconnecting.
  final Duration minBackoff;

  /// Maximum backoff delay between reconnect attempts.
  final Duration maxBackoff;

  /// Interval at which [stats] samples are emitted.
  final Duration statsInterval;

  final http.Client Function() _clientFactory;

  final _stateCtl = StreamController<VideoState>.broadcast();
  final _statsCtl = StreamController<VideoStats>.broadcast();
  final _frameCtl = StreamController<Uint8List>.broadcast();

  @override
  late final Stream<VideoState> state = _stateCtl.stream;
  @override
  late final Stream<VideoStats> stats = _statsCtl.stream;

  /// Broadcast stream of raw (encoded) JPEG frames as they arrive.
  late final Stream<Uint8List> frames = _frameCtl.stream;

  VideoState _state = const VideoIdle();
  @override
  VideoState get currentState => _state;

  /// Most recently received JPEG frame, allowing widgets to render immediately
  /// upon mounting.
  Uint8List? get lastFrame => _lastFrame;
  Uint8List? _lastFrame;

  Uri? _endpoint;
  String? _token;

  /// Incremented on each `connect`/`dispose` so older loops exit cleanly.
  int _generation = 0;
  http.Client? _client;
  Completer<void>? _wake;

  final _clock = Stopwatch()..start();
  Timer? _statsTimer;
  int _framesTotal = 0;
  int _windowFrames = 0;
  int _windowBytes = 0;
  Duration _windowStart = Duration.zero;
  Duration _windowMaxGap = Duration.zero;
  Duration? _lastFrameAt;

  /// Opens the MJPEG stream at [endpoint].
  ///
  /// Calling [connect] again with a different URI switches streams cleanly.
  @override
  Future<void> connect(Uri endpoint, {String? token}) async {
    if (_state is VideoClosed) {
      throw StateError('MjpegSource đã dispose');
    }
    _endpoint = endpoint;
    _token = token;
    final gen = _abortCurrent();
    _resetStats();
    _statsTimer ??= Timer.periodic(statsInterval, (_) => _emitStats());
    _setState(const VideoConnecting());
    unawaited(_run(gen));
  }

  @override
  Future<void> dispose() async {
    if (_state is VideoClosed) return;
    _abortCurrent();
    _statsTimer?.cancel();
    _setState(const VideoClosed());
    await Future.wait([
      _stateCtl.close(),
      _statsCtl.close(),
      _frameCtl.close(),
    ]);
  }

  int _abortCurrent() {
    _generation++;
    _client?.close();
    _client = null;
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
    return _generation;
  }

  Future<void> _run(int gen) async {
    var attempt = 0;
    while (gen == _generation) {
      final result = await _session(gen);
      if (result == null || gen != _generation) return;
      final error = result.error;
      final status = error.statusCode;
      if (status != null && status >= 400 && status < 500) {
        _setState(VideoFailed(error));
        return;
      }
      attempt = result.gotFrames ? 1 : attempt + 1;
      final delay = _backoff(attempt);
      _setState(
        VideoReconnecting(attempt: attempt, retryIn: delay, error: error),
      );
      await _sleep(delay);
    }
  }

  /// Runs one HTTP session; returns `null` if superseded by `connect`/`dispose`.
  Future<({VideoError error, bool gotFrames})?> _session(int gen) async {
    final client = _clientFactory();
    _client = client;
    var gotFrames = false;
    var stalled = false;
    Timer? stallTimer;

    void armStallTimer() {
      stallTimer?.cancel();
      stallTimer = Timer(stallTimeout, () {
        stalled = true;
        client.close();
      });
    }

    ({VideoError error, bool gotFrames}) fail(
      VideoErrorKind kind,
      String message, {
      int? statusCode,
    }) {
      final error = stalled
          ? VideoError(
              VideoErrorKind.stalled,
              'Không có frame mới trong ${stallTimeout.inMilliseconds} ms',
            )
          : VideoError(kind, message, statusCode: statusCode);
      return (error: error, gotFrames: gotFrames);
    }

    try {
      final request = http.Request('GET', _endpoint!);
      final token = _token;
      if (token != null) request.headers['Authorization'] = 'Bearer $token';

      final response = await client.send(request).timeout(connectTimeout);
      if (gen != _generation) return null;
      if (response.statusCode != 200) {
        return fail(
          VideoErrorKind.http,
          response.reasonPhrase ?? 'HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }

      armStallTimer();
      await for (final frame in response.stream.transform(
        const MjpegFrameDecoder(),
      )) {
        if (gen != _generation) return null;
        armStallTimer();
        gotFrames = true;
        _onFrame(frame);
      }
      if (gen != _generation) return null;
      return fail(
        VideoErrorKind.network,
        gotFrames
            ? 'Server đóng luồng'
            : 'Server đóng luồng khi chưa gửi frame nào – sai topic?',
      );
    } on TimeoutException {
      if (gen != _generation) return null;
      return fail(
        VideoErrorKind.network,
        'Không kết nối được trong ${connectTimeout.inSeconds} s',
      );
    } on FormatException catch (e) {
      if (gen != _generation) return null;
      return fail(VideoErrorKind.protocol, e.message);
    } catch (e) {
      if (gen != _generation) return null;
      return fail(VideoErrorKind.network, '$e');
    } finally {
      stallTimer?.cancel();
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  void _onFrame(Uint8List frame) {
    final now = _clock.elapsed;
    final last = _lastFrameAt;
    if (last != null) {
      final gap = now - last;
      if (gap > _windowMaxGap) _windowMaxGap = gap;
    }
    _lastFrameAt = now;
    _framesTotal++;
    _windowFrames++;
    _windowBytes += frame.length;
    _lastFrame = frame;
    if (_state is! VideoPlaying) _setState(const VideoPlaying());
    _frameCtl.add(frame);
  }

  void _emitStats() {
    if (_statsCtl.isClosed) return;
    final now = _clock.elapsed;
    final seconds = (now - _windowStart).inMicroseconds / 1e6;
    if (seconds <= 0) return;
    // Include any ongoing stall duration in maxFrameGap.
    var maxGap = _windowMaxGap;
    final last = _lastFrameAt;
    if (last != null && now - last > maxGap) maxGap = now - last;
    _statsCtl.add(
      VideoStats(
        fps: _windowFrames / seconds,
        bitrateKbps: _windowBytes * 8 / 1000 / seconds,
        maxFrameGap: maxGap,
        framesTotal: _framesTotal,
      ),
    );
    _windowStart = now;
    _windowFrames = 0;
    _windowBytes = 0;
    _windowMaxGap = Duration.zero;
  }

  void _resetStats() {
    _framesTotal = 0;
    _windowFrames = 0;
    _windowBytes = 0;
    _windowMaxGap = Duration.zero;
    _windowStart = _clock.elapsed;
    _lastFrameAt = null;
    _lastFrame = null;
  }

  Duration _backoff(int attempt) {
    final ms = minBackoff.inMilliseconds * math.pow(2, attempt - 1);
    return Duration(
      milliseconds: math.min(ms, maxBackoff.inMilliseconds).round(),
    );
  }

  Future<void> _sleep(Duration delay) {
    final wake = Completer<void>();
    _wake = wake;
    final timer = Timer(delay, () {
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future.whenComplete(timer.cancel);
  }

  void _setState(VideoState next) {
    _state = next;
    if (!_stateCtl.isClosed) _stateCtl.add(next);
  }
}
