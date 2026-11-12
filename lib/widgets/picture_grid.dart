import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

import '../services/browser.dart';
import '../services/places.dart';
import '../theme.dart';
import 'picture_actions.dart';

/// The middle pane: a location's pictures, newest first under a heading for
/// each month, as in Photos, below a bar with its name, how far along its
/// looking and sorting are, and (for drives and phones) chips to switch to
/// another.
///
/// Pictures are selected as in File Explorer: click, Ctrl+click, Shift+click,
/// the arrow keys (with Shift), Home and End, Ctrl+A, and Esc. Delete
/// deletes them, F2 renames, E edits.
class PictureGrid extends StatefulWidget {
  const PictureGrid({super.key, required this.browser, this.onOpen});

  final Browser browser;

  /// On a phone, where there's no preview pane beside the grid: opens the
  /// picture tapped on its own page.
  final ValueChanged<Picture>? onOpen;

  static const tileExtent = 168.0;
  static const _spacing = 8.0;
  static const _sidePadding = 20.0;

  /// Narrower than this (a phone, upright: 360 to 480 wide), the grid's
  /// laid out as a phone's gallery: see [_Metrics.phone].
  static const compactWidth = 500.0;

  @override
  State<PictureGrid> createState() => _PictureGridState();
}

class _PictureGridState extends State<PictureGrid> {
  final _focus = FocusNode(debugLabel: 'PictureGrid');
  final _scroll = ScrollController();

  final _headerKey = GlobalKey();

  /// The grid's layout, columns and row height, as last laid out.
  var _metrics = _Metrics.pc;
  var _columns = 1;
  var _rowExtent = PictureGrid.tileExtent + _Metrics.pc.captionHeight + PictureGrid._spacing;

  Browser get browser => widget.browser;

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _tap(Picture picture) {
    _focus.requestFocus();
    if (browser.picking) return browser.togglePicked(picture);
    final keys = HardwareKeyboard.instance;
    browser.click(picture, toggle: keys.isControlPressed, range: keys.isShiftPressed);
    if (widget.onOpen case final open? when !keys.isControlPressed && !keys.isShiftPressed) open(picture);
  }

