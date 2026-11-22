import unittest

from robot_stream_ros.waypoints import parse_waypoints, to_json


class WaypointsTest(unittest.TestCase):
    def test_parse_r550_file(self):
        text = '''# Tọa độ
waypoints:
  "trạm sạc": [-0.12, 0.25, 1.03]
  "tủ lạnh": [3.52, -0.75, 1]
  "hỏng": [1.0, 2.0]
  "chữ": ["a", 1, 2]
'''
        self.assertEqual(parse_waypoints(text), [
            {'name': 'trạm sạc', 'x': -0.12, 'y': 0.25, 'yaw': 1.03},
            {'name': 'tủ lạnh', 'x': 3.52, 'y': -0.75, 'yaw': 1.0},
        ])

    def test_bad_input(self):
        self.assertEqual(parse_waypoints(''), [])
        self.assertEqual(parse_waypoints('waypoints: [1, 2]'), [])
        self.assertEqual(parse_waypoints('{{{'), [])

    def test_json_keeps_vietnamese(self):
        self.assertIn('trạm sạc', to_json([{'name': 'trạm sạc'}]))


if __name__ == '__main__':
    unittest.main()
