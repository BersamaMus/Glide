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
    for (final entry in await entries()) {
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
              was.dimensions == dimensions
          ? was
          : LocalPicture(
              File(entry.path),
              takenMs: takenMs,
              modifiedMs: modifiedMs,
              bytes: entry.bytes,
              galleryId: entry.id,
              dimensions: dimensions,
            );
    }
    _listed = listed;
    return Listing(listed.values.toList()..sort(_newestFirst));
  }

  /// The gallery's pictures as they were last listed, by Android's id.
  /// Kept for the whole run, not just while the gallery's shown: on a phone
  /// it's what the app shows first and comes back to (Memories lists it
  /// too), so it would only be made again.
  static var _listed = <int, LocalPicture>{};

  /// Forgets what was listed, as if the app had just started: for tests,
  /// so one's pictures aren't handed out again in the next.
  @visibleForTesting
  static void forgetAll() => _listed = {};

  @override
  bool operator ==(Object other) => other is AndroidGallery;

  @override
  int get hashCode => (AndroidGallery).hashCode;
}
