## 0.1.1

- Translated all `MjpegFrameDecoder` and `MjpegSource` error messages from Vietnamese to English.

## 0.1.0

- Initial release of `robot_stream_mjpeg`.
- `MjpegSource` implementing `VideoSource` over HTTP `multipart/x-mixed-replace` streams with JPEG `FF D8`/`FF D9` framing, automatic exponential-backoff reconnect, stall detection, and live `VideoStats`.
- `MjpegView` Flutter widget and `webVideoServerUri` URI builder for ROS `web_video_server`.
