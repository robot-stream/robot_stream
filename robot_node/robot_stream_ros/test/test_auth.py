import os
import stat
import tempfile
import unittest

import yaml

from robot_stream_ros.auth import (WHEP_USER, bearer_ok, load_or_create_token,
                                   mediamtx_hash, render_mediamtx_config)

TEMPLATE = open(os.path.join(os.path.dirname(__file__), '..', 'config', 'mediamtx.yml')).read()


class TokenTest(unittest.TestCase):
    def test_create_once_private(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, 'sub', 'token')
            t1 = load_or_create_token(path)
            self.assertGreaterEqual(len(t1), 40)
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            self.assertEqual(load_or_create_token(path), t1)  # đọc lại, không tạo mới

    def test_bearer(self):
        self.assertTrue(bearer_ok('Bearer abc', 'abc'))
        self.assertFalse(bearer_ok('Bearer abd', 'abc'))
        self.assertFalse(bearer_ok('Basic abc', 'abc'))
        self.assertFalse(bearer_ok(None, 'abc'))
        self.assertFalse(bearer_ok('Bearer ', 'abc'))

    def test_hash_format(self):
        # sha256("testpass") = 13d249f2…9f6c (hex) → base64.
        self.assertEqual(mediamtx_hash('testpass'),
                         'sha256:E9JJ8stBJ7QM+nV4ZoUCeHk/gU3tPFh/5YieiJp6n2w=')


class MediamtxConfigTest(unittest.TestCase):
    def test_token_replaces_anyone_can_read(self):
        cfg = yaml.safe_load(render_mediamtx_config(TEMPLATE, token='tok'))
        users = cfg['authInternalUsers']
        anyone_read = [u for u in users if u['user'] == 'any' and not u.get('ips')]
        self.assertEqual(anyone_read, [])
        local = [u for u in users if u.get('ips')]
        self.assertEqual({p['action'] for p in local[0]['permissions']},
                         {'publish', 'api', 'metrics'})
        mine = [u for u in users if u['user'] == WHEP_USER]
        self.assertEqual(mine[0]['pass'], mediamtx_hash('tok'))
        self.assertNotIn('tok', yaml.safe_dump(cfg).replace(mediamtx_hash('tok'), ''))
        self.assertEqual(cfg['paths']['robot_cam']['source'], 'udp+rtp://127.0.0.1:9000')

    def test_no_token_keeps_template(self):
        self.assertEqual(yaml.safe_load(render_mediamtx_config(TEMPLATE)),
                         yaml.safe_load(TEMPLATE))

    def test_tls(self):
        cfg = yaml.safe_load(render_mediamtx_config(TEMPLATE, 'tok', '/c.pem', '/k.pem'))
        self.assertTrue(cfg['webrtcEncryption'])
        self.assertEqual((cfg['webrtcServerCert'], cfg['webrtcServerKey']),
                         ('/c.pem', '/k.pem'))
        self.assertNotIn('webrtcEncryption', yaml.safe_load(render_mediamtx_config(TEMPLATE)))


if __name__ == '__main__':
    unittest.main()
