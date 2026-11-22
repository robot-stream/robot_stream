#!/usr/bin/env bash
# Kiểm hồi quy sau mỗi lần sửa: thư viện vẫn chạy với CẢ robot mô phỏng lẫn R550.
#
#   tools/check_all.sh                 tất cả (bỏ qua máy nào không kết nối được)
#   tools/check_all.sh static          chỉ analyze + test (không cần robot)
#   tools/check_all.sh sim             TurtleBot3 mô phỏng trong VM (tự động hết, robot giả)
#   tools/check_all.sh r550            R550 chỉ đọc + in danh sách thử tay
#   DEPLOY=1 tools/check_all.sh ...    chép robot_node lên VM / R550 trước khi kiểm
#
# Biến: SIM_HOST (ubuntu@192.168.1.101), R550_SSH (r550), R550_IP (192.168.1.100).
# Phần R550 KHÔNG làm robot chạy; phần sim làm robot GIẢ chạy (nav_check.dart).
# Token lấy qua ssh (~/.config/robot_stream/token); app / ví dụ đi qua cổng gác :9091.
# Bài deadman trong nav_check có một app "chỉ xem" mở song song: robot vẫn phải dừng khi
# app đang lái mất kết nối (plan #9 – deadman theo phiên điều khiển).
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
WHAT=${1:-all}
SIM_HOST=${SIM_HOST:-ubuntu@192.168.1.101}
SIM_IP=${SIM_HOST#*@}
R550_SSH=${R550_SSH:-r550}
R550_IP=${R550_IP:-192.168.1.100}
DEPLOY=${DEPLOY:-0}
SSH="ssh -o ConnectTimeout=8 -o BatchMode=yes"

RESULTS=()
ok()   { RESULTS+=("OK    $1"); echo "  ✅ $1"; }
fail() { RESULTS+=("LỖI   $1"); echo "  ❌ $1"; }
skip() { RESULTS+=("BỎ QUA $1"); echo "  ⏭  $1"; }
http_code() { curl -s -o /dev/null -w '%{http_code}' -m 4 "$@"; }
# Bảo mật cơ bản: thiếu / sai token phải bị từ chối (401) ở cổng gác rosbridge và WHEP.
WS_KEY=$(printf 'the sample nonce' | base64)
WS_HDR=(-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $WS_KEY")
security_checks() { # security_checks <tên> <ip> <token>
  local n=$1 ip=$2 tok=$3
  [ "$(http_code "${WS_HDR[@]}" "http://$ip:9091/")" = 401 ] && ok "$n: cổng gác 9091 từ chối khi thiếu token" || fail "$n: cổng gác 9091 không đòi token"
  [ "$(http_code "${WS_HDR[@]}" -H 'Authorization: Bearer sai' "http://$ip:9091/")" = 401 ] && ok "$n: cổng gác 9091 từ chối token sai" || fail "$n: cổng gác 9091 nhận token sai"
  [ "$(http_code "${WS_HDR[@]}" -H "Authorization: Bearer $tok" "http://$ip:9091/")" = 101 ] && ok "$n: cổng gác 9091 nhận token đúng" || fail "$n: cổng gác 9091 từ chối token đúng"
  local whep="http://$ip:8889/robot_cam/whep" sdp=(-X POST -H 'Content-Type: application/sdp' --data v=0)
  [ "$(http_code "${sdp[@]}" "$whep")" = 401 ] && ok "$n: WHEP từ chối khi thiếu token" || fail "$n: WHEP không đòi token"
  # 400 = đã qua xác thực, chỉ SDP giả bị từ chối
  [ "$(http_code "${sdp[@]}" -H "Authorization: Bearer robot_stream:$tok" "$whep")" = 400 ] && ok "$n: WHEP nhận token đúng" || fail "$n: WHEP từ chối token đúng"
}

run()  { # run "tên" lệnh...  → OK/LỖI theo mã thoát, giữ log khi lỗi
  local name=$1; shift
  local log; log=$(mktemp)
  if "$@" >"$log" 2>&1; then ok "$name"; else fail "$name"; tail -15 "$log" | sed 's/^/      /'; fi
  rm -f "$log"
}

static_checks() {
  echo "== Không cần robot: analyze + test"
  run "dart analyze (melos)" dart run melos analyze
  run "dart test (melos)" dart run melos test
  for t in robot_node/robot_stream_ros/test/test_*.py; do
    run "python $(basename "$t")" env -C robot_node/robot_stream_ros PYTHONPATH=. python3 "test/$(basename "$t")"
  done
}

deploy() { # deploy <ssh-host>
  run "deploy robot_node → $1" "$ROOT/robot_node/scripts/deploy.sh" "$1"
}

sim_checks() {
  echo "== Robot mô phỏng: TurtleBot3 trong VM ($SIM_IP)"
  if ! $SSH "$SIM_HOST" true 2>/dev/null; then skip "sim: không ssh được $SIM_HOST (VM chưa bật?)"; return; fi
  if [ "$DEPLOY" = 1 ]; then
    deploy "$SIM_HOST"
    rsync -a "$ROOT/robot_node/scripts/" "$SIM_HOST:robot_stream/scripts/"
  fi
  # Bật lại sim cho sạch (goal cũ, pose cũ), chờ Nav2 sẵn sàng.
  $SSH "$SIM_HOST" 'bash ~/robot_stream/scripts/sim_tb3_up.sh' >/dev/null 2>&1
  if $SSH "$SIM_HOST" 'for i in $(seq 1 45); do tmux capture-pane -p -t tb3:nav2 -S -2000 | grep -q "Managed nodes are active" && exit 0; sleep 2; done; exit 1'; then
    ok "sim: Nav2 sẵn sàng"
  else
    fail "sim: Nav2 không lên sau 90 s"; return
  fi
  local tok; tok=$($SSH "$SIM_HOST" 'cat ~/.config/robot_stream/token')
  security_checks sim "$SIM_IP" "$tok"
  run "sim: rosbridge 9090 chỉ nghe localhost" $SSH "$SIM_HOST" 'ss -tln | grep -q "127.0.0.1:9090 " && ! ss -tln | grep -E "(0.0.0.0|\*|\[::\]):9090 " -q'
  run "sim: stream_node QoS tự chọn" $SSH "$SIM_HOST" 'tmux capture-pane -p -J -t tb3:stream -S -500 | grep -q "QoS camera: best_effort"'
  run "sim: MediaMTX sẵn sàng" $SSH "$SIM_HOST" 'curl -s -m 3 http://127.0.0.1:9997/v3/paths/get/robot_cam | grep -q "\"ready\":true"'
  run "sim: health_check (chỉ đọc)" env -C packages/robot_stream_rosbridge ROBOT_TOKEN="$tok" dart run example/health_check.dart "$SIM_IP" nav2 6
  run "sim: nav_check (waypoint · DỪNG · lái tay · deadman)" env -C packages/robot_stream_rosbridge ROBOT_TOKEN="$tok" timeout 300 dart run example/nav_check.dart "$SIM_IP" nav2 giữa
  run "sim: audit log ghi goal + lái tay" $SSH "$SIM_HOST" 'tail -200 ~/robot_stream/audit.log | grep -q "\"action_goal\"" && tail -200 ~/robot_stream/audit.log | grep -q "\"teleop_end\""' 
}

r550_checks() {
  echo "== R550 ($R550_IP) – chỉ đọc, robot KHÔNG chạy"
  if ! $SSH "$R550_SSH" true 2>/dev/null; then skip "r550: không ssh được (robot tắt?)"; return; fi
  if [ "$DEPLOY" = 1 ]; then
    deploy "$R550_SSH"
    $SSH "$R550_SSH" 'systemctl --user restart robot-stream'
    sleep 35
  fi
  run "r550: dịch vụ robot-stream chạy" $SSH "$R550_SSH" 'systemctl --user is-active robot-stream'
  run "r550: MediaMTX theo hồ sơ (wlP1p1s0)" $SSH "$R550_SSH" 'P=$(pgrep -f "robot_stream/mediamtx/mediamtx " | head -1); tr "\0" "\n" < /proc/$P/environ | grep -q "MTX_WEBRTCIPSFROMINTERFACESLIST=wlP1p1s0"'
  run "r550: MediaMTX sẵn sàng" $SSH "$R550_SSH" 'curl -s -m 3 http://127.0.0.1:9997/v3/paths/get/robot_cam | grep -q "\"ready\":true"'
  run "r550: stream_node QoS reliable (Astra)" $SSH "$R550_SSH" 'tail -c 300000 ~/robot_stream/stream.log | grep -a "QoS camera" | tail -1 | grep -q reliable'
  # camera_info: message nhỏ, cùng nhịp với ảnh (ros2 topic hz không theo kịp ảnh 900 KB).
  run "r550: camera ≥ 20 fps" $SSH "$R550_SSH" 'source /opt/ros/humble/setup.bash; timeout 10 ros2 topic hz /camera/color/camera_info 2>&1 | grep "average rate" | tail -1 | awk "{exit !(\$3 >= 20)}"'
  # Ngay sau khởi động lại slam còn đang khớp → đo lại tối đa ~30 s.
  run "r550: định vị khớp bản đồ ≥ 70%" $SSH "$R550_SSH" "source /opt/ros/humble/setup.bash; for i in 1 2 3; do timeout 10 python3 ~/robot_stream/tools/align_watch.py ${R550_MAP:-~/robot_stream/maps/map.pgm} ${R550_MAP_ORIGIN:-0.0 0.0} 2>&1 | grep khớp | tail -1 | awk '{exit !(\$2+0 >= 70)}' && exit 0; done; exit 1"
  local tok; tok=$($SSH "$R550_SSH" 'cat ~/.config/robot_stream/token')
  security_checks r550 "$R550_IP" "$tok"
  run "r550: health_check (chỉ đọc)" env -C packages/robot_stream_rosbridge ROBOT_TOKEN="$tok" dart run example/health_check.dart "$R550_IP" r550 6
  cat <<'EOF'

  Lưu ý: rosbridge 9090 của AIUI vẫn mở ra LAN, không token (đóng: bản Pro).
  Thử tay trên R550 (người đứng cạnh robot, app Samsung mặc định PROFILE=r550):
    [ ] App đã nhập token (show_token) – sai token thì góc trên phải báo "Robot từ chối"
    [ ] Video WebRTC ~30 fps, pose + pin hiện góc trên phải
    [ ] Bấm 1 waypoint gần → "lần cuối: tới nơi"
    [ ] Bấm waypoint xa, đang đi bấm DỪNG → robot dừng, "Nav2 đã xác nhận DỪNG"
    [ ] Giữ ▲ 1 s rồi nhả → robot đi ~20 cm và dừng ngay
    [ ] (deadman) Đang giữ ▲ thì tắt Wifi điện thoại → robot dừng < 1 s
EOF
}

case $WHAT in
  static) static_checks ;;
  sim) sim_checks ;;
  r550) r550_checks ;;
  all) static_checks; sim_checks; r550_checks ;;
  *) echo "Dùng: $0 [all|static|sim|r550]"; exit 2 ;;
esac

echo; echo "== Tổng kết"
printf '  %s\n' "${RESULTS[@]}"
printf '%s\n' "${RESULTS[@]}" | grep -q '^LỖI' && exit 1 || exit 0
