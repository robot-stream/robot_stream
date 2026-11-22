"""TurtleBot4 mô phỏng KHÔNG giao diện Gazebo (chỉ server), cho VM không có GPU.

Giống turtlebot4_ignition_bringup/turtlebot4_ignition.launch.py (Humble) nhưng ign_args có `-s`
(bản gốc viết cứng --gui-config, cửa sổ Gazebo treo trong VM UTM và kéo cả mô phỏng chậm theo).

  ros2 launch tb4_headless.launch.py               # Nav2 + AMCL trên bản đồ warehouse
  ros2 launch tb4_headless.launch.py world:=maze map:=/opt/ros/humble/share/turtlebot4_navigation/maps/maze.yaml
"""

import os
from pathlib import Path

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import (DeclareLaunchArgument, IncludeLaunchDescription,
                            SetEnvironmentVariable)
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node


def generate_launch_description():
    share = get_package_share_directory
    tb4_bringup = share('turtlebot4_ignition_bringup')
    tb4_desc = share('turtlebot4_description')
    create_desc = share('irobot_create_description')
    create_bringup = share('irobot_create_ignition_bringup')
    nav = share('turtlebot4_navigation')

    args = [
        DeclareLaunchArgument('world', default_value='warehouse'),
        DeclareLaunchArgument('model', default_value='standard'),
        DeclareLaunchArgument('nav2', default_value='true'),
        DeclareLaunchArgument('localization', default_value='true'),
        DeclareLaunchArgument('slam', default_value='false'),
        DeclareLaunchArgument('rviz', default_value='false'),
        DeclareLaunchArgument('map', default_value=os.path.join(nav, 'maps', 'warehouse.yaml')),
        DeclareLaunchArgument('use_sim_time', default_value='true'),
    ]
    resource_path = SetEnvironmentVariable(
        name='IGN_GAZEBO_RESOURCE_PATH',
        value=':'.join([
            os.path.join(tb4_bringup, 'worlds'),
            os.path.join(create_bringup, 'worlds'),
            str(Path(tb4_desc).parent.resolve()),
            str(Path(create_desc).parent.resolve()),
        ]))
    gazebo = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            [PathJoinSubstitution([share('ros_ign_gazebo'), 'launch', 'ign_gazebo.launch.py'])]),
        launch_arguments=[('ign_args', [LaunchConfiguration('world'), '.sdf -r -s -v 2'])],
    )
    clock_bridge = Node(
        package='ros_gz_bridge', executable='parameter_bridge', name='clock_bridge',
        output='screen', arguments=['/clock@rosgraph_msgs/msg/Clock[ignition.msgs.Clock'])
    spawn = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            [PathJoinSubstitution([tb4_bringup, 'launch', 'turtlebot4_spawn.launch.py'])]),
        launch_arguments=[('model', LaunchConfiguration('model')),
                          ('nav2', LaunchConfiguration('nav2')),
                          ('localization', LaunchConfiguration('localization')),
                          ('slam', LaunchConfiguration('slam')),
                          ('rviz', LaunchConfiguration('rviz')),
                          ('map', LaunchConfiguration('map'))],
    )
    return LaunchDescription([*args, resource_path, gazebo, clock_bridge, spawn])
