import FlutterMacOS
import Foundation

/// No-op macOS plugin stub for `robot_stream_webrtc`.
///
/// Android uses a low-latency WifiLock via MethodChannel; macOS does not need one.
public class RobotStreamWebrtcPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}
