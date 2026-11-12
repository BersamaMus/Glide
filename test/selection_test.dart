import 'dart:io';

import 'package:better_image_manager/services/browser.dart';
import 'package:better_image_manager/services/library_index.dart';
import 'package:better_image_manager/services/places.dart';
import 'package:better_image_manager/widgets/preview_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory folder;
  late Browser browser;

  /// The selected pictures' names, in order.
  List<String> selected() => [for (final picture in browser.selection) picture.name];

  Picture picture(String name) => browser.pictures.firstWhere((picture) => picture.name == name);

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('selection_test');
    // All changed at the same moment, with no date taken: in order of name.
    for (final name in ['a', 'b', 'c', 'd', 'e', 'f', 'g']) {
      final file = File(p.join(folder.path, '$name.jpg'));
      await file.writeAsString('');
      await file.setLastModified(DateTime(2026, 10, 1));
    }
    PhotoLibrary.forgetAll();
    await LibraryIndex.at(File(p.join(folder.path, '.index', 'index.json')));
    PhotoLibrary.readDates = (paths) async => [for (final _ in paths) DateTaken.none];
    browser = Browser(PhotoLibrary(folder.path));
    await browser.open(browser.location);
    // Done reading dates taken (none), so nothing's left writing.
    while (browser.updating) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });

  tearDown(() async {
    browser.dispose();
    PhotoLibrary.forgetAll();
    await LibraryIndex.idle();
    await folder.delete(recursive: true);
  });

  test('lists just the pictures, no folders', () {
    expect(browser.pictures.map((p) => p.name), ['a.jpg', 'b.jpg', 'c.jpg', 'd.jpg', 'e.jpg', 'f.jpg', 'g.jpg']);
  });

  test('a click selects just that picture', () {
    browser.click(picture('b.jpg'));
    browser.click(picture('d.jpg'));
    expect(selected(), ['d.jpg']);
    expect(browser.focused?.name, 'd.jpg');
  });

  test('Ctrl+click adds and takes out', () {
    browser.click(picture('b.jpg'));
    browser.click(picture('d.jpg'), toggle: true);
    browser.click(picture('f.jpg'), toggle: true);
    browser.click(picture('d.jpg'), toggle: true);
    expect(selected(), ['b.jpg', 'f.jpg']);
  });

  test('Shift+click selects the range from the last click, either way', () {
    browser.click(picture('e.jpg'));
    browser.click(picture('b.jpg'), range: true);
    expect(selected(), ['b.jpg', 'c.jpg', 'd.jpg', 'e.jpg']);
    // From the same anchor, a new range replaces the old one.
    browser.click(picture('g.jpg'), range: true);
    expect(selected(), ['e.jpg', 'f.jpg', 'g.jpg']);
  });

  test('Ctrl+Shift+click adds a range to what is selected', () {
    browser.click(picture('a.jpg'));
    browser.click(picture('e.jpg'), toggle: true);
    browser.click(picture('g.jpg'), toggle: true, range: true);
    expect(selected(), ['a.jpg', 'e.jpg', 'f.jpg', 'g.jpg']);
  });

  test('arrow keys move by one or by a row, stopping at the ends', () {
    browser.moveFocus(1); // nothing focused yet: the first
    expect(selected(), ['a.jpg']);
    browser.moveFocus(3); // down a row of three
    expect(selected(), ['d.jpg']);
    browser.moveFocus(10);
    expect(selected(), ['g.jpg']);
    browser.moveFocus(-1);
    expect(selected(), ['f.jpg']);
    browser.focusEdge(last: false);
    expect(selected(), ['a.jpg']);
  });

  test('Shift+arrows extend from the anchor, and shrink back', () {
    browser.click(picture('c.jpg'));
    browser.moveFocus(1, extend: true);
    browser.moveFocus(1, extend: true);
    expect(selected(), ['c.jpg', 'd.jpg', 'e.jpg']);
    browser.moveFocus(-1, extend: true);
    expect(selected(), ['c.jpg', 'd.jpg']);
    browser.focusEdge(last: false, extend: true);
    expect(selected(), ['a.jpg', 'b.jpg', 'c.jpg']);
  });

  test('Ctrl+A and Esc', () {
    browser.selectAll();
    expect(browser.selectedCount, 7);
    expect(browser.focused?.name, 'a.jpg');
    browser.clearSelection();
    expect(browser.selectedCount, 0);
    expect(browser.focused, isNull);
  });

  test('a refresh keeps the selection, less what has gone', () async {
    browser.click(picture('b.jpg'));
    browser.click(picture('c.jpg'), toggle: true);
    await File(p.join(folder.path, 'b.jpg')).delete();
    // Gone behind the app's back: noticed once it's looked through again.
    browser.location.forget();
    await browser.refresh();
    while (browser.updating) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(selected(), ['c.jpg']);
    expect(browser.focused?.name, 'c.jpg');
  });

  test('renaming the focused picture keeps it selected', () async {
    browser.click(picture('b.jpg'));
    expect(await browser.renameFocused('zebra'), isNull);
    expect(selected(), ['zebra.jpg']);
    expect(File(p.join(folder.path, 'zebra.jpg')).existsSync(), isTrue);
    expect(await browser.renameFocused('c'), 'There\'s already a file with that name.');
    expect(await browser.renameFocused('a/b'), contains('can\'t contain'));
  });

  test('on a phone, a long press starts picking: taps add and take out', () {
    browser.startPicking(picture('b.jpg'));
    expect(browser.picking, isTrue);
    browser.togglePicked(picture('d.jpg'));
    browser.togglePicked(picture('f.jpg'));
    expect(selected(), ['b.jpg', 'd.jpg', 'f.jpg']);
    browser.togglePicked(picture('d.jpg'));
    expect(selected(), ['b.jpg', 'f.jpg']);
  });

  test('picking stops once nothing is picked, or when asked', () {
    browser.startPicking(picture('b.jpg'));
    browser.togglePicked(picture('b.jpg'));
    expect(browser.picking, isFalse);
    expect(selected(), isEmpty);

    browser.startPicking(picture('c.jpg'));
    browser.togglePicked(picture('e.jpg'));
    browser.stopPicking();
    expect(browser.picking, isFalse);
    expect(selected(), isEmpty);
    expect(browser.focused, isNull);
  });

  test('opening somewhere else stops picking', () async {
    browser.startPicking(picture('b.jpg'));
    await browser.open(browser.location);
    expect(browser.picking, isFalse);
  });

  test('a rename can change just the letters\' case', () async {
    browser.click(picture('b.jpg'));
    expect(await browser.renameFocused('B'), isNull);
    final names = [for (final entry in folder.listSync()) p.basename(entry.path)];
    expect(names, contains('B.jpg'));
    expect(names, isNot(contains('b.jpg')));
  });

  test('a rename tries again while something holds the file a moment', () async {
    final from = p.join(folder.path, 'held.jpg');
    final to = p.join(folder.path, 'free.jpg');
    await File(from).writeAsString('x');
    // Held open (as antivirus might) for a moment: renamed once it's let go.
    final held = await File(from).open(mode: FileMode.append);
    final letGo = Future<void>.delayed(const Duration(milliseconds: 150), held.close);
    expect(await Browser.renameWithRetries(from, to), to);
    await letGo;
    expect(File(to).existsSync(), isTrue);
  });

  test('a rename gives up if the file stays held', () async {
    final from = p.join(folder.path, 'held.jpg');
    await File(from).writeAsString('x');
    final held = await File(from).open(mode: FileMode.append);
    expect(await Browser.renameWithRetries(from, p.join(folder.path, 'free.jpg'), attempts: 3), isNull);
    await held.close();
    expect(File(from).existsSync(), isTrue);
  });

  testWidgets('the selection\'s size is added up from the listing', (tester) async {
    await tester.runAsync(() async {
      await File(p.join(folder.path, 'b.jpg')).writeAsBytes(List.filled(3072, 0));
      await File(p.join(folder.path, 'd.jpg')).writeAsBytes(List.filled(1024, 0));
      await browser.open(browser.location);
      while (browser.updating) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    expect(picture('b.jpg').bytes, 3072);
    browser.click(picture('b.jpg'));
    browser.click(picture('d.jpg'), toggle: true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PreviewPane(browser: browser))));
    await tester.pump();
    expect(find.textContaining('4 KB'), findsOneWidget);
  });
}
