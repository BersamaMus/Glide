import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/browser.dart';
import '../services/picture_image.dart';
import '../services/places.dart';
import '../theme.dart';
import 'picture_grid.dart';
import 'picture_actions.dart';
import 'wiggle.dart';

/// The right-hand pane: the selected picture, zoomable, with its details and
/// what can be done with it. On a phone, [PictureViewer] instead.
class PreviewPane extends StatelessWidget {
  const PreviewPane({super.key, required this.browser});

  final Browser browser;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: browser,
      builder: (context, _) {
        final picture = browser.focused;
        if (picture == null) {
          return Column(
            children: [
              const Expanded(
                child: MessageView(icon: Icons.photo_outlined, text: 'Select a picture to preview it.'),
              ),
              _Progress(browser: browser),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  child: _PreviewPicture(picture: picture),
                ),
              ),
            ),
            if (browser.selectedCount > 1) _SelectionDetails(browser: browser) else _Details(picture: picture),
            _Actions(browser: browser),
            _Progress(browser: browser),
          ],
        );
      },
    );
  }
}

/// The picture previewed: zoomable, or brought to life ([WigglePicture])
/// with the button in its corner.
class _PreviewPicture extends StatefulWidget {
  const _PreviewPicture({required this.picture});

  final Picture picture;

  @override
  State<_PreviewPicture> createState() => _PreviewPictureState();
}

class _PreviewPictureState extends State<_PreviewPicture> {
  var _alive = false;
  final _transform = TransformationController();

  /// What was last on screen, the thumbnail or the whole picture: kept up
  /// while the next picture and its thumbnail are both still to come in (or
  /// its thumbnail can't be had), rather than nothing. A spinner until
  /// there's been one, never between one picture and the next.
  ImageProvider? _lastShown;

  /// In the picture's place while neither it nor its thumbnail is in.
  Widget _meanwhile() => switch (_lastShown) {
    final last? => Image(image: last, fit: BoxFit.contain, width: double.infinity, height: double.infinity),
    null => const Center(child: CircularProgressIndicator()),
  };

  /// The picture shown whole and sharp: the one previewed, once it's been
  /// that for a moment. Until then (and while it's read and decoded, a
  /// good part of a second for a camera's photo) it's shown as its tile's
  /// thumbnail, which is there at once.
  ///
  /// Flicked through (an arrow key held down), pictures were each read and
  /// decoded whole though gone in a blink, the one stopped on waiting behind
  /// them all, and the thumbnails scrolling into view behind those.
  late Picture _sharp = widget.picture;
  Timer? _settling;

  /// Time since the picture last changed; not running until it first does,
  /// so the first change after the pane opens isn't taken for flicking.
  final _sinceChanged = Stopwatch();

  /// Changed again this soon, the pictures are being flicked through; left
  /// this long, the one stopped on is shown sharp.
  static const _flicking = Duration(milliseconds: 300);
  static const _settled = Duration(milliseconds: 120);

  @override
  void didUpdateWidget(_PreviewPicture old) {
    super.didUpdateWidget(old);
    if (old.picture.id == widget.picture.id) return;
    // Each picture starts unzoomed and still.
    _alive = false;
    _transform.value = Matrix4.identity();
    final flicking = _sinceChanged.isRunning && _sinceChanged.elapsed < _flicking;
    _sinceChanged
      ..reset()
      ..start();
    _settling?.cancel();
    if (flicking) {
      _settling = Timer(_settled, () {
        if (mounted) setState(_sharpen);
      });
    } else {
      _sharpen();
    }
  }

  void _sharpen() {
    _sharp = widget.picture;
  }

