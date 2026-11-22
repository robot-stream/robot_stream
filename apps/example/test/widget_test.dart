import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:robot_stream_example/main.dart';

void main() {
  testWidgets('màn hình camera (MJPEG) hiển thị trạng thái chưa kết nối', (
    tester,
  ) async {
    // Kích thước điện thoại (360x800 dp) thay cho mặc định 800x600.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // MJPEG: RTCVideoRenderer của WebRTC cần plugin native, không chạy trong widget test.
    await tester.pumpWidget(
      const RobotStreamApp(
        autoConnect: false,
        initialTransport: Transport.mjpeg,
      ),
    );

    expect(find.text('Chưa kết nối'), findsOneWidget);
    expect(find.text('Kết nối'), findsOneWidget);
    expect(find.text('WebRTC'), findsOneWidget);
    expect(
      find.textContaining('topic=/camera/color/image_raw'),
      findsOneWidget,
    );

    await tester.tap(find.text('Có khung YOLO'));
    await tester.pump();
    expect(find.textContaining('topic=/detected_image'), findsOneWidget);

    // Gỡ widget để MjpegSource được dispose, không còn timer chạy.
    await tester.pumpWidget(const SizedBox());
  });
}
