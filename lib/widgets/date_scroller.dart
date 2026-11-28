import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// A scroll bar down the grid's right-hand side, whose thumb can be dragged
/// to get a long way quickly, saying the month of the pictures it's at as it
/// goes (in Memories, the day), as a phone's gallery does. It's said while
/// the grid's scrolled any other way too, and for a moment after.
///
/// On a PC it's there whenever there's more than a screenful: a slim bar
/// that widens under the mouse, to be dragged, or clicked anywhere along to
/// jump there (the mouse wheel over it still scrolls). It stands in for the
/// scroll bar a PC's grid would otherwise have. On a phone ([compact]), a
/// handle that comes out from the edge while the grid's scrolled, to be
/// grabbed, and goes again a moment after, leaving the pictures under it to
/// tap; only where there are a few screenfuls, as there's no need for it
/// otherwise.
///
/// It runs from [topInset] down, below the grid's header (which stays put
/// at the top).
class DateScroller extends StatefulWidget {
  const DateScroller({
    super.key,
    required this.controller,
    required this.labelAt,
    required this.topInset,
    required this.compact,
    required this.child,
  });

  /// The grid's.
  final ScrollController controller;

  /// What's said of the pictures at the top of the grid, scrolled [offset]
  /// down: their heading ("March 2021"). Null for nothing to say.
  final String? Function(double offset) labelAt;

  /// How far down it starts: the height of what's pinned at the top, as last
  /// laid out.
  final double Function() topInset;

  /// On a phone: a handle that comes and goes, rather than a bar.
  final bool compact;

  /// The grid it scrolls.
  final Widget child;

  @override
  State<DateScroller> createState() => _DateScrollerState();
}

class _DateScrollerState extends State<DateScroller> {
  /// The thumb's held (dragged, or the bar's pressed).
  var _dragging = false;

  /// The mouse is over the bar.
  var _hovering = false;

  /// The grid's just been scrolled: the handle's out, and the date's said.
  var _scrolled = false;
  Timer? _quiet;

  /// Where along the thumb it's held, from its top.
  var _heldAt = 0.0;

  /// Where the bar is, and the thumb on it, as last laid out: for the
  /// pointer, which moves the thumb from there.
  ({double top, double travel, double thumbTop})? _bar;

  /// What was said last: faded out, rather than gone at once, when there's
  /// nothing more to say.
  String? _said;

  /// The thumb's height, and its width on a phone.
  static const _thumbHeight = 48.0;
  static const _handleWidth = 36.0;

  /// The width of a PC's bar, which takes the pointer.
  static const _barWidth = 16.0;

  /// How long the handle's out, and the date's said, after the grid stops.
  static const _quietAfter = Duration(milliseconds: 1200);

  ScrollPosition? get _position => widget.controller.hasClients ? widget.controller.position : null;

  @override
  void dispose() {
    _quiet?.cancel();
    super.dispose();
  }

