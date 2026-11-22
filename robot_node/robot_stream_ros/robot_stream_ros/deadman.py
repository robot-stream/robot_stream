"""Logic deadman, tách khỏi ROS để test được không cần robot.

Mỗi app có một mã phiên, gửi heartbeat kèm mã đó. Trước khi ra lệnh làm robot chạy, app
**nhận quyền điều khiển** (`claim`). Deadman chỉ canh heartbeat của phiên đang điều khiển:
phiên đó mất quá `timeout` **khi robot đang đi** → ra lệnh dừng, kể cả khi app khác vẫn
đang mở để xem (plan #9). Chưa ai nhận quyền (vd robot đi theo lệnh giọng nói) → còn
phiên nào sống là đủ.

Robot đứng yên lúc mất heartbeat thì chỉ về `idle`, không làm gì (để lệnh giọng nói sau
đó vẫn chạy bình thường).
"""

IDLE = 'idle'  # chưa có app nào (hoặc app đã đi khi robot đứng yên)
ARMED = 'armed'  # đang nhận heartbeat của phiên điều khiển (hoặc của ai đó, nếu chưa ai nhận)
TRIPPED = 'tripped'  # phiên điều khiển mất heartbeat khi robot đang đi → đã ra lệnh dừng


class Deadman:
    def __init__(self, timeout=1.0, retry_interval=1.0, max_retries=3, forget_after=60.0):
        self.timeout = timeout
        self.retry_interval = retry_interval
        self.max_retries = max_retries
        self.forget_after = forget_after
        self.state = IDLE
        self.controller = None  # mã phiên đang điều khiển
        self._beats = {}  # mã phiên → lần heartbeat gần nhất
        self._last_stop = None
        self._stops = 0

    def _fresh(self, session, now):
        t = self._beats.get(session)
        return t is not None and now - t <= self.timeout

    def _ok(self, now):
        if self.controller is not None:
            return self._fresh(self.controller, now)
        return any(now - t <= self.timeout for t in self._beats.values())

    def heartbeat(self, now, session='app'):
        self._beats[session] = now
        if self.state != ARMED and self._ok(now):
            self.state = ARMED

    def claim(self, now, session):
        """Phiên `session` sắp ra lệnh làm robot chạy → từ giờ canh phiên này."""
        self.controller = session
        self._beats.setdefault(session, now)
        if self.state != ARMED and self._ok(now):
            self.state = ARMED

    def update(self, now, moving):
        """Gọi định kỳ. Trả về True nếu phải gửi lệnh dừng ngay bây giờ."""
        for s in [s for s, t in self._beats.items() if now - t > self.forget_after]:
            del self._beats[s]
        if self.state == ARMED:
            if self._ok(now):
                return False
            if not moving:
                self.state = IDLE
                self.controller = None
                return False
            self.state = TRIPPED
            self._last_stop = now
            self._stops = 1
            return True
        if self.state == TRIPPED:
            # Lệnh dừng có thể chưa tới (service Nav2 bận…): gửi lại vài lần nếu
            # robot vẫn đang đi.
            if (moving and self._stops < self.max_retries
                    and now - self._last_stop >= self.retry_interval):
                self._last_stop = now
                self._stops += 1
                return True
        return False


# action_msgs/GoalStatus: 1 accepted, 2 executing, 3 canceling.
ACTIVE_GOAL_STATUSES = (1, 2, 3)


def is_moving(goal_statuses, nav_mode, linear, angular,
              lin_eps=0.02, ang_eps=0.05):
    """Robot có đang (hoặc sắp) di chuyển không: goal Nav2 đang chạy, semantic_nav
    đang làm việc, hoặc odometry báo đang chạy (tay cầm, teleop…)."""
    if any(s in ACTIVE_GOAL_STATUSES for s in goal_statuses):
        return True
    if nav_mode not in (None, '', 'IDLE'):
        return True
    return abs(linear) > lin_eps or abs(angular) > ang_eps


def _clamp(v, lim):
    return max(-lim, min(lim, v))


class TeleopGate:
    """Cổng lái tay: chỉ chuyển lệnh vận tốc của app sang /cmd_vel khi deadman đang
    canh, giới hạn tốc độ, và tự gửi lệnh 0 khi app ngừng gửi quá `cmd_timeout`
    (nhả nút, rớt mạng, app treo)."""

    def __init__(self, cmd_timeout=0.3, max_linear=0.3, max_angular=0.8):
        self.cmd_timeout = cmd_timeout
        self.max_linear = max_linear
        self.max_angular = max_angular
        self.active = False
        self._last = None

    def command(self, now, linear, angular, armed):
        """Lệnh mới từ app. Trả về None nếu bỏ qua (deadman chưa canh), ngược lại
        (linear, angular, vừa_bắt_đầu) – vừa_bắt_đầu = True ở lệnh đầu của một lượt
        lái, để node hủy goal Nav2 đang chạy (tránh hai bên giành /cmd_vel)."""
        if not armed:
            return None
        started = not self.active
        self.active = True
        self._last = now
        return (_clamp(linear, self.max_linear), _clamp(angular, self.max_angular),
                started)

    def update(self, now, armed):
        """Gọi định kỳ. True = phải gửi lệnh 0 ngay (hết lượt lái)."""
        if self.active and (not armed or now - self._last > self.cmd_timeout):
            self.active = False
            return True
        return False
