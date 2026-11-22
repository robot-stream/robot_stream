import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'mjpeg_source.dart';

/// Displays the latest JPEG frame emitted by an [MjpegSource].
///
/// This widget does not own [source]; callers manage `connect` and `dispose`.
class MjpegView extends StatelessWidget {
  /// Creates an [MjpegView] displaying frames from [source].
  const MjpegView({
    super.key,
    required this.source,
    this.fit = BoxFit.contain,
    this.placeholder,
  });

  /// Video source providing JPEG frames.
  final MjpegSource source;

  /// How the image should be inscribed into the available layout space.
  final BoxFit fit;

  /// Widget shown before the first frame arrives.
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Uint8List>(
      stream: source.frames,
      initialData: source.lastFrame,
      builder: (context, snapshot) {
        final frame = snapshot.data;
        if (frame == null) return placeholder ?? const SizedBox.expand();
        return Image.memory(
          frame,
          fit: fit,
          // Retain the previous frame while decoding the next to avoid flicker.
          gaplessPlayback: true,
        );
      },
    );
  }
}
