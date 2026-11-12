import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:native_imaging/native_imaging.dart';

import '../services/browser.dart';
import '../services/places.dart';
import '../services/subject.dart';
import '../theme.dart';

/// Edits a picture on this PC, as Windows Photos does: crops, turns and
/// flips it, adjusts its light and colour, filters it, and changes its
/// background (blurred, removed, or a colour of the user's); then saves it
/// in its place or as a copy. Pops with what to tell the user, or null.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.browser, required this.picture});

  final Browser browser;
  final LocalPicture picture;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

/// The editor's tabs.
enum _Tool {
  crop('Crop', Icons.crop_rotate_rounded),
  adjust('Adjustment', Icons.tune_rounded),
  filter('Filter', Icons.auto_awesome_outlined),
  background('Background', Icons.wallpaper_rounded);

  const _Tool(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// The crop's shapes: none, the picture's own, or width to height.
enum _Aspect {
  free('Free'),
  original('Original'),
  square('Square'),
  fourThree('4:3'),
  sixteenNine('16:9');

  const _Aspect(this.label);

  final String label;
}

/// A filter: a look laid over the picture's adjustments, at an intensity.
class _Filter {
  const _Filter(this.name, this.look);

  final String name;
  final Look look;
}

const _filters = [
  _Filter('Original', Look.none),
  _Filter('Vivid', Look(contrast: 0.2, saturation: 0.35)),
  _Filter('Punch', Look(contrast: 0.35, saturation: 0.2, shadows: -0.1, vignette: 0.15)),
  _Filter('Warm', Look(warmth: 0.35, saturation: 0.05)),
  _Filter('Cool', Look(warmth: -0.3, tint: 0.05)),
  _Filter('Golden', Look(warmth: 0.45, highlights: -0.1, contrast: 0.1, saturation: 0.1)),
  _Filter('Calm', Look(contrast: -0.2, saturation: -0.25, fade: 0.15)),
  _Filter('Film', Look(fade: 0.3, contrast: -0.1, saturation: -0.15, warmth: 0.1)),
  _Filter('Dramatic', Look(contrast: 0.45, highlights: -0.3, shadows: -0.2, saturation: -0.2, vignette: 0.35)),
  _Filter('Mono', Look(mono: 1, contrast: 0.2)),
  _Filter('Noir', Look(mono: 1, contrast: 0.5, shadows: -0.2, vignette: 0.3)),
  _Filter('Sepia', Look(mono: 1, warmth: 0.8, fade: 0.1)),
];

const _full = Rect.fromLTWH(0, 0, 1, 1);

/// The side panel's width.
const _panelWidth = 320.0;

class _EditorScreenState extends State<EditorScreen> {
  var _tool = _Tool.crop;

  /// Quarter turns clockwise, 0 to 3.
  var _turns = 0;
  var _flip = false;

  /// The crop, as fractions of the picture as it's shown (turned, flipped).
  var _crop = _full;
  var _aspect = _Aspect.free;

  /// The light and colour adjustments, and the filter over them.
  var _adjust = Look.none;
  var _filter = _filters.first;
  var _filterAmount = 1.0;

  /// What's done to the background, and the colour it's replaced with.
  var _background = BackgroundEffect.none;
  var _backgroundColor = Colors.white;

  /// How far a blur spreads, as a fraction of the picture's longest side.
  var _blurSpread = defaultBlurSpread;

  /// Where the subject is: found the first time a background's chosen, and
  /// as an image, for the preview.
  SubjectMask? _mask;
  ui.Image? _maskImage;
  var _findingSubject = false;

  /// The shader the preview's adjusted and filtered with; null until it's
  /// loaded (or if it can't be: then the preview's as it was).
  ui.FragmentProgram? _lookProgram;

  /// The picture's size, upright; null until it's been read.
  (int, int)? _size;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    widget.picture.info().then((info) {
      if (mounted) setState(() => _size = info.dimensions ?? (1, 1));
    });
    ui.FragmentProgram.fromAsset('shaders/look.frag').then((program) {
      if (mounted) setState(() => _lookProgram = program);
    }, onError: (Object _) {});
  }

  @override
  void dispose() {
    _maskImage?.dispose();
    super.dispose();
  }

  /// The adjustments with the filter over them: what's saved.
  Look get _look => _adjust.plus(_filter.look, _filterAmount);

  bool get _changed => _turns != 0 || _flip || _crop != _full || _background != BackgroundEffect.none || !_look.isNone;

  /// The picture's size as shown, turned.
  Size get _shown {
    final (width, height) = _size ?? (1, 1);
    return _turns.isOdd ? Size(height.toDouble(), width.toDouble()) : Size(width.toDouble(), height.toDouble());
  }

  /// The crop's width to height in pixels, or null for any.
  double? get _ratio {
    final shown = _shown;
    final landscape = shown.width >= shown.height;
    return switch (_aspect) {
      _Aspect.free => null,
      _Aspect.original => shown.width / shown.height,
      _Aspect.square => 1,
      // Turned to match the picture: 3:4 for a portrait one.
      _Aspect.fourThree => landscape ? 4 / 3 : 3 / 4,
      _Aspect.sixteenNine => landscape ? 16 / 9 : 9 / 16,
    };
  }

  /// [_ratio], as fractions of the picture's width and height.
  double? get _fractionRatio => _ratio == null ? null : _ratio! * _shown.height / _shown.width;

  /// The biggest crop of the chosen shape, in the middle.
  Rect _fitted() {
    final ratio = _fractionRatio;
    if (ratio == null) return _full;
    final (width, height) = ratio >= 1 ? (1.0, 1 / ratio) : (ratio, 1.0);
    return Rect.fromLTWH((1 - width) / 2, (1 - height) / 2, width, height);
  }

  void _rotate(int by) => setState(() {
    _turns = (_turns + by) % 4;
    _crop = _fitted();
  });

  void _toggleFlip() => setState(() {
    _flip = !_flip;
    _crop = Rect.fromLTWH(1 - _crop.right, _crop.top, _crop.width, _crop.height);
  });

  void _setAspect(_Aspect aspect) => setState(() {
    _aspect = aspect;
    _crop = _fitted();
  });

  void _reset() => setState(() {
    _turns = 0;
    _flip = false;
    _aspect = _Aspect.free;
    _crop = _full;
    _adjust = Look.none;
    _filter = _filters.first;
    _filterAmount = 1;
    _background = BackgroundEffect.none;
    _blurSpread = defaultBlurSpread;
  });

  /// Blurs, removes or replaces the background: finding the subject first,
  /// the first time.
  Future<void> _setBackground(BackgroundEffect effect, {Color? color}) async {
    if (effect != BackgroundEffect.none && _mask == null) {
      if (_findingSubject) return;
      setState(() => _findingSubject = true);
      try {
        // On a PC, IS-Net; on a phone, Google's ML Kit.
        final mask = await findSubject(widget.picture);
        final image = await subjectImage(mask);
        if (!mounted) {
          image.dispose();
          return;
        }
        _mask = mask;
        _maskImage = image;
      } on Object catch (e) {
        if (!mounted) return;
        setState(() => _findingSubject = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(whyNoSubject(e))));
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _findingSubject = false;
      _background = effect;
      if (color != null) _backgroundColor = color;
    });
  }

