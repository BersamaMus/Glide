part of 'places.dart';

/// Every picture in a folder and the folders in it, newest first, as in
/// Photos: no folders to go through, just the pictures.
///
/// Newest by when they were taken, as their metadata says (EXIF and its
/// like); by when they were last changed for those it doesn't say for
/// (screenshots, saved pictures). What's been read is kept in the
/// [LibraryIndex], so each picture's read once, and again only if it
/// changes. New ones are shown at once, by their last change, and moved to
/// their place once they've been read.
class PhotoLibrary extends Location {
  const PhotoLibrary(this.path) : drive = null;

  /// Every picture on a drive, as in [PhotoLibrary], less what's on it that
  /// isn't anyone's pictures: Windows' and apps' folders, code, caches, and
  /// icons.
  PhotoLibrary.drive(Drive this.drive) : path = drive.root;

  final String path;

  /// The drive it's the whole of, if it is.
  final Drive? drive;

  bool get wholeDrive => drive != null;

  /// The drives on this PC, internal or [external], as libraries: what the
  /// Drives and External tabs show, and their chips switch between.
  static Future<List<PhotoLibrary>> drives({required bool external}) async => [
    for (final library in await allDrives())
      if (library.drive!.external == external) library,
  ];

  /// Every drive on this PC, internal and external, as libraries.
  static Future<List<PhotoLibrary>> allDrives() async => [
    if (Platform.isWindows)
      for (final drive in await listDrives()) PhotoLibrary.drive(drive),
  ];

  /// The drives on this PC: Windows', or a stand-in in tests.
  @visibleForTesting
  static Future<List<Drive>> Function() listDrives = Drives.list;

  /// Online-only OneDrive files: not read (that would download them), and
  /// not asked about again while the app runs.
  static final _notHere = <String>{};

  /// What's known of each library while the app runs: its last full scan,
  /// any scan under way, and any reading of dates.
  static final _sessions = <PhotoLibrary, _Session>{};

  /// Reads when pictures were taken: Windows' codecs, or a stand-in in tests.
  @visibleForTesting
  static Future<List<DateTaken>> Function(List<String> paths) readDates = NativeImaging.datesTaken;

  /// Forgets all that's been found while the app's run, as a restart would.
  @visibleForTesting
  static void forgetAll() {
    for (final session in _sessions.values) {
      session.scan?.cancel();
    }
    _sessions.clear();
    _notHere.clear();
  }

  /// Its pictures may have changed: scans it again the next time it's
  /// listed, showing what it had meanwhile, less what's [gone] and plus
  /// what's been [added] (by the app: deleted, moved, renamed, saved).
  @override
  void forget({Iterable<String> gone = const [], Iterable<String> added = const []}) {
    final session = _sessions[this];
    if (session == null) return;
    session.stale = true;
    session.gone.addAll(gone);
    for (final path in added) {
      session.gone.remove(path);
      try {
        final stat = File(path).statSync();
        if (stat.type == FileSystemEntityType.file) {
          session.added[path] = (path: path, size: stat.size, modified: stat.modified.millisecondsSinceEpoch);
        }
      } on FileSystemException {
        // Gone again already.
      }
    }
  }

  @override
  String get title => switch (drive) {
    final drive? => '${drive.name} (${drive.letter})',
    null => path == picturesFolder ? 'Pictures' : p.basename(path),
  };

  @override
  String get subtitle => switch (drive) {
    final drive? => '${_gigabytes(drive.bytesFree)} free of ${_gigabytes(drive.bytesTotal)}',
    null => path,
  };

  @override
  String get emptyText => wholeDrive ? 'No pictures on this drive.' : 'No pictures in $path yet.';

  @override
  bool get switchable => wholeDrive;

  @override
  Future<List<Location>> sources() async {
    final drive = this.drive;
    return drive == null ? const [] : drives(external: drive.external);
  }

  @override
  String get chipLabel => title;

