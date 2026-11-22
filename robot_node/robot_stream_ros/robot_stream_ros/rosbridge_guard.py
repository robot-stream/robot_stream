"""Cổng gác rosbridge: kiểm token rồi chuyển tiếp hai chiều tới rosbridge nội bộ.

  app ──ws(s)://robot:9091 + Authorization: Bearer <token>──► guard ──► ws://127.0.0.1:9090

rosbridge 2.x (ROS 2 Humble) không có xác thực → mọi lệnh từ máy khác đi qua đây. Sai /
thiếu token → HTTP 401 lúc mở WebSocket. Ghi audit log: ai (IP + mã phiên deadman) gửi lệnh
gì, lúc nào – goal, hủy goal, service, publish lệnh; lái tay chỉ ghi lúc bắt đầu / hết lượt;
heartbeat không ghi.

Chỉ dùng Tornado (rosbridge_server đã cần, có sẵn trên robot). Không dùng rclpy.

  rosbridge_guard --port 9091 --upstream ws://127.0.0.1:9090 [--no-auth] \
      [--tls-cert cert.pem --tls-key key.pem] [--audit-file ~/robot_stream/audit.log]
"""

import argparse
import json
import logging
import logging.handlers
import os
import time

from .auth import DEFAULT_TOKEN_FILE, bearer_ok, load_or_create_token

HEARTBEAT_TOPIC = '/robot_stream/heartbeat'
TELEOP_TOPIC = '/robot_stream/cmd_vel'
MAX_MESSAGE = 64 * 1024 * 1024  # rosbridge có thể gửi message lớn (bản đồ…)
_ARG_LIMIT = 300  # độ dài tối đa phần nội dung lệnh ghi vào log


def _short(obj):
    s = json.dumps(obj, ensure_ascii=False, separators=(',', ':'))
    return s if len(s) <= _ARG_LIMIT else s[:_ARG_LIMIT] + '…'


class Audit:
    """Chọn lọc lệnh đáng ghi từ luồng JSON của client. Không phụ thuộc mạng → test được.

    `write(record)` nhận dict (đã có t, ip, phiên…). Trả về các bản ghi đã ghi để test.
    """

    def __init__(self, write, heartbeat_topic=HEARTBEAT_TOPIC, teleop_topic=TELEOP_TOPIC,
                 teleop_gap=1.0):
        self._write = write
        self.heartbeat_topic = heartbeat_topic
        self.teleop_topic = teleop_topic
        self.teleop_gap = teleop_gap
        self._conns = {}  # id kết nối → {ip, session, teleop: (bắt đầu, lần cuối, số lệnh)}

    def _session_of(self, c):
        """Mã phiên của kết nối; chưa có (kết nối goal riêng của app không gửi heartbeat)
        → mã phiên gần nhất từ cùng IP."""
        if c.get('session') or not c.get('ip'):
            return c.get('session')
        same_ip = [o for o in self._conns.values() if o['ip'] == c['ip'] and o['session']]
        return max(same_ip, key=lambda o: o['session_t'])['session'] if same_ip else None

    def _emit(self, conn, now, event, **fields):
        c = self._conns.get(conn, {})
        rec = {'t': round(now, 3), 'ip': c.get('ip'), 'session': self._session_of(c),
               'event': event, **fields}
        self._write(rec)
        return rec

    def connected(self, conn, ip, now):
        self._conns[conn] = {'ip': ip, 'session': None, 'session_t': 0.0, 'teleop': None,
                             'since': now}
        return [self._emit(conn, now, 'connect')]

    def rejected(self, ip, now, reason):
        rec = {'t': round(now, 3), 'ip': ip, 'session': None, 'event': 'rejected',
               'reason': reason}
        self._write(rec)
        return [rec]

    def disconnected(self, conn, now):
        out = self._end_teleop(conn, now)
        c = self._conns.get(conn)
        if c is not None:
            out.append(self._emit(conn, now, 'disconnect',
                                  duration_s=round(now - c['since'], 1)))
            del self._conns[conn]
        return out

    def _end_teleop(self, conn, now):
        c = self._conns.get(conn)
        if not c or not c['teleop']:
            return []
        start, last, n = c['teleop']
        c['teleop'] = None
        return [self._emit(conn, now, 'teleop_end', commands=n,
                           duration_s=round(last - start, 2))]

    def tick(self, now):
        """Gọi định kỳ: đóng lượt lái tay đã ngừng quá `teleop_gap`."""
        out = []
        for conn, c in list(self._conns.items()):
            if c['teleop'] and now - c['teleop'][1] > self.teleop_gap:
                out += self._end_teleop(conn, now)
        return out

    def client_message(self, conn, text, now):
        try:
            msg = json.loads(text)
        except (ValueError, TypeError):
            return []
        if not isinstance(msg, dict):
            return []
        op = msg.get('op')
        c = self._conns.get(conn)
        if c is None:
            return []
        if op == 'publish':
            topic = msg.get('topic')
            if topic == self.heartbeat_topic:
                data = (msg.get('msg') or {}).get('data')
                if isinstance(data, str) and data != c['session']:
                    c['session'] = data
                    c['session_t'] = now
                    return [self._emit(conn, now, 'session')]
                return []
            if topic == self.teleop_topic:
                out = []
                if c['teleop'] and now - c['teleop'][1] > self.teleop_gap:
                    out += self._end_teleop(conn, now)
                if c['teleop'] is None:
                    c['teleop'] = (now, now, 1)
                    out.append(self._emit(conn, now, 'teleop_start', msg=_short(msg.get('msg'))))
                else:
                    start, _, n = c['teleop']
                    c['teleop'] = (start, now, n + 1)
                return out
            return [self._emit(conn, now, 'publish', topic=topic, msg=_short(msg.get('msg')))]
        if op == 'send_action_goal':
            return [self._emit(conn, now, 'action_goal', action=msg.get('action'),
                               args=_short(msg.get('args')))]
        if op == 'cancel_action_goal':
            return [self._emit(conn, now, 'action_cancel', action=msg.get('action'))]
        if op == 'call_service':
            return [self._emit(conn, now, 'service', service=msg.get('service'),
                               args=_short(msg.get('args')))]
        return []


