import 'package:flutter/material.dart';
import 'package:robot_stream_core/robot_stream_core.dart';
import 'package:robot_stream_mjpeg/robot_stream_mjpeg.dart';
import 'package:robot_stream_rosbridge/robot_stream_rosbridge.dart';
import 'package:robot_stream_webrtc/robot_stream_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'latency_probe.dart';
import 'nav_panel.dart';
import 'telemetry_overlay.dart';

void main() => runApp(
  const RobotStreamApp(
    initialTransport: String.fromEnvironment('TRANSPORT') == 'mjpeg'
        ? Transport.mjpeg
        : Transport.webrtc,
  ),
);

class RobotStreamApp extends StatelessWidget {
  const RobotStreamApp({
    super.key,
    this.autoConnect = true,
    this.initialTransport = Transport.webrtc,
  });

  /// Tự kết nối tới IP mặc định khi mở app.
  final bool autoConnect;
  final Transport initialTransport;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'R550 Stream',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: CameraPage(
        autoConnect: autoConnect,
        initialTransport: initialTransport,
      ),
    );
  }
}

/// `--dart-define=ZERO_PLAYOUT=true` để thử WhepSource.zeroPlayoutDelay (mặc định tắt:
/// mất frame; WifiLock trong MainActivity.kt đã đưa jitter buffer xuống ~14 ms).
const _zeroPlayoutDelay = bool.fromEnvironment('ZERO_PLAYOUT');

/// `--dart-define=WIFI_LOCK=false` để thử không giữ WifiLock LOW_LATENCY.
const _wifiLock = bool.fromEnvironment('WIFI_LOCK', defaultValue: true);

/// `--dart-define=AUTO_LATENCY=true`: tự bấm "Đo latency" khi có video (máy ảo iOS
/// không có lệnh bấm như adb; kết quả ở log `[latency]`).
const _autoLatency = bool.fromEnvironment('AUTO_LATENCY');

/// Đường nhận video.
enum Transport {
  webrtc('WebRTC'),
  mjpeg('MJPEG');

  const Transport(this.label);

  final String label;
}

/// Token robot (`ros2 run robot_stream_ros show_token` trên robot). Nhập trong app (lưu
/// lại cho lần sau) hoặc `--dart-define=ROBOT_TOKEN=…`.
const _tokenDefine = String.fromEnvironment('ROBOT_TOKEN');
const _tokenPrefKey = 'robot_token';

/// Robot bật TLS (`stream.launch.py tls:=true`): `--dart-define=ROBOT_CERT_SHA256=<vân
/// tay>` (make_cert.sh in ra) → wss + https, chỉ tin đúng chứng chỉ đó.
const _certSha256 = String.fromEnvironment('ROBOT_CERT_SHA256');
const _secure = _certSha256 != '';

/// Loại robot: `--dart-define=PROFILE=r550|nav2` (mặc định r550). Quyết định topic,
/// giới hạn pin / tốc độ – xem [RobotProfile].
final _profile = RobotProfile.byId(const String.fromEnvironment('PROFILE'));

/// Địa chỉ mặc định cho từng hồ sơ (chỉ dùng trong app example).
const _defaultHosts = {'r550': '192.168.1.100', 'nav2': '192.168.1.100'};

class CameraPage extends StatefulWidget {
  const CameraPage({
    super.key,
    this.autoConnect = true,
    this.initialTransport = Transport.webrtc,
  });

  final bool autoConnect;
  final Transport initialTransport;

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  final _host = TextEditingController(text: _defaultHosts[_profile.id] ?? '');
  final _token = TextEditingController(text: _tokenDefine);
  bool _showToken = false;
  late Transport _transport = widget.initialTransport;
  late VideoSource _source = _newSource();

  /// Telemetry (pose, pin) + điều hướng (NavPanel) qua cổng gác rosbridge :9091.
  final _telemetry = RosbridgeTransport(
    robotId: _profile.id,
    topics: _profile.topics,
    httpClient: _secure ? pinnedHttpClient(_certSha256) : null,
  );

  String? get _tokenOrNull =>
      _token.text.trim().isEmpty ? null : _token.text.trim();

  /// WHEP (MediaMTX) nhận Bearer dạng `robot_stream:<token>`; MJPEG (web_video_server
  /// của R550) không có xác thực.
  String? get _videoToken =>
      _transport == Transport.webrtc && _tokenOrNull != null
      ? mediamtxCredential(_tokenOrNull!)
      : null;

  void _connectAll() {
    _source.connect(_endpoint, token: _videoToken);
    _telemetry.connect(
      rosbridgeUri(host: _host.text.trim(), secure: _secure),
      token: _tokenOrNull,
    );
  }