  Future<void> _chooseBackgroundColor() async {
    final color = await showDialog<Color>(
      context: context,
      builder: (context) => _ColorDialog(initial: _backgroundColor),
    );
    if (color != null) await _setBackground(BackgroundEffect.replace, color: color);
  }

  Future<void> _save({required bool asCopy}) async {
    if (_saving || !_changed || _findingSubject) return;
    setState(() => _saving = true);
    final message = await widget.browser.saveEdit(
      widget.picture,
      quarterTurns: _turns,
      flip: _flip,
      crop: (_crop.left, _crop.top, _crop.width, _crop.height),
      asCopy: asCopy,
      background: _background,
      backgroundColor: _backgroundColor.toARGB32() & 0xFFFFFF,
      blurSpread: _blurSpread,
      mask: _mask,
      look: _look,
    );
    if (!mounted) return;
    if (message == null) {
      setState(() => _saving = false); // cancelled: still editing
    } else {
      Navigator.pop(context, message);
    }
  }

  Future<void> _close() async {
    if (_changed && !_saving) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard your changes?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep editing')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
          ],
        ),
      );
      if (discard != true) return;
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final replaceable = Browser.canReplace(widget.picture, background: _background);
    final copyFormat = _background == BackgroundEffect.remove ? 'PNG' : 'JPEG';
    // A phone, upright: the panel under the picture rather than beside it.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final canSave = _changed && !_saving;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _close,
          const SingleActivator(LogicalKeyboardKey.keyR): () => _rotate(1),
          const SingleActivator(LogicalKeyboardKey.keyR, shift: true): () => _rotate(3),
          const SingleActivator(LogicalKeyboardKey.keyF): _toggleFlip,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => _save(asCopy: !replaceable),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              leading: IconButton(tooltip: 'Close (Esc)', icon: const Icon(Icons.close_rounded), onPressed: _close),
              title: Text(widget.picture.name, overflow: TextOverflow.ellipsis),
              actions: [
                if (_saving)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                if (narrow) ...[
                  IconButton(
                    tooltip: 'Reset',
                    icon: const Icon(Icons.restart_alt_rounded),
                    onPressed: canSave ? _reset : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 4, right: 12),
                    child: FilledButton(
                      onPressed: canSave ? () => _save(asCopy: !replaceable) : null,
                      child: Text(replaceable ? 'Save' : 'Save copy'),
                    ),
                  ),
                ] else ...[
                  TextButton(onPressed: _changed && !_saving ? _reset : null, child: const Text('Reset')),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _changed && !_saving ? () => _save(asCopy: true) : null,
                    child: Text(replaceable ? 'Save a copy' : 'Save a copy ($copyFormat)'),
                  ),
                  if (replaceable)
                    Padding(
                      padding: const EdgeInsets.only(left: 8, right: 16),
                      child: FilledButton(
                        onPressed: _changed && !_saving ? () => _save(asCopy: false) : null,
                        child: const Text('Save'),
                      ),
                    )
                  else
                    const SizedBox(width: 16),
                ],
              ],
            ),
            body: narrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 0), child: _tabs(compact: true)),
                      Expanded(child: _canvas()),
                      SizedBox(
                        height: (MediaQuery.sizeOf(context).height * 0.38).clamp(240, 360),
                        child: Material(color: AppColors.surface, child: _panel()),
                      ),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            Padding(padding: const EdgeInsets.only(top: 8), child: _tabs()),
                            Expanded(child: _canvas()),
                          ],
                        ),
                      ),
                      // Material, so the tiles' highlights and ripples show on it.
                      SizedBox(
                        width: _panelWidth,
                        child: Material(color: AppColors.surface, child: _panel()),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  /// The tabs; [compact] (on a phone), as icons, their names as tooltips.
  Widget _tabs({bool compact = false}) => SegmentedButton<_Tool>(
    segments: [
      for (final tool in _Tool.values)
        ButtonSegment(
          value: tool,
          icon: Icon(tool.icon),
          label: compact ? null : Text(tool.label),
          tooltip: compact ? tool.label : null,
        ),
    ],
    selected: {_tool},
    showSelectedIcon: false,
    onSelectionChanged: (selected) => setState(() => _tool = selected.single),
  );

  /// The picture as it'll be saved, upright and then turned and flipped:
  /// adjusted, filtered, its background changed.
  Widget _picture() => Transform.flip(
    flipX: _flip,
    child: RotatedBox(
      quarterTurns: _turns,
      child: _BackgroundPreview(
        image: widget.picture.image(2560),
        look: _look,
        program: _lookProgram,
        effect: _background,
        color: _backgroundColor,
        blurSpread: _blurSpread,
        mask: _maskImage,
      ),
    ),
  );

  Widget _canvas() {
    if (_size == null) return const Center(child: CircularProgressIndicator());
    final cropping = _tool == _Tool.crop;
    return Padding(
      // Room around the picture for the crop's handles.
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? (cropping ? 20 : 8) : (cropping ? 32 : 24)),
      child: LayoutBuilder(
        builder: (context, area) {
          final Widget shown;
          if (cropping) {
            // The whole picture, the crop over it.
            final fitted = applyBoxFit(BoxFit.contain, _shown, area.biggest).destination;
            shown = SizedBox.fromSize(
              size: fitted,
              child: Stack(
                children: [
                  Positioned.fill(child: _picture()),
                  Positioned.fill(
                    child: _CropOverlay(
                      crop: _crop,
                      ratio: _fractionRatio,
                      onChanged: (crop) => setState(() => _crop = crop),
                    ),
                  ),
                ],
              ),
            );
          } else {
            // Only what's kept, as big as it'll go.
            final kept = Size(_shown.width * _crop.width, _shown.height * _crop.height);
            final fitted = applyBoxFit(BoxFit.contain, kept, area.biggest).destination;
            final whole = Size(fitted.width / _crop.width, fitted.height / _crop.height);
            shown = SizedBox.fromSize(
              size: fitted,
              child: ClipRect(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: -_crop.left * whole.width,
                      top: -_crop.top * whole.height,
                      width: whole.width,
                      height: whole.height,
                      child: _picture(),
                    ),
                  ],
                ),
              ),
            );
          }
          return Stack(
            alignment: Alignment.center,
            children: [
              shown,
              if (_findingSubject)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 16),
                        Text('Finding the subject…', style: Theme.of(context).textTheme.bodyLarge),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// The chosen tab's settings.
  Widget _panel() => switch (_tool) {
    _Tool.crop => _cropPanel(),
    _Tool.adjust => _adjustPanel(),
    _Tool.filter => _filterPanel(),
    _Tool.background => _backgroundPanel(),
  };

  Widget _cropPanel() {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Rotate and flip', style: text.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            IconButton(
              tooltip: 'Rotate left (Shift+R)',
              icon: const Icon(Icons.rotate_left_rounded),
              onPressed: () => _rotate(3),
            ),
            IconButton(
              tooltip: 'Rotate right (R)',
              icon: const Icon(Icons.rotate_right_rounded),
              onPressed: () => _rotate(1),
            ),
            IconButton(tooltip: 'Flip (F)', icon: const Icon(Icons.flip_rounded), onPressed: _toggleFlip),
          ],
        ),
        const SizedBox(height: 20),
        Text('Aspect ratio', style: text.titleSmall),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final aspect in _Aspect.values)
              ChoiceChip(label: Text(aspect.label), selected: _aspect == aspect, onSelected: (_) => _setAspect(aspect)),
          ],
        ),
      ],
    );
  }

  Widget _adjustPanel() {
    Widget slider(String label, double value, Look Function(double value) changed) => _LookSlider(
      label: label,
      value: value,
      onChanged: _saving ? null : (value) => setState(() => _adjust = changed(value)),
    );
    final a = _adjust;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      children: [
        _SectionHeader(
          'Light',
          onReset:
              a.exposure != 0 ||
                  a.brightness != 0 ||
                  a.contrast != 0 ||
                  a.highlights != 0 ||
                  a.shadows != 0 ||
                  a.vignette != 0
              ? () => setState(
                  () => _adjust = a.copyWith(
                    exposure: 0,
                    brightness: 0,
                    contrast: 0,
                    highlights: 0,
                    shadows: 0,
                    vignette: 0,
                  ),
                )
              : null,
        ),
        slider('Brightness', a.brightness, (v) => _adjust.copyWith(brightness: v)),
        slider('Exposure', a.exposure, (v) => _adjust.copyWith(exposure: v)),
        slider('Contrast', a.contrast, (v) => _adjust.copyWith(contrast: v)),
        slider('Highlights', a.highlights, (v) => _adjust.copyWith(highlights: v)),
        slider('Shadows', a.shadows, (v) => _adjust.copyWith(shadows: v)),
        slider('Vignette', a.vignette, (v) => _adjust.copyWith(vignette: v)),
        const SizedBox(height: 16),
        _SectionHeader(
          'Color',
          onReset: a.saturation != 0 || a.warmth != 0 || a.tint != 0
              ? () => setState(() => _adjust = a.copyWith(saturation: 0, warmth: 0, tint: 0))
              : null,
        ),
        slider('Saturation', a.saturation, (v) => _adjust.copyWith(saturation: v)),
        slider('Warmth', a.warmth, (v) => _adjust.copyWith(warmth: v)),
        slider('Tint', a.tint, (v) => _adjust.copyWith(tint: v)),
      ],
    );
  }

  Widget _filterPanel() {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              // On a phone, smaller, as the panel's shorter.
              crossAxisCount: MediaQuery.sizeOf(context).width < 600 ? 4 : 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 10,
              childAspectRatio: 0.78,
            ),
            itemCount: _filters.length,
            itemBuilder: (context, i) {
              final filter = _filters[i];
              final selected = filter == _filter;
              return Semantics(
                button: true,
                selected: selected,
                label: '${filter.name} filter',
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.art),
                  onTap: _saving
                      ? null
                      : () => setState(() {
                          _filter = filter;
                          _filterAmount = 1;
                        }),
                  child: Column(
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(AppRadius.art),
                            border: Border.all(color: selected ? AppColors.accent : Colors.transparent, width: 2),
                          ),
                          padding: const EdgeInsets.all(2),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(AppRadius.art - 2),
                            child: Transform.flip(
                              flipX: _flip,
                              child: RotatedBox(
                                quarterTurns: _turns,
                                child: _LookImage(
                                  image: widget.picture.thumbnail(256),
                                  look: _adjust.plus(filter.look),
                                  program: _lookProgram,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(filter.name, style: text.bodySmall?.copyWith(color: selected ? AppColors.accent : null)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (_filter != _filters.first)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: _LookSlider(
              label: 'Intensity',
              value: _filterAmount,
              min: 0,
              onChanged: _saving ? null : (value) => setState(() => _filterAmount = value),
            ),
          ),
      ],
    );
  }

  Widget _backgroundPanel() {
    final busy = _findingSubject || _saving;
    Widget choice(BackgroundEffect effect, IconData icon, String label, VoidCallback onTap) => ListTile(
      leading: Icon(icon),
      title: Text(label),
      selected: _background == effect,
      selectedTileColor: AppColors.accentSoft,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.art)),
      enabled: !busy,
      onTap: onTap,
    );
    const least = 0.003, most = 0.04;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text(
            'The subject is found for you; what\'s behind it can be blurred, turned black and white, removed or replaced.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        choice(BackgroundEffect.none, Icons.image_outlined, 'Original', () => _setBackground(BackgroundEffect.none)),
        choice(BackgroundEffect.blur, Icons.blur_on_rounded, 'Blur', () => _setBackground(BackgroundEffect.blur)),
        choice(
          BackgroundEffect.colorPop,
          Icons.invert_colors_rounded,
          'Colour pop',
          () => _setBackground(BackgroundEffect.colorPop),
        ),
        if (_background == BackgroundEffect.blur)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 8),
            child: _LookSlider(
              label: 'Blur intensity',
              value: (_blurSpread - least) / (most - least),
              min: 0,
              onChanged: _saving ? null : (value) => setState(() => _blurSpread = least + value * (most - least)),
            ),
          ),
        choice(
          BackgroundEffect.remove,
          Icons.layers_clear_outlined,
          'Remove',
          () => _setBackground(BackgroundEffect.remove),
        ),
        choice(
          BackgroundEffect.replace,
          Icons.format_color_fill_rounded,
          'Replace with a colour',
          _background == BackgroundEffect.replace
              ? _chooseBackgroundColor
              : () => _setBackground(BackgroundEffect.replace),
        ),
        if (_background == BackgroundEffect.replace)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _backgroundColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.outline),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(onPressed: busy ? null : _chooseBackgroundColor, child: const Text('Change colour…')),
              ],
            ),
          ),
      ],
    );
  }
}

