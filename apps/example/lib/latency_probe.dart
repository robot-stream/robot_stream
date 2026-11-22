import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:robot_stream_core/robot_stream_core.dart';

/// Đo latency WebRTC ngay trên điện thoại.
///
/// Cần robot ở chế độ đo (`robot_node/scripts/measure_mode.sh on`): stream_node vẽ
/// `header.stamp` (ms, 32 bit) thành mã vạch ở 32 hàng trên cùng, time_server UDP :9123.
///
/// `captureFrame()` của flutter_webrtc (Android) lấy frame **đầu tiên giao tới sink sau
/// lúc gọi** (đã decode, sắp lên màn hình) rồi nén JPEG. Lấy lúc gọi làm mốc → latency
/// "tới lúc decode xong" là **cận dưới**, sai tối đa 1 khoảng frame (~33 ms ở 30 fps);
/// hiển thị lên màn hình thêm ~1 vsync.
class LatencyProbe {
  LatencyProbe({required this.host, this.timePort = 9123});

  final String host;
  final int timePort;

  static const _bits = 32;
  static const _rowH = 16;

  /// Độ lệch đồng hồ (ms) = giờ robot − giờ điện thoại, lấy mẫu RTT nhỏ nhất.
  Future<({double offsetMs, double rttMs})> clockOffset({
    int count = 100,
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final robot = InternetAddress(host);
    // Mỗi gói một Completer theo seq: gói trả lời trễ / mất không làm kẹt gói sau.
    final pending = <int, Completer<(int robotNs, int t1)>>{};
    final sub = socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d == null || d.data.length < 16) return;
      final t1 = _nowUs();
      final b = ByteData.sublistView(d.data);
      final c = pending.remove(b.getInt64(0));
      if (c != null && !c.isCompleted) c.complete((b.getInt64(8), t1));
    });
    (int, int)? best; // (rtt µs, offset µs)
    try {
      for (var seq = 0; seq < count; seq++) {
        final reply = Completer<(int, int)>();
        pending[seq] = reply;
        final t0 = _nowUs();
        final sent = socket.send(
          (ByteData(8)..setInt64(0, seq)).buffer.asUint8List(),
          robot,
          timePort,
        );
        if (sent == 0) {
          pending.remove(seq); // socket chưa sẵn sàng ghi
        } else {
          final got = await reply.future
              .then<(int, int)?>((r) => r)
              .timeout(
                const Duration(milliseconds: 500),
                onTimeout: () => null,
              );
          pending.remove(seq);
          if (got != null) {
            final (robotNs, t1) = got;
            final rtt = t1 - t0;
            if (best == null || rtt < best.$1) {
              best = (rtt, robotNs ~/ 1000 - (t0 + t1) ~/ 2);
            }
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    } finally {
      await sub.cancel();
      socket.close();
    }
    if (best == null) {
      throw StateError(
        'time_server :$timePort không trả lời – robot đã bật measure_mode chưa?',
      );
    }
    return (offsetMs: best.$2 / 1000, rttMs: best.$1 / 1000);
  }

  /// Chụp [samples] frame, đọc mã vạch, trả latency (ms) từ `header.stamp` tới lúc
  /// frame được decode xong trên điện thoại.
  ///
  /// Frame được giao tới sink trong khoảng (lúc gọi, lúc gọi + 1 khoảng frame), nên
  /// "lúc gọi − stamp" là cận dưới (có thể âm khi FPS thấp) và "lúc captureFrame trả về
  /// − stamp" là cận trên (gồm cả nén JPEG). Ước lượng = cận dưới + ½ khoảng frame.
  Future<LatencyResult> measure(
    MediaStreamTrack track, {
    required double offsetMs,
    required double fps,
    int samples = 60,
    Duration interval = const Duration(milliseconds: 200),
    void Function(int done)? onProgress,
  }) async {
    final lo = <double>[], hi = <double>[];
    var decodeFail = 0;
    int? lastValue;
    for (var i = 0; i < samples; i++) {
      final t0Ms = _nowUs() / 1000;
      final jpeg = await track.captureFrame();
      final t1Ms = _nowUs() / 1000;
      final value = await _readBarcode(jpeg.asUint8List());
      if (value == null) {
        decodeFail++;
      } else if (value != lastValue) {
        // Bỏ frame lặp (stream_node giữ frame cuối khi camera khựng).
        lastValue = value;
        lo.add(_signed32((t0Ms + offsetMs).round() - value).toDouble());
        hi.add(_signed32((t1Ms + offsetMs).round() - value).toDouble());
      }
      onProgress?.call(i + 1);
      await Future<void>.delayed(interval);
    }
    return LatencyResult(
      lo,
      hi,
      decodeFail,
      frameMs: fps > 0 ? 1000 / fps : 33,
    );
  }

  /// Mã vạch chỉ giữ 32 bit thấp của ms → đưa hiệu về khoảng ±2^31.
  static int _signed32(int d) {
    final m = d & 0xFFFFFFFF;
    return m >= 0x80000000 ? m - 0x100000000 : m;
  }

  static Future<int?> _readBarcode(Uint8List jpeg) async {
    final codec = await ui.instantiateImageCodec(jpeg);
    final image = (await codec.getNextFrame()).image;
    final w = image.width;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    codec.dispose();
    if (data == null || image.height < 2 * _rowH) return null;
    final px = data.buffer.asUint8List();
    final cell = w ~/ _bits;
    double luma(int x, int y) {
      var s = 0.0;
      for (var dy = -3; dy <= 3; dy++) {
        for (var dx = -3; dx <= 3; dx++) {
          final i = ((y + dy) * w + (x + dx)) * 4;
          s += 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];
        }
      }
      return s / 49;
    }

    var value = 0;
    for (var b = 0; b < _bits; b++) {
      final x = ((b + 0.5) * cell).floor();
      final top = luma(x, _rowH ~/ 2), bottom = luma(x, _rowH + _rowH ~/ 2);
      // Hàng đảo bit không khớp → đọc sai.
      if ((top - bottom).abs() < 60) return null;
      value = value * 2 + (top > bottom ? 1 : 0);
    }
    return value;
  }

  static int _nowUs() => DateTime.now().microsecondsSinceEpoch;
}

