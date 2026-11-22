"""TurtleBot3 fake node + robot_state_publisher, không rviz.

Bản gốc turtlebot3_fake_node.launch.py lấy URDF từ turtlebot3_gazebo (không có bản arm64) và
luôn mở rviz → dùng URDF của turtlebot3_description (cùng mô hình).

  TURTLEBOT3_MODEL=burger ros2 launch tb3_fake.launch.py
"""

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.substitutions import Command
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue


def generate_launch_description():
    model = os.environ.get('TURTLEBOT3_MODEL', 'burger')
    params = os.path.join(get_package_share_directory('turtlebot3_fake_node'), 'param',
                          f'{model}.yaml')
    urdf = os.path.join(get_package_share_directory('turtlebot3_description'), 'urdf',
                        f'turtlebot3_{model}.urdf')
    # File .urdf thật ra là xacro (link tên ${namespace}base_link) → phải qua xacro.
    robot_description = ParameterValue(Command(['xacro ', urdf, ' namespace:=']), value_type=str)
    return LaunchDescription([
        Node(package='turtlebot3_fake_node', executable='turtlebot3_fake_node',
             parameters=[params], output='screen'),
        Node(package='robot_state_publisher', executable='robot_state_publisher',
             parameters=[{'robot_description': robot_description}], output='screen'),
    ])
