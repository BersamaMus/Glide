part of 'places.dart';

/// Every picture on this phone, newest first by month, as in its own Photos
/// app: the gallery Android keeps (the camera's, screenshots, downloads,
/// apps' pictures), read once access is given.
class AndroidGallery extends Location {
  const AndroidGallery();

  /// What the app may read, as last asked.
  static var _access = GalleryAccess.all;

  /// Whether Android's prompt has been shown unasked this run: once, the
  /// first time the gallery's opened.
  static var _prompted = false;

  /// The gallery's pictures: Android's, or a stand-in in tests.
  @visibleForTesting
  static Future<List<GalleryEntry>> Function() entries = Gallery.list;

  @override
  String get title => 'Pictures';

  @override
  String get subtitle => _access == GalleryAccess.some ? 'Only the pictures you allowed' : 'On this phone';

  @override
  String get emptyText => switch (_access) {
    GalleryAccess.none => 'Allow access to your photos to see the pictures on this phone.',
    GalleryAccess.blocked =>
      'Access to your photos is turned off.\nTurn it on in Settings, under Permissions, then Photos and videos.',
    GalleryAccess.some => 'None of the pictures you allowed are here.',
    GalleryAccess.all => 'No pictures on this phone yet.',
  };

  @override
  EmptyAction? get emptyAction => switch (_access) {
    GalleryAccess.none => (label: 'Allow access', onPressed: _ask),
    GalleryAccess.blocked => (label: 'Open Settings', onPressed: Gallery.openSettings),
    GalleryAccess.some => (label: 'Choose more', onPressed: _ask),
    GalleryAccess.all => null,
  };

  static Future<void> _ask() async => _access = await Gallery.askForAccess();

  @override
  Future<Listing> list() async {
    _access = await Gallery.access();
    if (_access == GalleryAccess.none && !_prompted) {
      _prompted = true;
      await _ask();
    }
    if (_access == GalleryAccess.none || _access == GalleryAccess.blocked) {
      // Access taken away: what was listed isn't held on to.
      _listed = {};
      return const Listing([]);
    }

    final latest = _latest();
    // Those listed before, kept where they're as they were: the gallery's
    // listed again each time the app's come back to, and making thousands of
    // pictures anew (and working out each one's name, type and kind again)
    // held the app up just as it was picked up again.
    final before = _listed;
    final listed = <int, LocalPicture>{};
    // The cameras read before, kept in the library's index by path: loaded
    // while Android lists the gallery, not before. It's megabytes of JSON
    // with a big library, and the gallery's what a phone shows first: if
    // it's not ready yet, the pictures are shown without their cameras and
    // listed again once it is.
    final loading = LibraryIndex.load();
    final unread = <GalleryEntry>[];
    // While cameras are read it's listed again every second or so, to show
    // them: the gallery as Android last listed it, rather than asked for
    // thousands of pictures again each time.
    final all = _reader?.done == false ? (_entries ?? await entries()) : await entries();
    final index = LibraryIndex.loaded;
    for (final entry in all) {
      final read = index?.camera(entry.path, size: entry.bytes, modified: entry.modified);
      // Each tried once a run at most: one that couldn't be read just now is
      // tried again next run, and two of Android's entries for one path
      // (which share an entry in the index) don't start reading over and
      // over.
      if (read == null && index != null && !_tried.contains(entry.id)) unread.add(entry);
      final camera = read == null || read.isEmpty ? null : read;
      final takenMs = _plausible(entry.taken == 0 ? null : entry.taken, latest);
      final modifiedMs = _plausible(entry.modified, latest);
      final dimensions = entry.width > 0 && entry.height > 0 ? (entry.width, entry.height) : null;
      final was = before[entry.id];
      listed[entry.id] =
          was != null &&
              was.file.path == entry.path &&
              was.takenMs == takenMs &&
              was.modifiedMs == modifiedMs &&
              was.bytes == entry.bytes &&
              was.dimensions == dimensions &&
              was.camera == camera
          ? was
          : LocalPicture(
              File(entry.path),
              takenMs: takenMs,
              modifiedMs: modifiedMs,
              bytes: entry.bytes,
              galleryId: entry.id,
              dimensions: dimensions,
              camera: camera,
            );
    }
    _listed = listed;
    final pictures = listed.values.toList()..sort(_newestFirst);
    if (index == null) {
      _entries = null;
      return Listing(pictures, pending: loading);
    }

    // The cameras not read yet (all of them, the first time), read behind
    // what's shown: the pictures are in their places already, by Android's
    // dates, and their camera chips come as they're read.
    var reader = _reader;
    if ((reader == null || (reader.done && !reader.failed)) && unread.isNotEmpty) {
      for (final entry in unread) {
        _tried.add(entry.id);
      }
      reader = _reader = _IndexReader(unread, index, _readCameras, work: Work.cameras, atOnce: 2, each: 100);
    }
    // The gallery as Android listed it: only held on to while it's needed.
    final reading = reader != null && !reader.done;
    _entries = reading ? all : null;
    if (reading) {
      return Listing(pictures, pending: reader.next, work: Work.cameras, progress: reader.progress);
    }
    // Pictures gone from the gallery since: forgotten, once a run.
    if (!_pruned) {
      _pruned = true;
      final paths = {for (final picture in pictures) picture.file.path: null};
      if (await index.keepOnly(paths, under: '/')) unawaited(index.save());
    }
    return Listing(pictures);
  }

