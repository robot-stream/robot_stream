#!/usr/bin/env python3
"""In độ khớp lidar với bản đồ đã lưu (% điểm quét nằm trong ~10 cm quanh tường) mỗi giây.
Chỉ đọc: /scan + TF map->laser. Dùng: align_watch.py <map.pgm> <origin_x> <origin_y> [res]"""
import sys, math, rclpy
from rclpy.node import Node
from sensor_msgs.msg import LaserScan
from rclpy.qos import qos_profile_sensor_data
import tf2_ros

pgm, ox, oy = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
res = float(sys.argv[4]) if len(sys.argv) > 4 else 0.05
d = open(pgm, "rb").read(); p = d.split(maxsplit=4); w, h = int(p[1]), int(p[2]); px = p[4][:w*h]
wall = bytearray(w*h)
for r in range(h):
    for c in range(w):
        if px[r*w+c] <= 5:
            for a in (-2,-1,0,1,2):
                for b in (-2,-1,0,1,2):
                    if 0 <= r+a < h and 0 <= c+b < w: wall[(r+a)*w+c+b] = 1

class W(Node):
    def __init__(s):
        super().__init__("align_watch")
        s.buf = tf2_ros.Buffer(); s.tl = tf2_ros.TransformListener(s.buf, s)
        s.scan = None
        s.create_subscription(LaserScan, "/scan", lambda m: setattr(s, "scan", m), qos_profile_sensor_data)
        s.create_timer(1.0, s.tick)
    def tick(s):
        m = s.scan
        if m is None: return
        try: t = s.buf.lookup_transform("map", m.header.frame_id, rclpy.time.Time())
        except Exception as e: print("tf:", e, flush=True); return
        q = t.transform.rotation; yaw = math.atan2(2*(q.w*q.z+q.x*q.y), 1-2*(q.y*q.y+q.z*q.z))
        x0, y0 = t.transform.translation.x, t.transform.translation.y
        n = hit = 0; a = m.angle_min
        for i, r in enumerate(m.ranges):
            if i % 3 == 0 and m.range_min < r < min(m.range_max, 8.0):
                x = x0 + r*math.cos(yaw+a); y = y0 + r*math.sin(yaw+a)
                ci = int((x-ox)/res); ri = h-1-int((y-oy)/res); n += 1
                if 0 <= ri < h and 0 <= ci < w and wall[ri*w+ci]: hit += 1
            a += m.angle_increment
        if n: print(f"khớp {100*hit/n:3.0f}%  laser x={x0:6.2f} y={y0:6.2f} yaw={yaw:5.2f}  ({n} điểm)", flush=True)

rclpy.init(); rclpy.spin(W())
