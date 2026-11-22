import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:robot_stream_core/robot_stream_core.dart';
import 'package:robot_stream_mjpeg/robot_stream_mjpeg.dart';

import 'fixtures.dart';

/// Server MJPEG giả, mỗi request gọi [handler] để quyết định cách trả lời.
class FakeMjpegServer {
  FakeMjpegServer._(this._server);

  final HttpServer _server;
  late Future<void> Function(HttpResponse response, int requestIndex) handler;
  int requests = 0;

  static Future<FakeMjpegServer> start() async {
    final fake = FakeMjpegServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fake._server.listen((request) async {
      final index = fake.requests++;
      try {
        await fake.handler(request.response, index);
      } catch (_) {
        // Client đã đóng kết nối.
      }
    });
    return fake;
  }

  Uri get uri => Uri.parse(
    'http://127.0.0.1:${_server.port}/stream?topic=/camera&type=mjpeg',
  );

  Future<void> close() => _server.close(force: true);
}

void startMultipart(HttpResponse response) {
  response.headers.set(
    'Content-Type',
    'multipart/x-mixed-replace;boundary=boundarydonotcross',
  );
  response.bufferOutput = false;
}

Future<void> sendFrames(HttpResponse response, int count) async {
  for (var i = 0; i < count; i++) {
    response.add(part(fakeJpeg([i])));
    await response.flush();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

MjpegSource newSource() => MjpegSource(
  robotId: 'r550',
  stallTimeout: const Duration(milliseconds: 300),
  minBackoff: const Duration(milliseconds: 50),
  maxBackoff: const Duration(milliseconds: 100),
  statsInterval: const Duration(milliseconds: 100),
);

Future<T> firstWhere<T extends VideoState>(MjpegSource source) => source.state
    .where((s) => s is T)
    .cast<T>()
    .first
    .timeout(const Duration(seconds: 5));

void main() {
  late FakeMjpegServer server;
  late MjpegSource source;

  setUp(() async {
    server = await FakeMjpegServer.start();
    source = newSource();
  });

  tearDown(() async {
    await source.dispose();
    await server.close();
  });

  test('nhận frame, chuyển connecting → playing, có stats', () async {
    server.handler = (response, _) async {
      startMultipart(response);
      await sendFrames(response, 1000);
    };
    final states = <VideoState>[];
    source.state.listen(states.add);
    final frames = source.frames.take(5).toList();
    final stats = source.stats
        .firstWhere((s) => s.framesTotal > 0)
        .timeout(const Duration(seconds: 5));

    await source.connect(server.uri);

    expect(await frames, hasLength(5));
    expect(states.take(2).toList(), [
      isA<VideoConnecting>(),
      isA<VideoPlaying>(),
    ]);
    expect(source.lastFrame, isNotNull);
    final s = await stats;
    expect(s.fps, greaterThan(0));
    expect(s.bitrateKbps, greaterThan(0));
  });

  test('server đóng luồng → reconnect rồi playing lại', () async {
    server.handler = (response, index) async {
      startMultipart(response);
      await sendFrames(response, index == 0 ? 2 : 1000);
      await response.close();
    };
    await source.connect(server.uri);
    await firstWhere<VideoPlaying>(source);

    final reconnecting = await firstWhere<VideoReconnecting>(source);
    expect(reconnecting.error.kind, VideoErrorKind.network);
    expect(reconnecting.attempt, 1);

    await firstWhere<VideoPlaying>(source);
    expect(server.requests, greaterThanOrEqualTo(2));
  });

  test('đứng hình quá stallTimeout → reconnect với lỗi stalled', () async {
    final hold = Completer<void>();
    addTearDown(() => hold.isCompleted ? null : hold.complete());
    server.handler = (response, index) async {
      startMultipart(response);
      await sendFrames(response, 1);
      if (index == 0) await hold.future; // giữ kết nối nhưng không gửi gì
      await sendFrames(response, 1000);
    };
    await source.connect(server.uri);

    final reconnecting = await firstWhere<VideoReconnecting>(source);
    expect(reconnecting.error.kind, VideoErrorKind.stalled);
    await firstWhere<VideoPlaying>(source);
  });

  test('HTTP 404 → failed, không thử lại', () async {
    server.handler = (response, _) async {
      response.statusCode = HttpStatus.notFound;
      await response.close();
    };
    await source.connect(server.uri);

    final failed = await firstWhere<VideoFailed>(source);
    expect(failed.error.kind, VideoErrorKind.http);
    expect(failed.error.statusCode, 404);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(server.requests, 1);
  });

  test('server không chạy → reconnecting với backoff tăng dần', () async {
    final uri = server.uri;
    await server.close();
    await source.connect(uri);

    final attempts = await source.state
        .whereType<VideoReconnecting>()
        .take(3)
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(attempts.map((s) => s.attempt), [1, 2, 3]);
    expect(attempts.map((s) => s.retryIn.inMilliseconds), [50, 100, 100]);
  });

  test('connect lại với endpoint khác thì chuyển luồng', () async {
    final other = await FakeMjpegServer.start();
    addTearDown(other.close);
    server.handler = (response, _) async {
      startMultipart(response);
      await sendFrames(response, 1000);
    };
    other.handler = (response, _) async {
      startMultipart(response);
      for (var i = 0; i < 1000; i++) {
        response.add(part(fakeJpeg([0xAA])));
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    };

    await source.connect(server.uri);
    await source.frames.first.timeout(const Duration(seconds: 5));

    await source.connect(other.uri);
    final frame = await source.frames
        .firstWhere((f) => f.length == 5 && f[2] == 0xAA)
        .timeout(const Duration(seconds: 5));
    expect(frame, fakeJpeg([0xAA]));
  });

  test('dispose → closed, connect sau đó báo lỗi', () async {
    server.handler = (response, _) async {
      startMultipart(response);
      await sendFrames(response, 1000);
    };
    await source.connect(server.uri);
    await firstWhere<VideoPlaying>(source);

    await source.dispose();
    expect(source.currentState, isA<VideoClosed>());
    expect(() => source.connect(server.uri), throwsStateError);
  });
}

extension<T> on Stream<T> {
  Stream<S> whereType<S>() => where((e) => e is S).cast<S>();
}
