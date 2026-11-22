"""Quyết định có cần mã hóa video đủ fps không, theo số người xem MediaMTX báo.

Không ai xem quá `idle_after` giây → nghỉ (stream_node chỉ giữ 1 khung/giây để
MediaMTX không coi nguồn là chết). Không hỏi được MediaMTX (readers=None) → coi như
có người xem: thà tốn CPU còn hơn người dùng mở app không thấy hình.
"""

import json
import urllib.request


class OnDemand:
    def __init__(self, idle_after=5.0):
        self.idle_after = idle_after
        self.active = True  # lúc khởi động chạy đủ cho tới khi biết chắc không ai xem
        self._last_viewer = None

    def update(self, now, readers):
        """Trả về (active, đổi_trạng_thái)."""
        if self._last_viewer is None:
            self._last_viewer = now
        if readers is None or readers > 0:
            self._last_viewer = now
            want = True
        else:
            want = now - self._last_viewer < self.idle_after
        changed = want != self.active
        self.active = want
        return want, changed


def mediamtx_readers(api, path, timeout=0.5):
    """Số người đang xem path, hoặc None nếu không hỏi được."""
    try:
        with urllib.request.urlopen(f'{api}/v3/paths/get/{path}', timeout=timeout) as r:
            data = json.load(r)
        return len(data.get('readers') or [])
    except Exception:  # noqa: BLE001 – lỗi mạng / JSON / 404 đều coi là không biết
        return None
