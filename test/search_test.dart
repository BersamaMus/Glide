import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glide/services/browser.dart';
import 'package:glide/services/library_index.dart';
import 'package:glide/services/places.dart';
import 'package:glide/widgets/picture_grid.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory folder;
  late Browser browser;

  List<String> shown() => [for (final picture in browser.pictures) picture.name];

  Future<void> settle() async {
    while (browser.updating) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// A trip to Venice (June 2019: a Nikon's photo and an iPhone's), Rome
  /// and a screenshot (March 2021), and a beach (January 2025), in folders
  /// of their own but the last.
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('search_test');
    final pictures = {
      p.join('Venice', 'canal.jpg'): DateTime(2019, 6, 12, 12),
      p.join('Venice', 'gondola.heic'): DateTime(2019, 6, 11, 12),
      p.join('Rome', 'IMG_0001.jpg'): DateTime(2021, 3, 5, 12),
      p.join('Screenshots', 'Screenshot_20210304.png'): DateTime(2021, 3, 4, 12),
      'beach.png': DateTime(2025, 1, 1, 12),
    };
    for (final MapEntry(key: path, value: date) in pictures.entries) {
      final file = File(p.join(folder.path, path));
      await file.create(recursive: true);
      await file.setLastModified(date);
    }
    PhotoLibrary.forgetAll();
    await LibraryIndex.at(File(p.join(folder.path, '.index', 'index.json')));
    const cameras = {
      'canal.jpg': ('NIKON CORPORATION', 'NIKON D40'),
      'gondola.heic': ('Apple', 'iPhone 15 Pro'),
      'IMG_0001.jpg': ('Apple', 'iPhone 15 Pro'),
    };
    PhotoLibrary.readDates = (paths) async => [
      for (final path in paths)
        if (cameras[p.basename(path)] case (final make, final model))
          DateTaken.undated(make: make, model: model)
        else
          DateTaken.none,
    ];
    browser = Browser(PhotoLibrary(folder.path));
    await browser.open(browser.location);
    await settle();
  });

  tearDown(() async {
    browser.dispose();
    PhotoLibrary.forgetAll();
    await LibraryIndex.idle();
    await folder.delete(recursive: true);
  });

  test('finds pictures by name', () {
    browser.search('gondola');
    expect(shown(), ['gondola.heic']);
  });

  test('finds pictures by the folder they are in, whatever the case', () {
    browser.search('VENICE');
    expect(shown(), ['canal.jpg', 'gondola.heic']);
  });

  test("doesn't find every picture by the folders the library's in", () {
    // The library's own folder is in every picture's path, but only the
    // beach is in it rather than in a folder within; the one above it
    // (Temp) is the folder none of them is in.
    browser.search(p.basename(folder.path));
    expect(shown(), ['beach.png']);
    browser.search(p.basename(folder.parent.path));
    expect(shown(), isEmpty);
  });

  test('finds pictures by the camera that took them', () {
    browser.search('nikon');
    expect(shown(), ['canal.jpg']);
    browser.search('iphone');
    expect(shown(), ['IMG_0001.jpg', 'gondola.heic']);
  });

  test('finds pictures by the month and year they were taken, in either order', () {
    browser.search('march 2021');
    expect(shown(), ['IMG_0001.jpg', 'Screenshot_20210304.png']);
    browser.search('2019 jun');
    expect(shown(), ['canal.jpg', 'gondola.heic']);
  });

  test('finds pictures by type, by any of its names, and screenshots', () {
    browser.search('jpeg');
    expect(shown(), ['IMG_0001.jpg', 'canal.jpg']);
    browser.search('heif');
    expect(shown(), ['gondola.heic']);
    browser.search('screenshot');
    expect(shown(), ['Screenshot_20210304.png']);
  });

  test('finds only pictures with every word somewhere', () {
    browser.search('venice iphone');
    expect(shown(), ['gondola.heic']);
    browser.search('venice  rome');
    expect(shown(), isEmpty);
  });

  test('a search of nothing, or of spaces, shows every picture', () {
    browser.search('rome');
    browser.search('   ');
    expect(shown(), hasLength(5));
    expect(browser.total, 5);
  });

  test('the chips count what the search finds, and filter it further', () {
    browser.search('venice');
    expect(browser.total, 5);
    expect(browser.typeCounts, [('HEIC', 1), ('JPG', 1)]);
    expect(browser.cameraCounts, [('Nikon D40', 1), ('iPhone 15 Pro', 1)]);
    browser.toggleCamera('iPhone 15 Pro');
    expect(shown(), ['gondola.heic']);
    browser.search('');
    expect(shown(), ['IMG_0001.jpg', 'gondola.heic']);
  });

  test('a picture the search hides is no longer selected', () {
    browser.click(browser.pictures.firstWhere((picture) => picture.name == 'canal.jpg'));
    browser.search('rome');
    expect(browser.selection, isEmpty);
    expect(browser.focused, isNull);
  });

  test('the search stays while the pictures are listed again, and opened again', () async {
    browser.search('venice');
    browser.location.forget();
    await browser.refresh();
    await settle();
    expect(shown(), ['canal.jpg', 'gondola.heic']);
    await browser.open(browser.location);
    await settle();
    expect(shown(), ['canal.jpg', 'gondola.heic']);
  });

  testWidgets('the search box searches as it is typed, and keeps its keys to itself', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final search = TextEditingController();
    final searchFocus = FocusNode();
    addTearDown(search.dispose);
    addTearDown(searchFocus.dispose);
    search.addListener(() => browser.search(search.text));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PictureGrid(browser: browser, search: search, searchFocus: searchFocus),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'venice');
    await tester.pump();
    expect(shown(), ['canal.jpg', 'gondola.heic']);
    expect(find.textContaining('2 of 5 pictures'), findsOneWidget);

    // Down goes to what was found, focusing the first.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(browser.focused?.name, 'canal.jpg');
    expect(searchFocus.hasFocus, isFalse);

    // Back in the box, Ctrl+A selects its text, not every picture.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(searchFocus.hasFocus, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(browser.selectedCount, 1);

    // Nothing found: says so, and what can be searched by.
    await tester.enterText(find.byType(TextField), 'venice rome');
    await tester.pump();
    expect(find.textContaining('Nothing here matches “venice rome”'), findsOneWidget);

    // Esc clears it; again, goes back to the pictures.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(search.text, isEmpty);
    expect(shown(), hasLength(5));
    expect(searchFocus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(searchFocus.hasFocus, isFalse);

    await tester.pumpWidget(const SizedBox());
    // The thumbnails' time limits, run out (see filter_test.dart).
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 21));
    }
  });
}
