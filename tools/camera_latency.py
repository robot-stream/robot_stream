"""Phân tích trễ camera + USB + driver từ lần nháy màn hình (flash.html) và độ sáng
từng frame trên robot (brightness_probe.py).

Với mỗi lần đổi màu ở thời điểm T (đồng hồ Mac → đổi sang đồng hồ robot bằng offset),
tìm frame đầu tiên sau T có độ sáng vượt ngưỡng giữa đen/trắng theo đúng chiều.
Trễ = header.stamp của frame đó − T. Màu thực sự lên màn hình sau T khoảng 1 khung
(~16.7 ms ở 60 Hz), nên số "đã trừ màn hình" = trễ − DISPLAY_MS.

Dùng: python3 -I camera_latency.py <flashes.json> <brightness.csv> <offset_ms> [display_ms]
(offset bị bỏ qua nếu flashes.json có robot_clock: true – trang đã tự đồng bộ.)
"""

import json
import sys

flashes_path, csv_path, offset_ms = sys.argv[1], sys.argv[2], float(sys.argv[3])
display_ms = float(sys.argv[4]) if len(sys.argv) > 4 else 16.7

data = json.load(open(flashes_path))
flashes = data['flashes']
# Trang tự đồng bộ qua HTTP (điện thoại) → thời điểm đã theo đồng hồ robot.
if data.get('robot_clock'):
    offset_ms = 0.0
frames = []
for line in open(csv_path).read().splitlines()[1:]:
    stamp, recv, bright = (float(x) for x in line.split(','))
    frames.append((stamp, recv, bright))
frames.sort()
if not frames or not flashes:
    sys.exit('Thiếu dữ liệu: không có frame hoặc không có lần nháy')

values = sorted(b for _, _, b in frames)
low, high = values[len(values) // 20], values[-len(values) // 20 - 1]
mid = (low + high) / 2
if high - low < 30:
    sys.exit(f'Độ sáng chỉ thay đổi {low:.0f}→{high:.0f}: camera chưa nhìn vào màn hình?')

lat, recv_lat, missed = [], [], 0
for i, f in enumerate(flashes):
    t = f['t'] + offset_ms  # đồng hồ robot
    t_next = flashes[i + 1]['t'] + offset_ms if i + 1 < len(flashes) else t + 2000
    hit = next(
        (fr for fr in frames
         if t <= fr[0] < t_next and ((fr[2] > mid) if f['white'] else (fr[2] < mid))),
        None,
    )
    if hit is None:
        missed += 1
        continue
    lat.append(hit[0] - t)
    recv_lat.append(hit[1] - t)


def stats(a):
    a = sorted(a)
    p = lambda q: a[min(len(a) - 1, int(q * len(a)))]
    return f'p50 {p(0.5):.0f} · p95 {p(0.95):.0f} · min {a[0]:.0f} · max {a[-1]:.0f} ms'


fps = (len(frames) - 1) / ((frames[-1][0] - frames[0][0]) / 1000)
print(f'{len(flashes)} lần nháy, {len(lat)} khớp, {missed} không thấy · camera {fps:.1f} fps · '
      f'độ sáng đen {low:.0f} / trắng {high:.0f}')
if lat:
    print(f'Màn hình đổi lệnh → header.stamp (thô):      {stats(lat)}')
    print(f'Trừ ~{display_ms:.1f} ms màn hình hiện màu → camera+USB+driver: '
          f'{stats([x - display_ms for x in lat])}')
    print(f'(Tới lúc node ROS nhận ảnh, thô:              {stats(recv_lat)})')
