from glob import glob

from setuptools import setup

package_name = 'robot_stream_ros'

setup(
    name=package_name,
    version='0.1.0',
    packages=[package_name],
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        ('share/' + package_name + '/launch', glob('launch/*.launch.py')),
        ('share/' + package_name + '/config', glob('config/*.yml')),
        ('share/' + package_name + '/config/profiles', glob('config/profiles/*.yaml')),
    ],
    install_requires=['setuptools'],
    zip_safe=True,
    entry_points={
        'console_scripts': [
            'stream_node = robot_stream_ros.stream_node:main',
            'deadman_node = robot_stream_ros.deadman_node:main',
            'waypoints_node = robot_stream_ros.waypoints_node:main',
            'rosbridge_guard = robot_stream_ros.rosbridge_guard:main',
            'show_token = robot_stream_ros.auth:show_token_main',
        ],
    },
)
