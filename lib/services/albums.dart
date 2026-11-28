part of 'places.dart';

/// Where pictures came from, as their folders and names say: the Albums
/// tab's chips. A picture can be in more than one: one sent in WhatsApp and
/// saved to Downloads is in both.
enum AlbumKind {
  camera('Camera', Icons.photo_camera_rounded, 'Taken with the camera'),
  screenshots('Screenshots', Icons.screenshot_monitor_rounded, 'Taken of the screen'),
  downloads('Downloads', Icons.download_rounded, 'Saved from the web, emails and apps'),
  whatsapp('WhatsApp', Icons.chat_rounded),
  telegram('Telegram', Icons.telegram),
  instagram('Instagram', Icons.camera_alt_rounded),
  messenger('Messenger', Icons.messenger_outline_rounded),
  facebook('Facebook', Icons.facebook),
  snapchat('Snapchat', Icons.snapchat),
  signal('Signal', Icons.forum_rounded),
  discord('Discord', Icons.discord);

  const AlbumKind(this.label, this.icon, [this._about]);

  final String label;
  final IconData icon;
  final String? _about;

  /// What's in it, under its name.
  String get about => _about ?? 'Sent, received and saved in $label';
}

/// The albums [picture] is in (see [AlbumKind]), by the folders it's in and
/// its name. Worked out once per picture: see [Picture.albums].
///
/// An app's pictures are in its folder, wherever that is: "WhatsApp Images"
/// (or Android 11's Android/media/com.whatsapp), "Telegram Images", a
/// backup of a phone's copied to a drive. WhatsApp's are known by their
/// names too ("IMG-20250101-WA0001.jpg" on a phone, "WhatsApp Image ..." from
/// WhatsApp on a PC), saved somewhere else. Its stickers aren't anyone's
/// pictures. The camera's are under DCIM (the camera's folder, on a phone or
/// a memory card) or in Windows' Camera Roll, less screenshots and apps'.
List<AlbumKind> albumsOf(Picture picture) {
  final folder = switch (picture) {
    LocalPicture(:final file) => file.parent.path,
    PhonePicture(:final folder) => folder,
  }.toLowerCase();
  final folders = folder.split(RegExp(r'[\\/]'));
  final name = picture.name.toLowerCase();
  bool inFolder(bool Function(String folder) test) => folders.any(test);
  bool named(String part) => inFolder((folder) => folder.contains(part));
  final apps = [
    if ((named('whatsapp') && !named('sticker')) || name.startsWith('whatsapp image') || _whatsAppName.hasMatch(name))
      AlbumKind.whatsapp,
    if (named('telegram')) AlbumKind.telegram,
    if (named('instagram')) AlbumKind.instagram,
    if (inFolder((folder) => folder == 'messenger' || folder == 'com.facebook.orca')) AlbumKind.messenger,
    if (inFolder((folder) => folder == 'facebook' || folder == 'com.facebook.katana')) AlbumKind.facebook,
    if (named('snapchat')) AlbumKind.snapchat,
    if (inFolder((folder) => folder == 'signal' || folder == 'org.thoughtcrime.securesms')) AlbumKind.signal,
    if (named('discord')) AlbumKind.discord,
  ];
  final screenshot = picture.kind == 'Screenshots';
  final camera = inFolder((folder) => folder == 'dcim') || const {'camera', 'camera roll'}.contains(folders.last);
  return [
    if (camera && !screenshot && apps.isEmpty) AlbumKind.camera,
    if (screenshot) AlbumKind.screenshots,
    if (inFolder((folder) => folder == 'download' || folder == 'downloads') || _inDownloads(folder))
      AlbumKind.downloads,
    ...apps,
  ];
}

/// What WhatsApp on a phone calls the pictures it's sent: "IMG-20250101-WA0001".
final _whatsAppName = RegExp(r'^img-\d{8}-wa\d+');

/// Whether [folder] (lowercased) is the user's Downloads folder or in it,
/// wherever it's been moved to.
bool _inDownloads(String folder) =>
    folder == _downloads ||
    folder.startsWith(_downloads.endsWith(p.separator) ? _downloads : '$_downloads${p.separator}');

final _downloads = downloadsFolder.toLowerCase();

