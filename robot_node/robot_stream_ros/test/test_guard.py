import json
import unittest

from robot_stream_ros.rosbridge_guard import Audit

try:
    import tornado  # noqa: F401
    HAVE_TORNADO = True
except ImportError:  # máy dev không có tornado → chỉ chạy phần Audit
    HAVE_TORNADO = False


def pub(topic, msg):
    return json.dumps({'op': 'publish', 'topic': topic, 'msg': msg})


class AuditTest(unittest.TestCase):
    def setUp(self):
        self.log = []
        self.a = Audit(self.log.append)
        self.a.connected(1, '192.168.1.20', 0.0)

    def events(self):
        return [r['event'] for r in self.log]

    def test_heartbeat_sets_session_not_logged_each_time(self):
        for t in (0.2, 0.4, 0.6):
            self.a.client_message(1, pub('/robot_stream/heartbeat', {'data': 'ab12cd34'}), t)
        self.assertEqual(self.events(), ['connect', 'session'])
        self.a.client_message(1, pub('/robot_stream/control', {'data': 'ab12cd34'}), 1.0)
        self.assertEqual(self.log[-1]['session'], 'ab12cd34')
        self.assertEqual(self.log[-1]['ip'], '192.168.1.20')
        self.assertEqual(self.log[-1]['topic'], '/robot_stream/control')

    def test_goal_connection_borrows_session_from_same_ip(self):
        # App mở 2 kết nối: chính (heartbeat) + goal (không heartbeat).
        self.a.connected(2, '192.168.1.20', 0.1)
        self.a.connected(3, '10.0.0.5', 0.1)
        self.a.client_message(1, pub('/robot_stream/heartbeat', {'data': 'ab12cd34'}), 0.2)
        self.a.client_message(2, json.dumps({'op': 'send_action_goal', 'action': '/n'}), 1.0)
        self.a.client_message(3, json.dumps({'op': 'send_action_goal', 'action': '/n'}), 1.0)
        self.assertEqual(self.log[-2]['session'], 'ab12cd34')
        self.assertIsNone(self.log[-1]['session'])  # IP khác → không đoán

    def test_goal_cancel_service(self):
        self.a.client_message(1, json.dumps({
            'op': 'send_action_goal', 'id': 'g1', 'action': '/navigate_to_pose',
            'action_type': 'nav2_msgs/action/NavigateToPose',
            'args': {'pose': {'pose': {'position': {'x': 1.5, 'y': -0.2}}}}}), 1.0)
        self.a.client_message(1, json.dumps({'op': 'cancel_action_goal', 'id': 'g1',
                                             'action': '/navigate_to_pose'}), 2.0)
        self.a.client_message(1, json.dumps({
            'op': 'call_service', 'service': '/navigate_to_pose/_action/cancel_goal',
            'args': {}}), 3.0)
        self.assertEqual(self.events(), ['connect', 'action_goal', 'action_cancel', 'service'])
        self.assertIn('1.5', self.log[1]['args'])

    def test_teleop_logged_as_burst(self):
        for i in range(20):  # 2 s lái ở 10 Hz
            self.a.client_message(1, pub('/robot_stream/cmd_vel',
                                         {'linear': {'x': 0.2}}), 1.0 + i * 0.1)
        self.assertEqual(self.events(), ['connect', 'teleop_start'])
        self.a.tick(3.5)  # mới ngừng 0.6 s → chưa hết lượt
        self.assertEqual(self.events(), ['connect', 'teleop_start'])
        self.a.tick(4.0)
        self.assertEqual(self.events(), ['connect', 'teleop_start', 'teleop_end'])
        self.assertEqual(self.log[-1]['commands'], 20)
        self.assertAlmostEqual(self.log[-1]['duration_s'], 1.9)

    def test_disconnect_closes_teleop(self):
        self.a.client_message(1, pub('/robot_stream/cmd_vel', {}), 1.0)
        self.a.disconnected(1, 1.2)
        self.assertEqual(self.events(), ['connect', 'teleop_start', 'teleop_end', 'disconnect'])

    def test_ignored(self):
        self.a.client_message(1, json.dumps({'op': 'subscribe', 'topic': '/odom'}), 1.0)
        self.a.client_message(1, json.dumps({'op': 'advertise', 'topic': '/x'}), 1.0)
        self.a.client_message(1, 'không phải json', 1.0)
        self.a.client_message(1, '[1, 2]', 1.0)
        self.a.client_message(99, pub('/x', {}), 1.0)  # kết nối lạ
        self.assertEqual(self.events(), ['connect'])

    def test_long_args_truncated(self):
        self.a.client_message(1, pub('/x', {'data': 'a' * 5000}), 1.0)
        self.assertLess(len(self.log[-1]['msg']), 400)

    def test_rejected(self):
        self.a.rejected('10.0.0.9', 5.0, 'bad_token')
        self.assertEqual(self.log[-1], {'t': 5.0, 'ip': '10.0.0.9', 'session': None,
                                        'event': 'rejected', 'reason': 'bad_token'})