/// A section's title in the side panel, with a way to put it back as it was.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {required this.onReset});

  final String title;

  /// Null when there's nothing to put back.
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
      TextButton(onPressed: onReset, child: const Text('Reset')),
    ],
  );
}

/// A setting from [min] (-1, or 0) to 1, shown as -100 to 100 (or 0 to 100);
/// a double-click puts it back to 0 (or for one from 0, all the way).
class _LookSlider extends StatelessWidget {
  const _LookSlider({required this.label, required this.value, required this.onChanged, this.min = -1});

  final String label;
  final double value;
  final double min;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final shown = (value * 100).round();
    final rest = min < 0 ? 0.0 : 1.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Expanded(child: Text(label, style: text.bodyMedium)),
              Text(min < 0 && shown > 0 ? '+$shown' : '$shown', style: text.bodySmall),
            ],
          ),
        ),
        GestureDetector(
          onDoubleTap: onChanged == null ? null : () => onChanged!(rest),
          child: Slider(
            value: value.clamp(min, 1),
            min: min,
            max: 1,
            semanticFormatterCallback: (value) => '$label ${(value * 100).round()}',
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

/// [image] adjusted and filtered by [look] with the look shader, as saving
/// will (see shaders/look.frag); as it is while the shader's loading, or
/// when there's nothing to do.
class _LookImage extends StatefulWidget {
  const _LookImage({required this.image, required this.look, required this.program, this.fit = BoxFit.fill});

  final ImageProvider image;
  final Look look;
  final ui.FragmentProgram? program;
  final BoxFit fit;

  @override
  State<_LookImage> createState() => _LookImageState();
}

class _LookImageState extends State<_LookImage> {
  ImageStream? _stream;
  late final _listener = ImageStreamListener(
    (info, _) {
      if (!mounted) {
        info.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = info.image;
      });
    },
    // Couldn't be read: the plain Image below says so, rather than this
    // being reported as an unhandled error.
    onError: (_, _) {},
  );
  ui.Image? _image;
  ui.FragmentShader? _shader;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_LookImage old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) _resolve();
    if (old.program != widget.program) {
      _shader?.dispose();
      _shader = null;
    }
  }

  void _resolve() {
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _image?.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final program = widget.program;
    if (widget.look.isNone || image == null || program == null) {
      return Image(
        image: widget.image,
        fit: widget.fit,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image_outlined, size: 48)),
      );
    }
    final shader = _shader ??= program.fragmentShader();
    final painter = CustomPaint(painter: _LookPainter(shader, image, widget.look));
    if (widget.fit == BoxFit.fill) return painter;
    // Covering: the painter at the picture's shape, cut to the box.
    return ClipRect(
      child: FittedBox(
        fit: widget.fit,
        child: SizedBox(width: image.width.toDouble(), height: image.height.toDouble(), child: painter),
      ),
    );
  }
}

