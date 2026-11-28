import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glide/services/browser.dart';
import 'package:glide/services/library_index.dart';
import 'package:glide/services/places.dart';
import 'package:glide/widgets/preview_pane.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

/// A picture opened on a phone: what it is, under it, above its buttons.
void main() {
  late Directory folder;
  late Browser browser;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('viewer_test');
    // Real pictures (one pixel), so they can be shown: beach.png the newer,
    // so it's first, and city.png, in another folder, next.
    final pixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==',
    );
    for (final (name, day) in [(p.join('Holiday', 'beach.png'), 2), (p.join('Town', 'city.png'), 1)]) {
      final file = File(p.join(folder.path, name));
      await file.create(recursive: true);
      await file.writeAsBytes(pixel);
      await file.setLastModified(DateTime(2026, 3, day));
    }
    PhotoLibrary.forgetAll();
    await LibraryIndex.at(File(p.join(folder.path, '.index', 'index.json')));
    PhotoLibrary.readDates = (paths) async => [for (final _ in paths) DateTaken.none];
    browser = Browser(PhotoLibrary(folder.path));
    await browser.open(browser.location);
    while (browser.updating) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    browser.click(browser.pictures.first);
  });

  tearDown(() async {
    browser.dispose();
    PhotoLibrary.forgetAll();
    await LibraryIndex.idle();
    await folder.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: PictureViewer(browser: browser)));
    // Its details read.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  /// Done with: the picture's reading let finish, as Windows won't delete a
  /// file that's open. Each step of it (open, read, close) waits on the
  /// disk, then on the test's own clock, so the two take turns.
  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    PaintingBinding.instance.imageCache.clear();
  }

  testWidgets('upright: its name, what it is, and where it is; tapped, the picture has the screen', (tester) async {
    // A narrow phone: the buttons all fit across (with the test's wide font).
    await open(tester, const Size(360, 800));
    expect(find.text('beach.png'), findsOneWidget);
    // Where it is, as there's no camera to say: "… › Holiday".
    expect(find.textContaining('› Holiday'), findsOneWidget);
    expect(find.text('Info'), findsOneWidget);

    // The picture, tapped (after the wait for a second tap, to zoom): all
    // that's under it goes.
    await tester.tapAt(const Offset(180, 300));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('beach.png'), findsNothing);
    expect(find.text('Info'), findsNothing);

    await done(tester);
  });

  testWidgets("swiped on, the next picture's name and folder show at once, before the rest is read", (tester) async {
    await open(tester, const Size(360, 800));
    expect(find.text('beach.png'), findsOneWidget);
    // Its details read: how big it is is known.
    for (var i = 0; i < 50 && find.textContaining('1 × 1').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.textContaining('1 × 1'), findsOneWidget);

    // On to the next, with no time for its details to be read.
    browser.click(browser.pictures[1]);
    await tester.pump();
    expect(find.text('city.png'), findsOneWidget);
    expect(find.text('beach.png'), findsNothing);
    expect(find.textContaining('› Town'), findsOneWidget);
    expect(find.textContaining('› Holiday'), findsNothing);

    await done(tester);
  });

  testWidgets('on its side, the picture keeps the room, with only the buttons under it', (tester) async {
    await open(tester, const Size(900, 420));
    expect(find.text('beach.png'), findsNothing);
    expect(find.text('Info'), findsOneWidget);

    await done(tester);
  });
}
