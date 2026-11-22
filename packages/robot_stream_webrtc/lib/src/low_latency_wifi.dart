import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Controls an Android `WIFI_MODE_FULL_LOW_LATENCY` WifiLock via the native
/// plugin (`RobotStreamWebrtcPlugin.kt`); no-op on other platforms.
///
/// [WhepSource] calls [acquire] and [release] automatically during `connect`
/// and `dispose` when `holdLowLatencyWifi` is enabled, so applications do not
/// normally need to invoke this directly.
abstract final class LowLatencyWifi {
  static const _channel = MethodChannel('robot_stream_webrtc/wifi');

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// Acquires one reference on the Android low-latency WifiLock.
  static Future<void> acquire() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('acquire');
    } on MissingPluginException {
      // Plugin not registered (e.g. unit tests) – ignore.
    }
  }

  /// Releases one reference on the Android low-latency WifiLock.
  static Future<void> release() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('release');
    } on MissingPluginException {
      // Plugin not registered – ignore.
    }
  }
}
