#!/usr/bin/env bash
# One-command on-robot installer for robot_stream_ros (ROS 2 Humble, amd64/arm64).
# Checks system/ROS dependencies, downloads MediaMTX (if not installed), builds
# ~/robot_stream/ws with colcon, and prints the launch & token commands.
# Does not run sudo automatically; if packages are missing it prints the exact
# `sudo apt install` command to run first.
#
# Usage (run on the robot from the cloned repository):
#   bash robot_node/scripts/install_robot.sh [--force-mediamtx]
set -euo pipefail

FORCE_MTX=0
for arg in "$@"; do
  case "$arg" in
    --force-mediamtx) FORCE_MTX=1 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

ROS_DISTRO_NAME=${ROS_DISTRO_NAME:-humble}
ROS_SETUP="/opt/ros/$ROS_DISTRO_NAME/setup.bash"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$HOME/robot_stream"

if [ ! -f "$ROS_SETUP" ]; then
  echo "Error: $ROS_SETUP not found. Install ROS 2 Humble first." >&2
  exit 1
fi

echo "== 1. Checking system & ROS 2 dependencies..."
MISSING=()

for cmd in curl colcon gst-inspect-1.0 rsync; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done

if command -v gst-inspect-1.0 >/dev/null 2>&1; then
  for plugin in x264enc rtph264pay h264parse videoconvert appsrc; do
    gst-inspect-1.0 "$plugin" >/dev/null 2>&1 || MISSING+=("gstreamer:$plugin")
  done
fi

python3 -c "import gi; gi.require_version('Gst', '1.0'); from gi.repository import Gst" >/dev/null 2>&1 || MISSING+=("python3-gi/Gst")
python3 -c "import tornado" >/dev/null 2>&1 || MISSING+=("python3-tornado")
python3 -c "import yaml" >/dev/null 2>&1 || MISSING+=("python3-yaml")

# Check rosbridge_server inside the ROS 2 environment.
if ! bash -lc "source '$ROS_SETUP' && ros2 pkg prefix rosbridge_server >/dev/null 2>&1"; then
  MISSING+=("ros-$ROS_DISTRO_NAME-rosbridge-server")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Missing dependencies: ${MISSING[*]}" >&2
  cat >&2 <<EOF

Install the required packages on Ubuntu 22.04 / ROS 2 $ROS_DISTRO_NAME first:

  sudo apt update && sudo apt install -y \\
    curl rsync python3-colcon-common-extensions \\
    ros-$ROS_DISTRO_NAME-rosbridge-server \\
    gstreamer1.0-tools gstreamer1.0-plugins-base \\
    gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly \\
    python3-gi gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0 \\
    python3-tornado python3-yaml

Then re-run:
  bash robot_node/scripts/install_robot.sh
EOF
  exit 1
fi
echo "  All dependencies present."

echo "== 2. Installing MediaMTX..."
if [ "$FORCE_MTX" = 1 ] || [ ! -x "$DEST/mediamtx/mediamtx" ]; then
  bash "$ROOT/scripts/install_mediamtx.sh"
else
  echo "  MediaMTX already installed at $DEST/mediamtx/mediamtx (pass --force-mediamtx to reinstall)."
fi

echo "== 3. Setting up colcon workspace at $DEST/ws..."
mkdir -p "$DEST/ws/src"
rsync -a --delete --exclude __pycache__ "$ROOT/robot_stream_ros/" "$DEST/ws/src/robot_stream_ros/"
rsync -a --exclude __pycache__ "$ROOT/scripts" "$ROOT/systemd" "$DEST/"

echo "== 4. Building robot_stream_ros..."
bash -lc "cd '$DEST/ws' && source '$ROS_SETUP' && PYTHONNOUSERSITE=1 colcon build --symlink-install"

cat <<EOF

Done! Start the robot_stream gateway for a standard ROS 2 + Nav2 robot:

  source $ROS_SETUP
  source $DEST/ws/install/setup.bash
  ros2 launch robot_stream_ros stream.launch.py \\
    profile:=nav2_standard \\
    source_topic:=/camera/image_raw

In another terminal, print the auto-generated bearer token for the Flutter app:

  source $ROS_SETUP
  source $DEST/ws/install/setup.bash
  ros2 run robot_stream_ros show_token
EOF
