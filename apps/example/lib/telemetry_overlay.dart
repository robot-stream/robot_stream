import 'package:flutter/material.dart';
import 'package:robot_stream_core/robot_stream_core.dart';

/// Pose, pin, trạng thái kênh telemetry chồng lên video.
class TelemetryOverlay extends StatelessWidget {
  const TelemetryOverlay({super.key, required this.transport});

  final RobotTransport transport;

  /// Màu pin: theo phần trăm nếu robot báo, không thì theo điện áp (ngưỡng R550 3S:
  /// semantic_nav từ chối đi dưới 10.3 V, STM32 từng câm ~10.5 V).
  static Color batteryColor(BatteryState b) {
    final p = b.percentage, v = b.voltage;
    final level = p != null
        ? (p < 0.15 ? 0 : (p < 0.3 ? 1 : 2))
        : v != null
        ? (v < 10.5 ? 0 : (v < 11.0 ? 1 : 2))
        : 2;
    return [Colors.red, Colors.orange, Colors.green][level];
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<LinkState>(
      stream: transport.link,
      initialData: transport.currentLink,
      builder: (context, link) {
        final connected = link.data is LinkConnected;
        return StreamBuilder<RobotPose>(
          stream: transport.pose,
          initialData: transport.currentPose,
          builder: (context, pose) => StreamBuilder<BatteryState>(
            stream: transport.battery,
            initialData: transport.currentBattery,
            builder: (context, battery) {
              final p = pose.data, b = battery.data;
              final lines = [
                if (!connected) _linkText(link.data!),
                if (p != null)
                  'x ${p.x.toStringAsFixed(2)} · y ${p.y.toStringAsFixed(2)} · '
                      '${p.yawDegrees.toStringAsFixed(0)}° · ${p.frameId}',
                if (b != null)
                  [
                    'pin',
                    if (b.voltage != null) '${b.voltage!.toStringAsFixed(2)} V',
                    if (b.percentage != null)
                      '${(b.percentage! * 100).round()}%',
                  ].join(' '),
              ];
              if (lines.isEmpty) lines.add('Đang chờ telemetry…');
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.circle,
                        size: 8,
                        color: !connected
                            ? Colors.orange
                            : b == null
                            ? Colors.grey
                            : batteryColor(b),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          lines.join('\n'),
                          textAlign: TextAlign.right,
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
            },
          ),
        );
      },
    );
  }

  static String _linkText(LinkState s) => switch (s) {
    LinkIdle() => 'rosbridge: chưa kết nối',
    LinkConnecting() => 'rosbridge: đang kết nối…',
    LinkConnected() => 'rosbridge: đã kết nối',
    LinkReconnecting(:final attempt) => 'rosbridge: kết nối lại #$attempt',
    LinkRejected(:final reason) => 'rosbridge: $reason',
    LinkClosed() => 'rosbridge: đã đóng',
  };
}
