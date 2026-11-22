import unittest

from robot_stream_ros.on_demand import OnDemand


class OnDemandTest(unittest.TestCase):
    def test_starts_active_then_idles_after_grace(self):
        d = OnDemand(idle_after=5.0)
        self.assertEqual(d.update(0.0, 0), (True, False))
        self.assertEqual(d.update(4.9, 0), (True, False))
        self.assertEqual(d.update(5.0, 0), (False, True))
        self.assertEqual(d.update(9.0, 0), (False, False))

    def test_viewer_resumes_immediately(self):
        d = OnDemand(idle_after=5.0)
        d.update(0.0, 0)
        d.update(6.0, 0)
        self.assertEqual(d.update(6.5, 1), (True, True))

    def test_viewer_leaving_waits_grace(self):
        d = OnDemand(idle_after=5.0)
        d.update(0.0, 2)
        self.assertEqual(d.update(3.0, 0), (True, False))
        self.assertEqual(d.update(8.1, 0), (False, True))

    def test_unknown_counts_as_viewer(self):
        d = OnDemand(idle_after=5.0)
        d.update(0.0, 0)
        d.update(6.0, 0)
        self.assertEqual(d.update(7.0, None), (True, True))


if __name__ == '__main__':
    unittest.main()