  @override
  void dispose() {
    _settling?.cancel();
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final picture = widget.picture;
    // Its tile's thumbnail, in the picture's place till that's there. (A
    // spinner till the very first is; after that, the last one stays until
    // the next is in.)
    final soft = ValueListenableBuilder(
      valueListenable: PictureGrid.thumbnailSize,
      builder: (_, size, _) {
        final thumbnail = picture.thumbnail(size);
        return Image(
          image: thumbnail,
          fit: BoxFit.contain,
          width: double.infinity,
          height: double.infinity,
          frameBuilder: (_, child, frame, wasSynchronous) {
            if (frame == null && !wasSynchronous) return _meanwhile();
            _lastShown = thumbnail;
            return child;
          },
          errorBuilder: (_, _, _) => _meanwhile(),
        );
      },
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_alive && picture is LocalPicture)
          WigglePicture(picture: picture)
        else
          InteractiveViewer(
            transformationController: _transform,
            maxScale: 8,
            child: _sharp.id != picture.id
                ? soft
                : _Plays(
                    child: Image(
                      // Big enough to zoom into, without holding a 50 MP
                      // camera photo at full size.
                      image: picture.image(_viewerSize),
                      fit: BoxFit.contain,
                      width: double.infinity,
                      height: double.infinity,
                      frameBuilder: (_, child, frame, wasSynchronous) {
                        if (frame == null && !wasSynchronous) return soft;
                        _lastShown = picture.image(_viewerSize);
                        return child;
                      },
                      errorBuilder: (_, error, _) => UndecodableImage(name: picture.name, error: error, explain: true),
                    ),
                  ),
          ),
        if (picture is LocalPicture && (Platform.isWindows || picture.galleryId != null))
          Positioned(
            top: 8,
            right: 8,
            child: IconButton.filledTonal(
              tooltip: _alive ? 'Back to the picture' : 'Bring it to life (3D)',
              isSelected: _alive,
              icon: const Icon(Icons.view_in_ar_outlined),
              selectedIcon: const Icon(Icons.view_in_ar_rounded),
              onPressed: () => setState(() => _alive = !_alive),
            ),
          ),
      ],
    );
  }
}

/// On a phone, a picture opened from the grid: full screen, swiped left and
/// right for the pictures either side, pinched or double-tapped to zoom, as
/// in its gallery. A tap hides what's over it (and Android's status bar);
/// what can be done with it is along the bottom, its details a tap on Info.
class PictureViewer extends StatefulWidget {
  const PictureViewer({super.key, required this.browser});

  final Browser browser;

  @override
  State<PictureViewer> createState() => _PictureViewerState();
}

class _PictureViewerState extends State<PictureViewer> {
  Browser get browser => widget.browser;

  /// Whether the bars over the picture are showing.
  var _bars = true;

  /// Whether the picture's brought to life (see [WigglePicture]), over the
  /// pictures to swipe between.
  var _alive = false;

