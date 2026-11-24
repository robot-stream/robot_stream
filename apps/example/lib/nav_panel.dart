import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:robot_stream_core/robot_stream_core.dart';
import 'package:robot_stream_rosbridge/robot_stream_rosbridge.dart';

import 'strings.dart';

/// Điều hướng R550 (giai đoạn 2b) – **làm robot di chuyển thật**.
///
/// An toàn: nút DỪNG luôn bấm được và báo rõ nếu lệnh không tới robot; các lệnh đi
/// bị khóa khi mất kết nối / chưa biết pin / pin < [minBatteryV]; lệnh đi đầu tiên
/// mỗi lần mở app phải xác nhận khu vực trống.
class NavPanel extends StatefulWidget {
  const NavPanel({super.key, required this.transport, required this.profile});

  final RosbridgeTransport transport;

  /// Giới hạn pin, tốc độ lái tay của loại robot này.
  final RobotProfile profile;

  /// R550 semantic_nav từ chối đi dưới 10.3 V.

  @override
  State<NavPanel> createState() => _NavPanelState();
}

class _NavPanelState extends State<NavPanel> {
  RosbridgeTransport get t => widget.transport;

  bool _confirmed = false;
  NavHandle? _goal;
  NavProgress? _progress;
  String? _status;
  final _subs = <StreamSubscription<Object?>>[];

  @override
  void initState() {
    super.initState();
    for (final s in <Stream<Object?>>[
      t.link,
      t.battery,
      t.pose,
      t.navMode,
      t.deadman,
      t.waypoints,
    ]) {
      _subs.add(s.listen((_) => mounted ? setState(() {}) : null));
    }
    _subs.add(t.navActivity.listen(_onActivity));
  }

  /// Goal đã thấy đang chạy trong lần mở app này – để chỉ báo động khi chính goal
  /// đó bỏ cuộc, không báo lại kết quả cũ lúc vừa kết nối.
  final _seenActive = <String>{};

  void _onActivity(NavActivity a) {
    debugPrint('[nav] robot $a');
    if (!mounted) return;
    setState(() {});
    if (a.state == NavActivityState.active) _seenActive.add(a.goalId);
    if (a.state == NavActivityState.aborted && _seenActive.remove(a.goalId)) {
      _warn(tr('nav_aborted_banner'));
    }
  }

  static String _activityText(NavActivity a) => switch (a.state) {
    NavActivityState.active => tr('activity_active'),
    NavActivityState.canceling => tr('activity_canceling'),
    NavActivityState.succeeded => tr('activity_succeeded'),
    NavActivityState.canceled => tr('activity_canceled'),
    NavActivityState.aborted => tr('activity_aborted'),
  };

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  /// Lý do không cho đi, hoặc null nếu được đi.
  String? get _blocked {
    if (t.currentLink is! LinkConnected) return tr('blocked_disconnected');
    // Không có deadman thì rớt mạng giữa chừng robot vẫn đi tiếp tới đích.
    if (t.currentDeadman != 'armed') {
      return tr('blocked_deadman', {
        'state': t.currentDeadman ?? tr('deadman_missing'),
      });
    }
    final minV = widget.profile.minBatteryV;
    final minP = widget.profile.minBatteryPercent;
    if (minV == null && minP == null) return null; // robot không đặt ngưỡng pin
    final b = t.currentBattery;
    if (b == null) return tr('blocked_battery_unknown');
    final v = b.voltage, pct = b.percentage;
    if (minV != null && v != null && v < minV) {
      return tr('blocked_battery_low_v', {
        'v': v.toStringAsFixed(2),
        'min': minV,
      });
    }
    if (minP != null && pct != null && pct < minP) {
      return tr('blocked_battery_low_pct', {
        'pct': (pct * 100).round(),
        'min': (minP * 100).round(),
      });
    }
    if ((minV == null || v == null) && (minP == null || pct == null)) {
      return tr('blocked_battery_unreported');
    }
    return null;
  }