class LatencyResult {
  LatencyResult(
    List<double> lo,
    List<double> hi,
    this.decodeFail, {
    required this.frameMs,
  }) : lo = [...lo]..sort(),
       hi = [...hi]..sort();

  /// "lúc gọi captureFrame − stamp" (cận dưới) và "lúc trả về − stamp" (cận trên), ms.
  final List<double> lo, hi;
  final int decodeFail;

  /// Khoảng giữa hai frame lúc đo (1000 / fps).
  final double frameMs;

  static double _p(List<double> a, double q) => a[((a.length - 1) * q).round()];

  /// Ước lượng p50 latency tới lúc decode xong = cận dưới + ½ khoảng frame.
  double get estimateP50 => _p(lo, 0.5) + frameMs / 2;

  @override
  String toString() {
    if (lo.isEmpty) {
      return 'không đọc được frame nào (lỗi mã vạch $decodeFail) – stamp_barcode đã bật chưa?';
    }
    String f(double v) => v.toStringAsFixed(0);
    return '≈ ${f(estimateP50)} ms (p50) · cận dưới p50 ${f(_p(lo, 0.5))} / p95 ${f(_p(lo, 0.95))} · '
        'cận trên p50 ${f(_p(hi, 0.5))} · khung ${f(frameMs)} ms · n ${lo.length}, lỗi mã vạch $decodeFail';
  }
}

/// Gửi kết quả đo + stats WebRTC trong lúc đo tới `www_server.py` của robot
/// (`POST http://<robot>:8001/result`, chỉ chạy ở chế độ đo). Lỗi bị bỏ qua.
Future<void> postLatencyResult({
  required String host,
  required LatencyResult result,
  required double clockOffsetMs,
  required double clockRttMs,
  required List<VideoStats> stats,
}) async {
  double? pct(List<double> a, double q) {
    if (a.isEmpty) return null;
    final s = [...a]..sort();
    return s[((s.length - 1) * q).round()];
  }

  final jb = [for (final s in stats) ?s.jitterBufferMs];
  final fps = [for (final s in stats) s.fps];
  final body = jsonEncode({
    'label': 'app-${Platform.operatingSystem}',
    'os': Platform.operatingSystemVersion,
    'decode_ms_estimate_p50': result.lo.isEmpty ? null : result.estimateP50,
    'decode_ms_lo_p50': pct(result.lo, 0.5),
    'decode_ms_lo_p95': pct(result.lo, 0.95),
    'decode_ms_hi_p50': pct(result.hi, 0.5),
    'frame_ms': result.frameMs,
    'n': result.lo.length,
    'decode_fail': result.decodeFail,
    'clock_offset_ms': clockOffsetMs,
    'clock_rtt_ms': clockRttMs,
    'fps_p50': pct(fps, 0.5),
    'jitter_buffer_ms_p50': pct(jb, 0.5),
    'jitter_buffer_ms_p95': pct(jb, 0.95),
  });
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.postUrl(Uri.parse('http://$host:8001/result'));
    // www_server.py đọc theo Content-Length: không gửi chunked.
    final bytes = utf8.encode(body);
    req.headers.contentType = ContentType.json;
    req.contentLength = bytes.length;
    req.add(bytes);
    await (await req.close()).drain<void>();
  } catch (_) {
    // www_server chỉ chạy ở chế độ đo.
  } finally {
    client.close(force: true);
  }
}
