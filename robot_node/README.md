# robot_node – stream camera WebRTC/WHEP trên robot

Phía robot của robot_stream: lấy ảnh từ topic ROS 2, nén H.264 bằng CPU, phát WebRTC/WHEP qua MediaMTX.
Đã chạy và đo trên Wheeltec R550 (Jetson Orin Nano, JetPack 6.2, Ubuntu 22.04, ROS 2 Humble, camera Orbbec Astra).

```
/camera/color/image_raw (rgb8 640x480, ~30 fps)
   │  ROS 2, QoS reliable depth 1
   ▼
stream_node  ── appsrc → videoconvert → x264enc (CPU) → h264parse → rtph264pay ──┐
                                                            RTP/UDP 127.0.0.1:9000│
MediaMTX  ◄─────────────────────────────────────────────────────────────────────┘
   │  WebRTC: HTTP :8889 (WHEP), ICE :8189/udp
   ▼
http://<ip-robot>:8889/robot_cam/        (xem bằng trình duyệt)
http://<ip-robot>:8889/robot_cam/whep    (endpoint WHEP cho app)
```

Latency đo 04/11/2026 (từ lúc driver đóng dấu ảnh tới lúc Chrome hiển thị): **p50 66 ms, p95 93 ms**,
1.3 Mbps, YOLO không chậm đi.

## Cấu trúc

| Đường dẫn | Nội dung |
|---|---|
| `robot_stream_ros/` | ROS 2 package (ament_python): `stream_node`, `launch/stream.launch.py`, `config/mediamtx.yml` |
| `systemd/robot-stream.service` | systemd **user** service – tự chạy khi robot đăng nhập màn hình |
| `scripts/deploy.sh` | (Mac) chép code lên robot + build |
| `scripts/install_mediamtx.sh` | (robot) tải MediaMTX arm64 + kiểm checksum |
| `scripts/install_autostart.sh` | (robot) cài và bật service |
| `scripts/measure_mode.sh on\|off` | (robot) chuyển giữa service và chế độ đo latency |
| `scripts/measure_load.sh` | (robot) CPU/GPU/RAM + FPS YOLO trong N giây |
| `scripts/ab_load.sh` | (robot) A/B tải: xen kẽ tắt/bật stream N vòng |
| `scripts/time_server.py`, `www_server.py` | (robot) phục vụ đo latency tự động |

Trên robot mọi thứ nằm trong `~/robot_stream/`: `mediamtx/`, `ws/` (colcon workspace), `scripts/`, `systemd/`, `www/`, `stream.log`.

## Cài trên robot mới

Yêu cầu: ROS 2 Humble, GStreamer 1.20 có `x264enc`, `rtph264pay`, `videoconvert`, `appsrc`; `python3-gi`; `numpy` (chỉ khi đo).
Không cần sudo. Kiểm tra nhanh:

```bash
for p in x264enc rtph264pay h264parse videoconvert appsrc; do gst-inspect-1.0 $p >/dev/null && echo "có $p" || echo "THIẾU $p"; done
python3 -c "import gi; gi.require_version('Gst','1.0'); print('PyGObject OK')"
```

1. **Trên Mac** – chép code và build (cần `ssh r550` đăng nhập bằng key, xem `~/.ssh/config`):
   ```bash
   robot_node/scripts/deploy.sh r550
   ```
2. **Trên robot** – tải MediaMTX:
   ```bash
   bash ~/robot_stream/scripts/install_mediamtx.sh
   ```
3. **Trên robot** – sửa interface Wifi nếu khác `wlP1p1s0` (`ip -4 -o addr`): dòng `webrtcIPsFromInterfacesList`
   trong `~/robot_stream/ws/src/robot_stream_ros/config/mediamtx.yml`.
4. **Trên robot** – chạy thử một lần:
   ```bash
   source /opt/ros/humble/setup.bash && source ~/robot_stream/ws/install/setup.bash
   ros2 launch robot_stream_ros stream.launch.py
   ```
   Thấy `stream is available and online` và `5 s: nhận …` là được. Mở `http://<ip-robot>:8889/robot_cam/` để xem. Ctrl+C để dừng.