class _LookPainter extends CustomPainter {
  _LookPainter(this.shader, this.image, this.look);

  final ui.FragmentShader shader;
  final ui.Image image;
  final Look look;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height);
    for (final (i, value) in look.values.indexed) {
      shader.setFloat(2 + i, value);
    }
    shader.setImageSampler(0, image, filterQuality: FilterQuality.medium);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_LookPainter old) => old.image != image || old.look != look || old.shader != shader;
}

/// The picture with its background as it'll be saved: blurred, see-through
/// (a checkerboard behind), or a colour; adjusted and filtered first, by
/// [look]. Upright, as the subject's [mask].
class _BackgroundPreview extends StatelessWidget {
  const _BackgroundPreview({
    required this.image,
    required this.look,
    required this.program,
    required this.effect,
    required this.color,
    required this.blurSpread,
    required this.mask,
  });

  final ImageProvider image;
  final Look look;
  final ui.FragmentProgram? program;
  final BackgroundEffect effect;
  final Color color;

  /// The blur's spread, as a fraction of the picture's longest side: as
  /// saving it blurs it (see subject.cpp).
  final double blurSpread;
  final ui.Image? mask;

  @override
  Widget build(BuildContext context) {
    final picture = _LookImage(image: image, look: look, program: program);
    final mask = this.mask;
    if (effect == BackgroundEffect.none || mask == null) return picture;
    final subject = ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => ImageShader(
        mask,
        TileMode.clamp,
        TileMode.clamp,
        Matrix4.diagonal3Values(bounds.width / mask.width, bounds.height / mask.height, 1).storage,
        filterQuality: FilterQuality.medium,
      ),
      child: picture,
    );
    return LayoutBuilder(
      builder: (context, size) {
        final sigma = math.max(size.maxWidth, size.maxHeight) * blurSpread;
        final behind = switch (effect) {
          BackgroundEffect.blur => ClipRect(
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.mirror),
              child: picture,
            ),
          ),
          BackgroundEffect.remove => const CustomPaint(painter: _CheckerboardPainter()),
          BackgroundEffect.replace => ColoredBox(color: color),
          // In grey by Rec. 709's weights, as saving greys it.
          BackgroundEffect.colorPop => ColorFiltered(colorFilter: _grey, child: picture),
          BackgroundEffect.none => const SizedBox.shrink(),
        };
        return Stack(fit: StackFit.expand, children: [behind, subject]);
      },
    );
  }
}

