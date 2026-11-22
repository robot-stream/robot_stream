import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:robot_stream_webrtc/robot_stream_webrtc.dart';

const answerSdp = 'v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n';

/// Server WHEP giả: ghi lại request, trả lời theo [handler].
class FakeWhepServer {
  FakeWhepServer._(this._server);

  final HttpServer _server;
  final requests =
      <
        ({String method, String path, Map<String, String> headers, String body})
      >[];
  late Future<void> Function(HttpRequest request) handler;

  static Future<FakeWhepServer> start() async {
    final fake = FakeWhepServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fake._server.listen((request) async {
      final headers = <String, String>{};
      request.headers.forEach((k, v) => headers[k] = v.join(','));
      final body = await utf8Body(request);
      fake.requests.add((
        method: request.method,
        path: request.uri.path,
        headers: headers,
        body: body,
      ));
      await fake.handler(request);
    });
    return fake;
  }

  static Future<String> utf8Body(HttpRequest r) =>
      r.cast<List<int>>().transform(const SystemEncoding().decoder).join();

  Uri get whep => Uri.parse('http://127.0.0.1:${_server.port}/robot_cam/whep');

  Future<void> close() => _server.close(force: true);
}

void main() {
  late FakeWhepServer server;
  late WhepSignaling signaling;

  setUp(() async {
    server = await FakeWhepServer.start();
    signaling = WhepSignaling();
  });

  tearDown(() async {
    signaling.close();
    await server.close();
  });

  test(
    '201 + SDP: trả answer, Location tương đối được resolve, gửi đúng header',
    () async {
      server.handler = (r) async {
        r.response
          ..statusCode = HttpStatus.created
          ..headers.set('Content-Type', 'application/sdp')
          ..headers.set('Location', '/robot_cam/whep/session-123')
          ..write(answerSdp);
        await r.response.close();
      };

      final answer = await signaling.offer(
        server.whep,
        'v=0 offer',
        token: 'abc',
      );

      expect(answer.sdp, answerSdp);
      expect(
        answer.session,
        server.whep.resolve('/robot_cam/whep/session-123'),
      );
      final req = server.requests.single;
      expect(req.method, 'POST');
      expect(req.headers['content-type'], startsWith('application/sdp'));
      expect(req.headers['authorization'], 'Bearer abc');
      expect(req.body, 'v=0 offer');
    },
  );

  test('404 → WhepException(404) (robot chưa có luồng)', () async {
    server.handler = (r) async {
      r.response.statusCode = HttpStatus.notFound;
      await r.response.close();
    };
    expect(
      () => signaling.offer(server.whep, 'v=0'),
      throwsA(
        isA<WhepException>().having((e) => e.statusCode, 'statusCode', 404),
      ),
    );
  });

  test('200 thay vì 201 vẫn là lỗi', () async {
    server.handler = (r) async {
      r.response
        ..statusCode = HttpStatus.ok
        ..write(answerSdp);
      await r.response.close();
    };
    expect(
      () => signaling.offer(server.whep, 'v=0'),
      throwsA(
        isA<WhepException>().having((e) => e.statusCode, 'statusCode', 200),
      ),
    );
  });

  test('201 nhưng body không phải SDP → lỗi protocol', () async {
    server.handler = (r) async {
      r.response
        ..statusCode = HttpStatus.created
        ..write('<html>proxy</html>');
      await r.response.close();
    };
    expect(
      () => signaling.offer(server.whep, 'v=0'),
      throwsA(
        isA<WhepException>().having((e) => e.statusCode, 'statusCode', isNull),
      ),
    );
  });

  test('server không trả lời → TimeoutException', () async {
    final hang = Completer<void>();
    addTearDown(() => hang.isCompleted ? null : hang.complete());
    server.handler = (r) => hang.future;
    expect(
      () => signaling.offer(
        server.whep,
        'v=0',
        timeout: const Duration(milliseconds: 200),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('delete gửi DELETE tới URL phiên, lỗi bị bỏ qua', () async {
    server.handler = (r) async {
      r.response.statusCode = HttpStatus.ok;
      await r.response.close();
    };
    await signaling.delete(
      server.whep.resolve('/robot_cam/whep/s1'),
      token: 't',
    );
    expect(server.requests.single.method, 'DELETE');
    expect(server.requests.single.path, '/robot_cam/whep/s1');
    expect(server.requests.single.headers['authorization'], 'Bearer t');

    final dead = server.whep;
    await server.close();
    await signaling.delete(dead); // không ném lỗi khi server đã tắt
  });

  test('mediamtxWhepUri', () {
    expect(
      mediamtxWhepUri(host: '192.168.1.100').toString(),
      'http://192.168.1.100:8889/robot_cam/whep',
    );
  });
}
