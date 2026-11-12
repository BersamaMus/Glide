import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

import 'gallery.dart';
import 'library_index.dart';
import 'picture_image.dart';

part 'android_gallery.dart';
part 'memories.dart';
part 'phone_photos.dart';
part 'photo_library.dart';

/// Files Flutter decodes itself, on every platform.
const flutterExtensions = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'};

/// Files shown as pictures: on Windows, also those Windows' codecs decode.
bool isImage(String name) {
  final extension = p.extension(name).toLowerCase();
  return flutterExtensions.contains(extension) ||
      (Platform.isWindows && windowsCodecExtensions.contains(extension));
}

/// What kind of picture a file is, by its name: the grid's filter chips.
String pictureType(String name) => switch (p.extension(name).toLowerCase()) {
  '.jpg' || '.jpeg' => 'JPG',
  '.png' => 'PNG',
  '.gif' => 'GIF',
  '.webp' => 'WebP',
  '.heic' || '.heif' => 'HEIC',
  '.avif' => 'AVIF',
  '.tif' || '.tiff' => 'TIFF',
  '.bmp' => 'BMP',
  _ => 'RAW',
};

/// What a picture is, by its name and the folder it's in: a screenshot
/// (Windows', Android's, an iPhone's or a Mac's), or a photo (or any other
/// picture). The grid's second row of filter chips. Only the picture's own
/// folder counts, not those it's in: every photo on a drive called
/// "Screenshots and camera backup" isn't a screenshot. Worked out once per
/// picture: see [Picture.kind].
String pictureKind(Picture picture) {
  final name = picture.name.toLowerCase();
  if (_screenshotNames.any(name.contains)) return 'Screenshots';
  final folder = switch (picture) {
    LocalPicture(:final file) => p.basename(p.dirname(file.path)),
    PhonePicture(:final folder) => p.basename(folder),
  }.toLowerCase();
  if (folder.contains('screenshot') || folder.contains('screen shot')) return 'Screenshots';
  return 'Photos';
}

/// What screenshots are called, in a few languages.
const _screenshotNames = [
  'screenshot', 'screen shot', 'screen_shot', 'screencap', 'bildschirmfoto', //
  "capture d'écran", 'capture d’écran', "capture d'ecran", 'capture d’ecran',
  'schermata', 'captura de pantalla', 'tangkapan layar', 'skärmavbild',
];

/// Hidden and system folders ($RECYCLE.BIN, .thumbnails) hold no pictures
/// worth showing, and can be huge.
bool _hidden(String name) => name.startsWith('.') || name.startsWith(r'$');

int _byName(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());

/// The earliest a picture's date could be, in ms since 1970: before it, a
/// clock that was never set (1970 or 1980, where computers' and memory
/// cards' clocks start).
final int _earliest = DateTime(1980, 1, 2).millisecondsSinceEpoch;

/// The latest it could be (a day from now; after, a camera's set wrong).
/// Worked out once per listing, not per picture: tens of thousands of times
/// over, asking the time and the time zone took seconds.
int _latest() => DateTime.now().millisecondsSinceEpoch + Duration.millisecondsPerDay;

/// [ms] since 1970 as a date, if it's one a picture could have; [latest] is
/// [_latest].
DateTime? _plausible(int? ms, int latest) =>
    ms == null || ms < _earliest || ms > latest ? null : DateTime.fromMillisecondsSinceEpoch(ms);

/// The time zone's offset on each day (in ms since 1970 / a day's ms),
/// asked of the system once a day rather than once a picture: tens of
/// thousands of pictures' local months, one by one, kept the app waiting.
final _offsets = <int, int>{};

/// [date] as the clock here showed it: a UTC date whose year, month, day
/// and time are the local ones, quick to read for thousands of pictures.
DateTime localDate(DateTime date) {
  final ms = date.millisecondsSinceEpoch;
  final day = ms ~/ Duration.millisecondsPerDay;
  final offset = _offsets.putIfAbsent(
    day,
    () => DateTime.fromMillisecondsSinceEpoch(day * Duration.millisecondsPerDay).timeZoneOffset.inMilliseconds,
  );
  return DateTime.fromMillisecondsSinceEpoch(ms + offset, isUtc: true);
}

const monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// Its month, as year * 12 + month; 0 for no date.
int monthOf(Picture picture) {
  final date = picture.date;
  if (date == null) return 0;
  final local = localDate(date);
  return local.year * 12 + local.month;
}

/// [month]'s heading ([monthOf]); "Date unknown" for pictures with no date
/// they could have (sorted last).
String monthLabel(int month) {
  if (month == 0) return 'Date unknown';
  final (year, ofYear) = ((month - 1) ~/ 12, (month - 1) % 12);
  return '${monthNames[ofYear]} $year';
}

/// Newest first; pictures without a date after all the rest.
int _newestFirst(Picture a, Picture b) {
  final (x, y) = (a.date, b.date);
  if (x != y) {
    if (x == null) return 1;
    if (y == null) return -1;
    final byDate = y.compareTo(x);
    if (byDate != 0) return byDate;
  }
  return _byName(a.name, b.name);
}

/// A picture shown in the grid and the preview pane, wherever it is.
sealed class Picture {
  /// Tells pictures apart, for the selection.
  String get id;
  String get name;

  /// What it's sorted and grouped by: when it was taken, or else last
  /// changed; null if neither's a date it could have.
  DateTime? get date;

  /// For a tile: small, and quick to get.
  ImageProvider thumbnail(int size);

  /// For the preview, with neither side over [maxSize].
  ImageProvider image(int maxSize);

  /// Its size in bytes, date, and width and height where they're known.
  Future<PictureInfo> info();

  /// Its size in bytes, where the listing found out: null if it didn't.
  int? get bytes;

  /// Where it is: its folder, or the folder on the phone.
  String get place;

  /// A photo or a screenshot: see [pictureKind]. Worked out the first time
  /// it's asked, as the grid's filter asks of every picture on every listing.
  late final String kind = pictureKind(this);

  /// What it says about itself (camera, settings, where it was taken), for
  /// the picture previewed; null where that can't be read. On a phone, the
  /// file's read whole (as it is for the preview anyway).
  Future<PhotoDetails?> details();
}

class PictureInfo {
  const PictureInfo({this.bytes, this.modified, this.taken, this.dimensions});

  final int? bytes;
  final DateTime? modified;

  /// When it was taken, where that's known.
  final DateTime? taken;
  final (int, int)? dimensions;
}

/// A picture in a folder on this device.
class LocalPicture extends Picture {
  LocalPicture(this.file, {this.taken, this.modified, this.bytes, this.galleryId, this.dimensions});

  @override
  final int? bytes;

  final File file;

  /// When it was taken and last changed, where the listing found out (the
  /// library, which sorts by them).
  final DateTime? taken;
  final DateTime? modified;

  /// On Android, its id in the phone's gallery: for the thumbnail and
  /// metadata Android keeps of it.
  final int? galleryId;

  /// Its width and height upright, where the listing found out.
  final (int, int)? dimensions;

  @override
  DateTime? get date => taken ?? modified;

  @override
  String get id => file.path;

  @override
  String get name => p.basename(file.path);

  @override
  ImageProvider thumbnail(int size) =>
      galleryId != null ? GalleryThumbnail(galleryId!, size) : pictureThumbnail(file, size: size);

  @override
  ImageProvider image(int maxSize) => pictureImage(file, maxSize: maxSize);

  @override
  Future<PictureInfo> info() async {
    final stat = await file.stat();
    return PictureInfo(
      bytes: stat.size,
      modified: stat.modified,
      taken: taken,
      dimensions: dimensions ?? await pictureSize(file),
    );
  }

  @override
  String get place => file.parent.path;

  @override
  Future<PhotoDetails?> details() async {
    try {
      if (galleryId case final id?) return await Gallery.details(id);
      if (!Platform.isWindows) return null;
      return await NativeImaging.details(file.path);
    } on Object {
      return null;
    }
  }
}

/// A picture on a phone connected by USB.
class PhonePicture extends Picture {
  PhonePicture(this.phone, this.entry, {int? latest, this.folder = ''})
    : date = _plausible(entry.modified?.millisecondsSinceEpoch, latest ?? _latest());

  final Phone phone;
  final PhoneEntry entry;

  @override
  int get bytes => entry.size;

  /// The folder it's in on the phone: "DCIM/Camera".
  final String folder;

  @override
  String get id => 'phone:${phone.serial}/${entry.id}';

  @override
  String get name => entry.name;