  /// The grid's been scrolled: shown, and said, until it's been still a
  /// moment.
  bool _onScroll(ScrollNotification notification) {
    // The grid's own, not a row of chips' sideways.
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) return false;
    if (notification is ScrollUpdateNotification) {
      _quiet?.cancel();
      _quiet = Timer(_quietAfter, () {
        if (mounted) setState(() => _scrolled = false);
      });
      setState(() => _scrolled = true);
    }
    return false;
  }

  /// More pictures found, or the header grown: the thumb's somewhere else.
  bool _onMetrics(ScrollMetricsNotification notification) {
    if (notification.depth == 0) setState(() {});
    return false;
  }

  double _localY(Offset global) => (context.findRenderObject()! as RenderBox).globalToLocal(global).dy;

  /// Pressed: held where it's taken hold of on the thumb; elsewhere on a
  /// PC's bar, its middle jumps there.
  void _hold(PointerDownEvent event) {
    final bar = _bar;
    if (bar == null || event.buttons != kPrimaryButton) return;
    final y = _localY(event.position);
    final onThumb = y >= bar.thumbTop && y <= bar.thumbTop + _thumbHeight;
    _heldAt = onThumb ? y - bar.thumbTop : _thumbHeight / 2;
    setState(() => _dragging = true);
    _move(event.position);
  }

  /// Dragged: the grid's scrolled to as far down as the thumb is.
  void _move(Offset global) {
    final (position, bar) = (_position, _bar);
    if (!_dragging || position == null || bar == null) return;
    final along = bar.travel <= 0 ? 0.0 : ((_localY(global) - _heldAt - bar.top) / bar.travel).clamp(0.0, 1.0);
    position.jumpTo(along * position.maxScrollExtent);
  }

  void _letGo() {
    if (_dragging) setState(() => _dragging = false);
  }

  /// The mouse wheel over the bar scrolls the grid, as it would beside it.
  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      _position?.pointerScroll((event as PointerScrollEvent).scrollDelta.dy);
    });
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: _onMetrics,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: LayoutBuilder(builder: (context, box) => Stack(children: [widget.child, ..._scroller(box.biggest)])),
      ),
    );
  }

  List<Widget> _scroller(Size size) {
    final position = _position;
    _bar = null;
    if (position == null || !position.hasContentDimensions || !position.hasPixels) return const [];
    final extent = position.maxScrollExtent;
    // Nothing to scroll; or on a phone, too little to need it.
    if (extent <= 0 || (widget.compact && extent < position.viewportDimension * 2)) return const [];
    final top = widget.topInset().clamp(0.0, size.height);
    final bottom = MediaQuery.paddingOf(context).bottom + (widget.compact ? 8 : 4);
    // A window so short the header takes it all: no room for a thumb.
    if (size.height - top - bottom < _thumbHeight) return const [];
    final travel = math.max(0.0, size.height - top - bottom - _thumbHeight);
    final thumbTop = top + (position.pixels / extent).clamp(0.0, 1.0) * travel;
    _bar = (top: top, travel: travel, thumbTop: thumbTop);

    final speaking = _scrolled || _dragging;
    if (speaking) _said = widget.labelAt(position.pixels) ?? _said;
    final shown = !widget.compact || speaking;
    final said = _said;
    final reach = widget.compact ? _handleWidth : _barWidth;

    return [
      if (widget.compact)
        Positioned(
          top: thumbTop,
          right: 0,
          child: IgnorePointer(
            ignoring: !shown,
            child: AnimatedOpacity(
              opacity: shown ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: _pointer(_Handle(held: _dragging)),
            ),
          ),
        )
      else
        Positioned(
          top: top,
          bottom: bottom,
          right: 0,
          width: _barWidth,
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            child: _pointer(
              _Bar(thumbTop: thumbTop - top, thumbHeight: _thumbHeight, hovered: _hovering, held: _dragging),
            ),
          ),
        ),
      if (said != null)
        Positioned(
          top: thumbTop,
          height: _thumbHeight,
          right: reach + 8,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: speaking ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Align(alignment: Alignment.centerRight, child: _Bubble(said)),
            ),
          ),
        ),
    ];
  }

  /// [child], taking the pointer: pressed and dragged, at once (not waiting
  /// to see if it's a tap), and the grid beneath it not.
  Widget _pointer(Widget child) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: _hold,
    onPointerMove: (event) => _move(event.position),
    onPointerUp: (_) => _letGo(),
    onPointerCancel: (_) => _letGo(),
    onPointerSignal: _wheel,
    child: child,
  );
}

/// A PC's bar: a slim thumb, wider under the mouse and while it's held, on a
/// track that shows under the mouse.
class _Bar extends StatelessWidget {
  const _Bar({required this.thumbTop, required this.thumbHeight, required this.hovered, required this.held});

  final double thumbTop;
  final double thumbHeight;
  final bool hovered;
  final bool held;

  @override
  Widget build(BuildContext context) {
    final wide = hovered || held;
    return Stack(
      children: [
        if (wide)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(color: AppColors.hover, borderRadius: BorderRadius.circular(8)),
            ),
          ),
        Positioned(
          top: thumbTop,
          right: 3,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: wide ? 10 : 6,
            height: thumbHeight,
            decoration: BoxDecoration(
              color: held
                  ? AppColors.accent
                  : hovered
                  ? AppColors.textSecondary
                  : AppColors.textTertiary,
              borderRadius: BorderRadius.circular(5),
            ),
          ),
        ),
      ],
    );
  }
}

/// A phone's handle, out from the right-hand edge.
class _Handle extends StatelessWidget {
  const _Handle({required this.held});

  final bool held;

  @override
  Widget build(BuildContext context) => Container(
    width: _DateScrollerState._handleWidth,
    height: _DateScrollerState._thumbHeight,
    decoration: BoxDecoration(
      color: held ? AppColors.accent : AppColors.surfaceHigh,
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(24)),
      boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 6)],
    ),
    child: Icon(Icons.unfold_more_rounded, size: 22, color: held ? AppColors.onAccent : Colors.white),
  );
}

/// The month (or day) beside the thumb: "March 2021".
class _Bubble extends StatelessWidget {
  const _Bubble(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(AppRadius.large),
      border: Border.all(color: AppColors.outline),
      boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 8)],
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        label,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white),
      ),
    ),
  );
}
