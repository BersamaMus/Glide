import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_data.dart';

/// When each picture in the library was taken, as read from it, kept between
/// runs so a picture is only read again once it's changed.
///
/// Kept as JSON in the app's data folder: for each path, its size and modified
/// time when it was read (to tell if it's changed since), and when it was
/// taken (0 if it doesn't say). With a drive or two's photos that's tens of
/// thousands of entries, megabytes of JSON: read, written and checked against
/// the disk in isolates, so the app doesn't stop while it is.
class LibraryIndex {
  LibraryIndex._(this._file, this._entries);

  final File? _file;
  final Map<String, List<int>> _entries;

  static Future<LibraryIndex>? _loaded;

  /// The index, loaded once.
  static Future<LibraryIndex> load() => _loaded ??= _load();

  static Future<LibraryIndex> _load() async {
    File? file;
    try {
      file = File(p.join((await appDataDirectory()).path, 'library_index.json'));
      final path = file.path;
      return LibraryIndex._(file, await Isolate.run(() => _read(path)));
    } on Object {
      // None yet, or unreadable: start afresh.
      return LibraryIndex._(file, {});
    }
  }

  /// An index kept in [file], for tests.
  static Future<LibraryIndex> at(File file) async {
    _loaded = null;
    final path = file.path;
    final index = LibraryIndex._(file, await Isolate.run(() => _read(path)));
    _loaded = Future.value(index);
    return index;
  }

  /// What's in the file at [path]; nothing if there's none, or it can't be
  /// read (it's read again from the pictures, then).
  static Map<String, List<int>> _read(String path) {
    try {
      final json = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      if (json['version'] != 1) return {};
      return (json['entries'] as Map<String, dynamic>).map(
        (path, entry) => MapEntry(path, (entry as List<dynamic>).cast<int>()),
      );
    } on Object {
      return {};
    }
  }

  /// When the picture at [path] was taken, in ms since 1970: 0 if it doesn't
  /// say; null if it hasn't been read, or has changed since it was.
  int? taken(String path, {required int size, required int modified}) {
    final entry = _entries[path];
    if (entry == null || entry[0] != size || entry[1] != modified) return null;
    return entry[2];
  }

  void put(String path, {required int size, required int modified, required int taken}) =>
      _entries[path] = [size, modified, taken];

  /// Forgets pictures in the folder [under] that have gone: not in [paths]
  /// (what a scan of it found) and not there any more. (One a drive's scan
  /// leaves out, like an icon, may still be in another library.) True if
  /// any had gone.
  Future<bool> keepOnly(Set<String> paths, {required String under}) async {
    final prefix = under.endsWith(p.separator) ? under : '$under${p.separator}';
    final unfound = [
      for (final path in _entries.keys)
        if (path.startsWith(prefix) && !paths.contains(path)) path,
    ];
    if (unfound.isEmpty) return false;
    // Asked of the disk in an isolate: there may be thousands.
    final gone = await Isolate.run(() => [for (final path in unfound) if (!File(path).existsSync()) path]);
    gone.forEach(_entries.remove);
    return gone.isNotEmpty;
  }

  /// Forgets the loaded index, so the next [load] reads it afresh (slowly,
  /// in an isolate): for tests.
  @visibleForTesting
  static void unload() => _loaded = null;

  /// Once the index has finished any saving it's doing: for tests, which
  /// delete its folder after.
  @visibleForTesting
  static Future<void> idle() async {
    final index = await _loaded;
    for (var saving = index?._saving; saving != null; saving = index?._saving) {
      await saving;
    }
  }

  /// A save under way, and whether there's been a change since it began.
  Future<void>? _saving;
  var _changedSince = false;

  /// Writes it out, in an isolate: to a new file, then over the old, so it's
  /// never left half written. Saves asked for while one's under way make
  /// one more once it's done.
  Future<void> save() async {
    if (_saving case final saving?) {
      _changedSince = true;
      return saving;
    }
    final file = _file;
    if (file == null) return;
    final path = file.path;
    // A copy as it is now (each entry's list is replaced, never changed).
    final entries = Map.of(_entries);
    final saving = _saving = Isolate.run(() => _write(path, entries));
    try {
      await saving;
    } finally {
      _saving = null;
    }
    if (_changedSince) {
      _changedSince = false;
      await save();
    }
  }

  static void _write(String path, Map<String, List<int>> entries) {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      final temporary = File('$path.new');
      temporary.writeAsStringSync(jsonEncode({'version': 1, 'entries': entries}), flush: true);
      temporary.renameSync(path);
    } on FileSystemException {
      // Read again next time; nothing's lost but time.
    }
  }
}