  /// On a phone, a long press: starts picking pictures, or picks another.
  void _longPress(Picture picture) {
    if (widget.onOpen == null) return;
    HapticFeedback.selectionClick();
    browser.picking ? browser.togglePicked(picture) : browser.startPicking(picture);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final shift = keys.isShiftPressed;
    void move(int by) {
      browser.moveFocus(by, extend: shift);
      _reveal();
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowRight:
        move(1);
      case LogicalKeyboardKey.arrowLeft:
        move(-1);
      case LogicalKeyboardKey.arrowDown:
        browser.focusAt(_rowStep(down: true), extend: shift);
        _reveal();
      case LogicalKeyboardKey.arrowUp:
        browser.focusAt(_rowStep(down: false), extend: shift);
        _reveal();
      case LogicalKeyboardKey.home:
        browser.focusEdge(last: false, extend: shift);
        _reveal();
      case LogicalKeyboardKey.end:
        browser.focusEdge(last: true, extend: shift);
        _reveal();
      case LogicalKeyboardKey.keyA when keys.isControlPressed:
        browser.selectAll();
      case LogicalKeyboardKey.escape:
        browser.clearSelection();
      case LogicalKeyboardKey.delete when browser.canDelete:
        deleteSelection(context, browser);
      case LogicalKeyboardKey.f2 when browser.canChangeSelection && browser.selectedCount == 1:
        renameFocused(context, browser);
      case LogicalKeyboardKey.keyE when canEdit(browser):
        editFocused(context, browser);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // --- Months ---------------------------------------------------------------

  List<_Section>? _sectionsCache;
  List<Picture>? _sectionsFor;

  /// The grid's runs of pictures, one per heading the location puts them
  /// under: a month, or (in Memories) a day in a year.
  List<_Section> get _sections {
    if (identical(_sectionsFor, browser.pictures) && _sectionsCache != null) return _sectionsCache!;
    final pictures = browser.pictures;
    final location = browser.location;
    final sections = <_Section>[];
    var start = 0;
    var group = pictures.isEmpty ? 0 : location.group(pictures.first);
    for (var i = 1; i <= pictures.length; i++) {
      final next = i == pictures.length ? null : location.group(pictures[i]);
      if (next != group) {
        sections.add(_Section(pictures, start, i - start, group, location.groupLabel(group)));
        start = i;
        if (next != null) group = next;
      }
    }
    _sectionsFor = pictures;
    return _sectionsCache = sections;
  }

  /// The picture a row up or down from the focused one, in the same column
  /// where there is one; across into the next or last month's rows.
  int _rowStep({required bool down}) {
    final index = browser.focusedIndex;
    if (index == null) return 0;
    final sections = _sections;
    final s = sections.indexWhere((section) => index < section.start + section.count);
    final section = sections[s];
    final cell = index - section.start;
    final (row, column) = (cell ~/ _columns, cell % _columns);
    int at(_Section section, int row) => section.start + (row * _columns + column).clamp(0, section.count - 1);
    if (down) {
      if ((row + 1) * _columns < section.count) return at(section, row + 1);
      return s + 1 < sections.length ? at(sections[s + 1], 0) : index;
    }
    if (row > 0) return at(section, row - 1);
    if (s == 0) return index;
    final previous = sections[s - 1];
    return at(previous, (previous.count - 1) ~/ _columns);
  }

  /// Scrolls the focused picture into view.
  void _reveal() {
    final index = browser.focusedIndex;
    if (index == null || !_scroll.hasClients) return;
    final header = (_headerKey.currentContext?.findRenderObject() as RenderBox?)?.size.height ?? 0;
    var top = header;
    for (final section in _sections) {
      top += _sectionHeaderHeight;
      if (index < section.start + section.count) {
        top += ((index - section.start) ~/ _columns) * _rowExtent;
        break;
      }
      top += ((section.count + _columns - 1) ~/ _columns) * _rowExtent;
    }
    final bottom = top + _rowExtent;
    final view = _scroll.position;
    // The header and the month's heading stay at the top, over what's
    // scrolled under them: the row's to be below them.
    final covered = header + _sectionHeaderHeight;
    final double? target = top < view.pixels + covered
        ? top - covered
        : bottom > view.pixels + view.viewportDimension
        ? bottom - view.viewportDimension
        : null;
    if (target != null) {
      _scroll.jumpTo(target.clamp(0, view.maxScrollExtent));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final m = _metrics = constraints.maxWidth < PictureGrid.compactWidth ? _Metrics.phone : _Metrics.pc;
          // As SliverGridDelegateWithMaxCrossAxisExtent lays out tiles.
          final width = constraints.maxWidth - 2 * m.sidePadding;
          _columns = (width / (m.tileExtent + m.spacing)).ceil().clamp(1, 1000);
          _rowExtent = (width - m.spacing * (_columns - 1)) / _columns + m.captionHeight + m.spacing;
          return ListenableBuilder(
            listenable: browser,
            builder: (context, _) => GestureDetector(
              // A click on empty space clears the selection.
              onTap: () {
                _focus.requestFocus();
                browser.clearSelection();
              },
              behavior: HitTestBehavior.translucent,
              child: CustomScrollView(
                controller: _scroll,
                slivers: [
                  // Stays put while the pictures scroll under it.
                  PinnedHeaderSliver(
                    child: _Header(key: _headerKey, browser: browser, metrics: m),
                  ),
                  ..._content(context),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _content(BuildContext context) {
    if (browser.loading) {
      return const [SliverFillRemaining(child: Center(child: CircularProgressIndicator()))];
    }
    if (browser.error case final error?) {
      return [
        SliverFillRemaining(
          child: MessageView(icon: Icons.folder_off_outlined, text: error),
        ),
      ];
    }
    if (browser.pictures.isEmpty) {
      // Still looking, with nothing found yet: the header says so.
      if (browser.work != null) return const [];
      return [
        SliverFillRemaining(
          child: MessageView(
            icon: Icons.image_not_supported_outlined,
            text: browser.location.emptyText,
            action: switch (browser.location.emptyAction) {
              final action? => (
                label: action.label,
                onPressed: () async {
                  await action.onPressed();
                  await browser.refresh();
                },
              ),
              null => null,
            },
          ),
        ),
      ];
    }
    final focusedId = browser.focused?.id;
    final m = _metrics;
    // Decoded at about the tiles' size, so thousands of photos stay light.
    final thumbnailSize = (m.tileExtent * MediaQuery.devicePixelRatioOf(context)).round();
    return [
      // A month: its heading stays at the top, under the header, while its
      // pictures scroll, until the next month's pushes it off. Keyed by
      // month, so as months are found and put in above, each month's tiles
      // stay with their pictures (and their thumbnails keep loading) rather
      // than being handed others'. By the group, not its heading: two lots
      // of look-alikes can have the same heading ("2 alike · 3.1 MB").
      for (final section in _sections)
        SliverMainAxisGroup(
          key: ValueKey(('section', section.group)),
          slivers: [
            PinnedHeaderSliver(
              child: Container(
                height: _sectionHeaderHeight,
                color: AppColors.background,
                padding: EdgeInsets.fromLTRB(m.textIndent, 16, m.sidePadding, 0),
                child: Text(section.label, style: Theme.of(context).textTheme.titleMedium),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: m.sidePadding),
              // Built as they scroll into view: a drive can hold tens of thousands.
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: m.tileExtent,
                  mainAxisSpacing: m.spacing,
                  crossAxisSpacing: m.spacing,
                  // A square picture, with its name under it on a PC.
                  mainAxisExtent: _rowExtent - m.spacing,
                ),
                itemCount: section.count,
                // Likewise each tile, keyed by its picture.
                findChildIndexCallback: (key) => switch (key) {
                  ValueKey<String>(:final value) => section.indexOf(value),
                  _ => null,
                },
                itemBuilder: (_, i) {
                  final picture = section.pictures[section.start + i];
                  return _PictureTile(
                    key: ValueKey(picture.id),
                    picture: picture,
                    metrics: m,
                    thumbnailSize: thumbnailSize,
                    // On a phone, shown as picked only while picking: the last one
                    // opened is selected too, for the viewer.
                    selected: browser.isSelected(picture) && (!m.compact || browser.picking),
                    focused: !m.compact && picture.id == focusedId,
                    onTap: () => _tap(picture),
                    onLongPress: () => _longPress(picture),
                  );
                },
              ),
            ),
          ],
        ),
    ];
  }
}

/// The height of a month's heading.
const _sectionHeaderHeight = 48.0;

/// How the grid's laid out: on a PC, tiles with room between and their
/// names under them; on a phone, as its own gallery, square thumbnails edge
/// to edge, four or so across, without names.
class _Metrics {
  const _Metrics._(this.tileExtent, this.spacing, this.sidePadding, this.captionHeight, this.compact);

  static const pc = _Metrics._(PictureGrid.tileExtent, PictureGrid._spacing, PictureGrid._sidePadding, 26, false);
  static const phone = _Metrics._(100, 2, 0, 0, true);

  /// The widest a tile gets.
  final double tileExtent;
  final double spacing;
  final double sidePadding;

  /// The room under a tile for its name; 0 for none.
  final double captionHeight;
  final bool compact;

  /// Where the header and the months' headings start.
  double get textIndent => compact ? 16 : sidePadding + 4;
}

/// A month of the grid: [count] pictures from [start] in [pictures], under
/// [label].
class _Section {
  _Section(this.pictures, this.start, this.count, this.group, this.label);

  final List<Picture> pictures;
  final int start;
  final int count;

  /// The location's number for its heading (see [Location.group]): each
  /// section's own.
  final int group;
  final String label;

  Map<String, int>? _indexes;

  /// Where the picture [id] is in this month; null if it isn't.
  int? indexOf(String id) => (_indexes ??= {for (var i = 0; i < count; i++) pictures[start + i].id: i})[id];
}

class _Header extends StatelessWidget {
  const _Header({super.key, required this.browser, required this.metrics});

  final Browser browser;
  final _Metrics metrics;

  @override
  Widget build(BuildContext context) {
    final location = browser.location;
    final count = browser.pictures.length;
    final all = browser.total;
    final selected = browser.selectedCount;
    final text = Theme.of(context).textTheme;
    // Pinned over the pictures as they scroll: opaque, with a line under it.
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Padding(
        padding: metrics.compact
            ? EdgeInsets.fromLTRB(metrics.textIndent, 4, 0, 10)
            : EdgeInsets.fromLTRB(metrics.textIndent, 16, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // On a phone, the bar above already says where this is.
            if (!metrics.compact) Text(location.title, style: text.headlineSmall, overflow: TextOverflow.ellipsis),
            Text(
              [
                location.subtitle,
                if (count > 0 && count != all)
                  '${_thousands(count)} of ${_thousands(all)} pictures'
                else if (count > 0)
                  '${_thousands(count)} ${count == 1 ? 'picture' : 'pictures'}',
                // On a phone, the bar above says it while picking.
                if (selected > 1 && !metrics.compact) '$selected selected',
              ].join('  ·  '),
              style: text.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
            if (location.switchable) _SourceChips(browser: browser, oneRow: metrics.compact),
            _KindChips(browser: browser, oneRow: metrics.compact),
            _TypeChips(browser: browser, oneRow: metrics.compact),
            if (metrics.compact)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: _Progress(browser: browser),
              )
            else
              _Progress(browser: browser),
          ],
        ),
      ),
    );
  }
}

/// The kinds of picture there are here (JPG, PNG, GIF...), with how many of
/// each, to show only some: none chosen, all are. Only when there's more
/// than one kind to choose between.
class _TypeChips extends StatelessWidget {
  const _TypeChips({required this.browser, required this.oneRow});

  final Browser browser;

  /// In one row that scrolls sideways (on a phone), rather than wrapped.
  final bool oneRow;

  @override
  Widget build(BuildContext context) {
    final counts = browser.typeCounts;
    if (counts.length < 2 && browser.types.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: _Chips(
        oneRow: oneRow,
        spacing: 6,
        children: [
          FilterChip(
            label: const Text('All'),
            selected: browser.types.isEmpty,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => browser.showAllTypes(),
          ),
          for (final (type, count) in counts)
            FilterChip(
              label: Text('$type  ${_thousands(count)}'),
              selected: browser.types.contains(type),
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => browser.toggleType(type),
            ),
        ],
      ),
    );
  }
}

/// Photos or screenshots, with how many of each (see [pictureKind]): only
/// when there are both.
class _KindChips extends StatelessWidget {
  const _KindChips({required this.browser, required this.oneRow});

  final Browser browser;
  final bool oneRow;

  @override
  Widget build(BuildContext context) {
    final counts = browser.kindCounts;
    if (counts.length < 2 && browser.kind == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: _Chips(
        oneRow: oneRow,
        spacing: 6,
        children: [
          for (final (kind, count) in counts)
            FilterChip(
              avatar: Icon(
                kind == 'Screenshots' ? Icons.screenshot_monitor_rounded : Icons.photo_camera_outlined,
                size: 16,
              ),
              label: Text('$kind  ${_thousands(count)}'),
              selected: browser.kind == kind,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              onSelected: (on) => browser.showKind(on ? kind : null),
            ),
        ],
      ),
    );
  }
}

/// Chips wrapped onto as many rows as they need or, with [oneRow], in one
/// that scrolls sideways.
class _Chips extends StatelessWidget {
  const _Chips({required this.oneRow, required this.spacing, required this.children});

  final bool oneRow;
  final double spacing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (!oneRow) return Wrap(spacing: spacing, runSpacing: spacing, children: children);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(right: 16),
      child: Row(
        children: [
          for (final (i, chip) in children.indexed) ...[if (i > 0) SizedBox(width: spacing), chip],
        ],
      ),
    );
  }
}

/// [n] with thousands set apart: 57,821.
String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

/// How the looking and sorting are getting on: a bar that moves while
/// pictures are being found (there's no knowing how many are left), and
/// fills as they're sorted; then a tick, for a few seconds, once all's done.
class _Progress extends StatefulWidget {
  const _Progress({required this.browser});

  final Browser browser;

  @override
  State<_Progress> createState() => _ProgressState();
}

class _ProgressState extends State<_Progress> {
  /// What's said now, and how many times what's said has changed: each
  /// change fades in under a key of its own, so one that comes back while
  /// it's still fading out isn't two of the same at once.
  Key? _shown;
  var _changes = 0;

  @override
  Widget build(BuildContext context) {
    final browser = widget.browser;
    final style = Theme.of(context).textTheme.bodySmall;
    final Widget child;
    if (browser.work case final work?) {
      final count = browser.pictures.length;
      final progress = browser.progress;
      child = Column(
        key: ValueKey(work),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(switch (work) {
            Work.looking => 'Looking for pictures…  ${_thousands(count)} found so far',
            Work.sorting => 'Sorting by date taken…  ${((progress ?? 0) * 100).floor()}%',
          }, style: style),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(value: progress, minHeight: 4, backgroundColor: AppColors.surfaceHigh),
          ),
        ],
      );
    } else if (browser.finished case final finished?) {
      child = Row(
        key: const ValueKey('finished'),
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
            child: Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.check_rounded, size: 14, color: AppColors.onAccent),
            ),
          ),
          const SizedBox(width: 8),
          Text(finished, style: style?.copyWith(color: AppColors.accent)),
        ],
      );
    } else {
      child = const SizedBox.shrink(key: ValueKey('nothing'));
    }
    if (child.key != _shown) {
      _shown = child.key;
      _changes++;
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Padding(key: ValueKey((_shown, _changes)), padding: const EdgeInsets.only(top: 12), child: child),
    );
  }
}

