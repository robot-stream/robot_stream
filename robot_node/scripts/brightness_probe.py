"""Ghi độ sáng trung bình của từng ảnh camera kèm header.stamp, để đo trễ camera + USB.

Dùng với tools/flash.html + tools/run_camera_latency.sh (màn hình nháy đen/trắng).
Chạy: python3 brightness_probe.py [giây] [topic] [file csv]
CSV: stamp_ms (header.stamp), recv_ms (lúc node nhận, đồng hồ robot), brightness (0–255)
"""

import sys
import time

import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import Image

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 45
TOPIC = sys.argv[2] if len(sys.argv) > 2 else '/camera/color/image_raw'
OUT = sys.argv[3] if len(sys.argv) > 3 else '/tmp/brightness.csv'


class Probe(Node):
    def __init__(self):
        super().__init__('brightness_probe')
        self.rows = []
        # Reliable depth 1 như stream_node (best effort mất ~1/3 frame trên R550).
        qos = QoSProfile(history=HistoryPolicy.KEEP_LAST, depth=1,
                         reliability=ReliabilityPolicy.RELIABLE)
        self.create_subscription(Image, TOPIC, self.on_image, qos)

    def on_image(self, msg):
        recv_ms = time.time() * 1000
        stamp_ms = msg.header.stamp.sec * 1000 + msg.header.stamp.nanosec / 1e6
        ch = 3 if msg.encoding in ('rgb8', 'bgr8') else 1
        img = np.frombuffer(msg.data, dtype=np.uint8).reshape(msg.height, msg.width, ch)
        # Vùng giữa, lấy mẫu thưa: đủ để thấy màn hình đổi đen/trắng, rẻ CPU.
        h, w = msg.height, msg.width
        center = img[h // 4:3 * h // 4:4, w // 4:3 * w // 4:4]
        self.rows.append((stamp_ms, recv_ms, float(center.mean())))


def main():
    rclpy.init()
    node = Probe()
    end = time.time() + SECONDS
    while time.time() < end:
        rclpy.spin_once(node, timeout_sec=0.1)
    with open(OUT, 'w') as f:
        f.write('stamp_ms,recv_ms,brightness\n')
        for r in node.rows:
            f.write(f'{r[0]:.3f},{r[1]:.3f},{r[2]:.1f}\n')
    print(f'{len(node.rows)} frame → {OUT}')
    node.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()
