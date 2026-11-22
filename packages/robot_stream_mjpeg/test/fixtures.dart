import 'dart:convert';
import 'dart:typed_data';

/// JPEG giả: SOI + payload + EOI.
Uint8List fakeJpeg(List<int> payload) =>
    Uint8List.fromList([0xFF, 0xD8, ...payload, 0xFF, 0xD9]);

/// Một phần multipart giống web_video_server.
List<int> part(Uint8List jpeg) => [
  ...ascii.encode(
    '--boundarydonotcross\r\n'
    'Content-type: image/jpeg\r\n'
    'Content-Length: ${jpeg.length}\r\n'
    'X-Timestamp: 1730000000.000000\r\n\r\n',
  ),
  ...jpeg,
  ...ascii.encode('\r\n'),
];
