/// Builds an HTTP MJPEG stream URI for ROS `web_video_server`, for example
/// `http://<host>:8080/stream?topic=/camera/color/image_raw&type=mjpeg`.
///
/// Optional [quality], [width], and [height] reduce robot CPU and Wi-Fi
/// bandwidth (for example, `quality: 50, width: 640, height: 480`).
Uri webVideoServerUri({
  required String host,
  required String topic,
  int port = 8080,
  int? quality,
  int? width,
  int? height,
}) {
  final params = {
    'topic': topic,
    'type': 'mjpeg',
    if (quality != null) 'quality': '$quality',
    if (width != null) 'width': '$width',
    if (height != null) 'height': '$height',
  };
  // web_video_server does not decode `%2F` in `topic=`: keep `/` unencoded so
  // the server recognizes the ROS topic name instead of closing the stream.
  final query = params.entries
      .map(
        (e) =>
            '${e.key}=${Uri.encodeQueryComponent(e.value).replaceAll('%2F', '/')}',
      )
      .join('&');
  return Uri(
    scheme: 'http',
    host: host,
    port: port,
    path: '/stream',
    query: query,
  );
}
