import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

import 'favourites.dart';
import 'gallery.dart';
import 'places.dart';

/// The location being looked through, what's in it, and which pictures are
/// selected.
///
/// One picture is [focused]: the one in the preview pane, which the arrow
/// keys move from. The selection is any number of pictures (the focused one
/// among them, unless Ctrl+click has just taken it out).
class Browser extends ChangeNotifier {
  Browser(this.location);

  Location location;

  /// The pictures shown: all of [location]'s, or those a [search] finds, and
  /// with a [kind], [cameras] or [types] chosen, those of them.
  List<Picture> pictures = const [];

  /// All of [location]'s pictures.
  List<Picture> _all = const [];

  /// Those of them the [search] finds: all of them, with none.
  List<Picture> _found = const [];

  /// What's being searched for, as it was typed: empty for nothing. Kept
  /// when another drive or phone is opened (to look for the same there),
  /// and let go of by the app when another tab is.
  String query = '';

  /// [query]'s words: see [Picture.searchWords].
  List<String> _words = const [];

  /// Shows only the pictures that [text] finds (see [Picture.matches]), or
  /// with none, all of them again. The chips count what it finds; what's
  /// selected and now hidden is let go.
  void search(String text) {
    if (text == query) return;
    query = text;
    final words = Picture.searchWords(text);
    if (listEquals(words, _words)) return; // a space typed, say
    _words = words;
    _setAll(_all);
    _keepSelectionShown();
    notifyListeners();
  }

  /// The kinds of picture (JPG, PNG, GIF...) shown; none chosen, all are.
  final types = <String>{};

  /// How many of each kind there are among the photos or screenshots shown
  /// ([kind]) from the cameras chosen ([cameras]), most first: the filter's
  /// chips. A kind chosen is kept, at 0 if there are none of it now, so it
  /// can be let go of.
  List<(String, int)> typeCounts = const [];

  /// The cameras and phones (see [Picture.camera]) whose pictures are
  /// shown; none chosen, all pictures are, whatever took them (or if
  /// nothing says).
  final cameras = <String>{};

  /// How many pictures each camera took among the photos or screenshots
  /// shown ([kind]), most first: the camera chips. One chosen is kept, at
  /// 0 if there are none of it now, so it can be let go of.
  List<(String, int)> cameraCounts = const [];

  /// How many of the photos or screenshots shown ([kind]) don't say what
  /// camera took them (or haven't been read yet).
  int unknownCameraCount = 0;

  /// How many pictures [location] has, whatever the search and the filter.
  int get total => _all.length;

  /// Photos or screenshots (see [pictureKind]): the one shown, or null for
  /// both.
  String? kind;

  /// How many photos and screenshots [location] has, photos first: the
  /// filter's second row of chips. The one chosen is kept, at 0 if there are
  /// none of it now (all deleted, say), so it can be let go of rather than
  /// leaving the grid empty with no filter to be seen.
  List<(String, int)> kindCounts = const [];

  /// The location's pictures are now [all]: shown as the search and the
  /// filter have them. The selection's left alone (see [refresh] and
  /// [toggleType]).
  void _setAll(List<Picture> all) {
    _all = all;
    final words = _words;
    _found = words.isEmpty
        ? all
        : [
            for (final picture in all)
              if (picture.matches(words)) picture,
          ];
    final kinds = <String, int>{};
    for (final picture in _found) {
      kinds[picture.kind] = (kinds[picture.kind] ?? 0) + 1;
    }
    kindCounts = [
      for (final kind in const ['Photos', 'Screenshots'])
        if (kinds[kind] case final count?) (kind, count) else if (kind == this.kind) (kind, 0),
    ];
    _filter();
  }

  /// Works out [pictures]: of those the search finds, the photos or
  /// screenshots ([kind]), of those the ones from the [cameras] chosen, and
  /// of those the [types] chosen. Each row of chips counts what the row
  /// before leaves.
  void _filter() {
    final ofKind = kind == null ? _found : [for (final picture in _found) if (picture.kind == kind) picture];

    final byCamera = <String, int>{for (final camera in cameras) camera: 0};
    var unknown = 0;
    for (final picture in ofKind) {
      if (picture.camera case final camera?) {
        byCamera[camera] = (byCamera[camera] ?? 0) + 1;
      } else {
        unknown++;
      }
    }
    cameraCounts = _mostFirst(byCamera);
    unknownCameraCount = unknown;
    final ofCamera = cameras.isEmpty
        ? ofKind
        : [
            for (final picture in ofKind)
              if (cameras.contains(picture.camera)) picture,
          ];

    final byType = <String, int>{for (final type in types) type: 0};
    for (final picture in ofCamera) {
      byType[picture.type] = (byType[picture.type] ?? 0) + 1;
    }
    typeCounts = _mostFirst(byType);
    pictures = types.isEmpty
        ? ofCamera
        : [
            for (final picture in ofCamera)
              if (types.contains(picture.type)) picture,
          ];
  }