  @override
  IconData get chipIcon => switch (drive?.kind) {
    DriveKind.usb => Icons.usb_rounded,
    DriveKind.card => Icons.sd_card_rounded,
    DriveKind.internal => Icons.storage_rounded,
    null => Icons.folder_rounded,
  };

  /// An external drive that's been taken out leaves no drive: the
  /// External tab says how to plug one in.
  @override
  Location? get withoutSources => drive?.external == true ? const NoExternalDrive() : null;

  @override
  Future<Listing> list() async {
    final session = _sessions[this] ??= _Session();

    // Scanning: the first time, or again since it was forgotten.
    if (session.scan == null && (session.complete == null || session.stale)) {
      session.stale = false;
      final scan = session.scan = _Scan.start(path, wholeDrive: wholeDrive);
      // Something to show straight away, the first time.
      if (session.complete == null) await scan.firstResults;
    }
    if (session.scan case final scan? when scan.done) {
      session.scan = null;
      if (scan.error case final error?) {
        if (session.complete == null) throw FileSystemException(error, path);
      } else {
        session.complete = scan.found;
        session.pruned = false;
        // The new scan has what was added and doesn't have what went.
        session.gone.clear();
        session.added.clear();
      }
    }
    final scanning = session.scan;
    final found = [
      ...?session.complete ?? scanning?.found,
      ...session.added.values,
    ].where((file) => !session.gone.contains(file.path)).toList();

    final index = await LibraryIndex.load();
    // Dates taken are read with Windows' codecs.
    final readable = Platform.isWindows;
    final pictures = <LocalPicture>[];
    final unread = <_Found>[];
    final seen = <String>{};
    final latest = _latest();
    for (final file in found) {
      if (!seen.add(file.path)) continue; // added, and found by the scan too
      final taken = index.taken(file.path, size: file.size, modified: file.modified);
      if (taken == null && readable && !_notHere.contains(file.path)) unread.add(file);
      pictures.add(
        LocalPicture(
          File(file.path),
          taken: _plausible(taken, latest),
          modified: _plausible(file.modified, latest),
          bytes: file.size,
        ),
      );
    }
    pictures.sort(_newestFirst);

    // Still scanning for the first time: shown as found so far.
    if (scanning != null && session.complete == null) {
      return Listing(pictures, pending: scanning.next, work: Work.looking);
    }
    // Pictures gone since the index last saw them: forgotten, once a scan.
    if (scanning == null && !session.pruned) {
      session.pruned = true;
      if (await index.keepOnly(seen, under: path)) unawaited(index.save());
    }

    var reader = session.reader;
    if ((reader == null || (reader.done && !reader.failed)) && unread.isNotEmpty) {
      reader = session.reader = _DateReader(unread, index);
    }
    if (reader != null && !reader.done) {
      return Listing(pictures, pending: reader.next, work: Work.sorting, progress: reader.progress);
    }
    // A scan again, behind what's shown: listed again once it's done.
    return Listing(pictures, pending: scanning?.whenDone);
  }

