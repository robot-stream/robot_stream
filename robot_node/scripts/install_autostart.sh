#!/usr/bin/env bash
# Cài robot-stream thành systemd user service (không cần sudo) và bật ngay.
# Chạy trên robot sau khi đã colcon build ~/robot_stream/ws.
# Gỡ: systemctl --user disable --now robot-stream && rm ~/.config/systemd/user/robot-stream.service
set -eu
DIR=$(cd "$(dirname "$0")/.." && pwd)
UNIT_DIR=~/.config/systemd/user

mkdir -p "$UNIT_DIR"
cp "$DIR/systemd/robot-stream.service" "$UNIT_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now robot-stream.service
systemctl --user --no-pager status robot-stream.service | head -5