  Future<void> _loadTokenThenConnect() async {
    if (_token.text.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        _token.text = prefs.getString(_tokenPrefKey) ?? '';
      } catch (_) {}
    }
    if (!mounted) return;
    _connectAll();
    setState(() => _connected = true);
  }

  String _topic = _profile.mjpegTopics.first.$1;

  /// `quality=50&width=640&height=480`: giảm tải web_video_server.
  bool _lowLoad = true;
  bool _connected = false;
  bool _measuring = false;
  double _lastFps = 30;
  final _statsDuringMeasure = <VideoStats>[];
  String? _latencyText;

  /// Đồng bộ đồng hồ với robot rồi đọc mã vạch trên ~60 frame (xem LatencyProbe).
  Future<void> _measureLatency(WhepSource whep) async {
    final track = whep.currentStream?.getVideoTracks().firstOrNull;
    if (track == null) {
      setState(() => _latencyText = 'Chưa có video WebRTC');
      return;
    }
    final probe = LatencyProbe(host: _host.text.trim());
    setState(() {
      _measuring = true;
      _latencyText = 'Đồng bộ đồng hồ…';
    });
    try {
      final clock = await probe.clockOffset();
      final clockText =
          'đồng hồ lệch ${clock.offsetMs.toStringAsFixed(1)} ms, '
          'rtt min ${clock.rttMs.toStringAsFixed(1)} ms';
      _statsDuringMeasure.clear();
      final result = await probe.measure(
        track,
        offsetMs: clock.offsetMs,
        fps: _lastFps,
        onProgress: (n) {
          if (mounted) {
            setState(() => _latencyText = 'Đang đo $n/60 · $clockText');
          }
        },
      );
      final stats = [..._statsDuringMeasure];
      _statsDuringMeasure.clear();
      final text =
          'Latency tới lúc decode xong (cận dưới, ±1 frame): $result\n$clockText';
      debugPrint('[latency] $text');
      // Log `flutter run` từ iOS hay ngắt: gửi kết quả về www_server của robot
      // (chế độ đo) để đọc qua SSH: ~/robot_stream/www/results.jsonl.
      await postLatencyResult(
        host: _host.text.trim(),
        result: result,
        clockOffsetMs: clock.offsetMs,
        clockRttMs: clock.rttMs,
        stats: stats,
      );
      if (mounted) setState(() => _latencyText = text);
    } catch (e) {
      if (mounted) setState(() => _latencyText = 'Lỗi đo: $e');
    } finally {
      if (mounted) setState(() => _measuring = false);
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.autoConnect) _loadTokenThenConnect();
    if (_autoLatency) {
      Future<void>.delayed(const Duration(seconds: 8), () {
        if (_source case final WhepSource whep when mounted) {
          _measureLatency(whep);
        }
      });
    }
  }

  /// Mỗi lúc chỉ mở một nguồn, để robot không phải phục vụ hai luồng.
  VideoSource _newSource() {
    final VideoSource source = switch (_transport) {
      Transport.webrtc => WhepSource(
        robotId: 'r550',
        signalingFactory: _secure
            ? () => WhepSignaling.pinned(_certSha256)
            : null,
        zeroPlayoutDelay: _zeroPlayoutDelay,
        holdLowLatencyWifi: _wifiLock,
      ),
      Transport.mjpeg => MjpegSource(robotId: 'r550'),
    };
    // Ghi trạng thái ra log để xem bằng `flutter logs` / logcat.
    source.state.listen((s) => debugPrint('[video ${_transport.name}] $s'));
    source.stats.listen((s) {
      if (s.fps > 0) _lastFps = s.fps;
      if (_measuring) _statsDuringMeasure.add(s);
      debugPrint(
        '[stats ${_transport.name}] $s'
        '${s.jitterBufferMs == null ? '' : ' jb ${s.jitterBufferMs!.toStringAsFixed(0)} ms'}',
      );
    });
    return source;
  }

  void _switchTransport(Transport t) {
    if (t == _transport) return;
    final old = _source;
    setState(() {
      _transport = t;
      _source = _newSource();
    });
    old.dispose();
    if (_connected) _source.connect(_endpoint, token: _videoToken);
  }

  @override
  void dispose() {
    _source.dispose();
    _telemetry.dispose();
    _host.dispose();
    _token.dispose();
    super.dispose();
  }

  Uri get _endpoint => switch (_transport) {
    Transport.webrtc => mediamtxWhepUri(
      host: _host.text.trim(),
      secure: _secure,
    ),
    Transport.mjpeg => webVideoServerUri(
      host: _host.text.trim(),
      topic: _topic,
      quality: _lowLoad ? 50 : null,
      width: _lowLoad ? 640 : null,
      height: _lowLoad ? 480 : null,
    ),
  };

  void _connect() {
    if (_host.text.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    final token = _token.text.trim();
    SharedPreferences.getInstance()
        .then((p) => p.setString(_tokenPrefKey, token))
        .catchError((_) => false);
    _connectAll();
    setState(() => _connected = true);
  }

  /// Đổi tham số khi đang xem thì mở lại luồng ngay.
  void _update(VoidCallback change) {
    setState(change);
    if (_connected) _source.connect(_endpoint, token: _videoToken);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_profile.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    switch (_source) {
                      final WhepSource s => RobotVideoView(
                        key: ObjectKey(s),
                        source: s,
                        placeholder: _placeholder,
                      ),
                      final MjpegSource s => MjpegView(
                        key: ObjectKey(s),
                        source: s,
                        placeholder: _placeholder,
                      ),
                      _ => _placeholder,
                    },
                    Positioned(
                      left: 8,
                      right: 8,
                      top: 8,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: _StateBadge(
                          key: ObjectKey(_source),
                          source: _source,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      top: 8,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 210),
                        child: TelemetryOverlay(transport: _telemetry),
                      ),
                    ),
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 8,
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: _StatsOverlay(
                          key: ObjectKey(_source),
                          source: _source,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'IP robot',
              hintText: '192.168.1.100',
              border: OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onSubmitted: (_) => _connect(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: !_showToken,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Token robot',
              helperText: 'Trên robot: ros2 run robot_stream_ros show_token',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _showToken ? 'Ẩn' : 'Hiện',
                icon: Icon(
                  _showToken ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () => setState(() => _showToken = !_showToken),
              ),
            ),
            onSubmitted: (_) => _connect(),
          ),
          const SizedBox(height: 16),
          SegmentedButton<Transport>(
            segments: [
              for (final t in Transport.values)
                ButtonSegment(value: t, label: Text(t.label)),
            ],
            selected: {_transport},
            onSelectionChanged: (s) => _switchTransport(s.first),
          ),
          if (_transport == Transport.mjpeg) ...[
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: [
                for (final (topic, label) in _profile.mjpegTopics)
                  ButtonSegment(value: topic, label: Text(label)),
              ],
              selected: {_topic},
              onSelectionChanged: (s) => _update(() => _topic = s.first),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Giảm tải (640x480, quality 50)'),
              value: _lowLoad,
              onChanged: (v) => _update(() => _lowLoad = v),
            ),
          ],
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _connect,
            icon: Icon(_connected ? Icons.refresh : Icons.play_arrow),
            label: Text(_connected ? 'Kết nối lại' : 'Kết nối'),
          ),
          const SizedBox(height: 8),
          SelectableText(
            _endpoint.toString(),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          NavPanel(transport: _telemetry, profile: _profile),
          if (_source case final WhepSource whep) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _measuring ? null : () => _measureLatency(whep),
              icon: const Icon(Icons.timer_outlined),
              label: const Text('Đo latency (robot: measure_mode.sh on)'),
            ),
            if (_latencyText != null) ...[
              const SizedBox(height: 8),
              SelectableText(_latencyText!),
            ],
          ],
        ],
      ),
    );
  }
}