  void _toggleBars() {
    setState(() => _bars = !_bars);
    SystemChrome.setEnabledSystemUIMode(_bars ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _showDetails() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (context) => ListenableBuilder(
        listenable: browser,
        builder: (context, _) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: switch (browser.focused) {
              // As tall as the details, not the sheet's most.
              final picture? => Column(
                mainAxisSize: MainAxisSize.min,
                children: [_Details(key: ValueKey(picture.id), picture: picture, alwaysExpanded: true)],
              ),
              null => const SizedBox.shrink(),
            },
          ),
        ),
      ),
    );
  }

  Future<void> _delete() async {
    await deleteSelection(context, browser);
    if (mounted && browser.pictures.isEmpty) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: browser,
        builder: (context, _) {
          final picture = browser.focused;
          if (picture == null) return const SizedBox.shrink();
          Widget bar(Widget child, {required bool top}) => IgnorePointer(
            ignoring: !_bars,
            child: AnimatedOpacity(
              opacity: _bars ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: DecoratedBox(
                // Shaded, so it reads over a bright picture.
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: top ? Alignment.topCenter : Alignment.bottomCenter,
                    end: top ? Alignment.bottomCenter : Alignment.topCenter,
                    colors: const [Color(0xB3000000), Color(0x00000000)],
                  ),
                ),
                child: SafeArea(top: top, bottom: !top, child: child),
              ),
            ),
          );
          final date = picture.date;
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                onTap: _toggleBars,
                child: _Swiper(browser: browser),
              ),
              if (_alive && picture is LocalPicture)
                GestureDetector(
                  onTap: _toggleBars,
                  child: ColoredBox(
                    color: Colors.black,
                    child: WigglePicture(key: ValueKey(picture.id), picture: picture, sway: true),
                  ),
                ),
              Align(
                alignment: Alignment.topCenter,
                child: bar(
                  top: true,
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 16, 16),
                    child: Row(
                      children: [
                        const BackButton(color: Colors.white),
                        const SizedBox(width: 4),
                        if (date != null)
                          Expanded(
                            child: Text(
                              _formatDate(context, date),
                              style: text.titleSmall?.copyWith(color: Colors.white),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: bar(
                  top: false,
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        if (browser.canShare)
                          _ViewerButton(icon: Icons.share_outlined, label: 'Share', onPressed: browser.shareSelection),
                        if (canEdit(browser))
                          _ViewerButton(
                            icon: Icons.crop_rotate_rounded,
                            label: 'Edit',
                            onPressed: () => editFocused(context, browser),
                          ),
                        if (canSticker(browser)) ...[
                          _ViewerButton(
                            icon: _alive ? Icons.view_in_ar_rounded : Icons.view_in_ar_outlined,
                            label: _alive ? 'Still' : '3D',
                            onPressed: () => setState(() => _alive = !_alive),
                          ),
                          _ViewerButton(
                            icon: Icons.emoji_emotions_outlined,
                            label: 'Sticker',
                            onPressed: () => stickerOfFocused(context, browser),
                          ),
                        ],
                        _ViewerButton(icon: Icons.info_outline_rounded, label: 'Info', onPressed: _showDetails),
                        if (browser.canDelete)
                          _ViewerButton(icon: Icons.delete_outline_rounded, label: 'Delete', onPressed: _delete),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// An icon with its name under it, along the bottom of [PictureViewer].
class _ViewerButton extends StatelessWidget {
  const _ViewerButton({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => InkResponse(
    onTap: onPressed,
    radius: 36,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(height: 4),
          Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white)),
        ],
      ),
    ),
  );
}

/// The pictures shown, one at a time, swiped between; the one showing is the
/// browser's focused one.
class _Swiper extends StatefulWidget {
  const _Swiper({required this.browser});

  final Browser browser;

  @override
  State<_Swiper> createState() => _SwiperState();
}

class _SwiperState extends State<_Swiper> {
  Browser get browser => widget.browser;

  late final _pages = PageController(initialPage: _focusedIndex);

  /// Zoomed into a picture: dragging moves about it, rather than to the next.
  var _zoomed = false;

  int get _focusedIndex => math.max(0, browser.pictures.indexWhere((picture) => picture.id == browser.focused?.id));

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Once it's shown: precaching wants to know the screen it's for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _makeReady(_focusedIndex);
    });
  }

  void _turnedTo(int index) {
    setState(() => _zoomed = false);
    browser.click(browser.pictures[index]);
    _makeReady(index);
  }

  /// Has the pictures either side of the one at [index] ready for the next
  /// swipe, and lets go of those further off (see [keepPreview]).
  void _makeReady(int index) {
    final pictures = browser.pictures;
    for (final near in [index - 1, index + 1]) {
      if (near < 0 || near >= pictures.length) continue;
      precacheImage(pictures[near].image(_viewerSize), context);
    }
    // Noted last, so it's the newest of those kept.
    if (index >= 0 && index < pictures.length) pictures[index].image(_viewerSize);
  }

  @override
  Widget build(BuildContext context) {
    final pictures = browser.pictures;
    // Listed again meanwhile (back in the app, say): kept on the same picture.
    if (_pages.hasClients && _pages.page?.round() != _focusedIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pages.hasClients) _pages.jumpToPage(_focusedIndex);
      });
    }
    return ColoredBox(
      color: Colors.black,
      child: PageView.builder(
        controller: _pages,
        physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
        itemCount: pictures.length,
        onPageChanged: _turnedTo,
        itemBuilder: (context, i) => _ZoomablePicture(
          key: ValueKey(pictures[i].id),
          picture: pictures[i],
          onZoomed: (zoomed) {
            if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
          },
        ),
      ),
    );
  }
}

/// The size pictures are shown at in the viewer: big enough to zoom into,
/// without holding a 50 MP photo whole.
const _viewerSize = 2560;

/// A picture filling its page, pinched or double-tapped to zoom in.
class _ZoomablePicture extends StatefulWidget {
  const _ZoomablePicture({super.key, required this.picture, required this.onZoomed});

  final Picture picture;
  final ValueChanged<bool> onZoomed;

  @override
  State<_ZoomablePicture> createState() => _ZoomablePictureState();
}

class _ZoomablePictureState extends State<_ZoomablePicture> {
  final _transform = TransformationController();
  Offset _doubleTapAt = Offset.zero;

