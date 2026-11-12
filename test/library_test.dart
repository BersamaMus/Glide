import 'dart:io';

import 'package:better_image_manager/services/browser.dart';
import 'package:better_image_manager/services/library_index.dart';
import 'package:better_image_manager/services/places.dart';
import 'package:better_image_manager/widgets/picture_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late File indexFile;

  /// What the stand-in for Windows' codecs says each picture (by name) was
  /// taken; null for none, and the paths it was asked about.
  var dates = <String, DateTaken>{};
  final asked = <String>[];

  /// As if the app had been closed and opened again: nothing remembered but
  /// the index on disk.
  Future<void> restart() async {
    PhotoLibrary.forgetAll();
    await LibraryIndex.at(indexFile);
  }

  /// Five pictures in October 2025 (o1 the newest), two in September (s1
  /// the newer), spread over folders; and some that aren't to be shown.
  setUp(() async {
    root = await Directory.systemTemp.createTemp('library_test');
    indexFile = File(p.join(root.path, '.index', 'library_index.json'));
    await restart();
    dates = {};
    asked.clear();
    PhotoLibrary.readDates = (paths) async {
      asked.addAll(paths.map(p.basename));
      return [for (final path in paths) dates[p.basename(path)] ?? DateTaken.none];
    };
    Future<void> make(String path, DateTime date) async {
      final file = File(p.join(root.path, path));
      await file.parent.create(recursive: true);
      await file.writeAsString('');
      await file.setLastModified(date);
    }

    for (var i = 1; i <= 5; i++) {
      await make(i.isOdd ? 'o$i.jpg' : p.join('Trip', 'Day ${i ~/ 2}', 'o$i.jpg'), DateTime(2025, 10, 20 - i));
    }
    await make(p.join('Old', 's1.png'), DateTime(2025, 9, 20));
    await make('s2.jpg', DateTime(2025, 9, 10));
    await make(p.join('.thumbnails', 'hidden.jpg'), DateTime(2025, 10, 30));
    await make('notes.txt', DateTime(2025, 10, 30));
  });

  tearDown(() async {
    PhotoLibrary.forgetAll();
    await LibraryIndex.idle();
    await root.delete(recursive: true);
  });

  List<String> names(Listing listing) => [for (final picture in listing.pictures) picture.name];

  /// Lists [library] until it's found all its pictures (but maybe not yet
  /// read when they were taken).
  Future<Listing> scanned(PhotoLibrary library) async {
    var listing = await library.list();
    while (listing.work == Work.looking) {
      await listing.pending;
      listing = await library.list();
    }
    return listing;
  }

  /// Lists [library] until there's nothing left to do.
  Future<Listing> settled(Location library) async {
    var listing = await library.list();
    for (var pending = listing.pending; pending != null; pending = listing.pending) {
      await pending;
      listing = await library.list();
    }
    return listing;
  }

  test('lists every picture under the folder, newest first, skipping hidden ones', () async {
    final listing = await settled(PhotoLibrary(root.path));
    expect(names(listing), ['o1.jpg', 'o2.jpg', 'o3.jpg', 'o4.jpg', 'o5.jpg', 's1.png', 's2.jpg']);
  });

  test('memories on a PC are from Pictures and the drives, each picture once', () async {
    Memories.now = () => DateTime(2026, 10, 22, 9);
    addTearDown(() => Memories.now = DateTime.now);
    for (final (path, year) in [(p.join('Trip', 'm2020.jpg'), 2020), ('m2023.jpg', 2023)]) {
      final file = File(p.join(root.path, path));
      await file.writeAsString('');
      await file.setLastModified(DateTime(year, 10, 22, 12));
    }
    // Trip stands for Pictures, and the folder it's in for its drive.
    final memories = Memories([PhotoLibrary(p.join(root.path, 'Trip')), PhotoLibrary(root.path)]);
    final listing = await settled(memories);
    expect(names(listing), ['m2023.jpg', 'm2020.jpg']);
    expect({for (final picture in listing.pictures) memories.groupLabel(memories.group(picture))}, [
      '3 years ago today  ·  22 October 2023',
      '6 years ago today  ·  22 October 2020',
    ]);
  });

  test('sorts by when pictures were taken, once that has been read', () async {
    // s2 was copied in October, but taken in 2019; o4 has no date taken.
    dates = {
      for (final name in ['o1.jpg', 'o2.jpg', 'o3.jpg', 'o5.jpg', 's1.png']) name: DateTaken(DateTime(2025, 8)),
      's2.jpg': DateTaken(DateTime(2019, 5, 1)),
    };
    await File(p.join(root.path, 's2.jpg')).setLastModified(DateTime(2025, 10, 25));

    final library = PhotoLibrary(root.path);
    final first = await scanned(library);
    // Shown at once by when they were last changed; dates being read.
    expect(names(first).first, 's2.jpg');
    expect(first.work, Work.sorting);

    final done = await settled(library);
    // o4 by its last change (October); the rest by date taken, s2 last.
    expect(names(done).first, 'o4.jpg');
    expect(names(done).last, 's2.jpg');
    expect((done.pictures.last as LocalPicture).taken, DateTime(2019, 5, 1));
    expect(indexFile.existsSync(), isTrue);
  });

  test('puts pictures with no date they could have last, under no month', () async {
    // A camera whose clock was never set: its date's in the future.
    await File(p.join(root.path, 'o3.jpg')).setLastModified(DateTime(2049, 12, 31));
    dates = {'s1.png': DateTaken(DateTime(2050))};
    final listing = await settled(PhotoLibrary(root.path));
    expect(names(listing).last, 'o3.jpg');
    expect((listing.pictures.last as LocalPicture).date, isNull);
    // s1's date taken is no good, so it goes by when it was last changed.
    expect((listing.pictures.firstWhere((x) => x.name == 's1.png') as LocalPicture).date, DateTime(2025, 9, 20));
  });

  test('reads each picture once, across restarts, and again only once it changes', () async {
    final library = PhotoLibrary(root.path);
    await settled(library);
    expect(asked, hasLength(7));

    await restart();
    asked.clear();
    await settled(library);
    expect(asked, isEmpty);

    // Opened again (as a tab is), it's looked through again.
    await File(p.join(root.path, 's2.jpg')).writeAsString('edited');
    library.forget();
    await settled(library);
    expect(asked, ['s2.jpg']);
  });

  test('shows what the app changed at once, before looking again', () async {
    final library = PhotoLibrary(root.path);
    await settled(library);
    final s2 = p.join(root.path, 's2.jpg');
    final renamed = p.join(root.path, 'renamed.jpg');
    await File(s2).rename(renamed);
    library.forget(gone: [s2], added: [renamed]);
    final meanwhile = await library.list();
    expect(names(meanwhile), contains('renamed.jpg'));
    expect(names(meanwhile), isNot(contains('s2.jpg')));
    expect(names(await settled(library)), contains('renamed.jpg'));
  });

  test('a drive leaves out what is not anyone\'s pictures', () async {
    final drive = await Directory.systemTemp.createTemp('drive_test');
    addTearDown(() => drive.delete(recursive: true));
    final photo = List.filled(20 * 1024, 0);
    Future<void> make(String path, List<int> bytes) async {
      final file = File(p.join(drive.path, path));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    }

    await make(p.join('Holiday', 'beach.jpg'), photo);
    await make(p.join('Holiday', 'Windows', 'kept.jpg'), photo); // only the drive's own Windows is skipped
    await make(p.join('Windows', 'Web', 'wallpaper.jpg'), photo);
    await make(p.join('Code', 'app', 'pubspec.yaml'), [0]);
    await make(p.join('Code', 'app', 'assets', 'splash.png'), photo);
    await make(p.join('Videos', 'thumbnails', 'frame.jpg'), photo);
    await make(p.join('Music', 'Album', 'cover.jpg'), photo);
    await make(p.join('Music', 'Album', 'AlbumArt_{1234}_Large.jpg'), photo);
    await make(p.join('Holiday', 'icon.png'), [0, 0, 0]);

    final listing = await settled(PhotoLibrary.drive(Drive(drive.path, DriveKind.internal, '', 0, 0)));
    expect(names(listing)..sort(), ['beach.jpg', 'kept.jpg']);
    // The plain library keeps the lot.
    expect((await settled(PhotoLibrary(drive.path))).pictures, hasLength(8));
  });

  test('a big drive shows what it has found while it is still looking', () async {
    final drive = await Directory.systemTemp.createTemp('big_drive_test');
    addTearDown(() => drive.delete(recursive: true));
    final photo = List.filled(17 * 1024, 0);
    for (var folder = 0; folder < 300; folder++) {
      for (var i = 0; i < 10; i++) {
        final file = File(p.join(drive.path, 'f$folder', 'p$i.jpg'));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(photo);
      }
    }
    final library = PhotoLibrary.drive(Drive(drive.path, DriveKind.internal, '', 0, 0));
    final sizes = <int>[];
    var listing = await library.list();
    while (listing.work == Work.looking) {
      sizes.add(listing.pictures.length);
      await listing.pending;
      listing = await library.list();
    }
    expect(listing.pictures, hasLength(3000));
    // Whatever came in batches came in growing.
    for (var i = 1; i < sizes.length; i++) {
      expect(sizes[i], greaterThanOrEqualTo(sizes[i - 1]));
    }
  });

  test('internal and external drives are kept apart, each switching among its own kind', () async {
    PhotoLibrary.listDrives = () async => [
      Drive(r'C:\', DriveKind.internal, 'Acer', 500, 50),
      Drive(r'D:\', DriveKind.usb, 'Mus', 1000, 460),
      Drive(r'E:\', DriveKind.card, '', 64, 10),
    ];
    final internal = await PhotoLibrary.drives(external: false);
    final external = await PhotoLibrary.drives(external: true);
    expect([for (final drive in internal) drive.title], ['Acer (C:)']);
    expect([for (final drive in external) drive.title], ['Mus (D:)', 'Memory card (E:)']);
    expect([for (final drive in await external.first.sources()) drive.title], ['Mus (D:)', 'Memory card (E:)']);
    // A USB drive taken out leaves the External tab saying how to plug one in.
    expect(external.first.withoutSources, const NoExternalDrive());
    expect(internal.first.withoutSources, isNull);
    // Another stick given the same letter is another drive, with pictures of its own.
    expect(
      PhotoLibrary.drive(Drive(r'D:\', DriveKind.usb, 'Other', 16, 1)) == external.first,
      isFalse,
    );
  });

  test('a codec that hangs costs only its lot\'s dates, and they are not asked for again', () async {
    dates = {'s2.jpg': DateTaken(DateTime(2019, 5, 1))};
    var calls = 0;
    PhotoLibrary.readDates = (paths) async {
      calls++;
      asked.addAll(paths.map(p.basename));
      // Given up on, as one would be that hung (ERROR_TIMEOUT).
      throw NativeImagingException(0x800705B4);
    };
    final library = PhotoLibrary(root.path);
    final listing = await settled(library);
    expect(listing.pictures, hasLength(7));
    // By when they were last changed: s2's date taken was never had.
    expect((listing.pictures.last as LocalPicture).taken, isNull);
    expect(calls, greaterThan(0));

    await restart();
    asked.clear();
    await settled(library);
    expect(asked, isEmpty);
  });

  test('a folder that cannot be read fails, rather than looking for ever', () async {
    final missing = PhotoLibrary(p.join(root.path, 'not there'));
    await expectLater(missing.list(), throwsA(isA<FileSystemException>()));
  });

  test('the index survives saves on top of each other, and reads back whole', () async {
    final index = await LibraryIndex.at(indexFile);
    for (var i = 0; i < 20000; i++) {
      index.put(p.join(root.path, 'p$i.jpg'), size: i, modified: i * 2, taken: i * 3);
    }
    await Future.wait([index.save(), index.save(), index.save()]);
    index.put(p.join(root.path, 'last.jpg'), size: 1, modified: 2, taken: 3);
    await index.save();

    final again = await LibraryIndex.at(indexFile);
    expect(again.taken(p.join(root.path, 'p19999.jpg'), size: 19999, modified: 39998), 59997);
    expect(again.taken(p.join(root.path, 'last.jpg'), size: 1, modified: 2), 3);
    // Changed since it was read: not to be trusted.
    expect(again.taken(p.join(root.path, 'p5.jpg'), size: 6, modified: 10), isNull);
  });

  test('a scan over before the index has loaded still finishes', () async {
    // The index still to be loaded (slowly, in an isolate), and a folder
    // scanned in no time: the scan's done before the listing's ready to
    // wait on it.
    LibraryIndex.unload();
    final browser = Browser(PhotoLibrary(root.path));
    addTearDown(browser.dispose);
    await browser.open(browser.location);
    final waited = Stopwatch()..start();
    while (browser.updating && waited.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(browser.updating, isFalse);
    expect(browser.work, isNull);
    expect(browser.pictures, hasLength(7));
  });

  test('leaves online-only files unread, by when they were last changed', () async {
    dates = {'o1.jpg': DateTaken.notHere};
    final library = PhotoLibrary(root.path);
    await settled(library);
    asked.clear();
    library.forget();
    final again = await settled(library);
    expect(asked, isEmpty); // not asked again while the app runs
    expect(names(again).first, 'o1.jpg');
  });

  testWidgets('shows a heading per month, and the arrow keys move across them', (tester) async {
    final browser = Browser(PhotoLibrary(root.path));
    await tester.runAsync(() async {
      await browser.open(browser.location);
      while (browser.updating) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    // 568 wide: three columns of tiles.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: SizedBox(width: 568, height: 900, child: PictureGrid(browser: browser))),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('October 2025'), findsOneWidget);
    expect(find.text('September 2025'), findsOneWidget);

    Future<String?> press(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pump();
      return browser.focused?.name;
    }

    // October: o1 o2 o3 / o4 o5. September: s1 s2.
    browser.click(browser.pictures[1]); // o2, the middle column
    expect(await press(LogicalKeyboardKey.arrowDown), 'o5.jpg');
    expect(await press(LogicalKeyboardKey.arrowDown), 's2.jpg'); // into September, same column
    expect(await press(LogicalKeyboardKey.arrowDown), 's2.jpg'); // the end
    expect(await press(LogicalKeyboardKey.arrowUp), 'o5.jpg'); // back to October's last row
    expect(await press(LogicalKeyboardKey.arrowUp), 'o2.jpg');
    expect(await press(LogicalKeyboardKey.arrowUp), 'o2.jpg'); // the top

    // From the third column, down to a shorter row: its last picture.
    browser.click(browser.pictures[2]);
    expect(await press(LogicalKeyboardKey.arrowDown), 'o5.jpg');
    expect(await press(LogicalKeyboardKey.arrowRight), 's1.png'); // on into September

    // Shift+Down selects through to the next row.
    browser.click(browser.pictures[0]);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await press(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(browser.selection.map((picture) => picture.name), ['o1.jpg', 'o2.jpg', 'o3.jpg', 'o4.jpg']);

    await tester.pumpWidget(const SizedBox());
    // Queued thumbnails each start their time limit once the one before
    // them ends: time's moved on till all have.
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(seconds: 21));
    }
    browser.dispose();
  });
}
