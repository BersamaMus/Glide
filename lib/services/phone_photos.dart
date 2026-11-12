part of 'places.dart';

/// Every picture on a phone connected by USB, newest first, as in Photos;
/// or, with no phone ready, what to do about it.
///
/// Found a folder at a time over USB, the camera's first, and shown as
/// they're found. Dated by the phone's own dates (for a camera's photos,
/// when they were taken): reading each one's EXIF would mean copying it off
/// the phone.
class PhonePhotos extends Location {
  const PhonePhotos(Phone this.phone);

  /// No phone connected, or none chosen.
  const PhonePhotos.none() : phone = null;

  final Phone? phone;

  /// What's been found on each phone (by serial) while the app runs.
  static final _sessions = <String, _PhoneSession>{};

  /// What's in a folder on a phone: over USB, or a stand-in in tests.
  @visibleForTesting
  static Future<List<PhoneEntry>> Function(String serial, {String folderId}) children = Phones.children;

  /// Forgets all that's been found on phones, as a restart would.
  @visibleForTesting
  static void forgetAll() => _sessions.clear();

  /// The phone tab's first place: a phone that's ready if there is one, else
  /// a locked one, else none.
  static Future<PhonePhotos> first() async => firstOf(Platform.isWindows ? await Phones.list() : const <Phone>[]);

  /// [first], of [phones] already known.
  static PhonePhotos firstOf(Iterable<Phone> phones) {
    final phone = phones.where((phone) => phone.ready).firstOrNull ?? phones.firstOrNull;
    return phone == null ? const PhonePhotos.none() : PhonePhotos(phone);
  }

  @override
  String get title => phone?.name ?? 'Phone';

  @override
  String get subtitle => switch (phone) {
    null => 'Phones connected with a USB cable',
    Phone(ready: false) => 'Locked',
    final phone => '${_gigabytes(phone.bytesFree)} free of ${_gigabytes(phone.bytesTotal)}',
  };

  @override
  String get emptyText => switch (phone) {
    null => 'No phone connected.\nConnect one with a USB cable, unlock it, and on Android choose "File transfer".',
    Phone(ready: false, :final name) =>
      'Unlock $name, then:\n'
          'on Android, tap the "Charging this device via USB" notification and choose "File transfer";\n'
          'on an iPhone, tap Allow (or Trust).',
    _ => 'No pictures on this phone.',
  };

  @override
  bool get switchable => true;

  @override
  Future<List<Location>> sources() async => [for (final phone in await Phones.list()) PhonePhotos(phone)];

  @override
  bool sameSource(Location other) => other is PhonePhotos && other.phone?.serial == phone?.serial;

  @override
  Location? get withoutSources => phone == null ? null : const PhonePhotos.none();

  @override
  String get chipLabel => phone?.name ?? 'Phone';

  @override
  IconData get chipIcon => phone?.ready == false ? Icons.lock_rounded : Icons.smartphone_rounded;

  @override
  void forget({Iterable<String> gone = const [], Iterable<String> added = const []}) {
    if (phone case final phone?) _sessions[phone.serial]?.stale = true;
  }

  @override
  Future<Listing> list() async {
    final phone = this.phone;
    if (phone == null || !phone.ready) return const Listing([]);
    final session = _sessions[phone.serial] ??= _PhoneSession();

    if (session.scan == null && (session.complete == null || session.stale)) {
      session.stale = false;
      final scan = session.scan = _PhoneScan(phone);
      if (session.complete == null) await scan.firstResults;
    }
    if (session.scan case final scan? when scan.done) {
      session.scan = null;
      if (scan.error case final error?) {
        if (session.complete == null && scan.found.isEmpty) throw NativeImagingException(error);
        // Cut short (the phone locked, say): a whole look from before stays,
        // rather than the few folders read; it's looked at again next time.
        // With none before, what was found is better than nothing.
        if (session.complete == null) {
          session.complete = scan.found;
        } else {
          session.stale = true;
        }
      } else {
        session.complete = scan.found;
      }
    }
    final scanning = session.scan;
    final pictures = [...?session.complete ?? scanning?.found]..sort(_newestFirst);
    if (scanning != null && session.complete == null) {
      return Listing(pictures, pending: scanning.next, work: Work.looking);
    }
    return Listing(pictures, pending: scanning?.whenDone);
  }

