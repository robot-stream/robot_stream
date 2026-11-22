package com.robotstream.robot_stream_webrtc

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Holds Android Wi-Fi in low-latency mode while viewing a WebRTC stream.
 *
 * Wi-Fi power saving batches incoming packets, causing libwebrtc to expand its
 * jitter buffer. WIFI_MODE_FULL_LOW_LATENCY is reference-counted per WhepSource
 * and automatically restricted to foreground active sessions by Android.
 */
class RobotStreamWebrtcPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "robot_stream_webrtc/wifi")
        channel.setMethodCallHandler(this)
        val wifi = binding.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        wifiLock = wifi.createWifiLock(mode, "robot_stream_webrtc").apply { setReferenceCounted(true) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val lock = wifiLock ?: return result.success(false)
        when (call.method) {
            "acquire" -> {
                lock.acquire()
                result.success(true)
            }
            "release" -> {
                if (lock.isHeld) lock.release()
                result.success(lock.isHeld)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        wifiLock?.let { while (it.isHeld) it.release() }
        wifiLock = null
    }
}
