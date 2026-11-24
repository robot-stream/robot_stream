/// Simple EN/VI localization table for the example app (no external packages).
///
/// Defaults to English (`en`). Pass `--dart-define=LANG=vi` for Vietnamese.
const defaultAppLang = String.fromEnvironment('LANG') == 'vi' ? 'vi' : 'en';

/// Active language code (`'en'` or `'vi'`). Overridable in widget tests.
String appLang = defaultAppLang;

/// Looks up [key] in the active language and replaces `{name}` placeholders.
String tr(String key, [Map<String, Object?> params = const {}]) {
  var text = _strings[appLang]?[key] ?? _strings['en']![key] ?? key;
  for (final e in params.entries) {
    text = text.replaceAll('{${e.key}}', '${e.value}');
  }
  return text;
}

/// Returns a localized label for known MJPEG camera topics, falling back to
/// [fallback].
String trTopicLabel(String topic, String fallback) {
  final key = 'mjpeg_topic:$topic';
  return _strings[appLang]?[key] ?? _strings['en']?[key] ?? fallback;
}

const _strings = <String, Map<String, String>>{
  'en': {
    // main.dart
    'app_title': 'Robot Stream',
    'no_webrtc_video': 'No WebRTC video stream yet',
    'syncing_clock': 'Syncing clock…',
    'clock_summary': 'clock offset {offset} ms, min rtt {rtt} ms',
    'measuring_progress': 'Measuring {n}/60 · {clock}',
    'latency_result_header':
        'Decode latency (lower bound, ±1 frame): {result}\n{clock}',
    'measure_error': 'Measurement error: {error}',
    'robot_ip_label': 'Robot IP',
    'robot_token_label': 'Robot token',
    'robot_token_helper': 'On robot: ros2 run robot_stream_ros show_token',
    'hide': 'Hide',
    'show': 'Show',
    'low_load_label': 'Low bandwidth (640x480, quality 50)',
    'reconnect': 'Reconnect',
    'connect': 'Connect',
    'measure_latency_btn': 'Measure latency (robot: measure_mode.sh on)',
    'video_idle': 'Disconnected',
    'video_connecting': 'Connecting…',
    'video_playing': 'Playing',
    'video_reconnecting': 'Reconnecting #{attempt} – {kind}\n{message}',
    'video_failed': 'Error: {kind}\n{message}',
    'video_closed': 'Closed',
    'err_stalled': 'stalled',
    'err_protocol': 'protocol error',
    'err_network': 'network error',
    'stats_loss': 'loss {pct}%',
    'stats_frames': '{n} frames',
    'mjpeg_topic:/camera/color/image_raw': 'Raw camera',
    'mjpeg_topic:/detected_image': 'YOLO overlay',

    // telemetry_overlay.dart
    'battery_prefix': 'bat',
    'waiting_telemetry': 'Waiting for telemetry…',
    'rosbridge_idle': 'rosbridge: disconnected',
    'rosbridge_connecting': 'rosbridge: connecting…',
    'rosbridge_connected': 'rosbridge: connected',
    'rosbridge_reconnecting': 'rosbridge: reconnecting #{attempt}',
    'rosbridge_closed': 'rosbridge: closed',

    // nav_panel.dart
    'nav_aborted_banner':
        'Robot ABORTED: could not reach goal (off map / blocked / stuck).',
    'activity_active': 'robot moving',
    'activity_canceling': 'robot canceling',
    'activity_succeeded': 'last: succeeded',
    'activity_canceled': 'last: canceled',
    'activity_aborted': 'last: ABORTED',
    'blocked_disconnected': 'rosbridge not connected',
    'deadman_missing': 'deadman_node not detected',
    'blocked_deadman': 'Deadman not armed ({state})',
    'blocked_battery_unknown': 'Battery unknown',
    'blocked_battery_low_v': 'Battery {v} V < {min} V',
    'blocked_battery_low_pct': 'Battery {pct}% < {min}%',
    'blocked_battery_unreported':
        'Robot does not report required battery metric',
    'confirm_title': 'Robot will move',
    'confirm_body':
        'Is the area around the robot clear? Are you nearby to stop or lift the robot if needed?\n\n'
        'The STOP button is always at the top.',
    'confirm_cancel': 'Not yet',
    'confirm_ok': 'Area clear, proceed',
    'waypoint_sent': 'Sent: go to "{name}"',
    'send_failed_disconnected': 'Failed to send (disconnected)',
    'no_robot_pose': 'No robot pose yet',
    'navigating_to': 'Navigating to {x}, {y} ({frame})…',
    'outcome_succeeded': 'Goal reached',
    'outcome_canceled': 'Canceled',
    'outcome_aborted': 'Robot aborted (no path / stuck)',
    'outcome_rejected': 'Robot rejected goal',
    'outcome_connection_lost': 'CONNECTION LOST — robot may still be moving!',
    'stop_sent_waiting': 'STOP sent, waiting for Nav2 confirmation…',
    'stop_failed_disconnected':
        'FAILED TO STOP: lost connection to robot. Stop manually (E-stop / power button)!',
    'stop_confirmed': 'Nav2 confirmed STOP',
    'stop_rejected': 'Nav2 REJECTED stop command',
    'stop_no_ack': 'No confirmation from Nav2',
    'stop_unconfirmed_warn':
        'Robot did not confirm stop — watch the robot and stop manually if still moving!',
    'drive_send_failed': 'Failed to send drive command (disconnected)',
    'stop_btn': 'STOP',
    'nav_mode': 'Nav mode: {mode}',
    'distance_remaining': '{dist} m remaining',
    'forward_btn': 'Forward {m} m',
    'no_waypoints': 'No waypoints received from robot yet',

    // latency_probe.dart
    'time_server_no_reply':
        'time_server :{port} did not respond — is measure_mode enabled on the robot?',
    'latency_no_frames':
        'no readable frames (barcode errors: {fail}) — is stamp_barcode enabled?',
    'latency_summary':
        '≈ {est} ms (p50) · lower p50 {lo50} / p95 {lo95} · '
        'upper p50 {hi50} · frame {frame} ms · n {n}, barcode errors {fail}',
  },
  'vi': {
    // main.dart
    'app_title': 'R550 Stream',
    'no_webrtc_video': 'Chưa có video WebRTC',
    'syncing_clock': 'Đồng bộ đồng hồ…',
    'clock_summary': 'đồng hồ lệch {offset} ms, rtt min {rtt} ms',
    'measuring_progress': 'Đang đo {n}/60 · {clock}',
    'latency_result_header':
        'Latency tới lúc decode xong (cận dưới, ±1 frame): {result}\n{clock}',
    'measure_error': 'Lỗi đo: {error}',
    'robot_ip_label': 'IP robot',
    'robot_token_label': 'Token robot',
    'robot_token_helper': 'Trên robot: ros2 run robot_stream_ros show_token',
    'hide': 'Ẩn',
    'show': 'Hiện',
    'low_load_label': 'Giảm tải (640x480, quality 50)',
    'reconnect': 'Kết nối lại',
    'connect': 'Kết nối',
    'measure_latency_btn': 'Đo latency (robot: measure_mode.sh on)',
    'video_idle': 'Chưa kết nối',
    'video_connecting': 'Đang kết nối…',
    'video_playing': 'Đang phát',
    'video_reconnecting': 'Kết nối lại #{attempt} – {kind}\n{message}',
    'video_failed': 'Lỗi: {kind}\n{message}',
    'video_closed': 'Đã đóng',
    'err_stalled': 'đứng hình',
    'err_protocol': 'sai định dạng',
    'err_network': 'mất kết nối',
    'stats_loss': 'mất {pct}%',
    'stats_frames': '{n} frame',
    'mjpeg_topic:/camera/color/image_raw': 'Ảnh gốc',
    'mjpeg_topic:/detected_image': 'Có khung YOLO',

    // telemetry_overlay.dart
    'battery_prefix': 'pin',
    'waiting_telemetry': 'Đang chờ telemetry…',
    'rosbridge_idle': 'rosbridge: chưa kết nối',
    'rosbridge_connecting': 'rosbridge: đang kết nối…',
    'rosbridge_connected': 'rosbridge: đã kết nối',
    'rosbridge_reconnecting': 'rosbridge: kết nối lại #{attempt}',
    'rosbridge_closed': 'rosbridge: đã đóng',

    // nav_panel.dart
    'nav_aborted_banner':
        'Robot BỎ CUỘC: không tới được đích (đích ngoài bản đồ / bị chặn / kẹt).',
    'activity_active': 'robot đang đi',
    'activity_canceling': 'robot đang hủy',
    'activity_succeeded': 'lần cuối: tới nơi',
    'activity_canceled': 'lần cuối: đã hủy',
    'activity_aborted': 'lần cuối: BỎ CUỘC',
    'blocked_disconnected': 'Chưa kết nối rosbridge',
    'deadman_missing': 'không thấy deadman_node',
    'blocked_deadman': 'Robot chưa bật deadman ({state})',
    'blocked_battery_unknown': 'Chưa biết pin',
    'blocked_battery_low_v': 'Pin {v} V < {min} V',
    'blocked_battery_low_pct': 'Pin {pct}% < {min}%',
    'blocked_battery_unreported': 'Robot không báo mức pin cần kiểm',
    'confirm_title': 'Robot sẽ di chuyển',
    'confirm_body':
        'Khu vực quanh robot đã trống chưa? Bạn có đứng cạnh để dừng/nhấc robot khi cần không?\n\n'
        'Nút DỪNG luôn ở trên cùng.',
    'confirm_cancel': 'Chưa',
    'confirm_ok': 'Đã trống, cho đi',
    'waypoint_sent': 'Đã gửi: đi tới "{name}"',
    'send_failed_disconnected': 'Không gửi được (mất kết nối)',
    'no_robot_pose': 'Chưa có pose robot',
    'navigating_to': 'Đi tới {x}, {y} ({frame})…',
    'outcome_succeeded': 'Đã tới đích',
    'outcome_canceled': 'Đã hủy',
    'outcome_aborted': 'Robot bỏ cuộc (không tìm được đường / kẹt)',
    'outcome_rejected': 'Robot không nhận goal',
    'outcome_connection_lost': 'MẤT KẾT NỐI – robot có thể vẫn đang đi!',
    'stop_sent_waiting': 'Đã gửi lệnh DỪNG, chờ Nav2 xác nhận…',
    'stop_failed_disconnected':
        'CHƯA DỪNG ĐƯỢC: mất kết nối tới robot. Dừng bằng tay (nhấc robot / nút nguồn)!',
    'stop_confirmed': 'Nav2 đã xác nhận DỪNG',
    'stop_rejected': 'Nav2 TỪ CHỐI lệnh dừng',
    'stop_no_ack': 'Không có xác nhận từ Nav2',
    'stop_unconfirmed_warn':
        'Robot chưa xác nhận dừng – quan sát robot, dừng bằng tay nếu nó vẫn chạy!',
    'drive_send_failed': 'Không gửi được lệnh lái (mất kết nối)',
    'stop_btn': 'DỪNG',
    'nav_mode': 'Điều hướng: {mode}',
    'distance_remaining': 'còn {dist} m',
    'forward_btn': 'Tiến {m} m',
    'no_waypoints': 'Chưa nhận danh sách điểm từ robot',

    // latency_probe.dart
    'time_server_no_reply':
        'time_server :{port} không trả lời – robot đã bật measure_mode chưa?',
    'latency_no_frames':
        'không đọc được frame nào (lỗi mã vạch {fail}) – stamp_barcode đã bật chưa?',
    'latency_summary':
        '≈ {est} ms (p50) · cận dưới p50 {lo50} / p95 {lo95} · '
        'cận trên p50 {hi50} · khung {frame} ms · n {n}, lỗi mã vạch {fail}',
  },
};
