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

  /// What's been put on the clipboard: the files, and the picture.
  late List<({List<String> paths, String? picture, int maxSize})> copied;

  Future<void> settle() async {
    while (browser.updating) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Picture named(String name) => browser.pictures.firstWhere((picture) => picture.name == name);

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('clipboard_test');
    for (final (i, name) in ['a.jpg', 'b.png', 'c.heic'].indexed) {
      final file = File(p.join(folder.path, name));
      await file.writeAsString('');
      await file.setLastModified(DateTime(2025, 6, 30 - i));
    }
    PhotoLibrary.forgetAll();
    await LibraryIndex.at(File(p.join(folder.path, '.index', 'index.json')));
    PhotoLibrary.readDates = (paths) async => [for (final _ in paths) DateTaken.none];
    copied = [];
    Browser.putOnClipboard = (paths, {picture, maxSize = 0}) async {
      copied.add((paths: paths, picture: picture, maxSize: maxSize));
    };
    browser = Browser(PhotoLibrary(folder.path));
    await browser.open(browser.location);
    await settle();
  });

  tearDown(() async {
    browser.dispose();
    PhotoLibrary.forgetAll();
    PhonePhotos.forgetAll();
    await LibraryIndex.idle();
    await folder.delete(recursive: true);
  });

  test('one picture is copied as its file and as a picture', () async {
    browser.click(named('b.png'));
    final message = await browser.copyToClipboard();
    final path = p.join(folder.path, 'b.png');
    expect(copied.single.paths, [path]);
    expect(copied.single.picture, path);
    expect(copied.single.maxSize, Browser.clipboardPictureSize);
    expect(message, startsWith('Copied b.png.'));
    expect(browser.copyingToClipboard, isFalse);
  });

  test('several pictures are copied as their files only, in the grid\'s order', () async {
    browser.click(named('c.heic'));
    browser.click(named('a.jpg'), toggle: true);
    final message = await browser.copyToClipboard();
    expect(copied.single.paths, [p.join(folder.path, 'a.jpg'), p.join(folder.path, 'c.heic')]);
    expect(copied.single.picture, isNull);
    expect(message, startsWith('Copied 2 pictures.'));
  });

  test('nothing selected, nothing is copied', () async {
    expect(browser.canCopyToClipboard, isFalse);
    expect(await browser.copyToClipboard(), isNull);
    expect(copied, isEmpty);
  });

  test('says so when the clipboard can\'t be had', () async {
    Browser.putOnClipboard = (paths, {picture, maxSize = 0}) async =>
        throw NativeImagingException(0x80070005); // access denied
    browser.click(named('a.jpg'));
    final message = await browser.copyToClipboard();
    expect(message, startsWith('Couldn\'t copy a.jpg'));
    expect(browser.copyingToClipboard, isFalse);
  });

  test('a phone\'s pictures are copied off it first, and those files copied', () async {
    final phone = Phone('SERIAL1', 'Test Phone', true, 128 << 30, 40 << 30);
    PhonePhotos.children = (serial, {folderId = ''}) async => switch (folderId) {
      '' => [PhoneEntry('dcim', 'DCIM', true, 0, null)],
      'dcim' => [
        PhoneEntry('c1', 'IMG_1.jpg', false, 3, DateTime(2025, 7, 2)),
        PhoneEntry('c2', 'IMG_2.jpg', false, 3, DateTime(2025, 7, 1)),
      ],
      _ => const <PhoneEntry>[],
    };
    Browser.readFromPhone = (serial, id) async => Uint8List.fromList(id.codeUnits);
    addTearDown(() => Browser.readFromPhone = Phones.read);
    await browser.open(PhonePhotos(phone));
    await settle();
    browser.selectAll();
    final message = await browser.copyToClipboard();
    final paths = copied.single.paths;
    expect([for (final path in paths) p.basename(path)], ['IMG_1.jpg', 'IMG_2.jpg']);
    expect([for (final path in paths) File(path).readAsStringSync()], ['c1', 'c2']);
    expect(p.basename(p.dirname(paths.first)), 'Glide clipboard');
    expect(message, startsWith('Copied 2 pictures.'));
    expect(browser.copying, isNull);
  });

  testWidgets('Ctrl+C copies the selection, and says so', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PictureGrid(browser: browser))));
    await tester.tap(find.text('a.jpg'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(copied.single.paths, [p.join(folder.path, 'a.jpg')]);
    expect(find.textContaining('Copied a.jpg'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsWidgets);

    await tester.pumpWidget(const SizedBox());
    // The thumbnails' time limits, run out (see filter_test.dart).
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 21));
    }
  });
}
