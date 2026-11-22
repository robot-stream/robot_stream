"""deadman_node: robot tự dừng khi app mất kết nối giữa lúc đang đi.

App (qua rosbridge) publish `~heartbeat` (std_msgs/String = mã phiên của app) ~5 lần/giây;
trước khi ra lệnh làm robot chạy, app gửi mã phiên lên `~control` (nhận quyền điều khiển) –
deadman chỉ canh heartbeat của phiên đó (plan #9). Mất heartbeat
quá `timeout_s` khi robot đang di chuyển → hủy mọi goal Nav2, gửi "dừng lại" cho
semantic_nav, phát cmd_vel = 0. Trạng thái (idle/armed/tripped) phát trên `~state`
(latched) để app hiện ra và chỉ cho đi khi deadman đang canh.

Lái tay: app publish `~cmd_vel` (Twist, ~10 Hz khi giữ nút). Node chỉ chuyển sang
/cmd_vel khi deadman `armed`, giới hạn tốc độ, hủy goal Nav2 đang chạy ở lệnh đầu,
và tự gửi lệnh 0 khi app ngừng gửi > `teleop_cmd_timeout_s` (nhả nút / rớt mạng).

Lý do cần: rosbridge KHÔNG hủy goal khi client rớt (đo 12/11) → robot đi tiếp tới đích.
"""

import time

import rclpy
from action_msgs.msg import GoalStatusArray
from action_msgs.srv import CancelGoal
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import (DurabilityPolicy, HistoryPolicy, QoSProfile,
                       ReliabilityPolicy, qos_profile_sensor_data)
from std_msgs.msg import String

from .deadman import ARMED, Deadman, TeleopGate, is_moving


