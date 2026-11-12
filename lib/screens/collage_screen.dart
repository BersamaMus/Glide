import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/browser.dart';
import '../services/gallery.dart';
import '../services/places.dart';
import '../theme.dart';

/// A collage of 2 to 9 pictures: laid out in rows (a few ways to choose
/// from), in a square or another shape, with room between them and their
/// corners rounded as the user likes, over a colour. Saved as a PNG in
/// Pictures (on a phone, the gallery). Pops with what to tell the user, or
/// null.
class CollageScreen extends StatefulWidget {
  const CollageScreen({super.key, required this.browser, required this.pictures});

  final Browser browser;
  final List<Picture> pictures;

  static const fewest = 2;
  static const most = 9;

  /// The ways [count] pictures can be put in rows: how many in each row.
  static List<List<int>> layoutsFor(int count) => switch (count) {
    2 => [[2], [1, 1]],
    3 => [[1, 2], [2, 1], [3], [1, 1, 1]],
    4 => [[2, 2], [1, 3], [3, 1], [4]],
    5 => [[2, 3], [3, 2], [1, 2, 2], [2, 1, 2]],
    6 => [[3, 3], [2, 2, 2], [1, 2, 3], [2, 4]],
    7 => [[3, 4], [2, 3, 2], [4, 3], [1, 3, 3]],
    8 => [[4, 4], [3, 2, 3], [2, 3, 3], [2, 2, 2, 2]],
    _ => [[3, 3, 3], [2, 3, 4], [4, 3, 2]],
  };

  /// Where each picture goes, as fractions of the collage, with [gap] (as a
  /// fraction of its longest side) between them and round them.
  static List<Rect> cells(List<int> rows, double ratio, double gap) {
    final (width, height) = ratio >= 1 ? (1.0, 1 / ratio) : (ratio, 1.0);
    final rowHeight = (height - gap * (rows.length + 1)) / rows.length;
    final cells = <Rect>[];
    for (final (r, count) in rows.indexed) {
      final cellWidth = (width - gap * (count + 1)) / count;
      for (var c = 0; c < count; c++) {
        cells.add(
          Rect.fromLTWH(
            (gap + c * (cellWidth + gap)) / width,
            (gap + r * (rowHeight + gap)) / height,
            cellWidth / width,
            rowHeight / height,
          ),
        );
      }
    }
    return cells;
  }

  @override
  State<CollageScreen> createState() => _CollageScreenState();
}

/// The collage's shapes, width to height.
enum _Shape {
  square('Square', 1),
  landscape('4:3', 4 / 3),
  portrait('3:4', 3 / 4),
  wide('16:9', 16 / 9),
  story('9:16', 9 / 16);

  const _Shape(this.label, this.ratio);

  final String label;
  final double ratio;
}

class _CollageScreenState extends State<CollageScreen> {
  late var _order = [...widget.pictures];
  var _shape = _Shape.square;
  var _layout = 0;

  /// The room between pictures and round them, and their corners' rounding,
  /// as fractions of the collage's longest side.
  var _gap = 0.012;
  var _corner = 0.01;
  var _background = Colors.white;
  var _saving = false;

  List<List<int>> get _layouts => CollageScreen.layoutsFor(_order.length);

