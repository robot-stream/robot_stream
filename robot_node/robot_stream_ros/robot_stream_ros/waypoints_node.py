"""waypoints_node: phát danh sách waypoint của robot cho app.

Đọc `file` (mặc định semantic_waypoints.yaml của semantic_nav R550), publish JSON
`[{"name","x","y","yaw"}, ...]` trên `~topic` (std_msgs/String, latched). Kiểm tra file
mỗi `poll_s` giây, phát lại khi nội dung đổi → app luôn khớp với robot, không chép cứng.
"""

import os

import rclpy
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
from std_msgs.msg import String

from .waypoints import parse_waypoints, to_json

# Theo hồ sơ robot (config/profiles/*.yaml); R550 trỏ tới semantic_waypoints.yaml.
DEFAULT_FILE = '~/robot_stream/waypoints.yaml'


class WaypointsNode(Node):
    def __init__(self):
        super().__init__('waypoints')
        self.path = os.path.expanduser(self.declare_parameter('file', DEFAULT_FILE).value)
        topic = self.declare_parameter('topic', '/robot_stream/waypoints').value
        poll = self.declare_parameter('poll_s', 5.0).value
        latched = QoSProfile(depth=1, reliability=ReliabilityPolicy.RELIABLE,
                             durability=DurabilityPolicy.TRANSIENT_LOCAL)
        self.pub = self.create_publisher(String, topic, latched)
        self.last = None
        self._check()
        self.create_timer(poll, self._check)

    def _check(self):
        try:
            with open(self.path, encoding='utf-8') as f:
                text = f.read()
        except OSError as e:
            self.get_logger().warn(f'không đọc được {self.path}: {e}',
                                   throttle_duration_sec=60.0)
            return
        data = to_json(parse_waypoints(text))
        if data != self.last:
            self.last = data
            self.pub.publish(String(data=data))
            self.get_logger().info(f'waypoint: {data}')


def main():
    rclpy.init()
    node = WaypointsNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == '__main__':
    main()
