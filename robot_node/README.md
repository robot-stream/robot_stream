# robot_node (`robot_stream_ros`)

Robot-side ROS 2 Humble gateway for [`robot_stream`](../README.md). Runs on any Ubuntu 22.04 + ROS 2 Humble robot (`amd64` or `arm64`) to provide:

- **Low-latency WebRTC/WHEP video (`stream_node` + MediaMTX):** subscribes to a ROS 2 `sensor_msgs/Image` topic, encodes H.264 with GStreamer `x264enc` (`zerolatency` + `vbv-buf-capacity=100` + `sliced-threads=true`), pushes RTP/UDP locally to MediaMTX, and scales to multiple viewers without re-encoding per viewer. Automatically drops to ~1–1.5% idle CPU when no viewer is watching.
- **Per-session deadman safety (`deadman_node`):** tracks the active controlling client's heartbeat; cancels Nav2 goals and outputs zero `/cmd_vel` if connectivity drops. Also gates manual teleop commands (`/robot_stream/cmd_vel` → `/cmd_vel`) with a 0.3 s command timeout and velocity clamping.
- **Token-authenticated rosbridge guard (`rosbridge_guard`):** wraps unauthenticated ROS 2 Humble `rosbridge_server` (bound to `127.0.0.1:9090`) on port `9091` with `Authorization: Bearer <token>`, optional TLS (`wss://`), and rotating JSON-line audit logs (`~/robot_stream/audit.log`).
- **Dynamic waypoints (`waypoints_node`):** publishes named waypoints from a YAML file onto `/robot_stream/waypoints`.

```
ROS 2 camera topic (rgb8 / bgr8 / rgba8 / bgra8 / mono8)
   │  QoS auto-matched (depth 1)
   ▼
stream_node ──► GStreamer x264enc ──► RTP/UDP 127.0.0.1:9000 ──► MediaMTX
                                                                    │
                                   http(s)://<robot-ip>:8889/robot_cam/whep (Bearer token)

ROS 2 Nav2 / odom / battery / cmd_vel
   │
   ├── rosbridge_server (127.0.0.1:9090) ◄── rosbridge_guard (:9091, Bearer token + audit log)
   ├── deadman_node (/robot_stream/heartbeat, /robot_stream/control, /robot_stream/cmd_vel)
   └── waypoints_node (/robot_stream/waypoints)
```

---

## Prerequisites (Ubuntu 22.04 + ROS 2 Humble)

Install the required GStreamer, PyGObject, Tornado, and `rosbridge_server` packages on the robot (`amd64` or `arm64`):

```bash
sudo apt update && sudo apt install -y \
  curl python3-colcon-common-extensions \
  ros-humble-rosbridge-server \
  gstreamer1.0-tools gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-ugly \
  python3-gi gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0 \
  python3-tornado python3-yaml
```

---

## Quick Install (Any ROS 2 Humble Robot)

### Option A: One-command setup (recommended)

Clone the repository on your robot and run the installer script (no `sudo` required once prerequisites are installed):

```bash
git clone https://github.com/robot-stream/robot_stream.git
cd robot_stream
bash robot_node/scripts/install_robot.sh
```

The script verifies all dependencies, downloads MediaMTX (`v1.21.3`, auto-detecting `linux_amd64` or `linux_arm64` with SHA-256 verification) into `~/robot_stream/mediamtx/`, copies `robot_stream_ros` into `~/robot_stream/ws/src/`, and runs `colcon build --symlink-install`.

### Option B: Manual step-by-step setup

1. **Install MediaMTX** (auto-detects `amd64`/`arm64`, verifies SHA-256):
   ```bash
   bash robot_node/scripts/install_mediamtx.sh
   ```
2. **Build `robot_stream_ros` in a colcon workspace:**
   ```bash
   mkdir -p ~/robot_stream/ws/src
   cp -r robot_node/robot_stream_ros ~/robot_stream/ws/src/
   cd ~/robot_stream/ws
   source /opt/ros/humble/setup.bash
   PYTHONNOUSERSITE=1 colcon build --symlink-install
   ```

---

## Launch & Get Your Bearer Token

