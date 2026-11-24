import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:robot_stream_core/robot_stream_core.dart';

import 'low_latency_wifi.dart';
import 'whep_signaling.dart';

/// Receive-only WebRTC [VideoSource] using WHEP signaling (for example,
/// MediaMTX at `http://<host>:8889/<path>/whep`).
///
/// Each connection creates a fresh receive-only `RTCPeerConnection`, gathers
/// ICE candidates up to [iceGatherTimeout], posts the offer, and applies the
/// SDP answer. Sessions terminate and reconnect with exponential backoff if ICE
/// fails, remains disconnected longer than [disconnectGrace], or stops decoding
/// frames for [stallTimeout]. HTTP `401`/`403` stops retrying ([VideoFailed]);
/// `404` retries until the robot stream comes online.
class WhepSource implements VideoSource {
  /// Creates a [WhepSource] for [robotId] with optional signaling, timeout,
  /// backoff, and latency settings.
  WhepSource({
    required this.robotId,
    WhepSignaling Function()? signalingFactory,
    this.iceGatherTimeout = const Duration(milliseconds: 1500),
    this.connectTimeout = const Duration(seconds: 8),
    this.disconnectGrace = const Duration(seconds: 3),
    this.stallTimeout = const Duration(seconds: 5),
    this.minBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 5),
    this.statsInterval = const Duration(seconds: 1),
    this.zeroPlayoutDelay = false,
    this.holdLowLatencyWifi = true,
  }) : _signaling = (signalingFactory ?? WhepSignaling.new)();

  /// Holds an Android `WIFI_MODE_FULL_LOW_LATENCY` WifiLock from [connect]
  /// through [dispose] via [LowLatencyWifi] (no-op on other platforms).
  ///
  /// Prevents Android Wi-Fi power saving from batching packets and inflating
  /// the receiver jitter buffer.
  final bool holdLowLatencyWifi;
  bool _wifiHeld = false;

  /// Requests WebRTC `ForcePlayoutDelay(0, 0)` when initializing `flutter_webrtc`.
  ///
  /// Disabled by default because bursty arrivals can drop frames; prefer
  /// [holdLowLatencyWifi] on Android instead. Applies process-wide only if this
  /// source is the first caller to initialize `WebRTC`.
  final bool zeroPlayoutDelay;

  @override
  final String robotId;

  /// Maximum time to wait for ICE candidate gathering before sending the offer.
  final Duration iceGatherTimeout;

  /// Timeout for WHEP offer exchange and initial ICE connection.
  final Duration connectTimeout;

  /// Grace period before an ICE `disconnected` state triggers reconnection.
  final Duration disconnectGrace;

  /// Maximum time without decoded frames before the stream is considered stalled.
  final Duration stallTimeout;

  /// Initial backoff delay before reconnecting.
  final Duration minBackoff;

  /// Maximum backoff delay between reconnect attempts.
  final Duration maxBackoff;

  /// Interval at which WebRTC `getStats()` is sampled and emitted on [stats].
  final Duration statsInterval;

  final WhepSignaling _signaling;

  final _stateCtl = StreamController<VideoState>.broadcast();
  final _statsCtl = StreamController<VideoStats>.broadcast();
  final _streamCtl = StreamController<MediaStream?>.broadcast();

  @override
  late final Stream<VideoState> state = _stateCtl.stream;
  @override
  late final Stream<VideoStats> stats = _statsCtl.stream;

  /// Broadcast stream of the active remote [MediaStream] (`null` while
  /// disconnected or reconnecting), consumed by [RobotVideoView].
  late final Stream<MediaStream?> remoteStream = _streamCtl.stream;

  /// Current remote [MediaStream], or `null` if none is attached.
  MediaStream? get currentStream => _stream;
  MediaStream? _stream;

  VideoState _state = const VideoIdle();
  @override
  VideoState get currentState => _state;

  Uri? _endpoint;
  String? _token;

  /// Incremented on each `connect`/`dispose` so older loops exit cleanly.
  int _generation = 0;
  Completer<VideoError?>? _sessionEnd;
  Completer<void>? _wake;

  RTCPeerConnection? _pc;
  Timer? _statsTimer;
  final _clock = Stopwatch()..start();
  int _framesTotal = 0;
  int? _lastFramesDecoded;
  int? _lastBytes;
  int? _lastPacketsLost;
  int? _lastPacketsReceived;
  double? _lastJbDelay;
  int _lastJbEmitted = 0;
  Duration? _lastSampleAt;
  Duration _lastFrameAt = Duration.zero;

  /// Opens the WHEP video stream at [endpoint].
  ///
  /// Calling [connect] again with a new endpoint tears down the previous
  /// session and switches streams.
  @override
  Future<void> connect(Uri endpoint, {String? token}) async {
    if (_state is VideoClosed) {
      throw StateError('WhepSource has been disposed');
    }
    _endpoint = endpoint;
    _token = token;
    final gen = _abortCurrent();
    if (holdLowLatencyWifi && !_wifiHeld) {
      _wifiHeld = true;
      unawaited(LowLatencyWifi.acquire());
    }
    _setState(const VideoConnecting());
    unawaited(_run(gen));
  }

  @override
  Future<void> dispose() async {
    if (_state is VideoClosed) return;
    _abortCurrent();
    _setState(const VideoClosed());
    _signaling.close();
    if (_wifiHeld) {
      _wifiHeld = false;
      unawaited(LowLatencyWifi.release());
    }
    await Future.wait([
      _stateCtl.close(),
      _statsCtl.close(),
      _streamCtl.close(),
    ]);
  }

  int _abortCurrent() {
    _generation++;
    final end = _sessionEnd;
    if (end != null && !end.isCompleted) end.complete(null);
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
      final status = result.error.statusCode;
      if (status == 401 || status == 403) {
        _setState(VideoFailed(result.error));
        return;
      }
      attempt = result.played ? 1 : attempt + 1;
      final delay = _backoff(attempt);
      _setState(
        VideoReconnecting(
          attempt: attempt,
          retryIn: delay,
          error: result.error,
        ),
      );
      await _sleep(delay);
    }
  }

  /// Runs one WHEP session; returns `null` if superseded by `connect`/`dispose`.
  Future<({VideoError error, bool played})?> _session(int gen) async {
    final end = Completer<VideoError?>();
    _sessionEnd = end;
    var played = false;
    Uri? session;
    RTCPeerConnection? pc;
    Timer? disconnectTimer;

    void finish(VideoError error) {
      if (!end.isCompleted) end.complete(error);
    }

    try {
      if (!WebRTC.initialized) {
        await WebRTC.initialize(
          options: {if (zeroPlayoutDelay) 'zeroPlayoutDelay': true},
        );
      }
      pc = await createPeerConnection({
        'iceServers': <Map<String, dynamic>>[],
        'sdpSemantics': 'unified-plan',
      });
      _pc = pc;
      if (gen != _generation) return null;

      final gathered = Completer<void>();
      pc.onIceGatheringState = (s) {
        if (s == RTCIceGatheringState.RTCIceGatheringStateComplete &&
            !gathered.isCompleted) {
          gathered.complete();
        }
      };
      pc.onTrack = (event) => _onTrack(event, gen);
      pc.onConnectionState = (s) {
        if (gen != _generation) return;
        switch (s) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            disconnectTimer?.cancel();
            disconnectTimer = null;
            played = true;
            if (_state is! VideoPlaying) _setState(const VideoPlaying());
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            // Transient drops often recover on Wi-Fi; only reconnect after grace.
            disconnectTimer ??= Timer(disconnectGrace, () {
              finish(
                VideoError(
                  VideoErrorKind.network,
                  'ICE disconnected for more than ${disconnectGrace.inSeconds} s',
                ),
              );
            });
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            finish(const VideoError(VideoErrorKind.network, 'ICE failed'));
          default:
            break;
        }
      };

      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      await pc.setLocalDescription(await pc.createOffer());
      await gathered.future.timeout(iceGatherTimeout, onTimeout: () {});
      if (gen != _generation) return null;

      final offer = await pc.getLocalDescription();
      final answer = await _signaling.offer(
        _endpoint!,
        offer!.sdp!,
        token: _token,
        timeout: connectTimeout,
      );
      session = answer.session;
      if (gen != _generation) return null;
      await pc.setRemoteDescription(
        RTCSessionDescription(answer.sdp, 'answer'),
      );

      _startStats(pc, gen, finish);
      final error = await end.future.timeout(
        connectTimeout,
        onTimeout: () => played
            ? null
            : const VideoError(
                VideoErrorKind.network,
                'ICE connection timed out',
              ),
      );
      // If connected before connectTimeout, wait until the session actually ends.
      final reason = error ?? (played ? await end.future : null);
      if (reason == null || gen != _generation) return null;
      return (error: reason, played: played);
    } on WhepException catch (e) {
      if (gen != _generation) return null;
      final status = e.statusCode;
      return (
        error: VideoError(
          status == null ? VideoErrorKind.protocol : VideoErrorKind.http,
          status == 404 ? 'Robot stream not available (404)' : e.message,
          statusCode: status,
        ),
        played: played,
      );
    } on TimeoutException {
      if (gen != _generation) return null;
      return (
        error: VideoError(
          VideoErrorKind.network,
          'WHEP server did not respond within ${connectTimeout.inSeconds} s',
        ),
        played: played,
      );
    } catch (e) {
      if (gen != _generation) return null;
      return (error: VideoError(VideoErrorKind.network, '$e'), played: played);
    } finally {
      disconnectTimer?.cancel();
      _stopStats();
      if (session != null) unawaited(_signaling.delete(session, token: _token));
      if (identical(_pc, pc)) _pc = null;
      if (pc != null) {
        await pc.close();
        await pc.dispose();
      }
      // If superseded by a newer connect(), let the new session own the stream.
      if (gen == _generation) _setStream(null);
    }
  }

  Future<void> _onTrack(RTCTrackEvent event, int gen) async {
    if (gen != _generation || event.track.kind != 'video') return;
    var stream = event.streams.isNotEmpty ? event.streams.first : null;
    if (stream == null) {
      stream = await createLocalMediaStream('robot_$robotId');
      await stream.addTrack(event.track);
    }
    if (gen == _generation) _setStream(stream);
  }

  void _startStats(
    RTCPeerConnection pc,
    int gen,
    void Function(VideoError) finish,
  ) {
    _resetStats();
    _statsTimer = Timer.periodic(statsInterval, (_) async {
      if (gen != _generation || _statsCtl.isClosed) return;
      try {
        _emitStats(await pc.getStats(), finish);
      } catch (_) {
        // PeerConnection is closing.
      }
    });
  }

  void _stopStats() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  void _resetStats() {
    _lastFramesDecoded = null;
    _lastBytes = null;
    _lastPacketsLost = null;
    _lastPacketsReceived = null;
    _lastJbDelay = null;
    _lastJbEmitted = 0;
    _lastSampleAt = null;
    _lastFrameAt = _clock.elapsed;
  }

  void _emitStats(List<StatsReport> reports, void Function(VideoError) finish) {
    Map<dynamic, dynamic>? inbound;
    double? rttMs;
    for (final r in reports) {
      if (r.type == 'inbound-rtp' && r.values['kind'] == 'video') {
        inbound = r.values;
      }
      if (r.type == 'candidate-pair' &&
          (r.values['nominated'] == true || r.values['state'] == 'succeeded')) {
        final rtt = r.values['currentRoundTripTime'];
        if (rtt is num) rttMs = rtt * 1000;
      }
    }
    if (inbound == null) return;

    final now = _clock.elapsed;
    final frames = _int(inbound['framesDecoded']);
    final bytes = _int(inbound['bytesReceived']);
    final lost = _int(inbound['packetsLost']);
    final received = _int(inbound['packetsReceived']);
    final seconds = _lastSampleAt == null
        ? 0.0
        : (now - _lastSampleAt!).inMicroseconds / 1e6;

    var fps = 0.0, kbps = 0.0;
    double? loss;
    if (seconds > 0) {
      final df = frames - (_lastFramesDecoded ?? frames);
      fps = df / seconds;
      kbps = (bytes - (_lastBytes ?? bytes)) * 8 / 1000 / seconds;
      final dLost = lost - (_lastPacketsLost ?? lost);
      final dRecv = received - (_lastPacketsReceived ?? received);
      if (dLost + dRecv > 0) loss = dLost / (dLost + dRecv);
      if (df > 0) {
        _framesTotal += df;
        _lastFrameAt = now;
      }
    }
    _lastFramesDecoded = frames;
    _lastBytes = bytes;
    _lastPacketsLost = lost;
    _lastPacketsReceived = received;
    _lastSampleAt = now;

    // Treat extended lack of decoded frames as a stall even if ICE stays up.
    final gap = now - _lastFrameAt;
    if (frames > 0 && gap > stallTimeout) {
      finish(
        VideoError(
          VideoErrorKind.stalled,
          'No new frames for ${stallTimeout.inSeconds} s',
        ),
      );
    }

    // Compute per-window jitter buffer delay from cumulative WebRTC counters.
    final emitted = _int(inbound['jitterBufferEmittedCount']);
    final jbRaw = inbound['jitterBufferDelay'];
    final jbDelay = jbRaw is num ? jbRaw.toDouble() : null;
    double? jitterBufferMs;
    if (jbDelay != null && _lastJbDelay != null && emitted > _lastJbEmitted) {
      jitterBufferMs =
          1000 * (jbDelay - _lastJbDelay!) / (emitted - _lastJbEmitted);
    }
    _lastJbDelay = jbDelay;
    _lastJbEmitted = emitted;
    _statsCtl.add(
      VideoStats(
        fps: fps,
        bitrateKbps: kbps,
        // Sampled every statsInterval, so gap resolution is ~1 s.
        maxFrameGap: gap,
        framesTotal: _framesTotal,
        rttMs: rttMs,
        packetLoss: loss,
        jitterBufferMs: jitterBufferMs,
      ),
    );
  }

  static int _int(Object? v) => v is num ? v.toInt() : 0;

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

  void _setStream(MediaStream? stream) {
    _stream = stream;
    if (!_streamCtl.isClosed) _streamCtl.add(stream);
  }

  void _setState(VideoState next) {
    _state = next;
    if (!_stateCtl.isClosed) _stateCtl.add(next);
  }
}
