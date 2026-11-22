#!/usr/bin/env bash
# Chuyển robot giữa chạy bình thường (robot-stream.service) và chế độ đo latency.
#   measure_mode.sh on   → dừng service; chạy trong tmux robot_stream: stream có mã vạch
#                          (stamp_barcode:=true), time_server :9123, www_server :8001
#                          → trên Mac: tools/run_latency.sh <nhãn>
#   measure_mode.sh off  → tắt tmux robot_stream, bật lại service (log: ~/robot_stream/stream.log)
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)

case "${1:-}" in
  on)
    systemctl --user stop robot-stream.service || true
    tmux kill-session -t robot_stream 2>/dev/null || true
    tmux new-session -d -s robot_stream -n stream "bash -c 'source /opt/ros/humble/setup.bash && source ~/robot_stream/ws/install/setup.bash && ros2 launch robot_stream_ros stream.launch.py stamp_barcode:=true 2>&1 | tee ~/robot_stream/stream.log'"
    tmux new-window -t robot_stream -n time "python3 $DIR/time_server.py 9123"
    tmux new-window -t robot_stream -n www "python3 $DIR/www_server.py 8001"
    echo "Chế độ đo: bật (tmux robot_stream)"
    ;;
  off)
    tmux kill-session -t robot_stream 2>/dev/null || true
    systemctl --user start robot-stream.service
    echo "Chế độ đo: tắt (robot-stream.service chạy lại)"
    ;;
  *)
    echo "Dùng: $0 on|off" >&2
    exit 2
    ;;
esac
