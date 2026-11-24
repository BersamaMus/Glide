import 'dart:io';

import 'package:glide/services/browser.dart';
import 'package:glide/services/library_index.dart';
import 'package:glide/services/places.dart';
import 'package:glide/widgets/picture_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  /// Four JPGs, two PNGs, a GIF and a HEIC, a day apart, newest first; three
  /// of the JPGs taken on a Nikon, the HEIC on an iPhone, and the rest not
  /// saying.
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('filter_test');
    final names = ['a.jpg', 'b.png', 'c.JPEG', 'd.gif', 'e.jpg', 'f.png', 'g.heic', 'h.jpg'];
    for (final (i, name) in names.indexed) {
      final file = File(p.join(folder.path, name));
      await file.writeAsString('');
      await file.setLastModified(DateTime(2025, 6, 30 - i));
    }
    PhotoLibrary.forgetAll();
    await LibraryIndex.at(File(p.join(folder.path, '.index', 'index.json')));
    const cameras = {
      'a.jpg': ('NIKON CORPORATION', 'NIKON D40'),
      'e.jpg': ('NIKON CORPORATION', 'NIKON D40'),
      'h.jpg': ('NIKON CORPORATION', 'NIKON D40'),
      'g.heic': ('Apple', 'iPhone 15 Pro'),
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

  test('counts each kind of picture, most first', () {
    expect(browser.typeCounts, [('JPG', 4), ('PNG', 2), ('GIF', 1), ('HEIC', 1)]);
    expect(browser.types, isEmpty);
    expect(shown(), hasLength(8));
  });

  test('shows only the kinds chosen, any number of them, in the same order', () {
    browser.toggleType('PNG');
    expect(shown(), ['b.png', 'f.png']);
    browser.toggleType('GIF');
    expect(shown(), ['b.png', 'd.gif', 'f.png']);
    browser.toggleType('PNG');
    expect(shown(), ['d.gif']);
    browser.showAllTypes();
    expect(shown(), hasLength(8));
  });

  test('a picture hidden by the filter is no longer selected', () {
    browser.click(browser.pictures[0]); // a.jpg
    browser.click(browser.pictures[1], toggle: true); // b.png
    browser.toggleType('PNG');
    expect([for (final picture in browser.selection) picture.name], ['b.png']);
    expect(browser.focused?.name, 'b.png');
  });

  test('the arrow keys and Ctrl+A go by what is shown', () {
    browser.toggleType('JPG');
    browser.moveFocus(1);
    browser.moveFocus(1);
    expect(browser.focused?.name, 'c.JPEG');
    browser.selectAll();
    expect(browser.selectedCount, 4);
  });

  test('counts the pictures each camera took, most first', () {
    expect(browser.cameraCounts, [('Nikon D40', 3), ('iPhone 15 Pro', 1)]);
    expect(browser.unknownCameraCount, 4);
    expect(browser.cameras, isEmpty);
  });

  test('shows only the cameras chosen, and counts the kinds among them', () {
    browser.toggleCamera('Nikon D40');
    expect(shown(), ['a.jpg', 'e.jpg', 'h.jpg']);
    expect(browser.typeCounts, [('JPG', 3)]);
    browser.toggleCamera('iPhone 15 Pro');
    expect(shown(), ['a.jpg', 'e.jpg', 'g.heic', 'h.jpg']);
    browser.toggleType('HEIC');
    expect(shown(), ['g.heic']);
    browser.showAllTypes();
    browser.showAllCameras();
    expect(shown(), hasLength(8));
  });

  test('a camera chosen is kept, at 0, while what is shown has none of its pictures', () {
    browser.toggleCamera('iPhone 15 Pro');
    browser.showKind('Screenshots');
    expect(browser.cameraCounts, [('iPhone 15 Pro', 0)]);
    expect(shown(), isEmpty);
  });

  testWidgets('the camera chips choose a camera\'s pictures', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PictureGrid(browser: browser))));
    expect(find.text('All cameras'), findsNothing);
    await tester.tap(find.text('Nikon D40  3'));
    await tester.pump();
    expect(shown(), ['a.jpg', 'e.jpg', 'h.jpg']);
    // Tapped again, it's let go of: every picture's shown again.
    await tester.tap(find.text('Nikon D40  3'));
    await tester.pump();
    expect(shown(), hasLength(8));
    // Or two chosen, and "All" lets go of both at once.
    await tester.tap(find.text('Nikon D40  3'));
    await tester.tap(find.text('iPhone 15 Pro  1'));
    await tester.pump();
    expect(shown(), hasLength(4));
    await tester.tap(find.text('All').first);
    await tester.pump();
    expect(shown(), hasLength(8));
    expect(browser.cameras, isEmpty);

    await tester.pumpWidget(const SizedBox());
    // The thumbnails' time limits, run out (see below).
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 21));
    }
  });

  test('opening another place shows all its kinds again', () async {
    browser.toggleType('GIF');
    browser.toggleCamera('Nikon D40');
    await browser.open(browser.location);
    await settle();
    expect(browser.types, isEmpty);
    expect(browser.cameras, isEmpty);
    expect(shown(), hasLength(8));
  });

  testWidgets('the header and the month stay at the top while the pictures scroll', (tester) async {
    // Enough pictures to scroll: a month of 60.
    await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        final file = File(p.join(folder.path, 'more$i.jpg'));
        await file.writeAsString('');
        await file.setLastModified(DateTime(2025, 5, 20));
      }
      browser.location.forget();
      await browser.refresh();
      await settle();
    });
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PictureGrid(browser: browser))));
    await tester.pump();

    final title = find.text(p.basename(folder.path));
    final may = find.text('May 2025');
    expect(tester.getTopLeft(title).dy, lessThan(40));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
    await tester.pump();
    // Still at the top: the header, and under it the month that's scrolled to.
    expect(title, findsOneWidget);
    expect(tester.getTopLeft(title).dy, lessThan(40));
    expect(may, findsOneWidget);
    final headerBottom = tester.getBottomLeft(find.text('All').last).dy;
    expect(tester.getTopLeft(may).dy, inInclusiveRange(headerBottom, headerBottom + 60));

    await tester.pumpWidget(const SizedBox());
    // Queued thumbnails each start their time limit once the one before
    // them ends: time's moved on till all have.
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(seconds: 21));
    }
  });
}
