"""Đo độ lệch đồng hồ: offset = giờ robot − giờ máy này (ms).

Gửi N gói UDP tới robot_node/scripts/time_server.py, lấy mẫu có RTT nhỏ nhất
(giả định đường đi/về đối xứng) → sai số ≈ ±RTT_min/2 (~1 ms trong LAN).
Dùng: python3 clock_offset.py <ip-robot> [port] [số gói]
"""

import socket
import struct
import sys
import time

host = sys.argv[1]
port = int(sys.argv[2]) if len(sys.argv) > 2 else 9123
count = int(sys.argv[3]) if len(sys.argv) > 3 else 200

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(0.5)
best = None
for seq in range(count):
    t0 = time.time_ns()
    sock.sendto(struct.pack('!q', seq), (host, port))
    try:
        data, _ = sock.recvfrom(64)
    except socket.timeout:
        continue
    t1 = time.time_ns()
    if struct.unpack('!q', data[:8])[0] != seq:
        continue
    robot = struct.unpack('!q', data[8:16])[0]
    rtt = t1 - t0
    if best is None or rtt < best[0]:
        best = (rtt, robot - (t0 + t1) // 2)
    time.sleep(0.01)

if best is None:
    sys.exit('Không nhận được phản hồi – time_server có chạy không?')
print(f'offset_ms={best[1] / 1e6:.2f} rtt_min_ms={best[0] / 1e6:.2f}')