/// The drives on this PC, or the phones connected to it, to choose whose
/// pictures to show. Looked for again every few seconds, so a USB drive or a
/// phone shows up when it's plugged in, goes when it's taken out, and opens
/// once it's unlocked.
class _SourceChips extends StatefulWidget {
  const _SourceChips({required this.browser, required this.oneRow});

  final Browser browser;

  /// In one row that scrolls sideways (on a phone), rather than wrapped.
  final bool oneRow;

  @override
  State<_SourceChips> createState() => _SourceChipsState();
}

class _SourceChipsState extends State<_SourceChips> {
  var _sources = const <Location>[];
  late final Timer _timer;
  var _looking = false;

  Browser get browser => widget.browser;

  @override
  void initState() {
    super.initState();
    _look();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _look());
  }

  Future<void> _look() async {
    if (_looking) return;
    _looking = true;
    final current = browser.location;
    List<Location> sources;
    try {
      sources = await current.sources();
    } on Object {
      sources = const [];
    } finally {
      _looking = false;
    }
    // Switched away meanwhile: this was another's.
    if (!mounted || browser.location != current) return;
    if (!listEquals(sources, _sources)) setState(() => _sources = sources);
    if (sources.contains(current)) return;
    // What's showing has gone (unplugged), or changed (a phone unlocked):
    // the same one as it is now, else another, else none.
    final instead =
        sources.where((source) => source.sameSource(current)).firstOrNull ??
        sources.firstOrNull ??
        current.withoutSources;
    if (instead != null && instead != current) await browser.open(instead);
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_sources.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _Chips(
        oneRow: widget.oneRow,
        spacing: 8,
        children: [
          for (final source in _sources)
            ChoiceChip(
              avatar: Icon(source.chipIcon, size: 18),
              label: Text(source.chipLabel),
              selected: source == browser.location,
              onSelected: (_) {
                if (source != browser.location) browser.open(source);
              },
            ),
        ],
      ),
    );
  }
}

