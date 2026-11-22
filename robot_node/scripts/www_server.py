"""Phục vụ ~/robot_stream/www (trang đo) và nhận kết quả đo qua POST /result.

Mỗi kết quả được nối vào results.jsonl cạnh trang, để đọc lại qua SSH.
Chạy: python3 www_server.py [port]  (mặc định 8001; cổng 8000 là web AIUI)
"""

import http.server
import os
import sys
import time

ROOT = os.path.expanduser('~/robot_stream/www')
RESULTS = os.path.join(ROOT, 'results.jsonl')


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def do_GET(self):
        # Giờ robot (ms) cho trang chạy trên điện thoại tự đồng bộ đồng hồ (không có UDP).
        if self.path == '/time':
            body = f'{{"t": {time.time() * 1000:.3f}}}'.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def do_POST(self):
        if self.path != '/result':
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))[:65536]
        with open(RESULTS, 'a') as f:
            f.write(f'{{"at": {time.time():.3f}, "data": {body.decode("utf-8", "replace")}}}\n')
        self.send_response(204)
        self.end_headers()

    def end_headers(self):
        # Trang đo hay được sửa: không để trình duyệt cache.
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8001
http.server.ThreadingHTTPServer(('0.0.0.0', port), Handler).serve_forever()