  /// Reads the cameras of the pictures [some] into [index]: see
  /// [_IndexReader].
  static Future<void> _readCameras(List<GalleryEntry> some, LibraryIndex index) async {
    final List<({String? make, String? model})?> cameras;
    try {
      cameras = await readCameras([for (final entry in some) entry.id]);
    } on PlatformException {
      // This lot couldn't be read: tried again next run, rather than the
      // rest not read at all.
      return;
    }
    for (final (i, camera) in cameras.indexed) {
      // Couldn't be read just now (a card taken out, access changed, a
      // file still being written): tried again next run, rather than kept
      // as saying nothing.
      if (camera == null) continue;
      final entry = some[i];
      index.put(
        entry.path,
        size: entry.bytes,
        modified: entry.modified,
        taken: entry.taken,
        camera: cameraName(camera.make, camera.model) ?? '',
      );
    }
  }

  /// The cameras the gallery's pictures were taken on (null for one that
  /// couldn't be read just now): read from each by Android, or a stand-in in
  /// tests.
  @visibleForTesting
  static Future<List<({String? make, String? model})?>> Function(List<int> ids) readCameras = Gallery.cameras;

  /// The pictures whose cameras have been read this run, or tried, by
  /// Android's id: see [list].
  static var _tried = <int>{};

  /// The cameras being read, if they are.
  static _IndexReader<GalleryEntry>? _reader;

  /// The gallery as Android last listed it, while cameras are being read:
  /// see [list].
  static List<GalleryEntry>? _entries;

  /// Pictures deleted or saved by the app, or the app come back to: Android's
  /// asked again next time, even while cameras are being read.
  @override
  void forget({Iterable<String> gone = const [], Iterable<String> added = const []}) => _entries = null;

  /// The index has been rid of pictures gone from the gallery, this run.
  static var _pruned = false;

  /// The gallery's pictures as they were last listed, by Android's id.
  /// Kept for the whole run, not just while the gallery's shown: on a phone
  /// it's what the app shows first and comes back to (Memories lists it
  /// too), so it would only be made again.
  static var _listed = <int, LocalPicture>{};

  /// Forgets what was listed, as if the app had just started: for tests,
  /// so one's pictures aren't handed out again in the next.
  @visibleForTesting
  static void forgetAll() {
    _listed = {};
    _reader = null;
    _entries = null;
    _tried = {};
    _pruned = false;
  }

  @override
  bool operator ==(Object other) => other is AndroidGallery;

  @override
  int get hashCode => (AndroidGallery).hashCode;
}
