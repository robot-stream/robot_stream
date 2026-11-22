"""stream_node: sensor_msgs/Image → x264 (CPU) → RTP/UDP nội bộ → MediaMTX → WebRTC/WHEP.

Áp dụng bài học V1–V5 từ bản mô phỏng: kích thước theo frame đầu (không cố
định), appsrc live + timestamp theo thời gian thực, keyframe mỗi ~1 s,
H.264 constrained-baseline, QoS reliable depth 1 (chỉ giữ frame mới nhất).
"""

import time

import gi
import rclpy
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import Image

gi.require_version('Gst', '1.0')
gi.require_version('GstVideo', '1.0')
from gi.repository import Gst, GstVideo  # noqa: E402

from .on_demand import OnDemand, mediamtx_readers  # noqa: E402

# Encoding ROS → format GStreamer.
FORMATS = {
    'rgb8': 'RGB',
    'bgr8': 'BGR',
    'rgba8': 'RGBA',
    'bgra8': 'BGRA',
    'mono8': 'GRAY8',
}


BARCODE_BITS = 32
BARCODE_ROW_H = 16


def draw_stamp_barcode(data, msg):
    """Ghi (header.stamp tính bằng ms) mod 2^32 thành 32 ô đen/trắng ở hàng 0–15,
    hàng 16–31 là bản đảo bit để bên nhận kiểm tra đọc đúng. Ô rộng width/32 px
    (20 px với 640) – đủ to để không vỡ sau nén H.264."""
    import numpy as np

    img = np.frombuffer(data, dtype=np.uint8).reshape(msg.height, msg.width, 3).copy()
    stamp_ms = msg.header.stamp.sec * 1000 + msg.header.stamp.nanosec // 1_000_000
    value = stamp_ms & 0xFFFFFFFF
    cell = msg.width // BARCODE_BITS
    for i in range(BARCODE_BITS):
        bit = (value >> (BARCODE_BITS - 1 - i)) & 1
        x0, x1 = i * cell, (i + 1) * cell
        img[0:BARCODE_ROW_H, x0:x1] = 255 if bit else 0
        img[BARCODE_ROW_H:2 * BARCODE_ROW_H, x0:x1] = 0 if bit else 255
    return img.tobytes()