Start the gateway with the standard ROS 2 + Nav2 profile (replace `source_topic` with your robot's camera topic):

```bash
source /opt/ros/humble/setup.bash
source ~/robot_stream/ws/install/setup.bash
ros2 launch robot_stream_ros stream.launch.py \
  profile:=nav2_standard \
  source_topic:=/camera/image_raw
```

On first launch, a random per-robot bearer token is generated automatically at `~/.config/robot_stream/token` (`chmod 0600`). In another terminal, print the token to enter into the Flutter app:

```bash
source /opt/ros/humble/setup.bash
source ~/robot_stream/ws/install/setup.bash
ros2 run robot_stream_ros show_token
```

To verify the video stream in a browser on the same LAN, open `http://<robot-ip>:8889/robot_cam/` (username `robot_stream`, password `<token>`).

> **Already running `rosbridge_server` on port `9090`?** The `nav2_standard` profile starts its own `rosbridge_server` bound strictly to `127.0.0.1:9090`. If your robot already launches `rosbridge_server` on `:9090`, create a custom profile YAML (copied from `config/profiles/nav2_standard.yaml`) with `start_rosbridge: false`, and ideally bind your existing rosbridge to `127.0.0.1`.

---

## Launch Arguments & Profiles

Profiles live in `robot_stream_ros/config/profiles/<profile>.yaml`. Command-line launch arguments override profile values.

| Argument | Default | Description |
|---|---|---|
| `profile` | `wheeltec_r550` | Profile name (`nav2_standard` for standard ROS 2 + Nav2 robots, `wheeltec_r550` for Wheeltec R550). |
| `source_topic` | *(from profile)* | Camera `sensor_msgs/Image` topic (`rgb8`, `bgr8`, `rgba8`, `bgra8`, or `mono8`). |
| `fallback_topic` | `''` | Optional fallback image topic if `source_topic` stalls > 2 s. |
| `qos` | `auto` | Camera QoS (`auto`, `reliable`, or `best_effort`). `auto` matches the publisher's QoS. |
| `bitrate_kbps` | `1500` | Target H.264 bitrate in kbps. |
| `encoder_threads` | `2` | `x264enc` thread count (leaves CPU headroom for Nav2/SLAM/YOLO). |
| `x264_options` | `vbv-buf-capacity=100 sliced-threads=true` | Low-jitter `x264enc` tuning. |
| `deadman_timeout_s` | *(from profile)* | Heartbeat timeout before `deadman_node` cancels goals (default `1.0` s). |
| `auth` | `true` | Require bearer token on `rosbridge_guard` (`:9091`) and WHEP (`:8889`). Set `false` only for local dev. |
| `tls` | `false` | Enable `wss://` and `https://` using certificates from `make_cert.sh`. |
| `guard_port` | `9091` | External WebSocket port exposed by `rosbridge_guard`. |
| `stamp_barcode` | `false` | Overlay 32-bit `header.stamp` barcode for automated latency measurement. |

### Network Ports

| Port | Bind | Purpose |
|---|---|---|
| `8889/tcp` | LAN | MediaMTX WebRTC/WHEP signaling (Bearer token required) |
| `8189/udp` | LAN | WebRTC ICE media |
| `9091/tcp` | LAN | `rosbridge_guard` WebSocket proxy (Bearer token + audit log) |
| `9000/udp` | `127.0.0.1` | Internal H.264 RTP stream (`stream_node` → MediaMTX) |
| `9997/tcp` | `127.0.0.1` | MediaMTX control API (viewer count for on-demand streaming) |
| `9090/tcp` | `127.0.0.1` | Local `rosbridge_server` upstream (when `start_rosbridge: true`) |

---

## Optional Security: Self-Signed TLS + Certificate Pinning

Without TLS (`tls:=false`), bearer tokens travel in plaintext over Wi-Fi. Outside trusted private networks, generate a self-signed certificate on the robot and pin its SHA-256 fingerprint in the Flutter app:

```bash
bash ~/robot_stream/scripts/make_cert.sh
# Prints the 64-char SHA-256 fingerprint to pass via --dart-define=ROBOT_CERT_SHA256=<sha256>

ros2 launch robot_stream_ros stream.launch.py profile:=nav2_standard tls:=true
```

To rotate the bearer token, delete `~/.config/robot_stream/token` and restart the launch/service. Command audit logs are written to `~/robot_stream/audit.log` (rotating JSON lines, 5 MB × 3).

---

## Optional: Waypoints & Systemd Auto-Start

### Named Waypoints
With `profile:=nav2_standard`, `waypoints_node` watches `~/robot_stream/waypoints.yaml` (reloaded every 5 s):

```yaml
waypoints:
  "dock": [0.0, 0.0, 0.0]       # [x (m), y (m), yaw (rad)] in map frame
  "kitchen": [2.5, -1.2, 1.57]
```

### Systemd User Service (Auto-Start on Boot)
Edit `robot_node/systemd/robot-stream.service` if you want `profile:=nav2_standard` (the checked-in unit runs the default profile), then install without `sudo`:

```bash
bash ~/robot_stream/scripts/install_autostart.sh
systemctl --user status robot-stream
tail -f ~/robot_stream/stream.log
```

To remove the service:
```bash
systemctl --user disable --now robot-stream && rm ~/.config/systemd/user/robot-stream.service
```

---

## Wheeltec R550 Reference & Remote Deploy

If you develop on a separate workstation (e.g., macOS/Linux) and deploy to a Wheeltec R550 over SSH:

```bash
robot_node/scripts/deploy.sh <ssh-host>
```

The `wheeltec_r550` profile binds MediaMTX ICE candidates to `wlP1p1s0`, connects to the vendor's existing rosbridge on `:9090` (`start_rosbridge: false`), and integrates with `semantic_nav` (`/odom_combined`, `/parsed_commands`, `/semantic_nav_mode`).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| WebRTC stays on `Connecting…` on a robot with Docker or multiple NICs | MediaMTX advertises unreachable ICE candidates (e.g. `docker0`, `l4tbr0`). | Restrict MediaMTX to your Wi-Fi interface: set `webrtc_interfaces: wlan0` (your interface from `ip -4 -o addr`) in your profile YAML, or run with `MTX_WEBRTCIPSFROMINTERFACESLIST=wlan0`. |
| `rosbridge_server` fails to bind port `9090` | Another `rosbridge_server` is already running on the robot. | Set `start_rosbridge: false` in a custom profile YAML and point `rosbridge_guard` at the existing `:9090`. |
| `0 frames` received by `stream_node` | Wrong `source_topic` or QoS mismatch, or node started before Wi-Fi had an IP. | Check `ros2 topic list` and pass `source_topic:=/your/topic`. Verify `qos:=auto` (or explicitly set `qos:=best_effort` / `qos:=reliable`). |
| `Exec format error` when launching MediaMTX | Wrong MediaMTX binary architecture copied between hosts. | Re-run `bash robot_node/scripts/install_mediamtx.sh` directly on the target robot. |
| High latency or jitter on Android clients | Android Wi-Fi power saving batches incoming UDP packets. | Use `WhepSource(holdLowLatencyWifi: true)` (enabled by default in `robot_stream_webrtc`). |