5. **Trên robot** – cài tự khởi động:
   ```bash
   bash ~/robot_stream/scripts/install_autostart.sh
   ```
   Kiểm tra sau `sudo reboot`: `systemctl --user is-active robot-stream` → `active`.

Gỡ: `systemctl --user disable --now robot-stream && rm ~/.config/systemd/user/robot-stream.service`.

## Vận hành

```bash
systemctl --user status robot-stream      # trạng thái
systemctl --user restart robot-stream     # áp dụng thay đổi code / config
tail -f ~/robot_stream/stream.log          # log (R550 không lưu journal của user service)
curl -s http://127.0.0.1:9997/v3/paths/get/robot_cam   # MediaMTX: ready, số người xem
```

Mỗi 5 s `stream_node` ghi: số frame nhận / đẩy / bỏ, fps, và trễ ROS (driver → node). Nếu camera im > 1 s node gửi
lại frame cuối ở 2 fps (`giữ frame cuối`) để MediaMTX không đóng phiên người xem.

Tham số launch (`ros2 launch robot_stream_ros stream.launch.py <tên>:=<giá trị>`):

| Tham số | Mặc định | Ghi chú |
|---|---|---|
| `source_topic` | `/camera/color/image_raw` | `rgb8`/`bgr8`/`rgba8`/`bgra8`/`mono8` |
| `fallback_topic` | (rỗng) | dùng khi nguồn chính im > 2 s |
| `bitrate_kbps` | 1500 | |
| `encoder_threads` | 2 | chừa CPU cho tác vụ khác |
| `x264_options` | `vbv-buf-capacity=100 sliced-threads=true` | tốt nhất đã đo |
| `stamp_barcode` | false | true chỉ khi đo latency |

| `auth` | true | đòi token ở cổng gác rosbridge và WHEP; `false` chỉ khi dev |
| `tls` | false | `wss://` + `https://` (cần `make_cert.sh`) |
| `guard_port` | 9091 | cổng gác rosbridge cho app |

Cổng mở ra mạng: 8889/tcp (WHEP, cần token), 8189/udp (ICE), 9091/tcp (cổng gác rosbridge, cần token).
Chỉ localhost: 9000/udp (RTP nội bộ), 9997/tcp (API MediaMTX), 9090/tcp (rosbridge – khi robot_stream tự bật
nó, hồ sơ `nav2_standard`). Không đụng 8000/8080/9090 của web AIUI trên R550.

## Bảo mật

Bản Free có bảo mật **cơ bản**, bật sẵn:

- **Token cho mỗi robot.** Tự tạo ở lần chạy đầu tại `~/.config/robot_stream/token` (quyền 0600). Xem token để nhập
  vào app: `ros2 run robot_stream_ros show_token`. Đổi token: xóa file rồi `systemctl --user restart robot-stream`.
- **Cổng gác rosbridge** (`rosbridge_guard`, :9091). rosbridge của ROS 2 Humble không có xác thực, nên app đi qua cổng
  gác. Cổng gác kiểm `Authorization: Bearer <token>`; sai hoặc thiếu token thì trả 401. Phía app (Dart):
  `transport.connect(rosbridgeUri(host: ip), token: token)`.
- **WHEP cần token.** Chỉ chính robot được đẩy luồng; máy khác muốn xem phải gửi `Bearer robot_stream:<token>`
  (Dart: `mediamtxCredential(token)`).
- **Audit log** `~/robot_stream/audit.log`: mỗi dòng một bản ghi JSON (thời điểm, IP, mã phiên, lệnh). Ghi kết nối,
  ngắt, bị từ chối, goal, hủy goal, gọi service, publish lệnh, lượt lái tay (lúc bắt đầu, lúc hết, số lệnh).
  Heartbeat không ghi. File xoay vòng 5 MB × 3.