Widget get _placeholder => Center(
  child: Icon(
    Icons.videocam_off_outlined,
    size: 48,
    color: Colors.white.withValues(alpha: 0.4),
  ),
);

class _StateBadge extends StatelessWidget {
  const _StateBadge({super.key, required this.source});

  final VideoSource source;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<VideoState>(
      stream: source.state,
      initialData: source.currentState,
      builder: (context, snapshot) {
        final (text, color) = switch (snapshot.data!) {
          VideoIdle() => ('Chưa kết nối', Colors.grey),
          VideoConnecting() => ('Đang kết nối…', Colors.blue),
          VideoPlaying() => ('Đang phát', Colors.green),
          VideoReconnecting(:final attempt, :final error) => (
            'Kết nối lại #$attempt – ${_describe(error)}\n${error.message}',
            Colors.orange,
          ),
          VideoFailed(:final error) => (
            'Lỗi: ${_describe(error)}\n${error.message}',
            Colors.red,
          ),
          VideoClosed() => ('Đã đóng', Colors.grey),
        };
        return _Badge(text: text, dotColor: color);
      },
    );
  }

  static String _describe(VideoError error) => switch (error.kind) {
    VideoErrorKind.stalled => 'đứng hình',
    VideoErrorKind.http => 'HTTP ${error.statusCode}',
    VideoErrorKind.protocol => 'sai định dạng',
    VideoErrorKind.network => 'mất kết nối',
  };
}

class _StatsOverlay extends StatelessWidget {
  const _StatsOverlay({super.key, required this.source});

  final VideoSource source;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<VideoStats>(
      stream: source.stats,
      builder: (context, snapshot) {
        final s = snapshot.data;
        if (s == null) return const SizedBox.shrink();
        final gapMs = s.maxFrameGap.inMilliseconds;
        final rtc = [
          if (s.rttMs != null) 'rtt ${s.rttMs!.toStringAsFixed(0)} ms',
          if (s.jitterBufferMs != null)
            'jb ${s.jitterBufferMs!.toStringAsFixed(0)} ms',
          if (s.packetLoss != null)
            'mất ${(s.packetLoss! * 100).toStringAsFixed(1)}%',
        ];
        return _Badge(
          text:
              '${s.fps.toStringAsFixed(1)} fps · '
              '${(s.bitrateKbps / 1000).toStringAsFixed(2)} Mbps · '
              'gap $gapMs ms · ${s.framesTotal} frame'
              '${rtc.isEmpty ? '' : '\n${rtc.join(' · ')}'}',
          // Tiêu chí: không đứng hình quá 0.5 s.
          dotColor: gapMs > 500 ? Colors.red : Colors.green,
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.dotColor});

  final String text;
  final Color dotColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 8, color: dotColor),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
