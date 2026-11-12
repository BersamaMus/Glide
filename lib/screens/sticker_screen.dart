import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

import '../services/browser.dart';
import '../services/gallery.dart';
import '../services/places.dart';
import '../services/subject.dart';
import '../theme.dart';

/// A sticker of a picture's subject: cut out (found for the user, as for
/// the editor's Background), with a white outline and a soft shadow, as
/// chat apps' stickers have. Copied to the clipboard (on a PC) or shared (on
/// a phone), or saved as a PNG beside the picture. Pops with what to tell
/// the user, or null.
class StickerScreen extends StatefulWidget {
  const StickerScreen({super.key, required this.browser, required this.picture});

  final Browser browser;
  final LocalPicture picture;

  @override
  State<StickerScreen> createState() => _StickerScreenState();
}

class _StickerScreenState extends State<StickerScreen> {
  ui.Image? _picture;
  ui.Image? _silhouette;

  /// The sticker as it is now; null while it's being made.
  ui.Image? _sticker;
  String? _error;

  /// How thick the outline is, as a fraction of the sticker's longest side.
  var _outline = 0.025;
  var _shadow = true;
  var _busy = false;

  /// The picture's size the sticker's made at: crisp in a chat, not huge.
  static const _size = 1600;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _picture?.dispose();
    _silhouette?.dispose();
    _sticker?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final mask = await findSubject(widget.picture);
      final silhouette = await subjectImage(mask);
      final picture = await _load(widget.picture.image(_size));
      if (!mounted) {
        silhouette.dispose();
        picture.dispose();
        return;
      }
      _silhouette = silhouette;
      _picture = picture;
      await _make();
    } on Object catch (e) {
      if (mounted) setState(() => _error = whyNoSubject(e));
    }
  }

  /// [image], decoded.
  Future<ui.Image> _load(ImageProvider image) {
    final done = Completer<ui.Image>();
    final stream = image.resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        done.complete(info.image.clone());
      },
      onError: (error, _) {
        stream.removeListener(listener);
        done.completeError(error);
      },
    );
    stream.addListener(listener);
    return done.future;
  }

  Future<void> _make() async {
    final picture = _picture, silhouette = _silhouette;
    if (picture == null || silhouette == null) return;
    final sticker = await makeSticker(picture, silhouette, outline: _outline, shadow: _shadow);
    if (!mounted) {
      sticker.dispose();
      return;
    }
    setState(() {
      _sticker?.dispose();
      _sticker = sticker;
    });
  }

  Future<Uint8List> _png(ui.Image sticker) async =>
      (await sticker.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();

  Future<void> _copy() async {
    final sticker = _sticker;
    if (sticker == null || _busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final pixels = (await sticker.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!.buffer.asUint8List();
      await NativeImaging.copyPicture(pixels, sticker.width, sticker.height, await _png(sticker));
      messenger.showSnackBar(const SnackBar(content: Text('Sticker copied. Paste it into a chat or a document.')));
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t copy the sticker ($e).')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Saves it as a PNG: on a PC beside the picture, as "name (sticker)"; on
  /// a phone in the gallery. With [share], then shares it (on a phone).
  Future<void> _save({bool share = false}) async {
    final sticker = _sticker;
    if (sticker == null || _busy) return;
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final picture = widget.picture;
    final stem = p.basenameWithoutExtension(picture.name);
    try {
      final png = await _png(sticker);
      if (picture.galleryId != null) {
        final saved = await Gallery.saveNew(png, '$stem (sticker).png');
        await widget.browser.refresh();
        if (share) await Gallery.share([saved.id]);
        navigator.pop(share ? null : 'Saved the sticker as ${p.basename(saved.path)}.');
        return;
      }
      var path = p.join(picture.place, '$stem (sticker).png');
      for (var n = 2; await File(path).exists(); n++) {
        path = p.join(picture.place, '$stem (sticker $n).png');
      }
      await File(path).writeAsBytes(png, flush: true);
      await widget.browser.madePicture(path);
      navigator.pop('Saved the sticker as ${p.basename(path)}.');
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn\'t save the sticker ($e).')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final sticker = _sticker;
    final onPhone = widget.picture.galleryId != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sticker'),
        actions: [
          if (Platform.isWindows)
            TextButton.icon(
              onPressed: sticker == null || _busy ? null : _copy,
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy'),
            ),
          if (onPhone)
            IconButton(
              tooltip: 'Share',
              onPressed: sticker == null || _busy ? null : () => _save(share: true),
              icon: const Icon(Icons.share_outlined),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 16),
            child: FilledButton(onPressed: sticker == null || _busy ? null : _save, child: const Text('Save')),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: switch ((sticker, _error)) {
                (_, final error?) => Center(child: Text(error, textAlign: TextAlign.center)),
                (final sticker?, _) => CustomPaint(
                  painter: const _Checkerboard(),
                  child: Center(child: RawImage(image: sticker, fit: BoxFit.contain)),
                ),
                _ => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text('Finding the subject…', style: text.bodyLarge),
                    ],
                  ),
                ),
              },
            ),
          ),
          if (_error == null)
            Material(
              color: AppColors.surface,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Row(
                    children: [
                      Text('Outline', style: text.bodyMedium),
                      Expanded(
                        child: Slider(
                          value: _outline,
                          max: 0.06,
                          onChanged: sticker == null ? null : (value) => setState(() => _outline = value),
                          onChangeEnd: (_) => _make(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text('Shadow', style: text.bodyMedium),
                      Switch(
                        value: _shadow,
                        onChanged: sticker == null
                            ? null
                            : (value) {
                                setState(() => _shadow = value);
                                _make();
                              },
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A sticker of [picture]'s subject, where [silhouette] (white, see-through
/// where it's background, in the picture's shape) says it is: cut out, an
/// [outline] round it ([outline] of its longest side thick, white), with a
/// [shadow] below; trimmed to the subject, with room for both.
Future<ui.Image> makeSticker(ui.Image picture, ui.Image silhouette, {required double outline, required bool shadow}) async {
  final width = picture.width.toDouble(), height = picture.height.toDouble();
  // Where the subject is: the silhouette's opaque part, read small.
  final bounds = await _subjectBounds(silhouette) ?? const Rect.fromLTWH(0, 0, 1, 1);
  final subject = Rect.fromLTRB(bounds.left * width, bounds.top * height, bounds.right * width, bounds.bottom * height);
  final thickness = outline * math.max(subject.width, subject.height);
  final blur = shadow ? math.max(4.0, thickness * 1.2) : 0.0;
  final margin = thickness + blur * 2 + 4;
  final area = subject.inflate(margin);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.translate(-area.left, -area.top);
  final whole = Rect.fromLTWH(0, 0, width, height);
  final source = Rect.fromLTWH(0, 0, silhouette.width.toDouble(), silhouette.height.toDouble());
  void drawSilhouette(Paint paint) => canvas.drawImageRect(silhouette, source, whole, paint);

  if (shadow) {
    canvas.save();
    canvas.translate(0, blur / 2);
    drawSilhouette(
      Paint()
        ..imageFilter = ui.ImageFilter.compose(
          outer: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          inner: ui.ImageFilter.dilate(radiusX: thickness, radiusY: thickness),
        )
        ..colorFilter = const ColorFilter.mode(Color(0x59000000), BlendMode.srcIn),
    );
    canvas.restore();
  }
  if (thickness > 0.5) {
    drawSilhouette(Paint()..imageFilter = ui.ImageFilter.dilate(radiusX: thickness, radiusY: thickness));
  }
  // The subject, cut out by its silhouette.
  canvas.saveLayer(whole, Paint());
  canvas.drawImageRect(picture, whole, whole, Paint()..filterQuality = FilterQuality.medium);
  drawSilhouette(Paint()..blendMode = BlendMode.dstIn);
  canvas.restore();

  return recorder.endRecording().toImage(area.width.ceil(), area.height.ceil());
}

/// Where the subject is in [silhouette], as fractions of it: what's at
/// least half opaque. Null if there's nothing.
Future<Rect?> _subjectBounds(ui.Image silhouette) async {
  final data = await silhouette.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (data == null) return null;
  final (w, h) = (silhouette.width, silhouette.height);
  var (left, top, right, bottom) = (w, h, -1, -1);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (data.getUint8((y * w + x) * 4 + 3) < 128) continue;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  if (right < 0) return null;
  return Rect.fromLTRB(left / w, top / h, (right + 1) / w, (bottom + 1) / h);
}

/// Grey squares behind the sticker, as image editors show what's see-through.
class _Checkerboard extends CustomPainter {
  const _Checkerboard();

  @override
  void paint(Canvas canvas, Size size) {
    const square = 12.0;
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF3A3A3A));
    final dark = Paint()..color = const Color(0xFF2E2E2E);
    for (var y = 0; y * square < size.height; y++) {
      for (var x = y.isOdd ? 1 : 0; x * square < size.width; x += 2) {
        canvas.drawRect(Rect.fromLTWH(x * square, y * square, square, square), dark);
      }
    }
  }

  @override
  bool shouldRepaint(_Checkerboard oldDelegate) => false;
}
