import 'dart:io';

import 'package:better_image_manager/services/browser.dart';
import 'package:better_image_manager/services/library_index.dart';
import 'package:better_image_manager/services/places.dart';
import 'package:better_image_manager/screens/collage_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

/// What's worked out from pictures: their kinds, collages.
void main() {
  late Directory root;

  /// A picture in the library, changed on [date].
  Future<void> make(String name, DateTime date, {int bytes = 0}) async {
    final file = File(p.join(root.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(bytes, 0));
    await file.setLastModified(date);
  }

  /// As if the app had been closed and opened again.
  Future<void> restart() async {
    PhotoLibrary.forgetAll();
    await LibraryIndex.at(File(p.join(root.path, '.index', 'library_index.json')));
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('views_test');
    PhotoLibrary.readDates = (paths) async => [for (final _ in paths) DateTaken.none];
    await restart();
  });

  tearDown(() async {
    PhotoLibrary.forgetAll();
    await LibraryIndex.idle();
    await root.delete(recursive: true);
  });

  test('screenshots are told apart from photos by name and folder', () async {
    await make('IMG_0001.jpg', DateTime(2025, 1, 1));
    await make('Screenshot 2025-01-02 101010.png', DateTime(2025, 1, 2));
    await make(p.join('Screenshots', 'chat.png'), DateTime(2025, 1, 3));
    final browser = Browser(PhotoLibrary(root.path));
    addTearDown(browser.dispose);
    await browser.open(browser.location);
    while (browser.updating) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(browser.kindCounts, [('Photos', 1), ('Screenshots', 2)]);
    browser.showKind('Screenshots');
    expect(browser.pictures.map((picture) => picture.name), ['chat.png', 'Screenshot 2025-01-02 101010.png']);
    browser.showKind(null);
    expect(browser.pictures, hasLength(3));
  });

  test('only the picture\'s own folder makes it a screenshot, and the chosen kind stays to be let go of', () async {
    await make(p.join('Screenshots and camera backup', '2019', 'IMG_0001.jpg'), DateTime(2019, 1, 1));
    await make(p.join('Screenshots and camera backup', '2019', 'Capture day 1.jpg'), DateTime(2019, 1, 2));
    await make(p.join('Pictures', 'Screenshots', 'chat.png'), DateTime(2025, 1, 3));
    final browser = Browser(PhotoLibrary(root.path));
    addTearDown(browser.dispose);
    await browser.open(browser.location);
    while (browser.updating) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(browser.kindCounts, [('Photos', 2), ('Screenshots', 1)]);
    browser.showKind('Screenshots');
    // The type chips count only the screenshots shown; the total's all.
    expect(browser.typeCounts, [('PNG', 1)]);
    expect(browser.total, 3);
    // Every screenshot gone: its chip stays, at 0, so it can be let go of.
    await File(p.join(root.path, 'Pictures', 'Screenshots', 'chat.png')).delete();
    await browser.open(browser.location);
    browser.showKind('Screenshots');
    while (browser.updating) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(browser.kindCounts, [('Photos', 2), ('Screenshots', 0)]);
    expect(browser.pictures, isEmpty);
    browser.showKind(null);
    expect(browser.kindCounts, [('Photos', 2)]);
  });

  test("a collage's layouts fit every picture in, each row filling the width", () {
    for (var count = CollageScreen.fewest; count <= CollageScreen.most; count++) {
      for (final rows in CollageScreen.layoutsFor(count)) {
        expect(rows.fold(0, (sum, row) => sum + row), count);
        final cells = CollageScreen.cells(rows, 1, 0.01);
        expect(cells, hasLength(count));
        expect(cells.every((cell) => cell.left >= 0 && cell.right <= 1.0001 && cell.bottom <= 1.0001), isTrue);
      }
    }
  });
}