/// One album: the pictures of a kind (see [AlbumKind]) among [from]'s,
/// newest first by month, with chips to switch to the other albums that
/// have pictures, as drives have, rather than folders to go into.
///
/// The pictures are [from]'s: on a phone, its gallery; on a PC, the Pictures
/// and Downloads folders and every drive inside it (a picture found in more
/// than one shown once). While they're still being looked through, what's
/// been found so far is shown, and filled in as more is.
class Album extends Location {
  const Album(this.kind, this.from);

  final AlbumKind kind;
  final List<Location> from;

  /// How many pictures each album had at the last listing of any of them,
  /// and of what: so the chips say which albums have pictures (and come as
  /// a scan finds them) without listing everything again.
  static ({List<Location> from, Map<AlbumKind, int> counts})? _counted;

  /// [_counted], if it's of [from]'s pictures.
  Map<AlbumKind, int>? get _counts => switch (_counted) {
    (:final from, :final counts) when listEquals(from, this.from) => counts,
    _ => null,
  };

  /// How many pictures each album has, listing them if that isn't known.
  Future<Map<AlbumKind, int>> _countAll() async {
    if (_counts case final counts?) return counts;
    await list();
    return _counts ?? const {};
  }

  /// The album to open the Albums tab on: [preferred] (the one looked at
  /// last) while it has pictures, else the first that has; the camera's if
  /// none has.
  static Future<Album> choose(List<Location> from, {AlbumKind? preferred}) async {
    final first = Album(preferred ?? AlbumKind.camera, from);
    await first._countAll();
    return first.instead ?? first;
  }

  /// The album to show in this one's place, as it has no pictures: the
  /// first that has, once that's known from a listing. Null while this one
  /// has pictures, none has, or it isn't known yet. The Albums tab opens
  /// straight away on the album looked at last, then moves on with this.
  Album? get instead {
    final counts = _counts;
    if (counts == null || (counts[kind] ?? 0) > 0) return null;
    for (final kind in AlbumKind.values) {
      if ((counts[kind] ?? 0) > 0) return Album(kind, from);
    }
    return null;
  }

  Location get _first => from.first;

  @override
  String get title => kind.label;

  @override
  String get subtitle => kind.about;

  /// With no access to the pictures (on a phone), why, and what to do: as
  /// the gallery says it.
  @override
  String get emptyText {
    if (_first.emptyAction != null) return _first.emptyText;
    if (_counts case final counts? when counts.isEmpty) {
      return 'No albums yet.\nPictures from the camera, screenshots, downloads, '
          'and apps like WhatsApp and Telegram will show here.';
    }
    return 'No pictures in ${kind.label} yet.';
  }

  @override
  EmptyAction? get emptyAction => _first.emptyAction;

  @override
  bool get switchable => true;

  /// The albums that have pictures, the camera's first, then screenshots,
  /// downloads and apps'.
  @override
  Future<List<Location>> sources() async {
    final counts = await _countAll();
    return [
      for (final kind in AlbumKind.values)
        if ((counts[kind] ?? 0) > 0) Album(kind, from),
    ];
  }

  /// "WhatsApp  1,204".
  @override
  String get chipLabel => switch (_counts?[kind]) {
    final count? => '${kind.label}  ${_thousands(count)}',
    null => kind.label,
  };

  @override
  IconData get chipIcon => kind.icon;

  @override
  void forget({Iterable<String> gone = const [], Iterable<String> added = const []}) =>
      _forgetIn(from, gone: gone, added: added);

  @override
  Future<Listing> list() async {
    final listing = await _listAll(from);
    final counts = <AlbumKind, int>{};
    final seen = <String>{};
    final pictures = <Picture>[];
    for (final picture in listing.pictures) {
      // In Pictures, and found on its drive too.
      if (from.length > 1 && !seen.add(picture._sameKey)) continue;
      for (final album in picture.albums) {
        counts[album] = (counts[album] ?? 0) + 1;
        if (album == kind) pictures.add(picture);
      }
    }
    _counted = (from: from, counts: counts);
    // Each source's are in order, but not one after another.
    if (from.length > 1) pictures.sort(_newestFirst);
    return Listing(pictures, pending: listing.pending, work: listing.work, progress: listing.progress);
  }

  /// Forgets which albums have pictures, as if the app had just started:
  /// for tests.
  @visibleForTesting
  static void forgetAll() => _counted = null;

  @override
  bool operator ==(Object other) => other is Album && other.kind == kind && listEquals(other.from, from);

  @override
  int get hashCode => Object.hash(kind, Object.hashAll(from));
}

/// [n] with thousands set apart: 57,821.
String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');
