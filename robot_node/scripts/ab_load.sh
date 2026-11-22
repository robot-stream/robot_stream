#!/usr/bin/env bash
# A/B tải robot: xen kẽ tắt / bật stream N vòng, mỗi trạng thái đo S giây (measure_load.sh).
# Tải nền R550 dao động mạnh (CPU 67–79%, YOLO 7–11 fps khi KHÔNG stream), nên phải xen kẽ.
# Dùng (trên robot): ab_load.sh [vòng] [giây] [tham số launch...]
ROUNDS=${1:-3}
SECS=${2:-20}
shift 2 2>/dev/null
LAUNCH_ARGS="$*"
DIR=$(cd "$(dirname "$0")" && pwd)

start_stream() {
  tmux new-window -t robot_stream:0 -n stream "bash -c 'source /opt/ros/humble/setup.bash && source ~/robot_stream/ws/install/setup.bash && ros2 launch robot_stream_ros stream.launch.py $LAUNCH_ARGS 2>&1 | tee ~/robot_stream/stream.log'"
  sleep 12
}
stop_stream() {
  tmux kill-window -t robot_stream:stream 2>/dev/null
  sleep 5
}

stop_stream
for r in $(seq 1 "$ROUNDS"); do
  echo "vòng $r TẮT: $("$DIR/measure_load.sh" "$SECS")"
  start_stream
  echo "vòng $r BẬT: $("$DIR/measure_load.sh" "$SECS")"
  stop_stream
done
start_stream
echo "(đã bật lại stream)"