/// A picture in black and white, as colour pop's background is.
const _grey = ColorFilter.matrix([
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0, 0, 0, 1, 0,
]);

/// Grey squares, as image editors show what's see-through.
class _CheckerboardPainter extends CustomPainter {
  const _CheckerboardPainter();

  static const _square = 10.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF3A3A3A));
    final dark = Paint()..color = const Color(0xFF262626);
    for (var y = 0; y * _square < size.height; y++) {
      for (var x = y.isOdd ? 1 : 0; x * _square < size.width; x += 2) {
        canvas.drawRect(Rect.fromLTWH(x * _square, y * _square, _square, _square), dark);
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerboardPainter oldDelegate) => false;
}

/// Picks the colour a background's replaced with: a few common ones, or
/// any by its hex code.
class _ColorDialog extends StatefulWidget {
  const _ColorDialog({required this.initial});

  final Color initial;

  @override
  State<_ColorDialog> createState() => _ColorDialogState();
}

class _ColorDialogState extends State<_ColorDialog> {
  static const _swatches = [
    Color(0xFFFFFFFF), Color(0xFFF2F2F2), Color(0xFFBDBDBD), Color(0xFF616161), Color(0xFF000000), //
    Color(0xFFE53935), Color(0xFFFB8C00), Color(0xFFFDD835), Color(0xFF43A047), Color(0xFF00897B),
    Color(0xFF1E88E5), Color(0xFF3949AB), Color(0xFF8E24AA), Color(0xFFD81B60), Color(0xFF6D4C41),
  ];

