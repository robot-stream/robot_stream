"""UDP time server: mỗi gói nhận được trả về time.time_ns() của robot (8 byte).

Dùng với tools/clock_offset.py để đo độ lệch đồng hồ Mac ↔ robot khi đo latency.
Chạy: python3 time_server.py [port]  (mặc định 9123)
"""

import socket
import struct
import sys
import time

port = int(sys.argv[1]) if len(sys.argv) > 1 else 9123
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(('0.0.0.0', port))
print(f'time_server UDP :{port}', flush=True)
while True:
    data, addr = sock.recvfrom(64)
    sock.sendto(data[:8] + struct.pack('!q', time.time_ns()), addr)