  /// Draws the collage, [size] pixels by its shape, with each picture as
  /// [images] has it.
  void _paint(Canvas canvas, Size size, List<ui.Image?> images) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _background);
    final longest = math.max(size.width, size.height);
    final radius = Radius.circular(_corner * longest);
    for (final (i, cell) in CollageScreen.cells(_layouts[_layout % _layouts.length], _shape.ratio, _gap).indexed) {
      final rect = Rect.fromLTWH(cell.left * size.width, cell.top * size.height, cell.width * size.width, cell.height * size.height);
      final image = images[i];
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(rect, radius));
      if (image == null) {
        canvas.drawRect(rect, Paint()..color = AppColors.surfaceHigh);
      } else {
        paintImage(canvas: canvas, rect: rect, image: image, fit: BoxFit.cover, filterQuality: FilterQuality.medium);
      }
      canvas.restore();
    }
  }

  /// [picture], decoded at most [size] a side.
  Future<ui.Image> _load(Picture picture, int size) {
    final done = Completer<ui.Image>();
    final stream = picture.image(size).resolve(ImageConfiguration.empty);
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

  /// The collage's longest side, saved.
  static const _saveSize = 3000;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final images = <ui.Image>[];
    try {
      for (final picture in _order) {
        images.add(await _load(picture, 1600));
      }
      final size = _shape.ratio >= 1
          ? Size(_saveSize.toDouble(), (_saveSize / _shape.ratio).roundToDouble())
          : Size((_saveSize * _shape.ratio).roundToDouble(), _saveSize.toDouble());
      final recorder = ui.PictureRecorder();
      _paint(Canvas(recorder), size, images);
      final collage = await recorder.endRecording().toImage(size.width.toInt(), size.height.toInt());
      final png = (await collage.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      collage.dispose();
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final name = 'Collage ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}.${two(now.minute)}.${two(now.second)}.png';
      String saved;
      if (Platform.isAndroid) {
        saved = (await Gallery.saveNew(png, name)).path;
        await widget.browser.refresh();
      } else {
        saved = p.join(picturesFolder, name);
        await File(saved).writeAsBytes(png, flush: true);
        await widget.browser.madePicture(saved);
      }
      navigator.pop('Saved the collage as ${p.basename(saved)}.');
    } on Object catch (e) {
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t save the collage ($e).')));
    } finally {
      for (final image in images) {
        image.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final preview = Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: AspectRatio(
          aspectRatio: _shape.ratio,
          child: _CollagePreview(
            pictures: _order,
            paint: _paint,
            // Repainted whenever anything about it changes.
            version: Object.hash(_shape, _layout, _gap, _corner, _background, Object.hashAll(_order)),
          ),
        ),
      ),
    );
    final panel = ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Layout', style: text.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (i, rows) in _layouts.indexed)
              ChoiceChip(
                label: Text(rows.join(' · ')),
                selected: _layout % _layouts.length == i,
                onSelected: (_) => setState(() => _layout = i),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Shape', style: text.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final shape in _Shape.values)
              ChoiceChip(label: Text(shape.label), selected: _shape == shape, onSelected: (_) => setState(() => _shape = shape)),
          ],
        ),
        const SizedBox(height: 16),
        Text('Spacing', style: text.titleSmall),
        Slider(value: _gap, max: 0.04, onChanged: (value) => setState(() => _gap = value)),
        Text('Corners', style: text.titleSmall),
        Slider(value: _corner, max: 0.05, onChanged: (value) => setState(() => _corner = value)),
        Text('Background', style: text.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          children: [
            for (final color in const [Colors.white, Color(0xFFF3EDE2), Colors.black, Color(0xFF1E3A5F), AppColors.accent])
              InkWell(
                customBorder: const CircleBorder(),
                onTap: () => setState(() => _background = color),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _background == color ? AppColors.accent : AppColors.outline,
                      width: _background == color ? 3 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: () => setState(() => _order = [..._order]..shuffle()),
          icon: const Icon(Icons.shuffle_rounded),
          label: const Text('Shuffle the pictures'),
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: Text('Collage of ${_order.length}'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 16),
            child: FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
          ),
        ],
      ),
      body: narrow
          ? Column(
              children: [
                Expanded(child: preview),
                SizedBox(height: 300, child: Material(color: AppColors.surface, child: panel)),
              ],
            )
          : Row(
              children: [
                Expanded(child: preview),
                SizedBox(width: 320, child: Material(color: AppColors.surface, child: panel)),
              ],
            ),
    );
  }
}

/// The collage as it'll be saved, painted with the pictures' previews as
/// they load.
class _CollagePreview extends StatefulWidget {
  const _CollagePreview({required this.pictures, required this.paint, required this.version});

  final List<Picture> pictures;
  final void Function(Canvas canvas, Size size, List<ui.Image?> images) paint;
  final int version;

  @override
  State<_CollagePreview> createState() => _CollagePreviewState();
}

class _CollagePreviewState extends State<_CollagePreview> {
  /// Each picture's preview, by its id, as it loads.
  final _images = <String, ui.Image>{};
  final _streams = <String, (ImageStream, ImageStreamListener)>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (final picture in widget.pictures) {
      if (_streams.containsKey(picture.id)) continue;
      final stream = picture.image(1024).resolve(createLocalImageConfiguration(context));
      final listener = ImageStreamListener((info, _) {
        if (!mounted) return;
        setState(() {
          _images[picture.id]?.dispose();
          _images[picture.id] = info.image.clone();
        });
      });
      stream.addListener(listener);
      _streams[picture.id] = (stream, listener);
    }
  }

  @override
  void dispose() {
    for (final (stream, listener) in _streams.values) {
      stream.removeListener(listener);
    }
    for (final image in _images.values) {
      image.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _Painter(
      (canvas, size) => widget.paint(canvas, size, [for (final picture in widget.pictures) _images[picture.id]]),
      Object.hash(widget.version, _images.length),
    ),
  );
}

class _Painter extends CustomPainter {
  _Painter(this.draw, this.version);

  final void Function(Canvas canvas, Size size) draw;
  final int version;

  @override
  void paint(Canvas canvas, Size size) => draw(canvas, size);

  @override
  bool shouldRepaint(_Painter old) => old.version != version;
}