  late var _color = widget.initial;
  late final _hex = TextEditingController(text: _hexOf(widget.initial));

  static String _hexOf(Color color) => (color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  void _pick(Color color) => setState(() {
    _color = color;
    _hex.text = _hexOf(color);
  });

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Background colour'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final swatch in _swatches)
                  Semantics(
                    button: true,
                    selected: swatch.toARGB32() == _color.toARGB32(),
                    label: '#${_hexOf(swatch)}',
                    child: InkWell(
                      onTap: () => _pick(swatch),
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: swatch,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: swatch.toARGB32() == _color.toARGB32() ? AppColors.accent : AppColors.outline,
                            width: swatch.toARGB32() == _color.toARGB32() ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _color,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.outline),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _hex,
                    decoration: const InputDecoration(prefixText: '#', labelText: 'Hex code'),
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]'))],
                    onChanged: (text) {
                      if (text.length == 6) setState(() => _color = Color(0xFF000000 | int.parse(text, radix: 16)));
                    },
                    onSubmitted: (_) => Navigator.pop(context, _color),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _color), child: const Text('Use colour')),
      ],
    );
  }
}

/// What a drag on the crop moves: all of it, a corner, or a side.
enum _Grip { move, topLeft, topRight, bottomLeft, bottomRight, left, top, right, bottom }

