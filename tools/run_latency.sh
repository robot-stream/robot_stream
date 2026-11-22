#!/usr/bin/env bash
# Đo latency tự động MJPEG + WebRTC cùng lúc trên R550.
# Cần trên robot: stream.launch.py stamp_barcode:=true, time_server.py :9123, www_server.py :8001.
# Dùng: tools/run_latency.sh <nhãn> [giây] [query thêm cho trang, vd "&jb=0"]
set -eu
LABEL=${1:?nhãn}
SECS=${2:-40}
EXTRA=${3:-}
IP=${ROBOT_IP:-192.168.1.100}
DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)

ssh r550 'rm -f ~/robot_stream/www/results.jsonl'
BEFORE=$(python3 -I "$DIR/clock_offset.py" $IP)
OFF=$(echo "$BEFORE" | sed -E 's/offset_ms=([-0-9.]+).*/\1/')

python3 -I "$DIR/mjpeg_latency.py" $IP "$OFF" "$SECS" > "$TMP/mjpeg.txt" 2>&1 &
open -a "Google Chrome" "http://$IP:8001/latency_auto.html?offset=$OFF&seconds=$SECS&label=$LABEL$EXTRA"
for _ in $(seq 1 $((SECS + 30))); do
  sleep 1
  ssh r550 'test -s ~/robot_stream/www/results.jsonl' && break
done
wait
AFTER=$(python3 -I "$DIR/clock_offset.py" $IP)

echo "== $LABEL  (đồng hồ trước: $BEFORE | sau: $AFTER)"
cat "$TMP/mjpeg.txt"
ssh r550 'cat ~/robot_stream/www/results.jsonl' | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())["data"]
if "error" in d:
    sys.exit("WebRTC lỗi: " + d["error"])
for k in ("receive_ms", "display_ms"):
    print(("WebRTC %-10s " % k) + "p50=%(p50)s p95=%(p95)s min=%(min)s n=%(n)s" % d[k])
print("jitter buffer %(jitter_buffer_ms)s ms · đọc mã vạch lỗi %(decode_fail)s/%(frames_seen)s" % d)
'
rm -rf "$TMP"
