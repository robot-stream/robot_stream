"""robot_stream phía robot: MediaMTX + stream_node + deadman_node + waypoints_node
+ cổng gác rosbridge (token + audit log).

Cấu hình theo hồ sơ robot `config/profiles/<profile>.yaml` (tham số từng node + mục
`launch`). Tham số truyền tay ở dòng lệnh đè lên hồ sơ.

  ros2 launch robot_stream_ros stream.launch.py                       # profile wheeltec_r550
  ros2 launch robot_stream_ros stream.launch.py profile:=nav2_standard
  ros2 launch robot_stream_ros stream.launch.py source_topic:=/detected_image

  ros2 launch robot_stream_ros stream.launch.py tls:=true            # wss + https
  ros2 launch robot_stream_ros stream.launch.py auth:=false           # CHỈ khi dev

WHEP: http(s)://<ip-robot>:8889/robot_cam/whep (Bearer robot_stream:<token>)
rosbridge cho app: ws(s)://<ip-robot>:9091 (Bearer <token>) – token: `ros2 run
robot_stream_ros show_token`. Audit log: ~/robot_stream/audit.log.
"""

import os

import yaml
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import (DeclareLaunchArgument, ExecuteProcess, IncludeLaunchDescription,
                            LogInfo, OpaqueFunction)
from launch.launch_description_sources import AnyLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node

from robot_stream_ros.auth import (DEFAULT_DIR, load_or_create_token, render_mediamtx_config,
                                   write_private)

# Tham số stream_node có thể truyền tay: tên → kiểu ('' = lấy theo hồ sơ).
STREAM_ARGS = {
    'source_topic': str, 'fallback_topic': str, 'bitrate_kbps': int,
    'encoder_threads': int, 'stamp_barcode': lambda v: v.lower() == 'true',
    'x264_options': str, 'qos': str,
}


def _setup(context):
    share = get_package_share_directory('robot_stream_ros')
    arg = lambda name: LaunchConfiguration(name).perform(context)  # noqa: E731
    profile_path = os.path.join(share, 'config', 'profiles', arg('profile') + '.yaml')
    with open(profile_path) as f:
        profile = yaml.safe_load(f) or {}

    def params(node):
        return dict((profile.get(node) or {}).get('ros__parameters') or {})

    stream_params = params('stream_node')
    for name, cast in STREAM_ARGS.items():
        if arg(name) != '':
            stream_params[name] = cast(arg(name))
    deadman_params = params('deadman')
    if arg('deadman_timeout_s') != '':
        deadman_params['timeout_s'] = float(arg('deadman_timeout_s'))
    waypoint_params = params('waypoints')

    launch_cfg = profile.get('launch') or {}
    auth = arg('auth').lower() == 'true'
    tls = arg('tls').lower() == 'true'
    cert, key = os.path.expanduser(arg('tls_cert')), os.path.expanduser(arg('tls_key'))
    if tls and not (os.path.isfile(cert) and os.path.isfile(key)):
        raise RuntimeError(f'tls:=true nhưng thiếu {cert} / {key} – tạo bằng '
                           'robot_node/scripts/make_cert.sh')
    token = load_or_create_token() if auth else None

    env = {}
    interfaces = str(launch_cfg.get('webrtc_interfaces') or '')
    if interfaces:
        env['MTX_WEBRTCIPSFROMINTERFACESLIST'] = interfaces
    mtx_config = os.path.join(share, 'config', 'mediamtx.yml')
    if auth or tls:
        # Cấu hình lúc chạy (chứa băm token) → thư mục riêng 0700, không nằm trong share.
        with open(mtx_config) as f:
            text = render_mediamtx_config(f.read(), token, cert if tls else None,
                                          key if tls else None)
        mtx_config = os.path.join(DEFAULT_DIR, 'mediamtx.yml')
        write_private(mtx_config, text)
    mediamtx = ExecuteProcess(
        cmd=[arg('mediamtx'), mtx_config],
        name='mediamtx', output='screen', additional_env=env,
        respawn=True, respawn_delay=2.0)

    guard_args = ['--port', arg('guard_port'), '--upstream',
                  f"ws://127.0.0.1:{launch_cfg.get('rosbridge_port', 9090)}"]
    if not auth:
        guard_args.append('--no-auth')
    if tls:
        guard_args += ['--tls-cert', cert, '--tls-key', key]
    extra = []
    if launch_cfg.get('start_rosbridge'):
        # Robot chưa có rosbridge: tự bật, chỉ nghe localhost → máy khác phải qua cổng gác.
        extra.append(IncludeLaunchDescription(
            AnyLaunchDescriptionSource(os.path.join(
                get_package_share_directory('rosbridge_server'), 'launch',
                'rosbridge_websocket_launch.xml')),
            launch_arguments={'address': '127.0.0.1',
                              'port': str(launch_cfg.get('rosbridge_port', 9090))}.items()))
    else:
        extra.append(LogInfo(msg='rosbridge của robot vẫn nghe ở cổng '
                                 f"{launch_cfg.get('rosbridge_port', 9090)} (không có token) – "
                                 'cổng gác chỉ bảo vệ khi cổng đó không mở ra LAN'))
    if not auth:
        extra.append(LogInfo(msg='auth:=false – KHÔNG kiểm token, ai trong mạng cũng điều '
                                 'khiển / xem được robot'))

    def node(executable, name, p, respawn_delay=2.0):
        return Node(package='robot_stream_ros', executable=executable, name=name,
                    output='screen', parameters=[p], respawn=True,
                    respawn_delay=respawn_delay)

    return [
        *extra,
        mediamtx,
        node('stream_node', 'stream_node', stream_params),
        # Robot tự dừng khi app mất kết nối giữa lúc đang đi (rosbridge không hủy goal).
        node('deadman_node', 'deadman', deadman_params),
        # Danh sách waypoint của robot cho app.
        node('waypoints_node', 'waypoints', waypoint_params, 5.0),
        # Cổng gác rosbridge: kiểm token, ghi audit log (rosbridge Humble không có xác thực).
        Node(package='robot_stream_ros', executable='rosbridge_guard', name='rosbridge_guard',
             output='screen', arguments=guard_args, respawn=True, respawn_delay=2.0),
    ]


def generate_launch_description():
    args = [
        DeclareLaunchArgument('profile', default_value='wheeltec_r550',
                              description='config/profiles/<profile>.yaml'),
        DeclareLaunchArgument(
            'mediamtx', default_value=os.path.expanduser('~/robot_stream/mediamtx/mediamtx')),
        DeclareLaunchArgument('deadman_timeout_s', default_value=''),
        DeclareLaunchArgument('auth', default_value='true',
                              description='kiểm token (rosbridge 9091 + WHEP); false chỉ khi dev'),
        DeclareLaunchArgument('tls', default_value='false', description='wss + https'),
        DeclareLaunchArgument('tls_cert', default_value=os.path.join(DEFAULT_DIR, 'tls', 'cert.pem')),
        DeclareLaunchArgument('tls_key', default_value=os.path.join(DEFAULT_DIR, 'tls', 'key.pem')),
        DeclareLaunchArgument('guard_port', default_value='9091'),
        *[DeclareLaunchArgument(n, default_value='', description='rỗng = theo hồ sơ')
          for n in STREAM_ARGS],
    ]
    return LaunchDescription([*args, OpaqueFunction(function=_setup)])