  @override
  bool operator ==(Object other) =>
      other is PhonePhotos && other.phone?.serial == phone?.serial && other.phone?.ready == phone?.ready;

  @override
  int get hashCode => Object.hash(phone?.serial, phone?.ready);
}

String _gigabytes(int bytes) => '${(bytes / (1 << 30)).toStringAsFixed(bytes < 10 << 30 ? 1 : 0)} GB';

/// What's been found on a phone while the app runs.
class _PhoneSession {
  List<PhonePicture>? complete;
  _PhoneScan? scan;
  var stale = false;
}

/// A look through a phone for its pictures, a folder at a time, those most
/// likely to be the user's own first (the camera's), so they show up while
/// the rest is still being looked through.
class _PhoneScan {
  _PhoneScan(Phone phone) {
    _run(phone);
  }

  final found = <PhonePicture>[];
  var done = false;

  /// Why it stopped early (the phone was unplugged or locked), as an HRESULT.
  int? error;

  var _next = Completer<void>();
  final _first = Completer<void>();
  final _finished = Completer<void>();
  final _sinceSaid = Stopwatch()..start();

  Future<void> get firstResults => _first.future;

  /// (At once if it's already done: asked for after the last saying, it
  /// would otherwise wait for one that never comes.)
  Future<void> get next => done ? Future.value() : _next.future;
  Future<void> get whenDone => _finished.future;

  /// How soon a storage's top folders are looked in: the camera's, then
  /// those people keep pictures in, then the rest, and apps' media last.
  static int _rank(String topFolder) => switch (topFolder.toLowerCase()) {
    'dcim' => 0,
    'pictures' || 'download' || 'screenshots' => 1,
    'android' => 3,
    _ => 2,
  };

  /// Folders with nothing worth showing: apps' private data, caches, and
  /// WhatsApp's stickers.
  static bool _skip(String name, String path) {
    final lower = name.toLowerCase();
    return _hidden(name) ||
        const {'cache', 'caches', 'thumbnails', 'thumbs', 'whatsapp stickers', 'whatsapp business stickers'}
            .contains(lower) ||
        path.toLowerCase().endsWith('android/data') ||
        path.toLowerCase().endsWith('android/obb');
  }

  Future<void> _run(Phone phone) async {
    // Each rank's folders still to look in: (object id, path, rank).
    final queues = List.generate(4, (_) => <(String, String, int)>[]);
    final latest = _latest();
    (String, String, int)? nextFolder() {
      for (final queue in queues) {
        if (queue.isNotEmpty) return queue.removeAt(0);
      }
      return null;
    }

    try {
      final storages = await PhonePhotos.children(phone.serial);
      for (final storage in storages.where((entry) => entry.isFolder)) {
        // With a memory card too, each storage's name starts its paths.
        queues[0].add((storage.id, storages.length > 1 ? storage.name : '', -1));
      }
      for (var folder = nextFolder(); folder != null; folder = nextFolder()) {
        final (id, path, rank) = folder;
        final inFolder = await PhonePhotos.children(phone.serial, folderId: id);
        for (final entry in inFolder) {
          final childPath = path.isEmpty ? entry.name : '$path/${entry.name}';
          if (entry.isFolder) {
            if (_skip(entry.name, childPath)) continue;
            // A storage's own folders take their rank from their name;
            // deeper ones keep theirs.
            final childRank = rank < 0 ? _rank(entry.name) : rank;
            queues[childRank].add((entry.id, childPath, childRank));
          } else if (isImage(entry.name) && !_hidden(entry.name) && entry.size > 0) {
            found.add(PhonePicture(phone, entry, latest: latest, folder: path));
          }
        }
        _say();
      }
    } on NativeImagingException catch (e) {
      error = e.hresult;
    } finally {
      done = true;
      _say(now: true);
      _finished.complete();
    }
  }

  /// Says more's been found: once there's something, then a second at a
  /// time, and when it's done.
  void _say({bool now = false}) {
    if (!now && _first.isCompleted && _sinceSaid.elapsedMilliseconds < 1000) return;
    if (!now && !_first.isCompleted && found.isEmpty) return;
    _sinceSaid.reset();
    final next = _next;
    _next = Completer();
    next.complete();
    if (!_first.isCompleted) _first.complete();
  }
}