  /// The pictures under [root], with their sizes and when they were last
  /// changed, skipping hidden and system folders. A folder that can't be
  /// read is left out rather than failing the lot.
  ///
  /// For a [wholeDrive], also what isn't anyone's pictures: Windows' and
  /// apps' folders, code (a folder with a project's files in it, and all
  /// under it), caches of thumbnails, music's cover art, and icons (small
  /// files).
  ///
  /// Hands them to [flush] a few times a second as they're found, so a drive
  /// of tens of thousands shows them from the start.
  static void _scan(String root, {required bool wholeDrive, required void Function(List<_Found>) flush}) {
    var found = <_Found>[];
    final sinceFlush = Stopwatch()..start();
    void flushNow() {
      flush(found);
      found = [];
      sinceFlush.reset();
    }

    final folders = [Directory(root)];
    while (folders.isNotEmpty) {
      final folder = folders.removeLast();
      final List<FileSystemEntity> entries;
      try {
        entries = folder.listSync(followLinks: false);
      } on FileSystemException {
        if (folder.path == root) rethrow;
        continue;
      }
      final top = folder.path == root;
      if (wholeDrive && !top && entries.any((entry) => _isProjectFile(p.basename(entry.path).toLowerCase()))) {
        continue;
      }
      for (final entity in entries) {
        final name = p.basename(entity.path);
        if (_hidden(name)) continue;
        if (entity is Directory) {
          final lower = name.toLowerCase();
          if (wholeDrive && (_notPictures.contains(lower) || (top && _systemFolders.contains(lower)))) continue;
          folders.add(entity);
        } else if (entity is File && isImage(name)) {
          if (wholeDrive && _isCoverArt(name.toLowerCase())) continue;
          final stat = entity.statSync();
          if (wholeDrive && stat.size < _iconSize) continue;
          found.add((path: entity.path, size: stat.size, modified: stat.modified.millisecondsSinceEpoch));
        }
      }
      // What's been found, a few times a second; and every few seconds even
      // when nothing has (long runs of folders without pictures), to say
      // it's still at it.
      final waited = sinceFlush.elapsedMilliseconds;
      if ((found.isNotEmpty && waited >= 300) || waited >= 3000) flushNow();
    }
    flushNow();
  }

  /// The names music players and stores give an album's cover.
  static bool _isCoverArt(String name) {
    final stem = p.basenameWithoutExtension(name);
    return const {'cover', 'folder', 'front', 'back', 'albumartsmall'}.contains(stem) || stem.startsWith('albumart_');
  }

  /// Folders at a drive's top that are Windows' or apps' own.
  static const _systemFolders = {
    'windows', 'windows.old', 'program files', 'program files (x86)', 'programdata', 'recovery', 'perflogs', //
    'msocache', 'intel', 'amd', 'nvidia', 'inetpub', 'onedrivetemp', 'config.msi', 'xboxgames', 'drivers',
    'system volume information',
  };

  /// Folders, anywhere, whose pictures are apps' or copies: apps' data and
  /// packages, build output, and thumbnail caches.
  static const _notPictures = {
    'appdata', 'node_modules', 'bower_components', 'site-packages', '__pycache__', 'build', 'pods', //
    'vendor', 'thumbnails', 'thumbs', 'cache', 'caches',
  };

  /// A file that says its folder is a code project.
  static bool _isProjectFile(String name) =>
      const {
        '.git', '.hg', '.svn', 'package.json', 'pubspec.yaml', 'build.gradle', 'build.gradle.kts', //
        'settings.gradle', 'cmakelists.txt', 'cargo.toml', 'go.mod', 'pom.xml', 'composer.json', 'gemfile',
        'pyproject.toml', 'setup.py', 'requirements.txt', 'makefile',
      }.contains(name) ||
      name.endsWith('.sln') ||
      name.endsWith('.csproj') ||
      name.endsWith('.xcodeproj');

  /// Smaller than this, a picture's an icon or a button, not a photo or a
  /// screenshot.
  static const _iconSize = 16 * 1024;

  @override
  bool operator ==(Object other) =>
      other is PhotoLibrary &&
      other.path == path &&
      other.wholeDrive == wholeDrive &&
      // Another USB stick given the same letter is another drive.
      other.drive?.label == drive?.label;

  @override
  int get hashCode => Object.hash(path, wholeDrive, drive?.label);
}

/// The External tab with no USB drive or memory card plugged in: says how,
/// and watches for one.
class NoExternalDrive extends Location {
  const NoExternalDrive();

  @override
  String get title => 'External';

  @override
  String get subtitle => 'USB drives and memory cards';

  @override
  String get emptyText => 'No external drive connected.\nPlug in a USB drive or a memory card to see its pictures.';

  @override
  bool get switchable => true;

  @override
  Future<List<Location>> sources() => PhotoLibrary.drives(external: true);

  @override
  Future<Listing> list() async => const Listing([]);

  @override
  bool operator ==(Object other) => other is NoExternalDrive;

