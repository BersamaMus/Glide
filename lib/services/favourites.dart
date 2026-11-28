import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_data.dart';

/// The pictures marked with a heart, kept between runs: what the Favourites
/// tab shows, and the hearts on the tiles.
///
/// By path, so a picture's a favourite wherever it's listed (Pictures, its
/// drive, an album, the phone's gallery); on Windows whatever its case, as
/// Windows' paths are. A favourite that's gone (deleted, or on a drive that
/// isn't plugged in) is kept, and shown again once it's back: put back from
/// the Recycle Bin, it's still a favourite.
///
/// Kept as JSON in the app's folder beside the library's index, oldest
/// first. There are rarely more than a few hundred, so it's read and
/// written whole, on the app's own thread.
class Favourites extends ChangeNotifier {
  Favourites._(Future<File> Function() find) {
    ready = _load(find);
  }

  /// The app's own, read the first time they're asked for.
  static Favourites get instance =>
      _instance ??= Favourites._(() async => File(p.join((await appDataDirectory()).path, 'favourites.json')));
  static Favourites? _instance;

  /// Favourites kept in [file], as if the app had just started: for tests.
  @visibleForTesting
  static Favourites at(File file) => _instance = Favourites._(() async => file);

  /// Where they're kept, once that's known: null if it can't be (they're
  /// kept for this run only, then).
  File? _file;

  /// Once what was kept has been read: until then there are none. Never
  /// fails.
  late final Future<void> ready;

  /// Each favourite's path, by [_key], in the order they were marked.
  final _paths = <String, String>{};

  /// What tells [path] apart from other paths: on Windows, its case doesn't.
  static String _key(String path) => Platform.isWindows ? path.toLowerCase() : path;

  Future<void> _load(Future<File> Function() find) async {
    try {
      final file = _file = await find();
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      for (final path in (json['paths'] as List<dynamic>).cast<String>()) {
        _paths[_key(path)] = path;
      }
    } on Object {
      // None yet, or unreadable: none, then.
    }
    if (_paths.isNotEmpty) notifyListeners();
  }

  /// Whether the picture at [path] is a favourite.
  bool contains(String path) => _paths.containsKey(_key(path));

  /// Every favourite's path, oldest first.
  List<String> get paths => _paths.values.toList();

  /// Marks the pictures at [paths] as favourites, or with [favourite] false,
  /// no longer; and saves them.
  Future<void> mark(Iterable<String> paths, {required bool favourite}) async {
    final asked = paths.toList();
    await ready;
    var changed = false;
    for (final path in asked) {
      final key = _key(path);
      if (!favourite) {
        changed |= _paths.remove(key) != null;
      } else if (!_paths.containsKey(key)) {
        _paths[key] = path;
        changed = true;
      }
    }
    if (!changed) return;
    notifyListeners();
    await _save();
  }

  /// The picture at [from] is at [to] now (renamed, or moved by the app):
  /// still a favourite there, if it was one.
  Future<void> moved(String from, String to) async {
    await ready;
    if (_paths.remove(_key(from)) == null) return;
    _paths[_key(to)] = to;
    notifyListeners();
    await _save();
  }

  /// The last save asked for, once it and those before it are done.
  Future<void> _saving = Future.value();

  /// Once what's been changed has been written: for tests.
  @visibleForTesting
  Future<void> get saved => _saving;

  /// Writes them out as they are now, after any save under way: to a new
  /// file, then over the old, so it's never left half written.
  Future<void> _save() {
    final paths = this.paths;
    return _saving = _saving.then((_) async {
      final file = _file;
      if (file == null) return;
      try {
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.new');
        await temporary.writeAsString(jsonEncode({'version': 1, 'paths': paths}), flush: true);
        await temporary.rename(file.path);
      } on Object {
        // Kept for this run, and written with the next change.
      }
    });
  }
}