  /// [counts] as chips have them: most first, then by name.
  static List<(String, int)> _mostFirst(Map<String, int> counts) =>
      counts.entries.map((entry) => (entry.key, entry.value)).toList()
        ..sort((a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1));

  /// Shows [camera]'s pictures too, or no longer; what's selected and now
  /// hidden is let go.
  void toggleCamera(String camera) {
    if (!cameras.remove(camera)) cameras.add(camera);
    _filter();
    _keepSelectionShown();
    notifyListeners();
  }

  /// Shows every camera's pictures again, and those that don't say.
  void showAllCameras() {
    if (cameras.isEmpty) return;
    cameras.clear();
    _filter();
    notifyListeners();
  }

  /// Shows [type]'s pictures too, or no longer; what's selected and now
  /// hidden is let go.
  void toggleType(String type) {
    if (!types.remove(type)) types.add(type);
    _filter();
    _keepSelectionShown();
    notifyListeners();
  }

  /// Shows every kind again.
  void showAllTypes() {
    if (types.isEmpty) return;
    types.clear();
    _filter();
    notifyListeners();
  }

  /// Shows only photos, or only screenshots, or (null) both again.
  void showKind(String? kind) {
    if (this.kind == kind) return;
    this.kind = kind;
    // Counted again: a kind kept at 0 only while chosen goes once it's not.
    _setAll(_all);
    _keepSelectionShown();
    notifyListeners();
  }

  void _keepSelectionShown() {
    // With nothing selected (as while a drive's looked through, listed again
    // every second), there's nothing to go through the pictures for.
    if (_selected.isNotEmpty) _selected.retainAll({for (final picture in pictures) picture.id});
    focused = _byId(focused?.id);
  }

  bool loading = false;
  String? error;

  /// Shown, but still being worked on (maybe quietly): listed again once
  /// it's better.
  bool updating = false;

  /// The work being done on what's shown, for the user to see: finding the
  /// pictures, or sorting them by when they were taken.
  Work? work;

  /// How far along [work] is, 0 to 1; null if there's no telling.
  double? progress;

  /// Said for a few seconds once all the work's done: "Up to date".
  String? finished;

  /// Told when all the work on a location is done, if it took a while, with
  /// what to tell the user.
  void Function(String message)? onFinished;

  /// When the work being done began; null if none is.
  DateTime? _workSince;
  Timer? _finishedTimer;

  Picture? focused;
  final _selected = _SelectedIds();

  /// Where a Shift+click or Shift+arrow range starts.
  String? _anchor;

  /// A copy off a phone under way: how many of how many are done.
  ({int done, int total})? copying;

  /// Counts listings, so a slow one that's been overtaken is dropped.
  int _generation = 0;

  /// Shows [to]'s pictures, with nothing selected and no filters on.
  /// With [lookAgain] false, it isn't told to look again first: for one
  /// whose pictures were only just listed (another album of the same).
  Future<void> open(Location to, {bool lookAgain = true}) async {
    location = to;
    focused = null;
    picking = false;
    _selected.clear();
    _anchor = null;
    types.clear();
    cameras.clear();
    kind = null;
    _setAll(const []);
    loading = true;
    error = null;
    work = null;
    progress = null;
    _workSince = null;
    _clearFinished();
    notifyListeners();
    // Looked through again: what's changed since is found (behind what was
    // found last time, for a library).
    if (lookAgain) to.forget();
    await refresh();
  }

  /// The app has changed files here: the location's told, so it shows them
  /// so until it's looked again, then it's listed again.
  Future<void> _changed({Iterable<String> gone = const [], Iterable<String> added = const []}) {
    location.forget(gone: gone, added: added);
    return refresh();
  }

  /// The app has made a new picture at [path] (a sticker, a collage): shown
  /// at once where it belongs, and focused if it's here.
  Future<void> madePicture(String path) async {
    await _changed(added: [path]);
    if (_byId(path) case final made?) click(made);
  }

