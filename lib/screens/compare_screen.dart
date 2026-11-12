import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/places.dart';
import '../theme.dart';
import '../widgets/picture_grid.dart' show UndecodableImage;

/// Two pictures side by side, or one over the other with a line to drag
/// across between them: then and now, the older first. For the same place
/// or person years apart (in Memories, say), or two takes of one shot.
class CompareScreen extends StatefulWidget {
  CompareScreen({super.key, required Picture a, required Picture b})
    : then = _older(a, b) ? a : b,
      now = _older(a, b) ? b : a;

  final Picture then;
  final Picture now;

  static bool _older(Picture a, Picture b) => switch ((a.date, b.date)) {
    (final x?, final y?) => !x.isAfter(y),
    (_, null) => true,
    _ => false,
  };

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  /// Over one another, the line between them dragged across; or side by side.
  var _wipe = true;

  /// Where the line is, 0 (all now) to 1 (all then).
  var _split = 0.5;

  /// "Then · 12 Mar 2019".
  String _label(String which, Picture picture) {
    final date = picture.date;
    if (date == null) return which;
    final local = localDate(date);
    return '$which  ·  ${local.day} ${monthNames[local.month - 1].substring(0, 3)} ${local.year}';
  }

  /// "6 years apart", "3 months apart", "the same day".
  String? get _apart {
    final (a, b) = (widget.then.date, widget.now.date);
    if (a == null || b == null) return null;
    // Calendar days as the clock here showed them, not 24 hours: 23:30 and
    // 08:00 the next morning are a day apart.
    final (x, y) = (localDate(a), localDate(b));
    final days = DateTime.utc(y.year, y.month, y.day).difference(DateTime.utc(x.year, x.month, x.day)).inDays;
    if (days < 1) return 'The same day';
    if (days < 60) return '$days ${days == 1 ? 'day' : 'days'} apart';
    final months = (days / 30.44).round();
    if (months < 24) return '$months months apart';
    final years = (days / 365.25).round();
    return '$years years apart';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.maybePop(context),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => setState(() => _split = (_split - 0.05).clamp(0, 1)),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => setState(() => _split = (_split + 0.05).clamp(0, 1)),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            title: Text(_apart ?? 'Then and now'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, icon: Icon(Icons.compare_rounded), tooltip: 'Slide between them'),
                    ButtonSegment(value: false, icon: Icon(Icons.view_column_outlined), tooltip: 'Side by side'),
                  ],
                  selected: {_wipe},
                  showSelectedIcon: false,
                  onSelectionChanged: (selected) => setState(() => _wipe = selected.single),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: _wipe ? _wipeView(text) : _sideBySide(text),
          ),
        ),
      ),
    );
  }

  Widget _caption(String label, TextTheme text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(AppRadius.art)),
    child: Text(label, style: text.labelLarge?.copyWith(color: Colors.white)),
  );

  /// [picture], or, when it can't be drawn (a broken file, a missing codec),
  /// an icon saying so.
  Widget _picture(Picture picture, BoxFit fit) => Image(
    image: picture.image(2560),
    fit: fit,
    errorBuilder: (_, error, _) => UndecodableImage(name: picture.name, error: error),
  );

  /// Both filling the same box, then's on the left of the line, now's on
  /// its right.
  Widget _wipeView(TextTheme text) => LayoutBuilder(
    builder: (context, area) {
      final x = area.maxWidth * _split;
      void drag(Offset at) => setState(() => _split = (at.dx / area.maxWidth).clamp(0, 1));
      return GestureDetector(
        onPanDown: (details) => drag(details.localPosition),
        onPanUpdate: (details) => drag(details.localPosition),
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Then's filled in black where it can't be drawn, so now's
              // fallback doesn't show through it.
              _picture(widget.now, BoxFit.cover),
              ClipRect(
                clipper: _LeftOf(x),
                child: ColoredBox(color: Colors.black, child: _picture(widget.then, BoxFit.cover)),
              ),
              Positioned(
                left: x - 1.5,
                top: 0,
                bottom: 0,
                child: Container(width: 3, color: Colors.white),
              ),
              Positioned(
                left: x - 20,
                top: area.maxHeight / 2 - 20,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(blurRadius: 8, color: Colors.black45)],
                  ),
                  child: const Icon(Icons.code_rounded, color: Colors.black87),
                ),
              ),
              Positioned(left: 16, top: 16, child: _caption(_label('Then', widget.then), text)),
              Positioned(right: 16, top: 16, child: _caption(_label('Now', widget.now), text)),
            ],
          ),
        ),
      );
    },
  );

  Widget _sideBySide(TextTheme text) {
    Widget half(String which, Picture picture) => Expanded(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Expanded(child: _picture(picture, BoxFit.contain)),
            const SizedBox(height: 12),
            _caption(_label(which, picture), text),
          ],
        ),
      ),
    );
    // On a phone held upright, one above the other.
    final upright = MediaQuery.sizeOf(context).aspectRatio < 1;
    final halves = [half('Then', widget.then), half('Now', widget.now)];
    return upright ? Column(children: halves) : Row(children: halves);
  }
}

/// The part of the box left of [x].
class _LeftOf extends CustomClipper<Rect> {
  _LeftOf(this.x);

  final double x;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, x, size.height);

  @override
  bool shouldReclip(_LeftOf old) => old.x != x;
}
