"""Đọc file waypoint của semantic_nav (R550: semantic_waypoints.yaml), tách khỏi ROS để test.

Định dạng file:
    waypoints:
      "trạm sạc": [-0.12, 0.25, 1.03]   # x, y (m, frame map), yaw (rad)
"""

import json

import yaml


def parse_waypoints(text):
    """Trả về list dict {name, x, y, yaw}, bỏ qua mục sai định dạng. Lỗi YAML → []."""
    try:
        data = yaml.safe_load(text) or {}
    except yaml.YAMLError:
        return []
    items = data.get('waypoints') if isinstance(data, dict) else None
    if not isinstance(items, dict):
        return []
    out = []
    for name, v in items.items():
        if (isinstance(v, (list, tuple)) and len(v) >= 3
                and all(isinstance(n, (int, float)) for n in v[:3])):
            out.append({'name': str(name), 'x': float(v[0]), 'y': float(v[1]),
                        'yaw': float(v[2])})
    return out


def to_json(waypoints):
    return json.dumps(waypoints, ensure_ascii=False)