  /// Lists [location] again, keeping what's selected where it's still there.
  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_generation;
    try {
      final listing = await location.list();
      if (generation != _generation || _disposed) return;
      _setAll(listing.pictures);
      error = null;
      _keepSelectionShown();
      // Shown as it is for now; listed again once it's better.
      updating = listing.pending != null;
      _setWork(listing.work, listing.progress);
      listing.pending?.then(
        (_) {
          if (generation == _generation) refresh();
        },
        onError: (Object _) {
          if (generation != _generation) return;
          updating = false;
          _setWork(null, null);
          notifyListeners();
        },
      );
    } on FileSystemException catch (e) {
      if (generation != _generation) return;
      error = e.osError?.message ?? e.message;
    } on NativeImagingException catch (e) {
      if (generation != _generation) return;
      // ERROR_DEVICE_NOT_CONNECTED, as an HRESULT.
      error = e.hresult == 0x8007048F
          ? 'The phone was disconnected, or locked.'
          : 'The phone couldn\'t be read ($e). Is it still unlocked?';
    }
    loading = false;
    notifyListeners();
  }

  /// Notes the work being done; when it's all done, if it took a while, says
  /// so ("Up to date") for a few seconds and tells [onFinished].
  void _setWork(Work? now, double? howFar) {
    final was = work;
    work = now;
    progress = howFar;
    if (now != null) {
      _workSince ??= DateTime.now();
      _clearFinished();
      return;
    }
    final since = _workSince;
    _workSince = null;
    if (was == null || since == null || DateTime.now().difference(since) < const Duration(seconds: 2)) return;
    final count = _all.length;
    finished = 'Up to date';
    onFinished?.call('${location.title} is up to date: ${_count(count)} ${count == 1 ? 'picture' : 'pictures'}.');
    _finishedTimer = Timer(const Duration(seconds: 5), () {
      _clearFinished();
      notifyListeners();
    });
  }

  void _clearFinished() {
    _finishedTimer?.cancel();
    _finishedTimer = null;
    finished = null;
  }

  /// [n] with thousands set apart: 57,821.
  static String _count(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

  Picture? _byId(String? id) => id == null ? null : pictures.where((picture) => picture.id == id).firstOrNull;

  // --- Selection ------------------------------------------------------------

  bool isSelected(Picture picture) => _selected.contains(picture.id);

  /// The selected pictures, in the grid's order. It can't be changed: the
  /// same list is handed to everyone who asks, so one who sorted it would
  /// change what the next delete or copy acts on.
  ///
  /// Worked out once each time the selection or the pictures change, not
  /// each time it's asked: the preview pane asks several times over whenever
  /// it's redrawn, and going through tens of thousands of pictures for each
  /// made every click and arrow key wait.
  ///
  /// The same list is given back until then, so whoever shows it can tell
  /// with [identical] that it hasn't changed. (A scan's progress, told every
  /// second, changes neither, so isn't a reason to go through them again.)
  List<Picture> get selection {
    if (_selection case (final of, final version, final selection)
        when identical(of, pictures) && version == _selected.version) {
      return selection;
    }
    final selection = _selected.isEmpty
        ? const <Picture>[]
        : List<Picture>.unmodifiable([
            for (final picture in pictures)
              if (_selected.contains(picture.id)) picture,
          ]);
    _selection = (pictures, _selected.version, selection);
    return selection;
  }

  /// [selection] as last worked out, with the pictures and the version of
  /// what's selected it was worked out from.
  (List<Picture>, int, List<Picture>)? _selection;

  int get selectedCount => _selected.length;

  /// A click: selects just [picture]; with [toggle] (Ctrl), adds or takes it
  /// out; with [range] (Shift), selects from the last one clicked to it.
  void click(Picture picture, {bool toggle = false, bool range = false}) {
    if (range && _anchor != null) {
      _selectRange(_anchor!, picture, keep: toggle);
    } else if (toggle) {
      if (!_selected.remove(picture.id)) _selected.add(picture.id);
      _anchor = picture.id;
    } else {
      _selected
        ..clear()
        ..add(picture.id);
      _anchor = picture.id;
    }
    focused = picture;
    notifyListeners();
  }

  /// On a phone, picking pictures, after a long press on one: taps add and
  /// take out rather than open, and what's picked can be shared or deleted
  /// together. (Elsewhere, the selection's always made with clicks.)
  var picking = false;

  /// Starts [picking], with [picture] picked.
  void startPicking(Picture picture) {
    picking = true;
    click(picture);
  }

  /// While [picking], a tap: adds [picture], or takes it out. Done picking
  /// once there's none.
  void togglePicked(Picture picture) {
    click(picture, toggle: true);
    if (_selected.isEmpty) stopPicking();
  }

  void stopPicking() {
    picking = false;
    _selected.clear();
    focused = null;
    _anchor = null;
    notifyListeners();
  }

  /// Moves the focus [by] pictures (a row, with the grid's width), selecting
  /// just it, or with [extend] (Shift) the range from the anchor.
  void moveFocus(int by, {bool extend = false}) {
    if (pictures.isEmpty) return;
    final from = focused == null ? -1 : pictures.indexWhere((picture) => picture.id == focused!.id);
    // With nothing focused yet, the first key press lands on the first.
    focusAt(from < 0 ? 0 : from + by, extend: extend);
  }

  /// Focuses the first picture, or with [last] the last.
  void focusEdge({required bool last, bool extend = false}) =>
      focusAt(last ? pictures.length - 1 : 0, extend: extend);

  /// Where the focused picture is in [pictures]; null if none is.
  int? get focusedIndex {
    final index = focused == null ? -1 : pictures.indexWhere((picture) => picture.id == focused!.id);
    return index < 0 ? null : index;
  }

  /// Focuses the picture at [index] in [pictures], selecting just it, or
  /// with [extend] the range from the anchor.
  void focusAt(int index, {bool extend = false}) {
    if (pictures.isEmpty) return;
    final picture = pictures[index.clamp(0, pictures.length - 1)];
    if (extend && _anchor != null) {
      _selectRange(_anchor!, picture, keep: false);
      focused = picture;
      notifyListeners();
    } else {
      click(picture);
    }
  }

  void _selectRange(String anchorId, Picture to, {required bool keep}) {
    final start = pictures.indexWhere((picture) => picture.id == anchorId);
    final end = pictures.indexWhere((picture) => picture.id == to.id);
    if (start < 0 || end < 0) return;
    if (!keep) _selected.clear();
    for (var i = start < end ? start : end; i <= (start < end ? end : start); i++) {
      _selected.add(pictures[i].id);
    }
  }

  void selectAll() {
    _selected.addAll(pictures.map((picture) => picture.id));
    focused ??= pictures.firstOrNull;
    notifyListeners();
  }

  void clearSelection() {
    if (_selected.isEmpty && focused == null) return;
    _selected.clear();
    focused = null;
    _anchor = null;
    notifyListeners();
  }

  // --- Changing files -------------------------------------------------------

  /// Whether the selection can be renamed, moved and deleted: pictures on
  /// this PC. A phone's can only be copied off it, for now. Not while
  /// they're put on the clipboard: one moved before its RAW's decoded would
  /// be put there by the path it's no longer at.
  bool get canChangeSelection =>
      Platform.isWindows &&
      _selected.isNotEmpty &&
      !copyingToClipboard &&
      selection.every((picture) => picture is LocalPicture);

  /// Whether the selection's all from the phone's own gallery, on Android:
  /// those can be shared and deleted (to Android's trash).
  bool get _inGallery =>
      Platform.isAndroid &&
      _selected.isNotEmpty &&
      selection.every((picture) => picture is LocalPicture && picture.galleryId != null);

  /// Whether the selection can be deleted: pictures on this PC (to the
  /// Recycle Bin), or in a phone's own gallery (to Android's trash).
  bool get canDelete => canChangeSelection || _inGallery;

  /// Whether the selection can be shared: on Android, through its share sheet.
  bool get canShare => _inGallery;

  /// Shares the selection through Android's share sheet.
  Future<void> shareSelection() async {
    if (!canShare) return;
    await Gallery.share([for (final picture in selection.cast<LocalPicture>()) picture.galleryId!]);
  }

  /// Moves the selection to the Recycle Bin (on Android, its trash) and
  /// focuses the picture after it. Returns what to tell the user: that it's
  /// done, or why it couldn't be; null if they cancelled.
  Future<String?> deleteSelection() async {
    if (!canDelete) return null;
    final doomed = selection.cast<LocalPicture>();
    final paths = [for (final picture in doomed) picture.file.path];
    try {
      final done = _inGallery
          ? await Gallery.trash([for (final picture in doomed) picture.galleryId!])
          : await NativeImaging.recycle(paths);
      // Skipped or cancelled part-way: whatever's still there stays.
      if (!done) {
        await _changed(gone: paths.where((path) => !File(path).existsSync()));
        return null;
      }
    } on NativeImagingException catch (e) {
      await _changed(gone: paths.where((path) => !File(path).existsSync()));
      return 'Couldn\'t delete ${_describe(doomed)} ($e).';
    } on PlatformException catch (e) {
      return 'Couldn\'t delete ${_describe(doomed)} (${e.message ?? e.code}).';
    }
    final where = _inGallery ? 'the trash' : 'the Recycle Bin';
    location.forget(gone: paths);
    _drop(doomed);
    return 'Moved ${_describe(doomed)} to $where.';
  }

  /// Takes [gone] out of what's shown (deleted, or on the Favourites tab no
  /// longer a favourite), with the selection, and focuses the picture after
  /// the first of them, to carry on from; on a phone, done picking instead.
  void _drop(List<Picture> gone) {
    final ids = {for (final picture in gone) picture.id};
    final first = pictures.indexWhere((picture) => ids.contains(picture.id));
    _setAll([
      for (final picture in _all)
        if (!ids.contains(picture.id)) picture,
    ]);
    _selected.clear();
    final wasPicking = picking;
    picking = false;
    focused = pictures.isEmpty || wasPicking ? null : pictures[first.clamp(0, pictures.length - 1)];
    if (focused case final next?) {
      _selected.add(next.id);
      _anchor = next.id;
    }
    notifyListeners();
  }

  // --- Favourites -----------------------------------------------------------

  /// Whether the selection can be marked as favourites: pictures on this PC
  /// or in the phone's gallery. A phone's over USB can't: it's only there
  /// while it's plugged in.
  bool get canFavourite => _selected.isNotEmpty && canFavouriteAll(selection);

  /// Whether [pictures] can be marked as favourites (see [canFavourite]).
  static bool canFavouriteAll(List<Picture> pictures) =>
      pictures.isNotEmpty && pictures.every((picture) => picture is LocalPicture);

  /// Whether every picture selected is a favourite: the heart's filled.
  bool get selectionIsFavourite => _selected.isNotEmpty && allFavourites(selection);

  /// Whether every one of [pictures] is a favourite.
  static bool allFavourites(List<Picture> pictures) {
    if (!canFavouriteAll(pictures)) return false;
    final favourites = Favourites.instance;
    return pictures.every((picture) => favourites.contains(picture.id));
  }

  /// What the heart over the preview stands for: the selection, if the
  /// picture previewed is in it; if it isn't (Ctrl+clicked off it, say),
  /// just the picture previewed, as that's the one in view.
  List<Picture> get previewed => switch (focused) {
    null => const [],
    final picture when _selected.contains(picture.id) => selection,
    final picture => [picture],
  };

  /// The toggle under way, so a second press waits for the first and sees
  /// what it did, rather than both deciding from the same hearts.
  Future<void> _favouriting = Future.value();

  /// Marks the selection (or [pictures]) as favourites; or, if they all are
  /// already, no longer. On the Favourites tab, those that aren't any more
  /// are taken out, and the picture after them focused, as for a delete.
  Future<void> toggleFavourite([List<Picture>? pictures]) {
    final chosen = pictures ?? selection;
    if (!canFavouriteAll(chosen)) return Future.value();
    return _favouriting = _favouriting.then((_) => _toggleFavourite(chosen));
  }

  Future<void> _toggleFavourite(List<Picture> chosen) async {
    final favourites = Favourites.instance;
    // Which way to go is only known once the favourites kept are read: one
    // pressed straight after starting must come off if it was one last time.
    await favourites.ready;
    if (_disposed) return;
    final favourite = !allFavourites(chosen);
    await favourites.mark([for (final picture in chosen) picture.id], favourite: favourite);
    if (_disposed) return;
    if (!favourite && location is FavouritePictures) {
      final ids = {for (final picture in chosen) picture.id};
      if (_selected.every(ids.contains)) {
        _drop(chosen);
      } else {
        // Chosen some other way than what's selected now (the picture in
        // view, or the selection changed since): take them out, and leave
        // the rest of the selection as it is. The picture after them is in
        // view instead, if the one in view went.
        final first = pictures.indexWhere((picture) => ids.contains(picture.id));
        _setAll([
          for (final picture in _all)
            if (!ids.contains(picture.id)) picture,
        ]);
        _selected.removeAll(ids);
        if (focused case final picture? when ids.contains(picture.id)) {
          focused = pictures.isEmpty ? null : pictures[first.clamp(0, pictures.length - 1)];
        }
        notifyListeners();
      }
    } else {
      notifyListeners();
    }
  }

  /// Copies the selection into [folder]; with [move], moves it (pictures on
  /// this PC only). Pictures on a phone are copied off it here, keeping
  /// their dates and taking a new name where one's taken; on this PC,
  /// Windows does it, asking about names that are taken. Returns what to
  /// tell the user, or null if they cancelled.
  Future<String?> copySelection(String folder, {bool move = false}) async {
    final chosen = selection;
    if (chosen.isEmpty) return null;
    final local = chosen.whereType<LocalPicture>().toList();
    final onPhone = chosen.whereType<PhonePicture>().toList();
    if (move && onPhone.isNotEmpty) return 'Pictures on a phone can be copied, not moved.';
    final sources = [for (final picture in local) picture.file.path];
    // Where they went, as far as can be told: Windows may have given some
    // new names, which the next look finds. Favourites moved are still
    // favourites where they went (one given a new name isn't, there being
    // no telling which). Where the name was already taken in the folder,
    // the file there now is only the one moved if it's the same size and
    // was changed at the same time (Windows keeps that on a move): if the
    // user kept both, it's the other picture, and the heart doesn't go there.
    final before = <String, (int, DateTime)>{};
    if (move) {
      for (final path in sources) {
        if (File(p.join(folder, p.basename(path))).existsSync()) before[path] = _sizeAndTime(path);
      }
    }
    Future<void> changed([List<String> fromPhone = const []]) async {
      if (move) {
        for (final path in sources) {
          final to = p.join(folder, p.basename(path));
          if (File(path).existsSync() || !File(to).existsSync()) continue;
          if (before[path] case final was? when was != _sizeAndTime(to)) continue;
          await Favourites.instance.moved(path, to);
        }
      }
      await _changed(
        gone: sources.where((path) => !File(path).existsSync()),
        added: [for (final path in sources) p.join(folder, p.basename(path)), ...fromPhone],
      );
    }
    final fromPhone = <String>[];
    try {
      if (local.isNotEmpty) {
        final done = await transfer(sources, folder, move: move);
        if (!done) {
          await changed();
          return null;
        }
      }
      if (onPhone.isNotEmpty) await _copyOffPhone(onPhone, folder, fromPhone);
    } on NativeImagingException catch (e) {
      copying = null;
      await changed(fromPhone);
      return 'Couldn\'t ${move ? 'move' : 'copy'} ${_describe(chosen)} ($e).';
    } on FileSystemException catch (e) {
      copying = null;
      await changed(fromPhone);
      return 'Couldn\'t copy ${_describe(chosen)}: ${e.osError?.message ?? e.message}';
    }
    await changed(fromPhone);
    return '${move ? 'Moved' : 'Copied'} ${_describe(chosen)} to ${p.basename(folder)}.';
  }

  /// Copies or moves files into a folder as File Explorer does (Windows asks
  /// about names that are taken): false if the user cancelled. Swapped in
  /// tests.
  @visibleForTesting
  static Future<bool> Function(List<String> paths, String folder, {bool move}) transfer = NativeImaging.transfer;

  /// The file at [path]'s size and when it was last changed: enough to tell
  /// one picture from another with the same name.
  static (int, DateTime) _sizeAndTime(String path) {
    final stat = File(path).statSync();
    return (stat.size, stat.modified);
  }

  /// Copies [chosen] off the phone into [folder], adding each file written
  /// to [written].
  Future<void> _copyOffPhone(List<PhonePicture> chosen, String folder, List<String> written) async {
    copying = (done: 0, total: chosen.length);
    notifyListeners();
    for (final (i, picture) in chosen.indexed) {
      final bytes = await readFromPhone(picture.phone.serial, picture.entry.id);
      final file = await File(await _freeName(folder, picture.name)).writeAsBytes(bytes, flush: true);
      written.add(file.path);
      if (picture.entry.modified case final modified?) await file.setLastModified(modified);
      copying = (done: i + 1, total: chosen.length);
      notifyListeners();
    }
    copying = null;
    notifyListeners();
  }

  /// Reads a picture off a phone, whole: Windows' WPD, or a stand-in in tests.
  @visibleForTesting
  static Future<Uint8List> Function(String serial, String objectId) readFromPhone = Phones.read;

  // --- The clipboard --------------------------------------------------------

  /// Whether the selection can be copied to the clipboard (Ctrl+C): on
  /// Windows, pictures on this PC or on a phone. Not while a copy off a
  /// phone ("Copy to PC…") is under way: both would count in [copying].
  bool get canCopyToClipboard =>
      Platform.isWindows && _selected.isNotEmpty && !copyingToClipboard && copying == null;

  /// Whether the selection's being put on the clipboard: read and decoded
  /// (a RAW file can take a second or two), or copied off a phone first.
  var copyingToClipboard = false;

  /// Puts the selection on the clipboard (with [putOnClipboard]) as File
  /// Explorer copies files, so Ctrl+V pastes them into a folder, an email
  /// or a chat. One picture's put there as a picture too, for what takes
  /// pictures rather than files (Paint, a document). A phone's are copied
  /// off it first, into a folder of the app's own in Windows' temporary
  /// files, as there's no file on this PC to hand over. Returns what to tell
  /// the user: that it's done, or why it couldn't be.
  Future<String?> copyToClipboard() async {
    final chosen = selection;
    if (!canCopyToClipboard) return null;
    copyingToClipboard = true;
    notifyListeners();
    final paths = [for (final picture in chosen.whereType<LocalPicture>()) picture.file.path];
    final onPhone = chosen.whereType<PhonePicture>().toList();
    try {
      if (onPhone.isNotEmpty) await _copyOffPhone(onPhone, (await _clipboardFolder()).path, paths);
      await putOnClipboard(
        paths,
        picture: paths.length == 1 ? paths.single : null,
        maxSize: clipboardPictureSize,
      );
    } on NativeImagingException catch (e) {
      return 'Couldn\'t copy ${_describe(chosen)} ($e).';
    } on FileSystemException catch (e) {
      return 'Couldn\'t copy ${_describe(chosen)}: ${e.osError?.message ?? e.message}';
    } on Exception catch (e) {
      // A phone unplugged part way, say: still told, as Ctrl+C doesn't wait
      // to hear how it went.
      return 'Couldn\'t copy ${_describe(chosen)} ($e).';
    } finally {
      // Only this copy's own count off a phone: no other's can be under way,
      // as [canCopyToClipboard] waits for it.
      if (onPhone.isNotEmpty) copying = null;
      copyingToClipboard = false;
      notifyListeners();
    }
    return chosen.length == 1
        ? 'Copied ${chosen.single.name}. Paste it into a folder, a chat or a document.'
        : 'Copied ${chosen.length} pictures. Paste them into a folder, an email or a chat.';
  }

  /// Puts files on the clipboard: Windows', or a stand-in in tests.
  @visibleForTesting
  static Future<void> Function(List<String> paths, {String? picture, int maxSize}) putOnClipboard =
      NativeImaging.copyFiles;

  /// The longest side a picture's put on the clipboard at, as a picture:
  /// a 45-megapixel photo whole would be 180 MB of bitmap, held twice over
  /// while it's handed to Windows. At 4096 it's at most 64 MB (45 MB for a
  /// 3:2 photo), plenty for Paint or a document.
  static const clipboardPictureSize = 4096;

  /// Where pictures copied off a phone for the clipboard go: emptied each
  /// time, as the clipboard only holds the last of them. (One that's open
  /// somewhere is left; a picture of the same name then takes another.)
  static Future<Directory> _clipboardFolder() async {
    final folder = Directory(p.join(Directory.systemTemp.path, 'Glide clipboard'));
    if (await folder.exists()) {
      await for (final entry in folder.list()) {
        try {
          await entry.delete(recursive: true);
        } on FileSystemException {
          // In use: left.
        }
      }
    }
    return folder.create(recursive: true);
  }

  /// Renames [from] to [to], trying a few times over half a second or so:
  /// antivirus or the indexer can hold a file just written for a moment.
  /// [to] once it's done; null if it still can't be.
  @visibleForTesting
  static Future<String?> renameWithRetries(String from, String to, {int attempts = 5}) async {
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        await File(from).rename(to);
        return to;
      } on FileSystemException {
        if (attempt < attempts) await Future<void>.delayed(Duration(milliseconds: 40 * attempt));
      }
    }
    return null;
  }

  /// [name] in [folder], or "name (2)" and so on if it's taken.
  static Future<String> _freeName(String folder, String name) async {
    final stem = p.basenameWithoutExtension(name);
    final extension = p.extension(name);
    var path = p.join(folder, name);
    for (var n = 2; await File(path).exists(); n++) {
      path = p.join(folder, '$stem ($n)$extension');
    }
    return path;
  }

  /// Formats Windows can write back as they were. Others (RAW, HEIC, WebP,
  /// GIF's animation) are saved as a JPEG copy instead.
  static const _rewritable = {'.jpg', '.jpeg', '.png', '.tif', '.tiff', '.bmp'};

  /// Whether an edit of [picture] can replace it, rather than only be saved
  /// as a copy. With its [background] removed, only a PNG can: other
  /// formats lose the transparency, so it's saved as a PNG copy.
  static bool canReplace(Picture picture, {BackgroundEffect background = BackgroundEffect.none}) {
    // On a phone, only copies: Android has no Recycle Bin for the original.
    if (picture is LocalPicture && picture.galleryId != null) return false;
    final extension = p.extension(picture.name).toLowerCase();
    return background == BackgroundEffect.remove ? extension == '.png' : _rewritable.contains(extension);
  }

  /// Saves [picture] adjusted and filtered by [look], its [background]
  /// changed where [mask] says it's not the subject (to [backgroundColor]
  /// for a replacement; spread [blurSpread] for a blur), turned, flipped and
  /// cropped: in its place (the original to the Recycle Bin, so it can be
  /// had back), or [asCopy] beside it as "name (edited)". Keeps its date.
  /// Focuses what was saved and returns what to tell the user; null if they
  /// cancelled.
  Future<String?> saveEdit(
    LocalPicture picture, {
    required int quarterTurns,
    required bool flip,
    required (double, double, double, double) crop,
    required bool asCopy,
    BackgroundEffect background = BackgroundEffect.none,
    int backgroundColor = 0xFFFFFF,
    double blurSpread = defaultBlurSpread,
    SubjectMask? mask,
    Look look = Look.none,
  }) async {
    if (picture.galleryId case final id?) {
      return _saveGalleryEdit(
        picture,
        id,
        quarterTurns: quarterTurns,
        flip: flip,
        crop: crop,
        background: background,
        backgroundColor: backgroundColor,
        blurSpread: blurSpread,
        mask: mask,
        look: look,
      );
    }
    final source = picture.file.path;
    final folder = p.dirname(source);
    final stem = p.basenameWithoutExtension(source);
    final removing = background == BackgroundEffect.remove;
    final keepFormat = canReplace(picture, background: background);
    final extension = keepFormat ? p.extension(source) : (removing ? '.png' : '.jpg');
    final modified = await picture.file.lastModified();
    Future<void> write(String to) => NativeImaging.edit(
      source,
      to,
      quarterTurns: quarterTurns,
      flip: flip,
      crop: crop,
      asJpeg: !keepFormat && !removing,
      asPng: !keepFormat && removing,
      background: background,
      backgroundColor: backgroundColor,
      blurSpread: blurSpread,
      mask: mask,
      look: look,
    );

    String saved;
    try {
      if (asCopy || !keepFormat) {
        saved = await _freeName(folder, '$stem (edited)$extension');
        await write(saved);
      } else {
        // Written aside first, so a failure leaves the original as it was.
        final temporary = await _freeName(folder, '$stem (saving)$extension');
        try {
          await write(temporary);
          if (!await NativeImaging.recycle([source])) {
            await File(temporary).delete();
            return null;
          }
        } catch (_) {
          // The original's still where it was: the edit is what goes.
          if (await File(temporary).exists()) await File(temporary).delete();
          rethrow;
        }
        // The original's in the Recycle Bin now, so from here the edit is
        // kept, even if it can't take the original's name: then "(edited)",
        // or failing that, where it was written.
        saved =
            await renameWithRetries(temporary, source) ??
            await renameWithRetries(temporary, await _freeName(folder, '$stem (edited)$extension')) ??
            temporary;
      }
      try {
        await File(saved).setLastModified(modified);
      } on FileSystemException {
        // Saved all the same, dated now.
      }
    } on NativeImagingException catch (e) {
      return 'Couldn\'t save ${picture.name} ($e).';
    } on FileSystemException catch (e) {
      return 'Couldn\'t save ${picture.name}: ${e.osError?.message ?? e.message}';
    }

    // Thumbnails and previews of the old picture are out of date.
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    // Saved in its place, it's another size now: looked at afresh.
    await _changed(added: [saved]);
    if (_byId(saved) case final result?) click(result);
    if (saved == source) return 'Saved ${picture.name}.';
    if (asCopy || !keepFormat) return 'Saved a copy as ${p.basename(saved)}.';
    return 'Saved as ${p.basename(saved)}: ${picture.name} was in use. The original\'s in the Recycle Bin.';
  }

  /// [saveEdit] on a phone: always a copy, into its gallery beside the
  /// original, which is left as it was.
  Future<String?> _saveGalleryEdit(
    LocalPicture picture,
    int id, {
    required int quarterTurns,
    required bool flip,
    required (double, double, double, double) crop,
    required BackgroundEffect background,
    required int backgroundColor,
    required double blurSpread,
    required SubjectMask? mask,
    required Look look,
  }) async {
    final ({int id, String path}) saved;
    try {
      saved = await Gallery.saveEditedCopy(
        id,
        quarterTurns: quarterTurns,
        flip: flip,
        crop: crop,
        look: look,
        background: background,
        backgroundColor: backgroundColor,
        blurSpread: blurSpread,
        mask: mask,
      );
    } on PlatformException catch (e) {
      return 'Couldn\'t save ${picture.name} (${e.message ?? e.code}).';
    }
    // Listed again, to show the copy, and focused.
    await refresh();
    if (pictures.where((other) => other is LocalPicture && other.galleryId == saved.id).firstOrNull case final copy?) {
      click(copy);
    }
    return 'Saved a copy as ${p.basename(saved.path)}.';
  }

  static String _describe(List<Picture> pictures) =>
      pictures.length == 1 ? pictures.single.name : '${pictures.length} pictures';

  /// Renames the focused picture, keeping its extension. Returns why it
  /// couldn't, or null.
  Future<String?> renameFocused(String newName) async {
    final picture = focused;
    if (picture is! LocalPicture || !Platform.isWindows) return null;
    final file = picture.file;
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return 'Enter a name.';
    if (RegExp(r'[<>:"/\\|?*]').hasMatch(trimmed)) return 'A name can\'t contain < > : " / \\ | ? *';
    final target = p.join(p.dirname(file.path), trimmed + p.extension(file.path));
    if (target == file.path) return null;
    // Windows' names aren't case-sensitive: one that changes only the case
    // is this file's own, not another's.
    final caseOnly = target.toLowerCase() == file.path.toLowerCase();
    if (!caseOnly && await File(target).exists()) return 'There\'s already a file with that name.';
    try {
      final renamed = LocalPicture(
        await file.rename(target),
        takenMs: picture.takenMs,
        modifiedMs: picture.modifiedMs,
        bytes: picture.bytes,
      );
      // Still a favourite by its new name.
      await Favourites.instance.moved(file.path, target);
      location.forget(gone: [file.path], added: [target]);
      _setAll([for (final other in _all) other.id == picture.id ? renamed : other]);
      if (_selected.remove(picture.id)) _selected.add(renamed.id);
      if (_anchor == picture.id) _anchor = renamed.id;
      focused = renamed;
      notifyListeners();
      return null;
    } on FileSystemException catch (e) {
      return e.osError?.message ?? e.message;
    }
  }

  /// Work outlives the browser (a scan's next batch, a timer): once it's
  /// gone, what that work would tell it is let go.
  var _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _finishedTimer?.cancel();
    super.dispose();
  }
}

/// The ids of the pictures selected, counting each change made to them, so
/// [Browser.selection] knows when it has to be worked out again without
/// every place that changes them having to say so.
class _SelectedIds extends SetBase<String> {
  final _ids = <String>{};

  /// Goes up with each change.
  int version = 0;

  @override
  bool add(String id) {
    final added = _ids.add(id);
    if (added) version++;
    return added;
  }

  @override
  bool remove(Object? id) {
    final removed = _ids.remove(id);
    if (removed) version++;
    return removed;
  }

  @override
  void clear() {
    if (_ids.isEmpty) return;
    _ids.clear();
    version++;
  }

  @override
  bool contains(Object? id) => _ids.contains(id);

  @override
  String? lookup(Object? id) => _ids.lookup(id);

  @override
  Iterator<String> get iterator => _ids.iterator;

  @override
  int get length => _ids.length;

  @override
  Set<String> toSet() => {..._ids};
}