/// The crop rectangle over the picture: the rest dimmed, with corners and
/// sides to drag, and the middle to move it by.
class _CropOverlay extends StatefulWidget {
  const _CropOverlay({required this.crop, required this.ratio, required this.onChanged});

  /// As fractions of the picture.
  final Rect crop;

  /// Width to height, as fractions of the picture's; null for any.
  final double? ratio;
  final ValueChanged<Rect> onChanged;

  @override
  State<_CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<_CropOverlay> {
  /// Smallest the crop gets, as a fraction of the picture.
  static const _min = 0.05;
  static const _cornerReach = 24.0;
  static const _sideReach = 14.0;

  _Grip? _grip;
  _Grip? _hovered;

  _Grip? _gripAt(Offset at, Size size) {
    final r = Rect.fromLTRB(
      widget.crop.left * size.width,
      widget.crop.top * size.height,
      widget.crop.right * size.width,
      widget.crop.bottom * size.height,
    );
    bool near(Offset corner) => (corner - at).distance <= _cornerReach;
    if (near(r.topLeft)) return _Grip.topLeft;
    if (near(r.topRight)) return _Grip.topRight;
    if (near(r.bottomLeft)) return _Grip.bottomLeft;
    if (near(r.bottomRight)) return _Grip.bottomRight;
    // Sides change the shape, so only for a free crop.
    if (widget.ratio == null) {
      final withinX = at.dx > r.left && at.dx < r.right;
      final withinY = at.dy > r.top && at.dy < r.bottom;
      if (withinY && (at.dx - r.left).abs() <= _sideReach) return _Grip.left;
      if (withinY && (at.dx - r.right).abs() <= _sideReach) return _Grip.right;
      if (withinX && (at.dy - r.top).abs() <= _sideReach) return _Grip.top;
      if (withinX && (at.dy - r.bottom).abs() <= _sideReach) return _Grip.bottom;
    }
    return r.contains(at) ? _Grip.move : null;
  }

  void _drag(DragUpdateDetails details, Size size) {
    final grip = _grip;
    if (grip == null) return;
    final crop = widget.crop;
    final x = (details.localPosition.dx / size.width).clamp(0.0, 1.0);
    final y = (details.localPosition.dy / size.height).clamp(0.0, 1.0);

    final Rect next;
    switch (grip) {
      case _Grip.move:
        final dx = details.delta.dx / size.width;
        final dy = details.delta.dy / size.height;
        next = crop.translate(dx.clamp(-crop.left, 1 - crop.right), dy.clamp(-crop.top, 1 - crop.bottom));
      case _Grip.left:
        next = Rect.fromLTRB(math.min(x, crop.right - _min), crop.top, crop.right, crop.bottom);
      case _Grip.right:
        next = Rect.fromLTRB(crop.left, crop.top, math.max(x, crop.left + _min), crop.bottom);
      case _Grip.top:
        next = Rect.fromLTRB(crop.left, math.min(y, crop.bottom - _min), crop.right, crop.bottom);
      case _Grip.bottom:
        next = Rect.fromLTRB(crop.left, crop.top, crop.right, math.max(y, crop.top + _min));
      case _Grip.topLeft || _Grip.topRight || _Grip.bottomLeft || _Grip.bottomRight:
        // The opposite corner stays put.
        final left = grip == _Grip.topLeft || grip == _Grip.bottomLeft;
        final top = grip == _Grip.topLeft || grip == _Grip.topRight;
        final anchorX = left ? crop.right : crop.left;
        final anchorY = top ? crop.bottom : crop.top;
        var width = ((left ? anchorX - x : x - anchorX)).clamp(_min, left ? anchorX : 1 - anchorX);
        var height = ((top ? anchorY - y : y - anchorY)).clamp(_min, top ? anchorY : 1 - anchorY);
        if (widget.ratio case final ratio?) {
          // Shrunk to the shape, so it stays inside the picture.
          if (width / height > ratio) {
            width = height * ratio;
          } else {
            height = width / ratio;
          }
        }
        next = Rect.fromLTRB(
          left ? anchorX - width : anchorX,
          top ? anchorY - height : anchorY,
          left ? anchorX : anchorX + width,
          top ? anchorY : anchorY + height,
        );
    }
    widget.onChanged(next);
  }

  MouseCursor _cursor(_Grip? grip) => switch (grip) {
    null => MouseCursor.defer,
    _Grip.move => SystemMouseCursors.move,
    _Grip.topLeft || _Grip.bottomRight => SystemMouseCursors.resizeUpLeftDownRight,
    _Grip.topRight || _Grip.bottomLeft => SystemMouseCursors.resizeUpRightDownLeft,
    _Grip.left || _Grip.right => SystemMouseCursors.resizeLeftRight,
    _Grip.top || _Grip.bottom => SystemMouseCursors.resizeUpDown,
  };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return MouseRegion(
          cursor: _cursor(_grip ?? _hovered),
          onHover: (event) {
            final grip = _gripAt(event.localPosition, size);
            if (grip != _hovered) setState(() => _hovered = grip);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (details) => setState(() => _grip = _gripAt(details.localPosition, size)),
            onPanUpdate: (details) => _drag(details, size),
            onPanEnd: (_) => setState(() => _grip = null),
            child: CustomPaint(size: size, painter: _CropPainter(widget.crop)),
          ),
        );
      },
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.crop);

  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(
      crop.left * size.width,
      crop.top * size.height,
      crop.right * size.width,
      crop.bottom * size.height,
    );
    // What's cropped away, dimmed.
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(r),
      Paint()..color = const Color(0x99000000),
    );
    // Thirds, to line things up by.
    final thirds = Paint()
      ..color = const Color(0x55FFFFFF)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = r.left + r.width * i / 3;
      final y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), thirds);
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), thirds);
    }
    canvas.drawRect(
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    // The corners' handles.
    final handle = Paint()
      ..color = AppColors.accent
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final arm = math.min(18.0, math.min(r.width, r.height) / 3);
    for (final (corner, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(corner, corner + Offset(arm * dx, 0), handle);
      canvas.drawLine(corner, corner + Offset(0, arm * dy), handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.crop != crop;
}
