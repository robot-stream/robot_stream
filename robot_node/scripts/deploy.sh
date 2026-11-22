#!/usr/bin/env bash
# Chạy trên Mac: chép robot_node lên robot rồi build.
#   robot_stream_ros → ~/robot_stream/ws/src/   (colcon build --symlink-install)
#   scripts, systemd → ~/robot_stream/
# Dùng: robot_node/scripts/deploy.sh [host ssh]   (mặc định r550)
# Đổi file Python / launch / config: chỉ cần restart service, không cần build lại (symlink).
set -eu
HOST=${1:-r550}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

ssh "$HOST" 'mkdir -p ~/robot_stream/ws/src'
rsync -a --delete --exclude __pycache__ "$ROOT/robot_stream_ros" "$HOST":robot_stream/ws/src/
rsync -a --exclude __pycache__ "$ROOT/scripts" "$ROOT/systemd" "$HOST":robot_stream/
ssh "$HOST" 'bash -lc "cd ~/robot_stream/ws && source /opt/ros/humble/setup.bash && PYTHONNOUSERSITE=1 colcon build --symlink-install 2>&1 | tail -1"'
echo "Xong. Áp dụng: ssh $HOST 'systemctl --user restart robot-stream'"