  @override
  void initState() {
    super.initState();
    _transform.addListener(() => widget.onZoomed(_transform.value.getMaxScaleOnAxis() > 1.01));
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// In to 2.5 times where it was tapped, or back out.
  void _toggleZoom() {
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _transform.value = Matrix4.identity();
    } else {
      const scale = 2.5;
      final at = _doubleTapAt;
      _transform.value = Matrix4.identity()
        ..translateByDouble(-at.dx * (scale - 1), -at.dy * (scale - 1), 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final picture = widget.picture;
    return GestureDetector(
      onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        maxScale: 8,
        child: _Plays(
          child: Image(
            image: picture.image(_viewerSize),
            fit: BoxFit.contain,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true,
            // The thumbnail meanwhile, as the gallery does, rather than
            // nothing: its tile's own, which is there already.
            frameBuilder: (_, child, frame, wasSynchronous) => frame == null && !wasSynchronous
                ? ValueListenableBuilder(
                    valueListenable: PictureGrid.thumbnailSize,
                    builder: (_, size, _) => Image(
                      image: picture.thumbnail(size),
                      fit: BoxFit.contain,
                      width: double.infinity,
                      height: double.infinity,
                    ),
                  )
                : child,
            errorBuilder: (_, error, _) => UndecodableImage(name: picture.name, error: error, explain: true),
          ),
        ),
      ),
    );
  }
}

/// A GIF (or animated WebP) opened plays, as a video would, even with
/// Android's animations turned off (Remove animations, or a battery saver
/// that sets their speed to nothing): Flutter holds a picture's animation
/// still then, as it does the app's own, and GIFs showed only their first
/// frame. The app's own animations still follow the setting.
class _Plays extends StatelessWidget {
  const _Plays({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: false), child: child);
}

/// The picture's name, a line of what it is (size, megapixels, format), and
/// below, what's known of it: when it was taken, with what and how, where,
/// and which folder it's in.
class _Details extends StatefulWidget {
  const _Details({super.key, required this.picture, this.alwaysExpanded = false});

  final Picture picture;

  /// All its details, without a way to hide them (on a phone, in a sheet
  /// of their own).
  final bool alwaysExpanded;

  @override
  State<_Details> createState() => _DetailsState();
}

class _DetailsState extends State<_Details> {
  /// Whether the rows below the summary are shown: kept from picture to
  /// picture while the app runs.
  static var _expanded = true;

  /// The picture whose details are shown, and what's been read about it.
  /// When another picture's selected, these stay until its details have
  /// been read, then all change at once: nothing grows in, and the picture
  /// above isn't squeezed as rows arrive.
  Picture? _shown;
  PictureInfo? _info;
  PhotoDetails? _photo;

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(_Details old) {
    super.didUpdateWidget(old);
    if (old.picture.id != widget.picture.id) _read();
  }

  // Read once per picture: the pane's rebuilt whenever the browser changes.
  Future<void> _read() async {
    final picture = widget.picture;
    final (info, photo) = await (
      picture.info().then<PictureInfo?>((info) => info, onError: (_) => null),
      picture.details().catchError((_) => null),
    ).wait;
    if (!mounted || widget.picture.id != picture.id) return;
    setState(() {
      _shown = picture;
      _info = info;
      _photo = photo;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final picture = _shown;
    // Only the first picture, while its details are read.
    if (picture == null) return const SizedBox(width: double.infinity);
    final details = _DetailsText(_info, _photo, picture, context);
    final rows = details.rows();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: SelectableText(picture.name, style: text.titleMedium)),
              if (rows.isNotEmpty && !widget.alwaysExpanded)
                IconButton(
                  tooltip: _expanded ? 'Fewer details' : 'More details',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
            ],
          ),
          Text(details.summary(), style: text.bodySmall),
          if ((_expanded || widget.alwaysExpanded) && rows.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
            ),
        ],
      ),
    );
  }
}

/// What [_Details] says, from what's been read so far.
class _DetailsText {
  _DetailsText(this.info, this.photo, this.picture, this.context);

  final PictureInfo? info;
  final PhotoDetails? photo;
  final Picture picture;
  final BuildContext context;

  (int, int)? get _dimensions =>
      info?.dimensions ??
      switch (photo) {
        PhotoDetails(:final width?, :final height?) => (width, height),
        _ => null,
      };

  /// "12.2 MP · 4032 × 3024 · 3.4 MB · HEIC".
  String summary() => [
    if (_dimensions case (final width, final height)) ...[
      if (width * height >= 1000000) '${(width * height / 1000000).toStringAsFixed(1)} MP',
      '$width × $height',
    ],
    if (info?.bytes case final bytes?) _formatBytes(bytes),
    pictureType(picture.name),
  ].join('  ·  ');

