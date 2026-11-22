import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:robot_stream_mjpeg/robot_stream_mjpeg.dart';

import 'fixtures.dart';

void main() {
  group('MjpegScanner', () {
    test('tách nhiều ảnh trong cùng một chunk', () {
      final a = fakeJpeg([1, 2, 3]);
      final b = fakeJpeg([4, 5]);
      final frames = MjpegScanner().add([...part(a), ...part(b)]);
      expect(frames, [a, b]);
    });

    test('ghép ảnh bị cắt ở mọi vị trí, kể cả giữa FF và D8/D9', () {
      final a = fakeJpeg([0xFF, 0x00, 7, 8, 9]);
      final b = fakeJpeg([10, 11]);
      final stream = [...part(a), ...part(b)];
      for (var cut = 1; cut < stream.length; cut++) {
        final scanner = MjpegScanner();
        final frames = [
          ...scanner.add(stream.sublist(0, cut)),
          ...scanner.add(stream.sublist(cut)),
        ];
        expect(frames, [a, b], reason: 'cắt tại $cut');
      }
    });

    test('nhận từng byte một', () {
      final a = fakeJpeg(List.generate(100, (i) => i));
      final scanner = MjpegScanner();
      final frames = [
        for (final byte in part(a)) ...scanner.add([byte]),
      ];
      expect(frames, [a]);
    });

    test('bỏ qua rác không phải JPEG', () {
      final scanner = MjpegScanner();
      expect(scanner.add(ascii.encode('HTTP junk without frames')), isEmpty);
      final a = fakeJpeg([1]);
      expect(scanner.add(part(a)), [a]);
    });

    test('báo lỗi khi ảnh vượt maxFrameBytes', () {
      final scanner = MjpegScanner(maxFrameBytes: 16);
      expect(
        () => scanner.add([0xFF, 0xD8, ...List.filled(32, 1)]),
        throwsFormatException,
      );
    });
  });

  test('MjpegFrameDecoder chuyển luồng byte thành luồng ảnh', () async {
    final a = fakeJpeg([1]);
    final b = fakeJpeg([2]);
    final bytes = [...part(a), ...part(b)];
    final frames = await Stream.fromIterable([
      bytes.sublist(0, 10),
      bytes.sublist(10),
    ]).transform(const MjpegFrameDecoder()).toList();
    expect(frames, [a, b]);
  });

  test('webVideoServerUri dựng đúng URL của web_video_server', () {
    final uri = webVideoServerUri(
      host: '192.168.1.50',
      topic: '/detected_image',
      quality: 50,
      width: 640,
      height: 480,
    );
    expect(
      uri.toString(),
      'http://192.168.1.50:8080/stream?topic=/detected_image&type=mjpeg'
      '&quality=50&width=640&height=480',
    );
  });
}
