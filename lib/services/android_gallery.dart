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
    if (_access == GalleryAccess.none || _access == GalleryAccess.blocked) return const Listing([]);

    final latest = _latest();
    final pictures = [
      for (final entry in await entries())
        LocalPicture(
          File(entry.path),
          taken: _plausible(entry.taken == 0 ? null : entry.taken, latest),
          modified: _plausible(entry.modified, latest),
          bytes: entry.bytes,
          galleryId: entry.id,
          dimensions: entry.width > 0 && entry.height > 0 ? (entry.width, entry.height) : null,
        ),
    ]..sort(_newestFirst);
    return Listing(pictures);
  }

  @override
  bool operator ==(Object other) => other is AndroidGallery;

  @override
  int get hashCode => (AndroidGallery).hashCode;
}
