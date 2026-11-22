#!/usr/bin/env python3
"""Cảm biến giả cho turtlebot3_fake_node (không vật lý, không Gazebo – chạy nhẹ trong VM arm64).

turtlebot3_fake_node chỉ có /odom + TF odom→base_footprint. Node này thêm phần còn thiếu để
Nav2 + app chạy như với robot ROS 2 chuẩn:
  /scan          sensor_msgs/LaserScan   – dò tia trên bản đồ tại vị trí thật (giống LDS: 360 tia, 5 Hz)
  /battery_state sensor_msgs/BatteryState – pin tụt dần (12.4 V → 10.5 V trong `drain_minutes`)
  /camera/image_raw sensor_msgs/Image (rgb8) – hình mẫu có giờ + vị trí, để thử luồng video

Vị trí thật = pose xuất phát trên bản đồ ⊕ /odom (fake node không trượt bánh).

  python3 fake_sensors.py --map /opt/ros/humble/share/nav2_bringup/maps/turtlebot3_world.yaml \
      --start -2.0 -0.5 0.0
"""

import argparse
import array
import math
import os
import time

import cv2
import numpy as np
import rclpy
import yaml
from nav_msgs.msg import Odometry
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import BatteryState, Image, LaserScan


def load_map(yaml_path):
    with open(yaml_path) as f:
        meta = yaml.safe_load(f)
    img_path = os.path.join(os.path.dirname(yaml_path), meta['image'])
    img = cv2.imread(img_path, cv2.IMREAD_GRAYSCALE)
    if meta.get('negate', 0):
        img = 255 - img
    occ = (255 - img) / 255.0 > meta['occupied_thresh']  # True = vật cản
    return occ[::-1, :], meta['resolution'], meta['origin']  # hàng 0 = y nhỏ nhất


class FakeSensors(Node):
    def __init__(self, args):
        super().__init__('fake_sensors')
        self.occ, self.res, origin = load_map(args.map)
        self.ox, self.oy = origin[0], origin[1]
        self.sx, self.sy, self.syaw = args.start
        self.pose = (self.sx, self.sy, self.syaw)
        self.drain_s = args.drain_minutes * 60
        self.t0 = time.monotonic()

        # LDS-01 của TurtleBot3: 360 tia, 0.12–3.5 m, 5 Hz.
        self.n = 360
        self.rmin, self.rmax = 0.12, 3.5
        steps = np.arange(self.rmin, self.rmax, self.res / 2)
        self.steps = steps[None, :]
        self.angles = np.linspace(0, 2 * math.pi, self.n, endpoint=False)

        self.scan_pub = self.create_publisher(LaserScan, 'scan', qos_profile_sensor_data)
        self.bat_pub = self.create_publisher(BatteryState, 'battery_state', 10)
        self.cam_pub = self.create_publisher(Image, 'camera/image_raw', qos_profile_sensor_data)
        self.create_subscription(Odometry, 'odom', self.on_odom, 10)
        self.create_timer(0.2, self.publish_scan)
        self.create_timer(1.0, self.publish_battery)
        # Nền camera dựng sẵn một lần; mỗi khung chỉ vẽ chữ lên bản sao.
        self.cam_bg = np.zeros((480, 640, 3), np.uint8)
        self.cam_bg[:, :, 0] = np.linspace(40, 200, 640, dtype=np.uint8)[None, :]
        self.cam_bg[:, :, 2] = np.linspace(200, 40, 480, dtype=np.uint8)[:, None]
        self.create_timer(1.0 / args.camera_fps, self.publish_camera)
        self.get_logger().info(
            f'bản đồ {self.occ.shape[1]}x{self.occ.shape[0]} @ {self.res} m, xuất phát {args.start}')

    def on_odom(self, msg):
        p = msg.pose.pose.position
        q = msg.pose.pose.orientation
        oyaw = math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
        c, s = math.cos(self.syaw), math.sin(self.syaw)
        self.pose = (self.sx + c * p.x - s * p.y, self.sy + s * p.x + c * p.y, self.syaw + oyaw)

    def publish_scan(self):
        x, y, yaw = self.pose
        a = (yaw + self.angles)[:, None]
        px = ((x + np.cos(a) * self.steps - self.ox) / self.res).astype(int)
        py = ((y + np.sin(a) * self.steps - self.oy) / self.res).astype(int)
        h, w = self.occ.shape
        inside = (px >= 0) & (px < w) & (py >= 0) & (py < h)
        hit = np.zeros_like(inside)
        hit[inside] = self.occ[py[inside], px[inside]]
        first = np.where(hit.any(axis=1), hit.argmax(axis=1), -1)
        ranges = np.where(first >= 0, self.steps[0][np.maximum(first, 0)], np.inf)
        m = LaserScan()
        m.header.stamp = self.get_clock().now().to_msg()
        m.header.frame_id = 'base_scan'
        m.angle_min, m.angle_max = 0.0, 2 * math.pi * (self.n - 1) / self.n
        m.angle_increment = 2 * math.pi / self.n
        m.scan_time, m.time_increment = 0.2, 0.0
        m.range_min, m.range_max = self.rmin, self.rmax
        m.ranges = ranges.astype(np.float32).tolist()
        self.scan_pub.publish(m)

    def publish_battery(self):
        frac = max(0.0, 1.0 - (time.monotonic() - self.t0) / self.drain_s)
        m = BatteryState()
        m.header.stamp = self.get_clock().now().to_msg()
        m.voltage = 10.5 + 1.9 * frac
        m.percentage = frac
        m.present = True
        m.power_supply_status = BatteryState.POWER_SUPPLY_STATUS_DISCHARGING
        self.bat_pub.publish(m)

    def publish_camera(self):
        w, h = 640, 480
        x, y, yaw = self.pose
        img = self.cam_bg.copy()
        cv2.putText(img, 'TurtleBot3 (fake)', (20, 60), cv2.FONT_HERSHEY_SIMPLEX, 1.4,
                    (255, 255, 255), 3)
        cv2.putText(img, time.strftime('%H:%M:%S') + f'.{int(time.time() * 10) % 10}',
                    (20, 140), cv2.FONT_HERSHEY_SIMPLEX, 1.6, (255, 255, 0), 3)
        cv2.putText(img, f'x {x:5.2f}  y {y:5.2f}  yaw {math.degrees(yaw):4.0f}', (20, 220),
                    cv2.FONT_HERSHEY_SIMPLEX, 1.0, (255, 255, 255), 2)
        m = Image()
        m.header.stamp = self.get_clock().now().to_msg()
        m.header.frame_id = 'camera_rgb_optical_frame'
        m.height, m.width, m.encoding, m.step = h, w, 'rgb8', w * 3
        # array('B') thay vì bytes: rclpy chép bytes vào uint8[] từng phần tử (rất chậm).
        m.data = array.array('B', img.tobytes())
        self.cam_pub.publish(m)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--map', default='/opt/ros/humble/share/nav2_bringup/maps/turtlebot3_world.yaml')
    ap.add_argument('--start', type=float, nargs=3, default=[-2.0, -0.5, 0.0])
    ap.add_argument('--drain-minutes', type=float, default=60.0)
    ap.add_argument('--camera-fps', type=float, default=15.0)
    args, ros_args = ap.parse_known_args()
    rclpy.init(args=ros_args)
    node = FakeSensors(args)
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == '__main__':
    main()