  @override
  int get hashCode => (NoExternalDrive).hashCode;
}

/// A picture a library's scan found: its size, and when it was last changed
/// (ms since 1970).
typedef _Found = ({String path, int size, int modified});

/// What a library knows while the app runs.
class _Session {
  /// Its last full scan; null until one's finished.
  List<_Found>? complete;

  /// A scan under way.
  _Scan? scan;

  /// Should be scanned again (the app's changed its files, or it's been
  /// opened again).
  var stale = false;

  /// What the app has deleted or moved away since the last full scan, and
  /// saved or moved here: shown so until the next scan has them.
  final gone = <String>{};
  final added = <String, _Found>{};

  /// Dates being read, if they are.
  _DateReader? reader;

  /// The index has been rid of what the last full scan didn't find.
  var pruned = false;
}

/// A library's scan, in an isolate of its own, sending what it finds as it
/// goes.
class _Scan {
  _Scan._(this._port);

  final ReceivePort _port;
  Isolate? _isolate;

  /// What's been found so far; all of it once [done].
  final found = <_Found>[];
  var done = false;

  /// Why the scan failed (its folder can't be read), if it did.
  String? error;

  var _next = Completer<void>();
  final _first = Completer<void>();
  final _finished = Completer<void>();

  /// Starts scanning [root]: the scan's there to ask at once, its isolate
  /// on its way.
  static _Scan start(String root, {required bool wholeDrive}) {
    final scan = _Scan._(ReceivePort());
    scan._port.listen(scan._received);
    scan._watch();
    Isolate.spawn(
      _scanInIsolate,
      (scan._port.sendPort, root, wholeDrive),
      // Told if it ends without saying it's done: it ran out of memory, say.
      onExit: scan._port.sendPort,
      onError: scan._port.sendPort,
    ).then(
      (isolate) {
        // Cancelled while it was starting.
        if (scan._cancelled) {
          isolate.kill(priority: Isolate.immediate);
        } else {
          scan._isolate = isolate;
        }
      },
      onError: (Object e) => scan._fail('The pictures couldn\'t be looked for ($e).'),
    );
    return scan;
  }

  bool _cancelled = false;

  /// Gives up if the scan's gone quiet for this long: it says something
  /// every few seconds while it's at work, so a drive that's stopped
  /// answering (failing, or unplugged mid-read) has it stuck.
  static const _silence = Duration(minutes: 1);
  Timer? _watchdog;

  void _watch() {
    _watchdog?.cancel();
    _watchdog = Timer(_silence, () {
      _isolate?.kill(priority: Isolate.immediate);
      _fail('The drive stopped answering. Is it still plugged in?');
    });
  }

  void _fail(String why) {
    if (done) return;
    error = why;
    _end();
    _say();
  }

  void _received(Object? message) {
    if (done) return;
    _watch();
    switch (message) {
      case List<Object?> batch when batch.every((item) => item is _Found):
        found.addAll(batch.cast<_Found>());
      // An uncaught error in the isolate: [error, stack trace].
      case List<Object?> crash:
        _fail('Looking for pictures stopped (${crash.firstOrNull}).');
        return;
      case String why:
        error = why;
        _end();
      // Its end: after saying it's done (null), or instead of it (onExit,
      // with nothing found since it last said).
      case null:
        _end();
    }
    _say();
  }

  void _say() {
    // Shown a second at a time: sorting and laying out tens of thousands
    // more often would keep thumbnails from loading.
    if (_first.isCompleted && !done && _sinceSaid.elapsedMilliseconds < 1000) return;
    _sinceSaid.reset();
    final next = _next;
    _next = Completer();
    next.complete();
    if (!_first.isCompleted) _first.complete();
  }

  final _sinceSaid = Stopwatch()..start();

  void _end() {
    if (done) return;
    done = true;
    _watchdog?.cancel();
    _port.close();
    _finished.complete();
  }

  /// Once there's something found, or it's done.
  Future<void> get firstResults => _first.future;