  List<Widget> rows() {
    final photo = this.photo;
    final taken = info?.taken;
    final modified = info?.modified;
    return [
      if (taken ?? modified case final date?)
        _DetailRow(
          icon: Icons.event_rounded,
          text: '${taken != null ? 'Taken' : 'Modified'} ${_formatDate(context, date)}',
          // Where it was taken some other time: the file's own date too.
          tooltip: taken != null && modified != null ? 'Modified ${_formatDate(context, modified)}' : null,
        ),
      if (photo != null) ...[
        if (_camera(photo) case final camera?) _DetailRow(icon: Icons.photo_camera_outlined, text: camera),
        if (photo.lens case final lens?) _DetailRow(icon: Icons.camera_outlined, text: lens),
        if (_exposure(photo) case final exposure?) _DetailRow(icon: Icons.tune_rounded, text: exposure),
        if ((photo.latitude, photo.longitude) case (final latitude?, final longitude?))
          _DetailRow(
            icon: Icons.place_outlined,
            text: _coordinates(latitude, longitude),
            tooltip: 'Show on Google Maps',
            onTap: () => launchUrl(
              Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': '$latitude,$longitude'}),
              mode: LaunchMode.externalApplication,
            ),
          ),
      ],
      _DetailRow(
        icon: picture is PhonePicture ? Icons.smartphone_rounded : Icons.folder_outlined,
        text: _shortPlace(picture),
        tooltip: switch (picture) {
          LocalPicture() when Platform.isWindows => 'Show in folder\n${picture.place}',
          _ => picture.place,
        },
        onTap: switch (picture) {
          final LocalPicture picture when Platform.isWindows => () => Process.run('explorer.exe', [
            '/select,',
            picture.file.path,
          ]),
          _ => null,
        },
      ),
    ];
  }
}

/// A line of the details: an icon and some text, perhaps a link.
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.text, this.tooltip, this.onTap});

  final IconData icon;
  final String text;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    Widget row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textTertiary),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: onTap == null ? style : style?.copyWith(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
    if (onTap != null) {
      row = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: row),
      );
    }
    return tooltip == null
        ? row
        : Tooltip(message: tooltip, waitDuration: const Duration(milliseconds: 500), child: row);
  }
}

/// "Apple iPhone 15 Pro"; the maker left out where the model says it
/// ("NIKON D750", not "NIKON CORPORATION NIKON D750").
String? _camera(PhotoDetails photo) {
  final (make, model) = (photo.make, photo.model);
  if (model == null) return make;
  if (make == null) return model;
  final maker = make.split(' ').first.toLowerCase();
  return model.toLowerCase().contains(maker) ? model : '$make $model';
}

/// "ƒ/1.8  ·  1/120 s  ·  ISO 100  ·  6.9 mm (26 mm equiv.)".
String? _exposure(PhotoDetails photo) {
  String number(double n) => n.toStringAsFixed(n < 10 && n != n.roundToDouble() ? 1 : 0);
  final parts = [
    if (photo.fNumber case final f?) 'ƒ/${number(f)}',
    if (photo.exposure case final time?) time >= 0.3 ? '${number(time)} s' : '1/${(1 / time).round()} s',
    if (photo.iso case final iso?) 'ISO $iso',
    if (photo.focalLength case final focal?)
      switch (photo.focalLength35) {
        final film? when (film - focal).abs() >= 1 => '${number(focal)} mm (${film.round()} mm equiv.)',
        _ => '${number(focal)} mm',
      }
    else if (photo.focalLength35 case final film?)
      '${film.round()} mm equiv.',
  ];
  return parts.isEmpty ? null : parts.join('  ·  ');
}

/// "51.5074° N, 0.1278° W".
String _coordinates(double latitude, double longitude) =>
    '${latitude.abs().toStringAsFixed(4)}° ${latitude < 0 ? 'S' : 'N'}, '
    '${longitude.abs().toStringAsFixed(4)}° ${longitude < 0 ? 'W' : 'E'}';

/// Where an Android phone keeps the user's files.
const _phoneStorage = '/storage/emulated/0';

