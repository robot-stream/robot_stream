#!/usr/bin/env bash
# Robot thứ hai để thử thư viện: TurtleBot4 mô phỏng (Ignition Fortress) + Nav2 (AMCL, bản
# đồ warehouse) + rosbridge + robot_stream. Chạy trên Ubuntu 22.04 / ROS 2 Humble (VM UTM,
# arm64 – TurtleBot3/Gazebo Classic không có bản arm64). Mỗi phần một cửa sổ tmux "sim".
#
#   sim_up.sh                bật                 tmux attach -t sim   xem log (Ctrl-b n)
#   tmux kill-session -t sim tắt hết
#
# Cần: ros-humble-turtlebot4-simulator ros-humble-turtlebot4-navigation
#      ros-humble-rosbridge-server, robot_node đã deploy (deploy.sh).
set -eu
S=sim
# DISPLAY: server Gazebo cần X (GLX) để dựng ảnh camera, dù không mở cửa sổ.
ENV='export DISPLAY=${DISPLAY:-:0} && source /opt/ros/humble/setup.bash && source ~/robot_stream/ws/install/setup.bash'

tmux kill-session -t $S 2>/dev/null || true

# Gazebo + robot + Nav2 + AMCL trên bản đồ có sẵn (warehouse). rviz tắt cho nhẹ.
# Bản gốc turtlebot4_ignition.launch.py luôn mở cửa sổ Gazebo (treo trong VM không GPU) →
# sim/tb4_headless.launch.py: cùng nội dung, chỉ chạy server.
tmux new-session -d -s $S -n tb4 "bash -c '$ENV && ros2 launch ~/robot_stream/scripts/sim/tb4_headless.launch.py; read'"
tmux new-window -t $S -n rosbridge "bash -c '$ENV && ros2 launch rosbridge_server \
  rosbridge_websocket_launch.xml; read'"
tmux new-window -t $S -n stream "bash -c '$ENV && ros2 launch robot_stream_ros stream.launch.py \
  source_topic:=/oakd/rgb/preview/image_raw; read'"

# AMCL chưa biết robot ở đâu: đặt pose khởi đầu = chỗ spawn (0, 0) cạnh dock.
sleep 45
timeout 30 bash -c "$ENV && ros2 topic pub --once /initialpose geometry_msgs/msg/PoseWithCovarianceStamped \
  '{header: {frame_id: map}, pose: {pose: {orientation: {w: 1.0}}, \
  covariance: [0.25,0,0,0,0,0, 0,0.25,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0.07]}}'" >/dev/null
echo "Đã bật. Xem: tmux attach -t $S"