/// A tile: a square picture with its name under it, as in Photos; on a
/// phone, just the picture, as in its gallery.
class _Tile extends StatelessWidget {
  const _Tile({
    required this.name,
    required this.metrics,
    required this.onTap,
    this.onLongPress,
    required this.child,
    this.border = BorderSide.none,
  });

  final String name;
  final _Metrics metrics;
  final VoidCallback onTap;

  /// On a phone, to start picking pictures.
  final VoidCallback? onLongPress;
  final Widget child;
  final BorderSide border;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(metrics.compact ? 2 : AppRadius.art);
    final picture = Container(
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: border == BorderSide.none ? null : Border.fromBorderSide(border),
      ),
      child: ClipRRect(borderRadius: radius, child: child),
    );
    if (metrics.captionHeight == 0) {
      return InkWell(onTap: onTap, onLongPress: onLongPress, borderRadius: radius, child: picture);
    }
    return InkWell(
      onTap: onTap,
      borderRadius: radius,
      hoverColor: AppColors.hover,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: picture),
          SizedBox(
            height: metrics.captionHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PictureTile extends StatelessWidget {
  const _PictureTile({
    super.key,
    required this.picture,
    required this.metrics,
    required this.thumbnailSize,
    required this.selected,
    required this.focused,
    required this.onTap,
    this.onLongPress,
  });

  final Picture picture;
  final _Metrics metrics;

  /// The thumbnail's longest side, in pixels.
  final int thumbnailSize;
  final bool selected;

  /// The one in the preview pane, which the arrow keys move from: outlined
  /// even when Ctrl+click has taken it out of the selection.
  final bool focused;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return _Tile(
      name: picture.name,
      metrics: metrics,
      onTap: onTap,
      onLongPress: onLongPress,
      border: selected
          ? const BorderSide(color: AppColors.accent, width: 3)
          : focused
          ? const BorderSide(color: AppColors.textSecondary, width: 1.5)
          : BorderSide.none,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: AppColors.surface,
            child: _Thumbnail(picture: picture, size: thumbnailSize),
          ),
          if (selected)
            const Positioned(
              top: 8,
              right: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
                child: Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.check_rounded, size: 16, color: AppColors.onAccent),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A tile's thumbnail. One that wasn't got for want of time (given up on
/// while the PC was busy looking through a drive, or dropped behind newer
/// asks) is asked for again while its tile's still shown, rather than
/// shown as a picture that can't be opened.
class _Thumbnail extends StatefulWidget {
  const _Thumbnail({required this.picture, required this.size});

  final Picture picture;
  final int size;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  /// Times it's been asked for again: a new [Image] each time, as the same
  /// picture's image wouldn't be looked for again otherwise.
  var _tries = 0;
  Timer? _retry;

  /// Asked for again at most this many times, a little later each time.
  static const _maxTries = 5;

  @override
  void didUpdateWidget(_Thumbnail old) {
    super.didUpdateWidget(old);
    if (old.picture.id != widget.picture.id || old.size != widget.size) {
      _retry?.cancel();
      _tries = 0;
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  Widget _failed(Object error) {
    final again = error is NativeImagingException && (error.cancelled || error.timedOut) && _tries < _maxTries;
    if (!again) return UndecodableImage(name: widget.picture.name);
    if (_retry?.isActive != true) {
      _retry = Timer(Duration(seconds: 1 << _tries), () {
        if (!mounted) return;
        // The failure's kept otherwise, and handed back as is.
        PaintingBinding.instance.imageCache.evict(widget.picture.thumbnail(widget.size));
        setState(() => _tries++);
      });
    }
    return const SizedBox.expand();
  }

  @override
  Widget build(BuildContext context) => Image(
    key: ValueKey(_tries),
    image: widget.picture.thumbnail(widget.size),
    fit: BoxFit.cover,
    errorBuilder: (_, error, _) => _failed(error),
  );
}

/// In place of a picture that couldn't be drawn (a broken file, or HEIC
/// without Windows' HEIF extension): an icon and its type.
class UndecodableImage extends StatelessWidget {
  const UndecodableImage({super.key, required this.name, this.error, this.explain = false});

  /// The file's name, for its type.
  final String name;
  final Object? error;

  /// Says why, under the icon (in the preview pane, which has the room).
  final bool explain;

  String get _reason {
    if (error case NativeImagingException(missingCodec: true)) {
      return switch (p.extension(name).toLowerCase()) {
        '.heic' || '.heif' =>
          'Windows needs the HEIF Image Extensions and HEVC Video Extensions from the Microsoft Store to show this.',
        '.avif' => 'Windows needs the AV1 Video Extension from the Microsoft Store to show this.',
        _ => 'Windows needs the Raw Image Extension from the Microsoft Store to show this.',
      };
    }
    return 'This picture couldn\'t be opened. It may be damaged.';
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_outlined, size: 40, color: AppColors.textTertiary),
            const SizedBox(height: 4),
            Text(
              p.extension(name).replaceFirst('.', '').toUpperCase(),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textTertiary),
            ),
            if (explain) ...[
              const SizedBox(height: 12),
              Text(_reason, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// A centred icon and message, for empty and failed folders.
class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;

  /// A button under the message: what can be done about it.
  final EmptyAction? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.textTertiary),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
            if (action case final action?) ...[
              const SizedBox(height: 20),
              FilledButton(onPressed: action.onPressed, child: Text(action.label)),
            ],
          ],
        ),
      ),
    );
  }
}