/// Where [picture] is, short: "Pictures › 2025 › Holiday", "Pixel 8 › DCIM ›
/// Camera"; the deepest few folders, where there are many.
String _shortPlace(Picture picture) {
  var parts = <String>[];
  if (picture case LocalPicture(:final place)) {
    final pictures = picturesFolder.toLowerCase();
    if (place.toLowerCase() == pictures || place.toLowerCase().startsWith('$pictures${Platform.pathSeparator}')) {
      parts = ['Pictures', ...place.substring(picturesFolder.length).split(RegExp(r'[\\/]'))];
    } else if (Platform.isAndroid && place.startsWith(_phoneStorage)) {
      // The phone's own storage, by the name it has on the phone.
      parts = ['Phone', ...place.substring(_phoneStorage.length).split('/')];
    } else {
      parts = place.split(RegExp(r'[\\/]'));
    }
  } else {
    parts = picture.place.split('/');
  }
  parts = parts.where((part) => part.isNotEmpty).toList();
  if (parts.length > 4) parts = ['…', ...parts.sublist(parts.length - 3)];
  return parts.join(' › ');
}

/// "5 pictures selected", how much they take up, and when they're from.
class _SelectionDetails extends StatefulWidget {
  const _SelectionDetails({required this.browser});

  final Browser browser;

  @override
  State<_SelectionDetails> createState() => _SelectionDetailsState();
}

class _SelectionDetailsState extends State<_SelectionDetails> {
  /// The selection all this was worked out for; its size, added up; the
  /// months it's from; and how many of it are on a phone.
  List<Picture>? _summed;
  late Future<int> _total;
  String? _monthSpan;
  var _onPhone = 0;

  /// Counts the selections worked out, so what's shown for an old one isn't
  /// shown for the next.
  var _generation = 0;

  /// Whether [selection] is the one already worked out. The browser gives
  /// the same list back while nothing's changed; a new list (a scan's listed
  /// the pictures again) is gone through only to see that it's the same.
  bool _same(List<Picture> selection) {
    final summed = _summed;
    if (identical(summed, selection)) return true;
    if (summed == null || summed.length != selection.length) return false;
    // The very same pictures, not just the same ids: a listing hands out
    // the same picture again only while nothing about it has changed, so a
    // new one (a date taken just read, a file that's grown) is summed anew.
    for (var i = 0; i < selection.length; i++) {
      if (!identical(summed[i], selection[i])) return false;
    }
    _summed = selection;
    return true;
  }