- **TLS (tùy chọn).** Chạy `bash ~/robot_stream/scripts/make_cert.sh` trên robot (in vân tay SHA-256), rồi launch
  với `tls:=true`. App ghim đúng vân tay đó: `--dart-define=ROBOT_CERT_SHA256=<vân tay>`, hoặc trong Dart dùng
  `pinnedHttpClient(vânTay)` và `WhepSignaling.pinned(vânTay)`.

**Giới hạn (cần biết):**

- Không bật TLS thì token đi dạng rõ trong Wifi. Cách này chặn được người lỡ tay, app lạ hay sinh viên nghịch,
  nhưng không chặn được người nghe lén mạng. Dùng ngoài mạng nhà thì bật TLS.
- Máy nào có ROS 2 trong cùng LAN vẫn publish thẳng qua DDS được (ví dụ `ros2 topic pub /cmd_vel`), không đi qua
  cổng gác. Robot chạy mọi node trên một máy có thể đặt `ROS_LOCALHOST_ONLY=1`. Phân quyền theo topic bằng SROS2
  để bản Pro.
- Robot nào đã có rosbridge riêng mở ra LAN (R550: 9090 do AIUI bật) thì cổng đó vẫn không có token.
- Đừng mở các cổng này ra internet. Truy cập từ xa (relay, TURN) để bản Pro.

## Đo latency tự động

Đo từ lúc driver đóng dấu ảnh (`header.stamp`) tới lúc frame tới / hiển thị trên máy xem, không cần quay camera.

```bash
ssh r550 '~/robot_stream/scripts/measure_mode.sh on'    # stream có mã vạch + time_server + www_server
tools/run_latency.sh <nhãn> [giây] ["&jb=0"]           # trên Mac: MJPEG + WebRTC cùng lúc
ssh r550 '~/robot_stream/scripts/measure_mode.sh off'   # về chạy bình thường
```

`run_latency.sh` đo độ lệch đồng hồ Mac ↔ robot trước và sau (UDP, ±1.5 ms). Nếu hai số lệch nhau nhiều
(đồng hồ Mac đang bị chỉnh) thì chỉ tin hiệu số WebRTC − MJPEG, không tin số tuyệt đối.

Đo tải: `ssh r550 '~/robot_stream/scripts/ab_load.sh 3 20'` – tải nền R550 dao động mạnh nên luôn đo xen kẽ.

## Sự cố đã gặp

| Hiện tượng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `stream_node` chỉ 17–20 fps, camera 30 fps | QoS best effort (nghi mất mảnh DDS của ảnh 900 KB) | reliable + depth 1 (mặc định): 29.6 fps |
| Sau khi bật robot: 0 frame, `stream_node` không có trong `ros2 node list` | Dịch vụ chạy trước khi Wifi có IP (nghi DDS chỉ gắn interface có sẵn) | Unit chờ default route; nếu vẫn gặp: `systemctl --user restart robot-stream` |
| WebRTC trễ ~230 ms, jitter buffer Chrome 120 ms | MPEG-TS: MediaMTX chờ frame sau mới tách frame trước → frame tới dồn cục | RTP thay MPEG-TS (mặc định) |
| FPS camera tụt 30 → 2–10 (thỉnh thoảng) | Chưa rõ; từng nghi phơi sáng tự động nhưng cảnh tối vẫn đo được 29.6 fps | Theo dõi `5 s: nhận …` trong log |
| Người xem bị ngắt khi camera khựng | MediaMTX đóng phiên khi nguồn im ~15 s | giữ frame cuối (mặc định) |
| Trang đo mở từ `file://` báo Failed to fetch | MediaMTX không trả CORS cho Origin `null` | mở qua `http://` (`python3 -m http.server`) |
| `rtspclientsink` / `rtmp2sink` không dùng được | thiếu `gstreamer1.0-rtsp` (cần sudo); rtmp2sink đòi URL `app/stream` | RTP/UDP |