  /// When more's been found, or it's done.
  /// (At once if it's already done: asked for after the last saying, it
  /// would otherwise wait for one that never comes.)
  Future<void> get next => done ? Future.value() : _next.future;

  Future<void> get whenDone => _finished.future;

  void cancel() {
    _cancelled = true;
    _isolate?.kill(priority: Isolate.immediate);
    if (!done) _end();
  }
}

/// Scans in its own isolate: [PhotoLibrary._scan], sent back a batch at a
/// time; then null when done, or why it failed.
void _scanInIsolate((SendPort, String, bool) job) {
  final (port, root, wholeDrive) = job;
  try {
    PhotoLibrary._scan(root, wholeDrive: wholeDrive, flush: port.send);
    port.send(null);
  } on FileSystemException catch (e) {
    port.send(e.osError?.message ?? e.message);
  }
}

/// Reads when pictures were taken into the [LibraryIndex], a few hundred at
/// a time (each lot split between isolates), saying when each lot's done,
/// and saving the index every so often, so what's been read is kept even if
/// the app's closed part way.
class _DateReader {
  _DateReader(List<_Found> files, LibraryIndex index) : _total = files.length {
    _run(files, index);
  }

  /// Read at once: [_isolates] isolates, [_each] files each. Small lots, so
  /// a codec that hangs over one file (given up on after a while) costs the
  /// others in its lot little.
  static const _isolates = 4;
  static const _each = 50;

  var done = false;

  /// It stopped on an error (Windows' codecs couldn't be had): not tried
  /// again while the app runs, so it isn't tried over and over.
  var failed = false;
  var _next = Completer<void>();
  final int _total;
  int _read = 0;

  /// How much of it's been read, 0 to 1.
  double get progress => _total == 0 ? 1 : _read / _total;

  /// When another lot's been read, or it's done.
  /// (At once if it's already done: asked for after the last saying, it
  /// would otherwise wait for one that never comes.)
  Future<void> get next => done ? Future.value() : _next.future;

  Future<void> _run(List<_Found> files, LibraryIndex index) async {
    final sinceSave = Stopwatch()..start();
    try {
      for (var start = 0; start < files.length; start += _isolates * _each) {
        final lot = files.sublist(start, (start + _isolates * _each).clamp(0, files.length));
        await Future.wait([
          for (var from = 0; from < lot.length; from += _each)
            _readSome(lot.sublist(from, (from + _each).clamp(0, lot.length)), index),
        ]);
        _read += lot.length;
        // Saved in an isolate, while reading goes on.
        if (sinceSave.elapsed.inSeconds >= 15) {
          unawaited(index.save());
          sinceSave.reset();
        }
        if (start + _isolates * _each < files.length) _signal();
      }
      await index.save();
    } on Object {
      failed = true;
    } finally {
      done = true;
      _signal(now: true);
    }
  }

  static Future<void> _readSome(List<_Found> files, LibraryIndex index) async {
    List<DateTaken> results;
    try {
      results = await PhotoLibrary.readDates([for (final file in files) file.path]);
    } on NativeImagingException {
      // Given up on (a codec hung over one of them): by when they were last
      // changed, then, rather than tried again and again.
      results = [for (final _ in files) DateTaken.none];
    }
    for (final (i, result) in results.indexed) {
      final file = files[i];
      if (!result.onThisPC) {
        PhotoLibrary._notHere.add(file.path);
      } else {
        index.put(file.path, size: file.size, modified: file.modified, taken: result.date?.millisecondsSinceEpoch ?? 0);
      }
    }
  }

  final _sinceSaid = Stopwatch()..start();

  /// Says another lot's been read: a second at a time (each saying re-sorts
  /// every picture), and when it's done.
  void _signal({bool now = false}) {
    if (!now && _sinceSaid.elapsedMilliseconds < 1000) return;
    _sinceSaid.reset();
    final next = _next;
    _next = Completer();
    next.complete();
  }
}
