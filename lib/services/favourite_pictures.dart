part of 'places.dart';

/// The pictures marked with a heart (see [Favourites]), newest first by
/// month, wherever they are.
///
/// On a phone, those in its gallery ([within]): the gallery's listed as for
/// the Pictures tab, so its favourites have the ids Android knows them by
/// (for their thumbnails, sharing, the trash). On a PC, each favourite's
/// looked at where it is, dated as the library's index has it: it's been
/// listed somewhere already to be marked, and its drive needn't be looked
/// through again to show it. One that isn't there (deleted, or on a drive
/// that isn't plugged in) is left out until it's back.
class FavouritePictures extends Location {
  const FavouritePictures({this.within});

  /// The phone's gallery, whose favourites are shown; null on a PC.
  final Location? within;

  @override
  String get title => 'Favourites';

  @override
  String get subtitle => 'The pictures you\'ve marked with a heart';

  /// With no access to the gallery (on a phone), why, and what to do: as
  /// the gallery says it.
  @override
  String get emptyText => within?.emptyAction != null
      ? within!.emptyText
      : Platform.isAndroid
      ? 'No favourites yet.\nOpen a picture and tap Favourite to see it here.'
      : 'No favourites yet.\nSelect a picture and click the heart (or press F) to see it here.';

  @override
  EmptyAction? get emptyAction => within?.emptyAction;

  @override
  IconData get chipIcon => Icons.favorite_rounded;

  @override
  void forget({Iterable<String> gone = const [], Iterable<String> added = const []}) =>
      within?.forget(gone: gone, added: added);

  @override
  Future<Listing> list() async {
    final favourites = Favourites.instance;
    await favourites.ready;
    if (within case final gallery?) {
      final listing = await gallery.list();
      return Listing(
        [
          for (final picture in listing.pictures)
            if (favourites.contains(picture.id)) picture,
        ],
        pending: listing.pending,
        work: listing.work,
        progress: listing.progress,
      );
    }
    return Listing(await _fromDisk(favourites.paths));
  }

  /// Each of [paths] that's there, as a picture: dated by when it was taken
  /// where the library's index knows (else when it was last changed), with
  /// the camera it names.
  static Future<List<Picture>> _fromDisk(List<String> paths) async {
    final stats = await Future.wait([for (final path in paths) FileStat.stat(path)]);
    final index = await LibraryIndex.load();
    final latest = _latest();
    // Those listed before, kept while they're as they were, as a library's
    // are: what's selected and focused stays put when it's listed again.
    final before = _listed;
    final listed = <String, LocalPicture>{};
    for (final (i, stat) in stats.indexed) {
      if (stat.type != FileSystemEntityType.file) continue;
      final path = paths[i];
      final modified = stat.modified.millisecondsSinceEpoch;
      final known = index.read(path, size: stat.size, modified: modified);
      final takenMs = _plausible(known?.taken, latest);
      final modifiedMs = _plausible(modified, latest);
      final camera = switch (known?.camera) {
        final camera? when camera.isNotEmpty => camera,
        _ => null,
      };
      final was = before[path];
      listed[path] =
          was != null &&
              was.takenMs == takenMs &&
              was.modifiedMs == modifiedMs &&
              was.bytes == stat.size &&
              was.camera == camera
          ? was
          : LocalPicture(File(path), takenMs: takenMs, modifiedMs: modifiedMs, bytes: stat.size, camera: camera);
    }
    _listed = listed;
    return listed.values.toList()..sort(_newestFirst);
  }

  /// The favourites on this PC as they were last listed, by path.
  static var _listed = <String, LocalPicture>{};

  /// Forgets what was listed, as if the app had just started: for tests.
  @visibleForTesting
  static void forgetAll() => _listed = {};

  @override
  bool operator ==(Object other) => other is FavouritePictures && other.within == within;

  @override
  int get hashCode => Object.hash(FavouritePictures, within);
}