  /// The phone's date for the file: for a camera's photo, when it was taken.
  @override
  final DateTime? date;

  @override
  ImageProvider thumbnail(int size) => PhoneImage(phone.serial, entry.id, entry.name, size, thumbnail: true);

  @override
  ImageProvider image(int maxSize) => PhoneImage(phone.serial, entry.id, entry.name, maxSize);

  @override
  Future<PictureInfo> info() async => PictureInfo(bytes: entry.size, modified: entry.modified);

  @override
  String get place => folder.isEmpty ? phone.name : '${phone.name}/$folder';

  @override
  Future<PhotoDetails?> details() async {
    try {
      return await NativeImaging.detailsOfBytes(await phoneFile(phone.serial, entry.id));
    } on Object {
      return null;
    }
  }
}

/// A button offered when a location has nothing to show: see
/// [Location.emptyAction].
typedef EmptyAction = ({String label, Future<void> Function() onPressed});

/// Work a location's still doing on its listing.
enum Work {
  /// Finding its pictures.
  looking,

  /// Reading when they were taken, to put them in their places.
  sorting,
}

/// What a location holds.
class Listing {
  const Listing(this.pictures, {this.pending, this.work, this.progress});

  final List<Picture> pictures;

  /// Work still going on that will make a better listing: list again once
  /// it's done.
  final Future<void>? pending;

  /// What that work is, for the user; null for work done quietly (looking
  /// again behind what's shown).
  final Work? work;

  /// How far along it is, 0 to 1; null if that can't be told (looking,
  /// where there's no knowing how much is left).
  final double? progress;
}

/// Somewhere whose pictures the browser shows, newest first by month, as in
/// Photos: a folder and all in it, a drive, or a phone.
sealed class Location {
  const Location();

  String get title;
  String get subtitle;

  /// Said when there's nothing here.
  String get emptyText => 'No pictures here.';

  /// What can be done about there being nothing here (giving access to the
  /// phone's photos, say): a button under [emptyText], after which it's
  /// listed again. Null for none.
  EmptyAction? get emptyAction => null;

  /// Whether it's one of several of its kind (a drive, or a phone), with
  /// [sources] to switch between.
  bool get switchable => false;

  /// The others of its kind there are (the drives, or the phones), shown as
  /// chips to switch between.
  Future<List<Location>> sources() async => const [];

  /// Its chip among [sources].
  String get chipLabel => title;
  IconData get chipIcon => Icons.folder_rounded;

  /// Whether [other] is this as it is now: a phone that's been unlocked, say.
  bool sameSource(Location other) => other == this;

  /// What to show once [sources] has none: no phone, say. Null to stay.
  Location? get withoutSources => null;

  /// Its pictures may have changed: looks again the next time it's listed.
  /// [gone] and [added] are the paths the app itself has deleted or moved
  /// away, and saved or moved here, so they're shown that way meanwhile.
  void forget({Iterable<String> gone = const [], Iterable<String> added = const []}) {}

  Future<Listing> list();

  /// Which heading the grid shows [picture] under, as a number that's the
  /// same for all the pictures under one heading (which the listing keeps
  /// together): its month, as in Photos.
  int group(Picture picture) => monthOf(picture);

  /// The heading over the pictures in [group].
  String groupLabel(int group) => monthLabel(group);
}

/// The user's Pictures folder, where the app starts.
final String picturesFolder = _findPicturesFolder();

String _findPicturesFolder() {
  // Shared storage on Android; reading it needs the media permission.
  if (!Platform.isWindows) return '/storage/emulated/0/Pictures';
  final profile = Platform.environment['USERPROFILE'] ?? r'C:\';
  // Pictures may have been moved (OneDrive backup moves it into OneDrive),
  // so ask Windows where it is.
  try {
    final result = Process.runSync('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
      '/v',
      'My Pictures',
    ]);
    final match = RegExp(r'REG_(?:EXPAND_)?SZ\s+(.+)').firstMatch(result.stdout as String);
    if (match != null) {
      final path = match.group(1)!.trim().replaceAllMapped(
        RegExp('%([^%]+)%'),
        (m) => Platform.environment[m.group(1)!] ?? m.group(0)!,
      );
      if (Directory(path).existsSync()) return path;
    }
  } on ProcessException {
    // Fall back to the usual place.
  }
  return p.join(profile, 'Pictures');
}