  /// How much the selection takes up: added up from what the listing found
  /// out; only those it didn't are looked at, once a selection. (Thousands
  /// may be selected, and the pane's rebuilt often while a drive's sorted.)
  Future<int> _totalBytes(List<Picture> selection) async {
    var total = 0;
    for (final picture in selection) {
      total +=
          picture.bytes ??
          switch (picture) {
            LocalPicture(:final file) => await file.length().catchError((Object _) => 0),
            _ => 0,
          };
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final browser = widget.browser;
    final text = Theme.of(context).textTheme;
    final count = browser.selectedCount;
    final selection = browser.selection;
    // Worked out anew only when the selection changes.
    if (!_same(selection)) {
      _summed = selection;
      _generation++;
      _total = _totalBytes(selection);
      // The first and last by their numbers: a date made of each of
      // thousands selected is slow (see [Picture.dateMs]).
      int? first, last;
      _onPhone = 0;
      for (final picture in selection) {
        if (picture is PhonePicture) _onPhone++;
        final ms = picture.dateMs;
        if (ms == null) continue;
        if (first == null || ms < first) first = ms;
        if (last == null || ms > last) last = ms;
      }
      _monthSpan = first == null || last == null
          ? null
          : _monthRange(DateTime.fromMillisecondsSinceEpoch(first), DateTime.fromMillisecondsSinceEpoch(last));
    }
    final onPhone = _onPhone;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: FutureBuilder(
        key: ValueKey(_generation),
        future: _total,
        builder: (context, snapshot) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$count pictures selected', style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              [
                if (snapshot.data case final bytes?) _formatBytes(bytes),
                ?_monthSpan,
                // Where some are on the phone and some on this PC.
                if (onPhone > 0 && onPhone < count) '$onPhone on the phone',
              ].join('  ·  '),
              style: text.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// "Mar 2024 – Jul 2025", "Mar – Jul 2025", "Jul 2025".
String _monthRange(DateTime first, DateTime last) {
  String month(DateTime d) => _months[d.month - 1];
  if (first.year != last.year) return '${month(first)} ${first.year} – ${month(last)} ${last.year}';
  if (first.month != last.month) return '${month(first)} – ${month(last)} ${last.year}';
  return '${month(last)} ${last.year}';
}

/// What can be done to the selection.
class _Actions extends StatelessWidget {
  const _Actions({required this.browser});

  final Browser browser;

  @override
  Widget build(BuildContext context) {
    final selection = browser.selection;
    // Not while a copy's under way, off a phone or to the clipboard: the
    // pictures mustn't be moved, renamed or deleted from under it.
    if (selection.isEmpty || browser.copying != null || browser.copyingToClipboard) {
      return const SizedBox(height: 16);
    }
    final single = selection.length == 1 ? selection.single : null;
    final onPhone = selection.any((picture) => picture is PhonePicture);
    // To the clipboard, to paste anywhere: what Ctrl+C does.
    final copyButton = Tooltip(
      message: 'Copy to the clipboard (Ctrl+C)',
      child: TextButton.icon(
        onPressed: () => copyToClipboard(context, browser),
        icon: const Icon(Icons.content_paste_rounded),
        label: const Text('Copy'),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      child: Wrap(
        spacing: 4,
        children: [
          if (onPhone)
            TextButton.icon(
              onPressed: () => copySelection(context, browser),
              icon: const Icon(Icons.download_rounded),
              label: const Text('Copy to PC…'),
            ),
          if (onPhone && browser.canCopyToClipboard) copyButton,
          if (browser.canChangeSelection) ...[
            if (single case final LocalPicture picture) ...[
              TextButton.icon(
                onPressed: () => editFocused(context, browser),
                icon: const Icon(Icons.crop_rotate_rounded),
                label: const Text('Edit'),
              ),
              TextButton.icon(
                onPressed: () => renameFocused(context, browser),
                icon: const Icon(Icons.drive_file_rename_outline_rounded),
                label: const Text('Rename'),
              ),
              TextButton.icon(
                onPressed: () => Process.run('explorer.exe', ['/select,', picture.file.path]),
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Show in folder'),
              ),
            ],
            if (browser.canCopyToClipboard) copyButton,
            TextButton.icon(
              onPressed: () => copySelection(context, browser),
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copy to…'),
            ),
            TextButton.icon(
              onPressed: () => copySelection(context, browser, move: true),
              icon: const Icon(Icons.drive_file_move_outline),
              label: const Text('Move to…'),
            ),
            TextButton.icon(
              onPressed: () => deleteSelection(context, browser),
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Delete'),
            ),
          ],
          // What can be made of them.
          if (canSticker(browser))
            TextButton.icon(
              onPressed: () => stickerOfFocused(context, browser),
              icon: const Icon(Icons.emoji_emotions_outlined),
              label: const Text('Sticker'),
            ),
          if (canCompare(browser))
            TextButton.icon(
              onPressed: () => compareSelection(context, browser),
              icon: const Icon(Icons.compare_rounded),
              label: const Text('Compare'),
            ),
          if (canCollage(browser))
            TextButton.icon(
              onPressed: () => collageSelection(context, browser),
              icon: const Icon(Icons.dashboard_outlined),
              label: const Text('Collage'),
            ),
          // On a phone: its own pictures shared, or moved to its trash.
          if (browser.canShare)
            TextButton.icon(
              onPressed: browser.shareSelection,
              icon: const Icon(Icons.share_outlined),
              label: const Text('Share'),
            ),
          if (browser.canDelete && !browser.canChangeSelection)
            TextButton.icon(
              onPressed: () => deleteSelection(context, browser),
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Delete'),
            ),
        ],
      ),
    );
  }
}

/// A copy off a phone under way; or the selection being read to put on the
/// clipboard, which a RAW file can take a second or two over.
class _Progress extends StatelessWidget {
  const _Progress({required this.browser});

  final Browser browser;

  @override
  Widget build(BuildContext context) {
    final progress = browser.copying;
    if (progress == null && browser.copyingToClipboard) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Copying to the clipboard…', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
        ),
      );
    }
    if (progress == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Copying from the phone: ${progress.done} of ${progress.total}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress.total == 0 ? null : progress.done / progress.total),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Sat 12 Jul 2025, 3:41 PM", the time as the system has it (12 or 24 hour).
String _formatDate(BuildContext context, DateTime d) {
  final time = MaterialLocalizations.of(context)
      .formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
  return '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]} ${d.year}, $time';
}
