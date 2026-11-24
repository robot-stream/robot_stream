## 0.1.1

- Translated all `WhepSignaling` and `WhepSource` error messages from Vietnamese to English.

## 0.1.0

- Initial release of `robot_stream_webrtc`.
- `WhepSignaling` (pure-HTTP WHEP client with optional SHA-256 TLS pinning) and `WhepSource` implementing `VideoSource` over `flutter_webrtc` with ICE gathering timeout, session `DELETE` teardown, reconnect backoff, stall detection, and per-window WebRTC stats.
- `RobotVideoView` Flutter widget, `mediamtxWhepUri` / `mediamtxCredential` helpers, and Android low-latency `WifiLock` plugin (`LowLatencyWifi`) with iOS and macOS no-op stubs.
