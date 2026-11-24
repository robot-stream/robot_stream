import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

/// Splits an MJPEG byte stream (`multipart/x-mixed-replace`) into individual
/// JPEG images.
///
/// Instead of parsing multipart headers, this decoder scans for JPEG Start of
/// Image (`FF D8`) and End of Image (`FF D9`) markers, so it works regardless
/// of boundary formatting. Inside JPEG entropy-coded data, `FF` bytes are
/// byte-stuffed with `00`, so `FF D9` only appears at the end of a frame
/// (excluding EXIF thumbnails, which `web_video_server` does not emit).
class MjpegFrameDecoder extends StreamTransformerBase<List<int>, Uint8List> {
  /// Creates an [MjpegFrameDecoder] that rejects frames larger than
  /// [maxFrameBytes].
  const MjpegFrameDecoder({this.maxFrameBytes = 8 * 1024 * 1024});

  /// Maximum buffered bytes before an image without an EOI marker is treated as
  /// a malformed stream.
  final int maxFrameBytes;

  @override
  Stream<Uint8List> bind(Stream<List<int>> stream) async* {
    final scanner = MjpegScanner(maxFrameBytes: maxFrameBytes);
    await for (final chunk in stream) {
      for (final frame in scanner.add(chunk)) {
        yield frame;
      }
    }
  }
}

/// Synchronous core of [MjpegFrameDecoder], exposed for direct testing and
/// chunk-by-chunk decoding.
class MjpegScanner {
  /// Creates an [MjpegScanner] with the given [maxFrameBytes] limit.
  MjpegScanner({this.maxFrameBytes = 8 * 1024 * 1024});

  /// Maximum allowed byte length for a single JPEG frame.
  final int maxFrameBytes;

  Uint8List _buf = Uint8List(64 * 1024);
  int _len = 0;

  /// True while `_buf` starts with SOI and is waiting for EOI.
  bool _inFrame = false;

  /// Next offset to search for EOI, avoiding rescanning previous chunks.
  int _scan = 0;

  /// Appends [chunk] and returns any complete JPEG frames extracted from it.
  List<Uint8List> add(List<int> chunk) {
    _append(chunk);
    final frames = <Uint8List>[];
    while (true) {
      if (!_inFrame) {
        final soi = _find(0xD8, 0);
        if (soi < 0) {
          // Keep trailing 0xFF: it may be the first byte of SOI.
          _discard(_len > 0 && _buf[_len - 1] == 0xFF ? _len - 1 : _len);
          break;
        }
        _discard(soi);
        _inFrame = true;
        _scan = 2;
      }
      final eoi = _find(0xD9, _scan);
      if (eoi < 0) {
        if (_len > maxFrameBytes) {
          throw FormatException(
            'JPEG end-of-image marker not found after $_len bytes — stream may not be MJPEG',
          );
        }
        _scan = math.max(2, _len - 1);
        break;
      }
      frames.add(_buf.sublist(0, eoi + 2));
      _discard(eoi + 2);
      _inFrame = false;
    }
    return frames;
  }

  /// Returns the index of the first `FF <marker>` starting at [from], or `-1`.
  int _find(int marker, int from) {
    for (var i = from; i + 1 < _len; i++) {
      if (_buf[i] == 0xFF && _buf[i + 1] == marker) return i;
    }
    return -1;
  }

  void _append(List<int> chunk) {
    final needed = _len + chunk.length;
    if (needed > _buf.length) {
      var capacity = _buf.length;
      while (capacity < needed) {
        capacity *= 2;
      }
      _buf = Uint8List(capacity)..setRange(0, _len, _buf);
    }
    _buf.setRange(_len, needed, chunk);
    _len = needed;
  }

  void _discard(int count) {
    if (count <= 0) return;
    _buf.setRange(0, _len - count, _buf, count);
    _len -= count;
  }
}
