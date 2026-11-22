"""Latency MJPEG tự động: giờ frame tới máy này (đổi sang giờ robot) − X-Timestamp.

web_video_server gửi X-Timestamp = header.stamp của ảnh, cùng mốc với mã vạch của
stream_node, nên so được trực tiếp với tools/latency_auto.html (cột receive).
Dùng: python3 -I mjpeg_latency.py <ip> <offset_ms robot−máy này> [giây] [topic]
"""

import re
import sys
import time
import urllib.request

ip, offset_ms = sys.argv[1], float(sys.argv[2])
seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 30
topic = sys.argv[4] if len(sys.argv) > 4 else '/camera/color/image_raw'
# web_video_server không giải mã %2F – giữ nguyên dấu /.
url = (f'http://{ip}:8080/stream?topic={topic}&type=mjpeg'
       '&quality=50&width=640&height=480')

pat = re.compile(rb'X-Timestamp: ([0-9.]+)')
buf, lat, last = b'', [], None
start = time.monotonic()
with urllib.request.urlopen(url, timeout=5) as r:
    while time.monotonic() - start < seconds:
        chunk = r.read1(65536)
        if not chunk:
            break
        buf += chunk
        while True:
            m = pat.search(buf)
            if not m:
                buf = buf[-64:]
                break
            end = buf.find(b'\xff\xd9', m.end())  # frame tới đủ khi thấy EOI
            if end < 0:
                buf = buf[m.start():]
                break
            stamp = float(m.group(1))
            if stamp != last:
                last = stamp
                lat.append((time.time() * 1000 + offset_ms) - stamp * 1000)
            buf = buf[end + 2:]

lat.sort()
pick = lambda p: lat[min(len(lat) - 1, int(p * len(lat)))]
print(f'MJPEG receive_ms p50={pick(0.5):.0f} p95={pick(0.95):.0f} '
      f'min={lat[0]:.0f} max={lat[-1]:.0f} n={len(lat)}')