class StreamNode(Node):

    def __init__(self):
        super().__init__('stream_node')
        self.source_topic = self.declare_parameter(
            'source_topic', '/camera/color/image_raw').value
        # Dùng khi source_topic im lặng quá fallback_after_s (ví dụ YOLO tắt).
        self.fallback_topic = self.declare_parameter('fallback_topic', '').value
        self.fallback_after_s = self.declare_parameter('fallback_after_s', 2.0).value
        # MediaMTX nghe udp+rtp tại đây (config/mediamtx.yml, path robot_cam).
        self.output_host = self.declare_parameter('output_host', '127.0.0.1').value
        self.output_port = self.declare_parameter('output_port', 9000).value
        self.bitrate_kbps = self.declare_parameter('bitrate_kbps', 1500).value
        # FPS danh định của nguồn, để x264 điều khiển bitrate đúng (timestamp vẫn theo thực tế).
        self.fps = self.declare_parameter('fps', 30).value
        self.keyint = self.declare_parameter('keyframe_interval', 30).value
        # Giới hạn luồng x264 để chừa CPU cho tác vụ khác (YOLO...). 0 = tự chọn.
        self.threads = self.declare_parameter('encoder_threads', 2).value
        # Thuộc tính x264enc thêm vào (vd "vbv-buf-capacity=100 sliced-threads=true"), để thử
        # cấu hình giảm jitter mà không sửa code.
        self.x264_options = self.declare_parameter('x264_options', '').value
        # Camera im lặng quá lâu → gửi lại frame cuối ở 2 fps, để MediaMTX không coi
        # nguồn là chết và đóng mọi phiên WebRTC (người xem chỉ thấy hình đứng).
        self.hold_after_s = self.declare_parameter('hold_last_frame_after_s', 1.0).value
        # Ảnh 640x480 rgb8 ~900 KB bị DDS chia thành hàng trăm mảnh UDP; best effort
        # mất 1 mảnh là mất cả ảnh → trên R550 chỉ còn 0–3 fps khi CPU bận. Reliable +
        # depth 1 gửi lại mảnh mất nhưng vẫn chỉ giữ frame mới nhất (không dồn hàng).
        # Đo latency: vẽ header.stamp (ms, 32 bit) thành mã vạch ở 32 hàng trên cùng của ảnh,
        # bên nhận đọc lại (tools/latency_auto.html). Chỉ bật khi đo.
        self.stamp_barcode = self.declare_parameter('stamp_barcode', False).value
        # Chỉ mã hóa đủ fps khi có người xem (hỏi API MediaMTX). Không ai xem → bỏ
        # đăng ký camera (khỏi giải mã ảnh ~900 KB × 30/s), chỉ gửi lại 1 khung/s (IDR)
        # để MediaMTX giữ luồng sống và người mới mở app thấy hình ngay.
        self.on_demand = self.declare_parameter('on_demand', True).value
        self.mediamtx_api = self.declare_parameter(
            'mediamtx_api', 'http://127.0.0.1:9997').value
        self.mediamtx_path = self.declare_parameter('mediamtx_path', 'robot_cam').value
        self.demand = OnDemand(idle_after=self.declare_parameter('idle_after_s', 5.0).value)
        # QoS đăng ký camera: 'auto' = theo bên phát (camera chuẩn dùng best effort –
        # sensor_data; R550 Astra phát reliable, ở đó reliable cho fps cao hơn hẳn).
        # Đăng ký reliable với bên phát best effort thì không nhận được gì.
        self.qos_mode = str(self.declare_parameter('qos', 'auto').value)

        Gst.init(None)
        self.pipeline = None
        self.appsrc = None
        self.caps_key = None
        self.retry_at = 0.0

        self.last_source_at = 0.0
        self.last_msg = None
        self.last_push_at = 0.0
        self.holding = False
        self.frames_in = 0
        self.frames_pushed = 0
        self.frames_dropped = 0
        self.frames_held = 0
        self.ros_delays_ms = []

        self.qos = None
        self.subs = []
        self.subscribe()
        self.create_timer(1.0, self.ensure_subscribed)
        if self.on_demand:
            self.create_timer(1.0, self.check_viewers)
        self.create_timer(0.5, self.poll_bus)
        self.create_timer(0.5, self.hold_last_frame)
        self.create_timer(5.0, self.log_stats)
        self.get_logger().info(
            f'source={self.source_topic} fallback={self.fallback_topic or "-"} '
            f'→ udp://{self.output_host}:{self.output_port} @ {self.bitrate_kbps} kbps')

    def resolve_qos(self):
        """QoS theo `qos`; 'auto' cần thấy bên phát – chưa thấy thì trả None (thử lại sau)."""
        if self.qos_mode in ('reliable', 'best_effort'):
            rel = (ReliabilityPolicy.RELIABLE if self.qos_mode == 'reliable'
                   else ReliabilityPolicy.BEST_EFFORT)
        else:
            pubs = self.get_publishers_info_by_topic(self.source_topic)
            if not pubs:
                return None
            # Có bên phát best effort → phải best effort mới nhận được.
            best_effort = any(p.qos_profile.reliability == ReliabilityPolicy.BEST_EFFORT
                              for p in pubs)
            rel = ReliabilityPolicy.BEST_EFFORT if best_effort else ReliabilityPolicy.RELIABLE
        self.get_logger().info(f'QoS camera: {rel.name.lower()} (qos={self.qos_mode})')
        return QoSProfile(history=HistoryPolicy.KEEP_LAST, depth=1, reliability=rel)

    def ensure_subscribed(self):
        """'auto' lúc khởi động có thể chưa thấy camera → đăng ký khi camera xuất hiện.

        Đang nghỉ mà CHƯA có khung nào (node bật trước camera) vẫn phải đăng ký tới khi có
        khung đầu: chế độ nghỉ chỉ phát lại khung cuối – không có khung thì MediaMTX không
        có luồng, WHEP trả 404, không ai xem được nên node cũng không bao giờ thức (21/11).
        """
        if not self.subs and (self.demand.active or self.last_msg is None):
            self.subscribe()
        elif self.subs and not self.demand.active and self.last_msg is not None:
            self.unsubscribe()  # đã có khung đầu → về nghỉ (giữ 1 khung/s)

    def subscribe(self):
        if self.subs:
            return
        if self.qos is None:
            self.qos = self.resolve_qos()
            if self.qos is None:
                self.get_logger().warn(f'Chưa thấy ai phát {self.source_topic} – chờ',
                                       throttle_duration_sec=30.0)
                return
        self.subs.append(self.create_subscription(
            Image, self.source_topic, self.on_source, self.qos))
        if self.fallback_topic:
            self.subs.append(self.create_subscription(
                Image, self.fallback_topic, self.on_fallback, self.qos))

    def unsubscribe(self):
        for sub in self.subs:
            self.destroy_subscription(sub)
        self.subs = []

    def check_viewers(self):
        readers = mediamtx_readers(self.mediamtx_api, self.mediamtx_path)
        active, changed = self.demand.update(time.monotonic(), readers)
        if not changed:
            return
        if active:
            self.get_logger().info(f'Có người xem ({readers}) – chạy đủ fps')
            self.subscribe()
            self.force_keyframe()  # người mới vào thấy hình ngay, không chờ IDR kế
        else:
            self.get_logger().info('Không ai xem – nghỉ (giữ 1 khung/s)')
            self.unsubscribe()

    def force_keyframe(self):
        if self.appsrc is None:
            return
        ev = GstVideo.video_event_new_downstream_force_key_unit(
            Gst.CLOCK_TIME_NONE, Gst.CLOCK_TIME_NONE, Gst.CLOCK_TIME_NONE, True, 0)
        self.appsrc.get_static_pad('src').push_event(ev)

    def on_source(self, msg):
        self.last_source_at = time.monotonic()
        self.push(msg)

    def on_fallback(self, msg):
        if time.monotonic() - self.last_source_at > self.fallback_after_s:
            self.push(msg)

    def push(self, msg):
        self.frames_in += 1
        # Trễ từ lúc driver đóng dấu ảnh tới lúc node nhận (cùng đồng hồ trên robot).
        stamp_ns = msg.header.stamp.sec * 10**9 + msg.header.stamp.nanosec
        if stamp_ns:
            self.ros_delays_ms.append((self.get_clock().now().nanoseconds - stamp_ns) / 1e6)
        fmt = FORMATS.get(msg.encoding)
        if fmt is None:
            self.frames_dropped += 1
            self.get_logger().error(
                f'Encoding {msg.encoding} chưa hỗ trợ', throttle_duration_sec=10.0)
            return
        key = (fmt, msg.width, msg.height)
        if key != self.caps_key:
            # Đổi kích thước/định dạng (V1): dựng lại pipeline thay vì bỏ frame.
            self.stop_pipeline()
            self.caps_key = key
        if self.pipeline is None:
            if time.monotonic() < self.retry_at:
                self.frames_dropped += 1
                return
            self.start_pipeline(*key)

        self.last_msg = msg
        if self.holding:
            self.holding = False
            self.get_logger().info('Có frame mới trở lại')
        if self.push_buffer(msg):
            self.frames_pushed += 1
        else:
            self.frames_dropped += 1

    def push_buffer(self, msg):
        self.last_push_at = time.monotonic()
        data = bytes(msg.data)
        if self.stamp_barcode and msg.encoding in ('rgb8', 'bgr8'):
            data = draw_stamp_barcode(data, msg)
        buf = Gst.Buffer.new_wrapped(data)
        return self.appsrc.emit('push-buffer', buf) == Gst.FlowReturn.OK

    def hold_last_frame(self):
        if self.pipeline is None or self.last_msg is None:
            return
        if not self.demand.active:
            # Đang nghỉ: 1 khung/s, mỗi khung là IDR để người mới vào giải mã được ngay.
            if time.monotonic() - self.last_push_at >= 1.0:
                self.force_keyframe()
                self.push_buffer(self.last_msg)
                self.frames_held += 1
            return
        if time.monotonic() - self.last_push_at > self.hold_after_s:
            if not self.holding:
                self.holding = True
                self.get_logger().warn(
                    f'Không có frame mới > {self.hold_after_s} s – giữ frame cuối')
            self.push_buffer(self.last_msg)
            self.frames_held += 1

    def start_pipeline(self, fmt, width, height):
        desc = (
            'appsrc name=src is-live=true do-timestamp=true format=time '
            'max-buffers=2 leaky-type=downstream block=false '
            f'caps=video/x-raw,format={fmt},width={width},height={height},framerate={self.fps}/1 '
            '! videoconvert ! video/x-raw,format=I420 '
            f'! x264enc tune=zerolatency speed-preset=ultrafast bitrate={self.bitrate_kbps} '
            f'key-int-max={self.keyint} bframes=0 threads={self.threads} {self.x264_options} '
            '! video/x-h264,profile=constrained-baseline '
            '! h264parse config-interval=-1 '
            # RTP thay MPEG-TS: PES video trong TS không ghi độ dài nên MediaMTX phải chờ
            # PES của frame sau mới biết frame trước xong → +1 khoảng frame (~50 ms đo được).
            # RTP có marker bit cuối frame. config-interval=-1: SPS/PPS kèm mỗi IDR.
            '! rtph264pay pt=96 config-interval=-1 '
            f'! udpsink host={self.output_host} port={self.output_port} sync=false async=false'
        )
        self.pipeline = Gst.parse_launch(desc)
        self.appsrc = self.pipeline.get_by_name('src')
        self.pipeline.set_state(Gst.State.PLAYING)
        self.get_logger().info(f'Pipeline chạy: {fmt} {width}x{height}')

    def stop_pipeline(self):
        if self.pipeline is not None:
            self.pipeline.set_state(Gst.State.NULL)
        self.pipeline = None
        self.appsrc = None

    def poll_bus(self):
        """Lỗi GStreamer (MediaMTX tắt, rớt kết nối...) → dựng lại sau 1 s."""
        if self.pipeline is None:
            return
        bus = self.pipeline.get_bus()
        while True:
            msg = bus.pop_filtered(Gst.MessageType.ERROR | Gst.MessageType.EOS)
            if msg is None:
                return
            if msg.type == Gst.MessageType.ERROR:
                err, _ = msg.parse_error()
                self.get_logger().warn(f'Lỗi pipeline: {err.message} – thử lại sau 1 s')
            else:
                self.get_logger().warn('Pipeline EOS – thử lại sau 1 s')
            self.stop_pipeline()
            self.retry_at = time.monotonic() + 1.0
            return

    def log_stats(self):
        if not self.demand.active:
            self.frames_held = 0
            return  # đang nghỉ – khỏi log mỗi 5 s
        held = f', giữ frame cuối {self.frames_held}' if self.frames_held else ''
        d = sorted(self.ros_delays_ms)
        delay = f', trễ ROS p50 {d[len(d) // 2]:.0f} / max {d[-1]:.0f} ms' if d else ''
        self.get_logger().info(
            f'5 s: nhận {self.frames_in}, đẩy {self.frames_pushed}, '
            f'bỏ {self.frames_dropped}{held} ({self.frames_pushed / 5:.1f} fps){delay}')
        self.frames_in = self.frames_pushed = self.frames_dropped = self.frames_held = 0
        self.ros_delays_ms = []

    def destroy_node(self):
        self.stop_pipeline()
        super().destroy_node()


def main():
    rclpy.init()
    node = StreamNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == '__main__':
    main()
