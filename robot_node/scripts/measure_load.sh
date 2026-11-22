#!/usr/bin/env bash
# Đo tải robot trong N giây: CPU trung bình (mọi nhân), GPU, RAM, và FPS của YOLO.
# Dùng: measure_load.sh [giây] [topic_yolo]
# Không dùng set -u: setup.bash của ROS dùng biến chưa khai báo.
SECS=${1:-15}
TOPIC=${2:-/detections}
source /opt/ros/humble/setup.bash
source ~/wheeltec_ros2/install/setup.bash 2>/dev/null

LOG=$(mktemp)
tegrastats --interval 1000 > "$LOG" &
TS=$!
HZ=$(timeout "$SECS" ros2 topic hz "$TOPIC" 2>/dev/null | grep "average rate" | tail -1 | awk '{print $3}')
kill $TS 2>/dev/null; wait $TS 2>/dev/null

# CPU [a%@f,b%@f,...] → trung bình các nhân; GR3D_FREQ x% → GPU.
awk '
  match($0, /CPU \[[^]]*\]/) {
    s = substr($0, RSTART + 5, RLENGTH - 6); n = split(s, c, ",")
    t = 0; for (i = 1; i <= n; i++) { split(c[i], p, "%"); t += p[1] }
    cpu += t / n; k++
  }
  match($0, /GR3D_FREQ [0-9]+%/) { split(substr($0, RSTART + 10), g, "%"); gpu += g[1] }
  match($0, /RAM [0-9]+\/[0-9]+MB/) { split(substr($0, RSTART + 4), r, "/"); ram = r[1] }
  END { if (k) printf "CPU %.0f%%  GPU %.0f%%  RAM %d MB", cpu / k, gpu / k, ram }
' "$LOG"
echo "  YOLO ${HZ:-?} fps (${TOPIC})"
rm -f "$LOG"
