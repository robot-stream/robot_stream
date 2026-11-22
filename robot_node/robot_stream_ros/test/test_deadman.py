import unittest

from robot_stream_ros.deadman import (ARMED, IDLE, TRIPPED, Deadman, TeleopGate,
                                      is_moving)


class DeadmanTest(unittest.TestCase):
    def test_idle_until_first_heartbeat(self):
        d = Deadman(timeout=1.0)
        self.assertFalse(d.update(100.0, moving=True))
        self.assertEqual(d.state, IDLE)

    def test_heartbeats_keep_armed(self):
        d = Deadman(timeout=1.0)
        for t in (0.0, 0.2, 0.4, 0.6):
            d.heartbeat(t)
            self.assertFalse(d.update(t + 0.1, moving=True))
        self.assertEqual(d.state, ARMED)

    def test_lost_while_moving_trips_once_then_retries(self):
        d = Deadman(timeout=1.0, retry_interval=1.0, max_retries=3)
        d.heartbeat(0.0)
        self.assertFalse(d.update(1.0, moving=True))  # đúng biên timeout: chưa
        self.assertTrue(d.update(1.1, moving=True))
        self.assertEqual(d.state, TRIPPED)
        self.assertFalse(d.update(1.5, moving=True))  # chưa tới lúc gửi lại
        self.assertTrue(d.update(2.1, moving=True))  # lần 2
        self.assertTrue(d.update(3.1, moving=True))  # lần 3
        self.assertFalse(d.update(9.0, moving=True))  # hết số lần

    def test_lost_while_stopped_disarms_silently(self):
        d = Deadman(timeout=1.0)
        d.heartbeat(0.0)
        self.assertFalse(d.update(2.0, moving=False))
        self.assertEqual(d.state, IDLE)
        # Sau đó robot đi bằng giọng nói: không can thiệp.
        self.assertFalse(d.update(5.0, moving=True))

    def test_tripped_no_retry_once_stopped(self):
        d = Deadman(timeout=1.0)
        d.heartbeat(0.0)
        self.assertTrue(d.update(1.5, moving=True))
        self.assertFalse(d.update(3.0, moving=False))

    def test_heartbeat_after_trip_rearms(self):
        d = Deadman(timeout=1.0)
        d.heartbeat(0.0)
        d.update(1.5, moving=True)
        d.heartbeat(2.0)
        self.assertEqual(d.state, ARMED)
        self.assertFalse(d.update(2.5, moving=True))


class SessionTest(unittest.TestCase):
    """#9: chỉ phiên đang điều khiển giữ deadman; app khác chỉ xem không cứu được."""

    def test_viewer_does_not_keep_robot_moving(self):
        d = Deadman(timeout=1.0)
        d.heartbeat(0.0, 'lái')
        d.heartbeat(0.0, 'xem')
        d.claim(0.1, 'lái')
        for t in (0.5, 1.0, 1.5):
            d.heartbeat(t, 'xem')  # app xem vẫn sống, app lái đã rớt sau 0.0
        self.assertTrue(d.update(1.6, moving=True))
        self.assertEqual(d.state, TRIPPED)
        d.heartbeat(2.0, 'xem')
        self.assertEqual(d.state, TRIPPED)  # app xem không tự gỡ được

    def test_viewer_takes_over_by_claiming(self):
        d = Deadman(timeout=1.0)
        d.heartbeat(0.0, 'lái')
        d.claim(0.0, 'lái')
        d.heartbeat(1.0, 'xem')
        d.update(1.5, moving=True)
        d.heartbeat(2.0, 'xem')
        d.claim(2.0, 'xem')
        self.assertEqual(d.state, ARMED)
        self.assertEqual(d.controller, 'xem')

    def test_controller_back_rearms(self):
        d = Deadman(timeout=1.0)
        d.heartbeat(0.0, 'lái')
        d.claim(0.0, 'lái')
        d.update(1.5, moving=True)
        d.heartbeat(2.0, 'lái')
        self.assertEqual(d.state, ARMED)

    def test_no_claim_any_session_counts(self):
        d = Deadman(timeout=1.0)
        d.heartbeat(0.0, 'a')
        d.heartbeat(0.9, 'b')
        self.assertFalse(d.update(1.5, moving=True))  # b còn sống
        self.assertTrue(d.update(2.0, moving=True))

    def test_idle_clears_controller(self):
        d = Deadman(timeout=1.0)
        d.heartbeat(0.0, 'lái')
        d.claim(0.0, 'lái')
        d.update(1.5, moving=False)
        self.assertEqual(d.state, IDLE)
        self.assertIsNone(d.controller)


class MovingTest(unittest.TestCase):
    def test_goal_active(self):
        self.assertTrue(is_moving([4, 2], 'IDLE', 0, 0))
        self.assertFalse(is_moving([4, 5, 6], 'IDLE', 0, 0))

    def test_nav_mode(self):
        self.assertTrue(is_moving([], 'VISUAL_SEARCH', 0, 0))
        self.assertFalse(is_moving([], None, 0, 0))

    def test_odometry(self):
        self.assertTrue(is_moving([], 'IDLE', 0.1, 0))
        self.assertTrue(is_moving([], 'IDLE', 0, -0.2))
        self.assertFalse(is_moving([], 'IDLE', 0.01, 0.02))


class TeleopGateTest(unittest.TestCase):
    def test_ignored_when_not_armed(self):
        g = TeleopGate()
        self.assertIsNone(g.command(0.0, 0.2, 0.0, armed=False))
        self.assertFalse(g.active)

    def test_clamp_and_started_flag(self):
        g = TeleopGate(max_linear=0.3, max_angular=0.8)
        self.assertEqual(g.command(0.0, 1.0, -2.0, armed=True), (0.3, -0.8, True))
        self.assertEqual(g.command(0.1, 0.1, 0.2, armed=True), (0.1, 0.2, False))

    def test_stop_after_timeout(self):
        g = TeleopGate(cmd_timeout=0.3)
        g.command(0.0, 0.2, 0.0, armed=True)
        self.assertFalse(g.update(0.3, armed=True))
        self.assertTrue(g.update(0.31, armed=True))
        self.assertFalse(g.update(1.0, armed=True))  # chỉ gửi lệnh 0 một lần

    def test_stop_when_deadman_trips(self):
        g = TeleopGate()
        g.command(0.0, 0.2, 0.0, armed=True)
        self.assertTrue(g.update(0.1, armed=False))

    def test_new_session_after_stop(self):
        g = TeleopGate(cmd_timeout=0.3)
        g.command(0.0, 0.2, 0.0, armed=True)
        g.update(1.0, armed=True)
        self.assertTrue(g.command(2.0, 0.2, 0.0, armed=True)[2])


if __name__ == '__main__':
    unittest.main()
