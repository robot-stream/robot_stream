"""Token của robot + cấu hình MediaMTX lúc chạy (bảo mật cơ bản, bản Free).

Mỗi robot một token (file 0600, tự tạo lần đầu). App gửi token:
- rosbridge qua cổng gác (rosbridge_guard): `Authorization: Bearer <token>`;
- WHEP (MediaMTX, tài khoản nội bộ): `Authorization: Bearer robot_stream:<token>` –
  MediaMTX v1.21 chỉ nhận Bearer dạng `user:pass` với tài khoản nội bộ.

Không có TLS thì token đi dạng rõ trong LAN: chặn được người lỡ tay / app lạ, không
chặn được người nghe lén Wifi (bật `tls:=true`). Máy có ROS 2 trong LAN vẫn publish
thẳng qua DDS được – khóa DDS (ROS_LOCALHOST_ONLY / SROS2) để bản Pro.
"""

import base64
import hashlib
import hmac
import os
import secrets

import yaml

DEFAULT_DIR = os.path.expanduser('~/.config/robot_stream')
DEFAULT_TOKEN_FILE = os.path.join(DEFAULT_DIR, 'token')
WHEP_USER = 'robot_stream'


def load_or_create_token(path=DEFAULT_TOKEN_FILE):
    """Đọc token; chưa có thì tạo (32 byte ngẫu nhiên, base64url) với quyền 0600."""
    try:
        with open(path) as f:
            token = f.read().strip()
        if token:
            return token
    except FileNotFoundError:
        pass
    os.makedirs(os.path.dirname(path) or '.', mode=0o700, exist_ok=True)
    token = secrets.token_urlsafe(32)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(token + '\n')
    return token


def bearer_ok(header, token):
    """Header Authorization có đúng `Bearer <token>` không (so sánh thời gian hằng)."""
    if not header or not header.startswith('Bearer '):
        return False
    return hmac.compare_digest(header[len('Bearer '):].strip().encode(), token.encode())


def mediamtx_hash(secret):
    """Dạng băm MediaMTX nhận trong authInternalUsers: `sha256:` + base64(sha256)."""
    return 'sha256:' + base64.b64encode(hashlib.sha256(secret.encode()).digest()).decode()


def render_mediamtx_config(template_text, token=None, tls_cert=None, tls_key=None):
    """Cấu hình MediaMTX lúc chạy từ config/mediamtx.yml.

    token: quyền `read` (xem WHEP) từ máy khác đòi user `robot_stream` + token (lưu
    dạng băm). Localhost giữ nguyên quyền (publish / api / metrics). None = ai cũng xem.
    tls_cert/tls_key: WHEP qua https.
    """
    cfg = yaml.safe_load(template_text) or {}
    if token is not None:
        users = []
        for u in cfg.get('authInternalUsers') or []:
            actions = {p.get('action') for p in u.get('permissions') or []}
            if actions == {'read'} and not u.get('ips'):
                continue  # mục "ai cũng xem" → thay bằng mục có mật khẩu
            users.append(u)
        users.append({
            'user': WHEP_USER, 'pass': mediamtx_hash(token), 'ips': [],
            'permissions': [{'action': 'read'}],
        })
        cfg['authInternalUsers'] = users
    if tls_cert and tls_key:
        cfg['webrtcEncryption'] = True
        cfg['webrtcServerCert'] = tls_cert
        cfg['webrtcServerKey'] = tls_key
    return yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False)


def write_private(path, text):
    os.makedirs(os.path.dirname(path) or '.', mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(text)


def show_token_main():
    """`ros2 run robot_stream_ros show_token`: in token để nhập vào app."""
    import sys
    path = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('-') \
        else DEFAULT_TOKEN_FILE
    token = load_or_create_token(path)
    print(token)
    print(f'# file: {path} – nhập token này vào app (hoặc --dart-define=ROBOT_TOKEN=…)',
          file=sys.stderr)