class DeadmanNode(Node):
    def __init__(self):
        super().__init__('deadman')
        p = self.declare_parameter
        self.timeout = p('timeout_s', 1.0).value
        heartbeat = p('heartbeat_topic', '/robot_stream/heartbeat').value
        control = p('control_topic', '/robot_stream/control').value
        state = p('state_topic', '/robot_stream/deadman').value
        cancel = p('cancel_service', '/navigate_to_pose/_action/cancel_goal').value
        status = p('status_topic', '/navigate_to_pose/_action/status').value
        self.stop_topic = p('stop_topic', '').value  # '' = robot không có lệnh dừng riêng
        self.stop_word = p('stop_word', '').value
        mode = p('nav_mode_topic', '').value
        odom = p('odom_topic', '/odom').value
        cmd_vel = p('cmd_vel_topic', '/cmd_vel').value
        teleop = p('teleop_topic', '/robot_stream/cmd_vel').value
        self.gate = TeleopGate(
            cmd_timeout=p('teleop_cmd_timeout_s', 0.3).value,
            max_linear=p('max_linear', 0.3).value,
            max_angular=p('max_angular', 0.8).value)

        self.dm = Deadman(timeout=self.timeout)
        self.goal_statuses = []
        self.nav_mode = None
        self.lin = self.ang = 0.0

        # best effort: nhận được dù bên phát reliable hay best effort.
        be = QoSProfile(depth=1, reliability=ReliabilityPolicy.BEST_EFFORT)
        self.create_subscription(String, heartbeat, self._on_beat, 10)
        self.create_subscription(String, control, self._on_claim, 10)
        self.create_subscription(GoalStatusArray, status, self._on_status, be)
        if mode:  # bộ điều hướng riêng của hãng (R550 semantic_nav)
            self.create_subscription(String, mode, self._on_mode, be)
        self.create_subscription(Odometry, odom, self._on_odom, qos_profile_sensor_data)
        self.create_subscription(Twist, teleop, self._on_teleop, 10)

        latched = QoSProfile(depth=1, history=HistoryPolicy.KEEP_LAST,
                             reliability=ReliabilityPolicy.RELIABLE,
                             durability=DurabilityPolicy.TRANSIENT_LOCAL)
        self.state_pub = self.create_publisher(String, state, latched)
        self.say_pub = (self.create_publisher(String, self.stop_topic, 10)
                        if self.stop_topic else None)
        self.vel_pub = self.create_publisher(Twist, cmd_vel, 10)
        self.cancel = self.create_client(CancelGoal, cancel)

        self._published = None
        self._publish_state()
        self.create_timer(0.1, self._tick)
        self.get_logger().info(
            f'deadman: heartbeat {heartbeat}, timeout {self.timeout:.1f} s')

    def _on_beat(self, msg):
        was = self.dm.state
        self.dm.heartbeat(time.monotonic(), msg.data or 'app')
        if was != self.dm.state:
            self.get_logger().info(f'app {msg.data} đã kết nối – deadman đang canh')
            self._publish_state()

    def _on_claim(self, msg):
        if not msg.data:
            return
        was, prev = self.dm.state, self.dm.controller
        self.dm.claim(time.monotonic(), msg.data)
        if prev != msg.data:
            self.get_logger().info(f'app {msg.data} nhận quyền điều khiển (trước: {prev})')
        if was != self.dm.state:
            self._publish_state()

    def _on_status(self, msg):
        self.goal_statuses = [s.status for s in msg.status_list]

    def _on_mode(self, msg):
        self.nav_mode = msg.data

    def _on_odom(self, msg):
        self.lin = msg.twist.twist.linear.x
        self.ang = msg.twist.twist.angular.z

    def _on_teleop(self, msg):
        out = self.gate.command(time.monotonic(), msg.linear.x, msg.angular.z,
                                self.dm.state == ARMED)
        if out is None:
            self.get_logger().warn('bỏ qua lệnh lái tay: deadman chưa canh',
                                   throttle_duration_sec=2.0)
            return
        lin, ang, started = out
        if started:
            self.get_logger().info('bắt đầu lái tay')
            # Nav2 / semantic_nav đang đi thì hủy, tránh hai bên giành /cmd_vel.
            if any(s in (1, 2) for s in self.goal_statuses) and self.cancel.service_is_ready():
                self.cancel.call_async(CancelGoal.Request())
            if self.nav_mode not in (None, '', 'IDLE'):
                self._say_stop()
        t = Twist()
        t.linear.x, t.angular.z = lin, ang
        self.vel_pub.publish(t)

    def _tick(self):
        moving = is_moving(self.goal_statuses, self.nav_mode, self.lin, self.ang)
        was = self.dm.state
        now = time.monotonic()
        if self.dm.update(now, moving):
            self._stop()
        if self.gate.update(now, self.dm.state == ARMED):
            self.get_logger().info('hết lượt lái tay → lệnh 0')
            for _ in range(2):
                self.vel_pub.publish(Twist())
        if was != self.dm.state:
            if self.dm.state == 'idle':
                self.get_logger().info('app ngắt khi robot đứng yên – không cần dừng')
            self._publish_state()

    def _stop(self):
        self.get_logger().warn(
            f'MẤT HEARTBEAT (phiên {self.dm.controller or "bất kỳ"}) > {self.timeout:.1f} s khi robot đang đi '
            f'(goal {self.goal_statuses}, mode {self.nav_mode}, '
            f'v {self.lin:.2f}, w {self.ang:.2f}) → DỪNG')
        if self.cancel.service_is_ready():
            req = CancelGoal.Request()  # goal_id 0 + stamp 0 = hủy mọi goal
            self.cancel.call_async(req)
        else:
            self.get_logger().error('service hủy goal Nav2 chưa sẵn sàng')
        self._say_stop()
        for _ in range(3):
            self.vel_pub.publish(Twist())

    def _say_stop(self):
        """Lệnh dừng riêng của robot (R550: "dừng lại" cho semantic_nav), nếu có."""
        if self.say_pub is not None:
            self.say_pub.publish(String(data=self.stop_word))

    def _publish_state(self):
        if self._published != self.dm.state:
            self._published = self.dm.state
            self.state_pub.publish(String(data=self.dm.state))


def main():
    rclpy.init()
    node = DeadmanNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == '__main__':
    main()
