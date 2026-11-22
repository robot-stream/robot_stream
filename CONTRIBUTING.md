# Contributing to robot_stream

Thank you for your interest in contributing to `robot_stream`!

## Prerequisites

- **Flutter** `>= 3.32.0` (with **Dart** `>= 3.8.1`)
- **Python 3** (for `robot_node/robot_stream_ros` unit tests)
- **ROS 2 Humble** (only needed if working on `robot_node/` integration on a robot or VM)

## Workspace Setup

This repository is a Dart pub workspace managed with Melos 7 (installed as a workspace dev dependency):

```bash
flutter pub get
```

## Running Checks Locally

Before opening a pull request, run static analysis and all unit tests:

```bash
dart run melos analyze
dart run melos test
```

You can also run the full offline check suite (Dart analysis, Dart/Flutter unit tests, and Python unit tests):

```bash
tools/check_all.sh static
```

To check formatting across Dart packages:

```bash
dart format --output=none --set-exit-if-changed packages apps/example
```

## Architecture Guidelines

- **`packages/robot_stream_core`**: Pure-Dart interfaces, data models, and TLS helpers. No Flutter or ROS protocol logic.
- **`packages/robot_stream_webrtc` / `packages/robot_stream_mjpeg`**: Video transport implementations and minimal display widgets.
- **`packages/robot_stream_rosbridge`**: Protocol and transport logic for rosbridge v2. Keep robot-specific topic mappings in `RosbridgeTopics` / `RobotProfile` presets rather than hardcoding them in transport logic.
- **`apps/example`**: Reference UI and manual testing tools. Do not put robot-specific IP addresses into published packages.
- **`robot_node/`**: ROS 2 gateway nodes, launch files, and robot-side scripts.

## Pull Request Checklist

- All existing tests pass and new behavior is covered by unit tests (using fake local servers for HTTP/WebSocket/WHEP logic).
- Public APIs include concise English dartdoc comments.
- No secrets, private tokens, Apple Team IDs, or personal LAN IPs are committed.
- `CHANGELOG.md` is updated for user-facing package changes.

## License

By contributing, you agree that your contributions to the Dart/Flutter packages will be licensed under the [BSD-3-Clause](LICENSE) license.
