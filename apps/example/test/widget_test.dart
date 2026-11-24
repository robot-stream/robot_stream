import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:robot_stream_example/main.dart';
import 'package:robot_stream_example/strings.dart';

void main() {
  tearDown(() => appLang = defaultAppLang);

  testWidgets('camera screen (MJPEG) defaults to English disconnected state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const RobotStreamApp(
        autoConnect: false,
        initialTransport: Transport.mjpeg,
      ),
    );

    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('WebRTC'), findsOneWidget);
    expect(
      find.textContaining('topic=/camera/color/image_raw'),
      findsOneWidget,
    );

    await tester.tap(find.text('YOLO overlay'));
    await tester.pump();
    expect(find.textContaining('topic=/detected_image'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('STOP'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('STOP'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('camera screen supports Vietnamese when appLang is vi', (
    tester,
  ) async {
    appLang = 'vi';
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const RobotStreamApp(
        autoConnect: false,
        initialTransport: Transport.mjpeg,
      ),
    );

    expect(find.text('Chưa kết nối'), findsOneWidget);
    expect(find.text('Kết nối'), findsOneWidget);

    await tester.tap(find.text('Có khung YOLO'));
    await tester.pump();
    expect(find.textContaining('topic=/detected_image'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('DỪNG'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('DỪNG'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