  Future<bool> _confirm() async {
    if (_confirmed) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('confirm_title')),
        content: Text(tr('confirm_body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('confirm_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('confirm_ok')),
          ),
        ],
      ),
    );
    _confirmed = ok ?? false;
    return _confirmed;
  }

  Future<void> _goWaypoint(String name) async {
    if (!await _confirm()) return;
    final sent = t.goToWaypoint(name);
    debugPrint('[nav] waypoint "$name" sent=$sent');
    setState(
      () => _status = sent
          ? tr('waypoint_sent', {'name': name})
          : tr('send_failed_disconnected'),
    );
  }

  Future<void> _goForward(double meters) async {
    final p = t.currentPose;
    if (p == null) {
      setState(() => _status = tr('no_robot_pose'));
      return;
    }
    if (!await _confirm()) return;
    final goal = NavGoal(
      x: p.x + meters * math.cos(p.yaw),
      y: p.y + meters * math.sin(p.yaw),
      yaw: p.yaw,
      frameId: p.frameId,
    );
    final h = t.navigateTo(goal);
    debugPrint('[nav] goal $goal (forward $meters m)');
    setState(() {
      _goal = h;
      _progress = null;
      _status = tr('navigating_to', {
        'x': goal.x.toStringAsFixed(2),
        'y': goal.y.toStringAsFixed(2),
        'frame': goal.frameId,
      });
    });
    h.progress.listen(
      (p) =>
          mounted && identical(_goal, h) ? setState(() => _progress = p) : null,
    );
    final outcome = await h.outcome;
    debugPrint('[nav] outcome $outcome');
    if (!mounted || !identical(_goal, h)) return;
    setState(() {
      _goal = null;
      _progress = null; // không hiện "còn x m" cũ sau khi đã xong
      _status = switch (outcome) {
        NavOutcome.succeeded => tr('outcome_succeeded'),
        NavOutcome.canceled => tr('outcome_canceled'),
        NavOutcome.aborted => tr('outcome_aborted'),
        NavOutcome.rejected => tr('outcome_rejected'),
        NavOutcome.connectionLost => tr('outcome_connection_lost'),
      };
    });
  }

  Future<void> _stop() async {
    final sent = t.stop();
    debugPrint('[nav] STOP sent=$sent (active goal: ${_goal != null})');
    setState(() => _status = sent ? tr('stop_sent_waiting') : null);
    if (!sent) {
      _warn(tr('stop_failed_disconnected'));
      return;
    }
    final ack = await t.lastStopAck;
    debugPrint('[nav] STOP ack=$ack');
    if (!mounted) return;
    setState(
      () => _status = switch (ack) {
        true => tr('stop_confirmed'),
        false => tr('stop_rejected'),
        null => tr('stop_no_ack'),
      },
    );
    if (ack != true) {
      _warn(tr('stop_unconfirmed_warn'));
    }
  }

  /// Tốc độ lái tay theo profile (robot còn tự giới hạn ở deadman_node).
  double get _driveLinear => widget.profile.driveLinear;
  double get _driveAngular => widget.profile.driveAngular;
  String? _driving;

  Future<void> _driveStart(String key, double linear, double angular) async {
    if (!_confirmed) {
      await _confirm(); // nhả nút trong lúc hộp thoại hiện → lần sau giữ lại
      return;
    }
    final sent = t.drive(linear, angular);
    debugPrint('[nav] drive $key sent=$sent');
    setState(() => _driving = sent ? key : null);
    if (!sent) _warn(tr('drive_send_failed'));
  }

  void _driveEnd() {
    if (_driving == null) return;
    t.drive(0, 0);
    debugPrint('[nav] drive release');
    setState(() => _driving = null);
  }

  Widget _driveButton(
    String key,
    IconData icon,
    double linear,
    double angular,
    bool enabled,
  ) {
    final active = _driving == key;
    return Listener(
      onPointerDown: enabled ? (_) => _driveStart(key, linear, angular) : null,
      onPointerUp: (_) => _driveEnd(),
      onPointerCancel: (_) => _driveEnd(),
      child: Container(
        width: 64,
        height: 52,
        decoration: BoxDecoration(
          color: !enabled
              ? Colors.grey.shade300
              : active
              ? Colors.orange
              : Colors.blueGrey.shade100,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 30, color: enabled ? null : Colors.grey),
      ),
    );
  }

  void _warn(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 6),
        content: Text(text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _blocked;
    final mode = t.currentNavMode;
    final progress = _progress?.distanceRemaining;
    final activity = t.currentLink is LinkConnected
        ? t.currentNavActivity
        : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(56),
                textStyle: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onPressed: _stop,
              icon: const Icon(Icons.stop_circle_outlined, size: 28),
              label: Text(tr('stop_btn')),
            ),
            const SizedBox(height: 8),
            Text(
              [
                // Chỉ robot có bộ điều hướng riêng (R550 semantic_nav) mới báo chế độ.
                if (widget.profile.topics.navModeTopic != null)
                  tr('nav_mode', {'mode': mode ?? '?'}),
                if (activity != null) _activityText(activity),
                ?blocked,
                if (progress != null)
                  tr('distance_remaining', {
                    'dist': progress.toStringAsFixed(2),
                  }),
                if (_status != null) _status!,
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final m in const [0.5, 1.0]) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: blocked == null && _goal == null
                          ? () => _goForward(m)
                          : null,
                      icon: const Icon(Icons.arrow_upward),
                      label: Text(tr('forward_btn', {'m': m})),
                    ),
                  ),
                  if (m == 0.5) const SizedBox(width: 8),
                ],
              ],
            ),
            const SizedBox(height: 8),
            // Lái tay: giữ để chạy, nhả để dừng.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _driveButton(
                  'left',
                  Icons.rotate_left,
                  0,
                  _driveAngular,
                  blocked == null,
                ),
                const SizedBox(width: 6),
                Column(
                  children: [
                    _driveButton(
                      'forward',
                      Icons.keyboard_arrow_up,
                      _driveLinear,
                      0,
                      blocked == null,
                    ),
                    const SizedBox(height: 6),
                    _driveButton(
                      'backward',
                      Icons.keyboard_arrow_down,
                      -_driveLinear,
                      0,
                      blocked == null,
                    ),
                  ],
                ),
                const SizedBox(width: 6),
                _driveButton(
                  'right',
                  Icons.rotate_right,
                  0,
                  -_driveAngular,
                  blocked == null,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                // Danh sách lấy từ robot (waypoints_node), không chép cứng.
                if (t.currentWaypoints == null)
                  Text(
                    tr('no_waypoints'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                for (final w in t.currentWaypoints ?? const <NamedWaypoint>[])
                  Tooltip(
                    message:
                        '(${w.x.toStringAsFixed(2)}, ${w.y.toStringAsFixed(2)})',
                    child: ActionChip(
                      label: Text(w.name),
                      onPressed: blocked == null
                          ? () => _goWaypoint(w.name)
                          : null,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
