Pod::Spec.new do |s|
  s.name             = 'robot_stream_webrtc'
  s.version          = '0.1.0'
  s.summary          = 'No-op macOS plugin stub for robot_stream_webrtc.'
  s.description      = <<-DESC
No-op macOS plugin stub for robot_stream_webrtc. Low-latency WifiLock is Android-only; macOS WebRTC streaming runs directly through flutter_webrtc.
                       DESC
  s.homepage         = 'https://github.com/robot-stream/robot_stream'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Dao Anh Tung' => '7088549+daoanhtung@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.14'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