def make_audit_writer(path, max_bytes=5 * 1024 * 1024, backups=3):
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    log = logging.getLogger('robot_stream.audit')
    log.setLevel(logging.INFO)
    log.propagate = False
    h = logging.handlers.RotatingFileHandler(path, maxBytes=max_bytes, backupCount=backups,
                                             encoding='utf-8')
    h.setFormatter(logging.Formatter('%(message)s'))
    log.addHandler(h)
    return lambda rec: log.info(json.dumps(rec, ensure_ascii=False))


def make_app(upstream, token, audit, clock=time.time):
    """Ứng dụng Tornado của cổng gác. token=None → không kiểm (auth:=false)."""
    import tornado.web
    import tornado.websocket

    class Guard(tornado.websocket.WebSocketHandler):
        _next_id = 0

        def check_origin(self, origin):
            return True  # app di động không gửi Origin của robot; token mới là chốt chặn

        async def get(self, *args, **kwargs):
            if token is not None and not bearer_ok(self.request.headers.get('Authorization'),
                                                   token):
                reason = 'missing' if not self.request.headers.get('Authorization') \
                    else 'bad_token'
                audit.rejected(self.request.remote_ip, clock(), reason)
                self.set_status(401)
                self.set_header('WWW-Authenticate', 'Bearer')
                self.finish('unauthorized')
                return
            await super().get(*args, **kwargs)

        async def open(self):
            Guard._next_id += 1
            self.conn = Guard._next_id
            self.up = None
            try:
                self.up = await tornado.websocket.websocket_connect(
                    upstream, max_message_size=MAX_MESSAGE)
            except Exception as e:  # rosbridge chưa chạy
                logging.getLogger('rosbridge_guard').warning(f'không nối được {upstream}: {e}')
                self.close(1011, 'rosbridge không chạy')
                return
            audit.connected(self.conn, self.request.remote_ip, clock())
            tornado.ioloop.IOLoop.current().spawn_callback(self._pump)

        async def _pump(self):
            while True:
                m = await self.up.read_message()
                if m is None:
                    self.close(1011, 'rosbridge đóng kết nối')
                    return
                try:
                    await self.write_message(m, binary=isinstance(m, bytes))
                except tornado.websocket.WebSocketClosedError:
                    return

        def on_message(self, message):
            if self.up is None:
                return
            if isinstance(message, str):
                audit.client_message(self.conn, message, clock())
            self.up.write_message(message, binary=isinstance(message, bytes))

        def on_close(self):
            if getattr(self, 'up', None) is not None:
                self.up.close()
                audit.disconnected(self.conn, clock())

    import tornado.ioloop  # noqa: F401 (dùng trong open)
    return tornado.web.Application([(r'/.*', Guard)], websocket_max_message_size=MAX_MESSAGE)


def main(argv=None):
    import ssl
    import sys

    import tornado.httpserver
    import tornado.ioloop

    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument('--address', default='0.0.0.0')
    p.add_argument('--port', type=int, default=9091)
    p.add_argument('--upstream', default='ws://127.0.0.1:9090')
    p.add_argument('--token-file', default=DEFAULT_TOKEN_FILE)
    p.add_argument('--no-auth', action='store_true', help='không kiểm token (chỉ khi dev)')
    p.add_argument('--tls-cert', default='')
    p.add_argument('--tls-key', default='')
    p.add_argument('--audit-file', default=os.path.expanduser('~/robot_stream/audit.log'))
    p.add_argument('--heartbeat-topic', default=HEARTBEAT_TOPIC)
    p.add_argument('--teleop-topic', default=TELEOP_TOPIC)
    args, _ = p.parse_known_args(sys.argv[1:] if argv is None else argv)  # bỏ --ros-args
    logging.basicConfig(level=logging.INFO, format='[rosbridge_guard] %(message)s')
    log = logging.getLogger('rosbridge_guard')

    token = None if args.no_auth else load_or_create_token(args.token_file)
    if token is None:
        log.warning('KHÔNG KIỂM TOKEN (--no-auth): ai trong mạng cũng điều khiển được robot')
    audit = Audit(make_audit_writer(os.path.expanduser(args.audit_file)),
                  args.heartbeat_topic, args.teleop_topic)
    ssl_ctx = None
    if args.tls_cert and args.tls_key:
        ssl_ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        ssl_ctx.load_cert_chain(os.path.expanduser(args.tls_cert),
                                os.path.expanduser(args.tls_key))
    server = tornado.httpserver.HTTPServer(make_app(args.upstream, token, audit),
                                           ssl_options=ssl_ctx)
    server.listen(args.port, args.address)
    tornado.ioloop.PeriodicCallback(lambda: audit.tick(time.time()), 500).start()
    log.info(f'{"wss" if ssl_ctx else "ws"}://{args.address}:{args.port} → {args.upstream}'
             f' (token: {"có" if token else "TẮT"}, audit: {args.audit_file})')
    tornado.ioloop.IOLoop.current().start()


if __name__ == '__main__':
    main()
