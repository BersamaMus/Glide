import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/places.dart';
import '../services/subject.dart';
import 'picture_grid.dart' show UndecodableImage;

/// A picture brought to life: its subject lifted off what's behind it, the
/// two moving apart as the mouse moves over it (on a phone, swaying by
/// itself, and with a finger), as if seen in 3D. The subject's found first,
/// as for the editor's Background; behind it, the picture blurred, so the
/// gap the subject leaves as it moves isn't a copy of it.
class WigglePicture extends StatefulWidget {
  const WigglePicture({super.key, required this.picture, this.sway = false});

  final LocalPicture picture;

  /// Moving by itself, gently, rather than only with the pointer.
  final bool sway;

  @override
  State<WigglePicture> createState() => _WigglePictureState();
}

class _WigglePictureState extends State<WigglePicture> with SingleTickerProviderStateMixin {
  ui.Image? _mask;
  String? _error;

  /// Where the pointer is, from -1 to 1 across and down; and where the
  /// picture's leaning, eased towards it.
  var _aim = Offset.zero;
  var _lean = Offset.zero;
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    // Ticking only once there's something to move, and only while it moves:
    // left still, no frames are asked for.
    _ticker = createTicker(_tick);
    findSubject(widget.picture).then(subjectImage).then(
      (mask) {
        if (mounted) {
          setState(() => _mask = mask);
          _wake();
        } else {
          mask.dispose();
        }
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = whyNoSubject(e));
      },
    );
  }

  @override
  void didUpdateWidget(WigglePicture old) {
    super.didUpdateWidget(old);
    if (widget.sway) _wake();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _mask?.dispose();
    super.dispose();
  }

  void _tick(Duration now) {
    final step = (now - _last).inMicroseconds / 1e6;
    _last = now;
    var aim = _aim;
    if (widget.sway) {
      // A slow figure of eight, when it's left alone.
      final t = now.inMicroseconds / 1e6;
      aim += Offset(math.sin(t * 0.9) * 0.8, math.sin(t * 1.8) * 0.35);
    }
    // Settled where it's aimed, and not swaying: still until it's moved.
    if (!widget.sway && (aim - _lean).distance < 0.001) {
      _ticker.stop();
      if (_lean != aim) setState(() => _lean = aim);
      return;
    }
    final next = Offset.lerp(_lean, aim, (step * 6).clamp(0, 1))!;
    if ((next - _lean).distance > 0.0005) setState(() => _lean = next);
  }

  /// Starts it moving again, if it's stopped and there's a subject to move.
  void _wake() {
    if (_mask == null || _ticker.isActive) return;
    _last = Duration.zero;
    _ticker.start();
  }

  void _aimAt(Offset aim) {
    _aim = aim;
    _wake();
  }

  void _point(Offset at, Size size) =>
      _aimAt(Offset((at.dx / size.width * 2 - 1).clamp(-1, 1), (at.dy / size.height * 2 - 1).clamp(-1, 1)));

  /// In place of the picture when it can't be drawn.
  Widget _failed(BuildContext context, Object error, StackTrace? _) =>
      UndecodableImage(name: widget.picture.name, error: error);

  @override
  Widget build(BuildContext context) {
    final mask = _mask;
    final image = widget.picture.image(2560);
    if (mask == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image(image: image, fit: BoxFit.contain, errorBuilder: _failed),
          Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: _error != null
                    ? Text(_error!)
                    : const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 14),
                          Text('Finding the subject…'),
                        ],
                      ),
              ),
            ),
          ),
        ],
      );
    }
    // In the picture's own shape (the mask's), as big as fits.
    return Center(
      child: AspectRatio(
        aspectRatio: mask.width / mask.height,
        child: LayoutBuilder(
          builder: (context, box) {
            final size = box.biggest;
            final reach = math.min(size.width, size.height) * 0.035;
            ImageShader shader(Rect bounds) => ImageShader(
              mask,
              TileMode.clamp,
              TileMode.clamp,
              Matrix4.diagonal3Values(bounds.width / mask.width, bounds.height / mask.height, 1).storage,
              filterQuality: FilterQuality.medium,
            );
            Widget picture() => Image(image: image, fit: BoxFit.fill, gaplessPlayback: true, errorBuilder: _failed);
            // Behind moves the other way to the subject, less, and is a
            // touch bigger, so its edges never show.
            final behind = Transform.translate(
              offset: -_lean * reach * 0.6,
              child: Transform.scale(
                scale: 1.08,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10), child: picture()),
                    // The background itself, sharp, where the subject isn't.
                    ShaderMask(blendMode: BlendMode.dstOut, shaderCallback: shader, child: picture()),
                  ],
                ),
              ),
            );
            final subject = Transform.translate(
              offset: _lean * reach,
              child: Transform.scale(
                scale: 1.1,
                child: ShaderMask(blendMode: BlendMode.dstIn, shaderCallback: shader, child: picture()),
              ),
            );
            return MouseRegion(
              onHover: (event) => _point(event.localPosition, size),
              onExit: (_) => _aimAt(Offset.zero),
              child: GestureDetector(
                onPanUpdate: (details) => _point(details.localPosition, size),
                onPanEnd: (_) => _aimAt(Offset.zero),
                child: ClipRect(child: Stack(fit: StackFit.expand, children: [behind, subject])),
              ),
            );
          },
        ),
      ),
    );
  }
}
