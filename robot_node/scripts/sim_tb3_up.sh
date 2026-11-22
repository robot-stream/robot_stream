#!/usr/bin/env bash
# Robot thứ hai để thử thư viện, bản nhẹ: TurtleBot3 burger "fake" (turtlebot3_fake_node – không
# vật lý) + sim/fake_sensors.py (lidar dò tia trên bản đồ, pin BatteryState, camera hình mẫu)
# + Nav2/AMCL thật trên bản đồ turtlebot3_world + rosbridge + robot_stream.
# Chạy được trong VM arm64 không GPU (Gazebo/TurtleBot4 quá nặng – xem sim_up.sh).
#
#   sim_tb3_up.sh                bật          tmux attach -t tb3   xem log (Ctrl-b n)
#   tmux kill-session -t tb3     tắt hết
#
# Cần: ros-humble-turtlebot3-fake-node ros-humble-turtlebot3-navigation2
#      ros-humble-turtlebot3-bringup ros-humble-nav2-bringup ros-humble-rosbridge-server,
#      robot_node đã deploy (deploy.sh).
set -eu
S=tb3
ENV='source /opt/ros/humble/setup.bash && source ~/robot_stream/ws/install/setup.bash && export TURTLEBOT3_MODEL=burger'
MAP=/opt/ros/humble/share/nav2_bringup/maps/turtlebot3_world.yaml
PARAMS=/opt/ros/humble/share/nav2_bringup/params/nav2_params.yaml
START="-2.0 -0.5 0.0"   # chỗ robot đứng trên bản đồ lúc bật

tmux kill-session -t $S 2>/dev/null || true
tmux new-session -d -s $S -n fake "bash -c '$ENV && ros2 launch ~/robot_stream/scripts/sim/tb3_fake.launch.py; read'"
tmux new-window -t $S -n sensors "bash -c '$ENV && python3 ~/robot_stream/scripts/sim/fake_sensors.py --map $MAP --start $START; read'"
tmux new-window -t $S -n nav2 "bash -c '$ENV && ros2 launch nav2_bringup bringup_launch.py use_sim_time:=False map:=$MAP params_file:=$PARAMS; read'"
# rosbridge: stream.launch.py (hồ sơ nav2_standard, start_rosbridge) tự bật, chỉ nghe
# 127.0.0.1:9090; app vào qua cổng gác :9091 có token.
# Danh sách điểm cho app (waypoints_node đọc file này theo hồ sơ nav2_standard).
[ -f ~/robot_stream/waypoints.yaml ] || cp ~/robot_stream/scripts/sim/tb3_world_waypoints.yaml ~/robot_stream/waypoints.yaml
tmux new-window -t $S -n stream "bash -c '$ENV && ros2 launch robot_stream_ros stream.launch.py profile:=nav2_standard; read'"

# AMCL chưa biết robot ở đâu → đặt đúng chỗ xuất phát.
sleep 20
timeout 30 bash -c "$ENV && ros2 topic pub --once /initialpose geometry_msgs/msg/PoseWithCovarianceStamped \
  '{header: {frame_id: map}, pose: {pose: {position: {x: -2.0, y: -0.5}, orientation: {w: 1.0}}, \
  covariance: [0.1,0,0,0,0,0, 0,0.1,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0.05]}}'" >/dev/null || true
echo "Đã bật. Xem: tmux attach -t $S"
