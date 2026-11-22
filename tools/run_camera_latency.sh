#!/usr/bin/env bash
# Đo trễ camera + USB + driver trên R550 bằng màn hình nháy đen/trắng (tools/flash.html).
# Cần trên robot: robot_node/scripts/measure_mode.sh on (www_server :8001, time_server :9123).
#
#   tools/run_camera_latency.sh phone [giây]  (mặc định) mở http://<robot>:8001/flash.html
#        trên điện thoại, chạm để bắt đầu, đưa màn hình sát camera. Trang tự đồng bộ đồng hồ
#        với robot qua HTTP.
#   tools/run_camera_latency.sh mac [giây]    mở trang trên Mac (Cmd+Ctrl+F), đồng hồ Mac↔robot
#        đo bằng UDP.
set -eu
MODE=${1:-phone}
SECS=${2:-40}
IP=${ROBOT_IP:-192.168.1.100}
DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
# Điện thoại: chờ người dùng mở link (tối đa ~2 phút) + thời gian đo.
PROBE_SECS=$([ "$MODE" = phone ] && echo $((SECS + 150)) || echo $((SECS + 90)))

rsync -a "$DIR/flash.html" r550:robot_stream/www/
rsync -a "$DIR/../robot_node/scripts/brightness_probe.py" "$DIR/../robot_node/scripts/www_server.py" r550:robot_stream/scripts/
# www_server mới có GET /time: khởi động lại cửa sổ www của chế độ đo.
ssh r550 'rm -f ~/robot_stream/www/results.jsonl; tmux kill-window -t robot_stream:www 2>/dev/null; tmux new-window -t robot_stream -n www "python3 ~/robot_stream/scripts/www_server.py 8001"'
OFF=0
if [ "$MODE" = mac ]; then
  OFF=$(python3 -I "$DIR/clock_offset.py" $IP | sed -E 's/offset_ms=([-0-9.]+).*/\1/')
fi

ssh r550 "bash -lc 'source /opt/ros/humble/setup.bash; python3 ~/robot_stream/scripts/brightness_probe.py $PROBE_SECS /camera/color/image_raw /tmp/brightness.csv'" > "$TMP/probe.log" 2>&1 &
PROBE=$!
sleep 2
if [ "$MODE" = mac ]; then
  open -a "Google Chrome" "http://$IP:8001/flash.html?seconds=$SECS"
else
  echo ">>> Trên điện thoại (cùng Wifi) mở: http://$IP:8001/flash.html?seconds=$SECS"
  echo ">>> Chạm màn hình, đưa sát camera robot, giữ yên tới khi hiện \"Xong\"."
fi
until ssh r550 'test -s ~/robot_stream/www/results.jsonl' 2>/dev/null; do
  kill -0 $PROBE 2>/dev/null || { echo "Hết giờ ghi độ sáng mà chưa có kết quả nháy"; exit 1; }
  sleep 3
done
echo "Đã nhận kết quả nháy, chờ robot ghi xong độ sáng (~$PROBE_SECS s kể từ lúc bắt đầu)…"
wait $PROBE

ssh r550 'cat ~/robot_stream/www/results.jsonl' | python3 -c 'import sys, json; print(json.dumps(json.loads(sys.stdin.readline())["data"]))' > "$TMP/flashes.json"
scp -q r550:/tmp/brightness.csv "$TMP/brightness.csv"
echo "== $(tail -1 "$TMP/probe.log") · $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("đồng bộ rtt %.1f ms" % d.get("sync_rtt_ms", -1))' "$TMP/flashes.json")"
python3 -I "$DIR/camera_latency.py" "$TMP/flashes.json" "$TMP/brightness.csv" "$OFF"
rm -rf "$TMP"