@unittest.skipUnless(HAVE_TORNADO, 'cần tornado (có sẵn trên robot / VM cùng rosbridge)')
class GuardNetworkTest(unittest.TestCase):
    """Cổng gác thật trên cổng ngẫu nhiên, trước một rosbridge giả (echo)."""

    def setUp(self):
        import tornado.testing  # noqa: F401
        import tornado.web
        import tornado.websocket

        from robot_stream_ros.rosbridge_guard import make_app

        class Echo(tornado.websocket.WebSocketHandler):
            def on_message(self, m):
                self.write_message('echo:' + m)

        import asyncio
        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        import tornado.httpserver
        import tornado.netutil
        up_sock, = tornado.netutil.bind_sockets(0, '127.0.0.1')
        self.up_port = up_sock.getsockname()[1]
        self.up_server = tornado.httpserver.HTTPServer(tornado.web.Application([(r'/', Echo)]))
        self.up_server.add_sockets([up_sock])
        self.log = []
        g_sock, = tornado.netutil.bind_sockets(0, '127.0.0.1')
        self.port = g_sock.getsockname()[1]
        self.server = tornado.httpserver.HTTPServer(
            make_app(f'ws://127.0.0.1:{self.up_port}/', 'secret', Audit(self.log.append)))
        self.server.add_sockets([g_sock])

    def tearDown(self):
        import asyncio
        self.server.stop()
        self.up_server.stop()
        self.loop.run_until_complete(asyncio.sleep(0.2))  # để các kết nối đóng hẳn
        for task in asyncio.all_tasks(self.loop):
            task.cancel()
        self.loop.run_until_complete(asyncio.sleep(0))
        self.loop.close()

    def connect(self, token):
        import tornado.httpclient
        import tornado.websocket
        headers = {'Authorization': f'Bearer {token}'} if token else {}
        req = tornado.httpclient.HTTPRequest(f'ws://127.0.0.1:{self.port}/', headers=headers)
        return tornado.websocket.websocket_connect(req)

    def run_(self, coro):
        return self.loop.run_until_complete(coro)

    def test_rejects_without_or_bad_token(self):
        import tornado.httpclient
        for tok in (None, 'wrong'):
            with self.assertRaises(tornado.httpclient.HTTPClientError) as e:
                self.run_(self.connect(tok))
            self.assertEqual(e.exception.code, 401)
        self.assertEqual([r['reason'] for r in self.log], ['missing', 'bad_token'])

    def test_forwards_both_ways_and_audits(self):
        async def go():
            ws = await self.connect('secret')
            ws.write_message(pub('/robot_stream/control', {'data': 'x'}))
            reply = await ws.read_message()
            ws.close()
            return reply
        reply = self.run_(go())
        self.assertTrue(reply.startswith('echo:'))
        self.assertIn('/robot_stream/control', reply)
        self.assertEqual([r['event'] for r in self.log][:2], ['connect', 'publish'])


if __name__ == '__main__':
    unittest.main()
