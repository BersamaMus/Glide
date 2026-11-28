import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glide/services/browser.dart';
import 'package:glide/services/favourites.dart';
import 'package:glide/services/gallery.dart';
import 'package:glide/services/library_index.dart';
import 'package:glide/services/places.dart';
import 'package:glide/widgets/picture_grid.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

/// Favourites: marked with a heart, kept between runs, and shown on a tab of
/// their own, wherever they are.
void main() {
  late Directory folder;
  late File kept;
  late Favourites favourites;

  String path(String name) => p.join(folder.path, name);

  Future<void> settle(Browser browser) async {
    while (browser.updating) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Five pictures a day apart (a the newest), in two folders.
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('favourites_test');
    kept = File(p.join(folder.path, '.app', 'favourites.json'));
    for (final (i, name) in ['a.jpg', 'b.jpg', p.join('Trip', 'c.jpg'), 'd.png', 'e.jpg'].indexed) {
      final file = File(path(name));
      await file.create(recursive: true);
      await file.setLastModified(DateTime(2026, 3, 20 - i));
    }
    PhotoLibrary.forgetAll();
    FavouritePictures.forgetAll();
    await LibraryIndex.at(File(p.join(folder.path, '.index', 'index.json')));
    PhotoLibrary.readDates = (paths) async => [for (final _ in paths) DateTaken.none];
    favourites = Favourites.at(kept);
  });

  tearDown(() async {
    PhotoLibrary.forgetAll();
    await favourites.saved;
    await LibraryIndex.idle();
    await folder.delete(recursive: true);
  });

  test('are kept between runs', () async {
    await favourites.mark([path('a.jpg'), path('d.png')], favourite: true);
    await favourites.mark([path('a.jpg')], favourite: false);
    await favourites.saved;

    final again = Favourites.at(kept);
    await again.ready;
    expect(again.paths, [path('d.png')]);
    expect(again.contains(path('a.jpg')), isFalse);
  });

  test('on Windows, a path is the same whatever its case', () async {
    if (!Platform.isWindows) return;
    await favourites.mark([path('a.jpg')], favourite: true);
    expect(favourites.contains(path('A.JPG')), isTrue);
    // Marked again in another case: still one.
    await favourites.mark([path('A.JPG')], favourite: true);
    expect(favourites.paths, hasLength(1));
  });

  test('the tab shows them newest first, wherever they are, and not those that have gone', () async {
    await favourites.mark([
      path('e.jpg'),
      path(p.join('Trip', 'c.jpg')),
      path('a.jpg'),
      path('gone.jpg'),
    ], favourite: true);
    final listing = await const FavouritePictures().list();
    expect([for (final picture in listing.pictures) picture.name], ['a.jpg', 'c.jpg', 'e.jpg']);
    expect(listing.pending, isNull);

    // Listed again: the very same pictures, so what's selected stays put.
    final again = await const FavouritePictures().list();
    expect([
      for (final (i, picture) in again.pictures.indexed) identical(picture, listing.pictures[i]),
    ], everyElement(isTrue));
  });

  test('a favourite is dated by when it was taken, where the library has read it', () async {
    final library = Browser(PhotoLibrary(folder.path));
    addTearDown(library.dispose);
    // e.jpg, the oldest by its file, was taken the newest of all.
    PhotoLibrary.readDates = (paths) async => [
      for (final file in paths) p.basename(file) == 'e.jpg' ? DateTaken(DateTime(2026, 4, 1)) : DateTaken.none,
    ];
    await library.open(library.location);
    await settle(library);

    await favourites.mark([path('a.jpg'), path('e.jpg')], favourite: true);
    final pictures = (await const FavouritePictures().list()).pictures.cast<LocalPicture>();
    expect([for (final picture in pictures) picture.name], ['e.jpg', 'a.jpg']);
    expect(pictures.first.taken, DateTime(2026, 4, 1));
  });

  group('the selection', () {
    late Browser browser;

    Picture picture(String name) => browser.pictures.firstWhere((picture) => picture.name == name);

    setUp(() async {
      browser = Browser(PhotoLibrary(folder.path));
      await browser.open(browser.location);
      await settle(browser);
    });

    tearDown(() => browser.dispose());

    test('is marked, or if all of it is already, no longer', () async {
      browser.click(picture('a.jpg'));
      browser.click(picture('b.jpg'), toggle: true);
      expect(browser.canFavourite, isTrue);
      expect(browser.selectionIsFavourite, isFalse);
      await browser.toggleFavourite();
      expect(favourites.paths, [path('a.jpg'), path('b.jpg')]);
      expect(browser.selectionIsFavourite, isTrue);

      // One more that isn't: all of them are marked, rather than unmarked.
      browser.click(picture('d.png'), toggle: true);
      expect(browser.selectionIsFavourite, isFalse);
      await browser.toggleFavourite();
      expect(favourites.paths, hasLength(3));
      await browser.toggleFavourite();
      expect(favourites.paths, isEmpty);
    });

    test('on the Favourites tab, one that is no longer goes, and the next is focused', () async {
      await favourites.mark([path('a.jpg'), path('b.jpg'), path('d.png')], favourite: true);
      await browser.open(const FavouritePictures());
      expect([for (final picture in browser.pictures) picture.name], ['a.jpg', 'b.jpg', 'd.png']);

      browser.click(picture('b.jpg'));
      await browser.toggleFavourite();
      expect([for (final picture in browser.pictures) picture.name], ['a.jpg', 'd.png']);
      expect(browser.focused?.name, 'd.png');
      expect(browser.selection.map((picture) => picture.name), ['d.png']);
    });

    test('pressed before the favourites kept are read, one that was a favourite comes off', () async {
      await favourites.mark([path('a.jpg')], favourite: true);
      await favourites.saved;
      // As if the app had just started: what was kept isn't read yet.
      favourites = Favourites.at(kept);
      browser.click(picture('a.jpg'));
      await browser.toggleFavourite();
      expect(favourites.contains(path('a.jpg')), isFalse);
    });

    test('two quick presses mark it, then unmark it', () async {
      browser.click(picture('a.jpg'));
      final first = browser.toggleFavourite();
      final second = browser.toggleFavourite();
      await (first, second).wait;
      expect(favourites.contains(path('a.jpg')), isFalse);
    });

    test("the heart over the preview is the picture in view's, if that isn't selected", () async {
      browser.click(picture('a.jpg'));
      browser.click(picture('b.jpg'), toggle: true);
      expect(browser.previewed.map((picture) => picture.name), ['a.jpg', 'b.jpg']);
      // Ctrl+clicked off: still in view, but no longer selected.
      browser.click(picture('b.jpg'), toggle: true);
      expect(browser.focused?.name, 'b.jpg');
      expect(browser.previewed.map((picture) => picture.name), ['b.jpg']);
      await browser.toggleFavourite(browser.previewed);
      expect(favourites.paths, [path('b.jpg')]);
    });

    test('on the Favourites tab, the picture in view taken out leaves the selection be', () async {
      await favourites.mark([path('a.jpg'), path('b.jpg'), path('d.png')], favourite: true);
      await browser.open(const FavouritePictures());
      browser.click(picture('a.jpg'));
      browser.click(picture('b.jpg'), toggle: true);
      browser.click(picture('b.jpg'), toggle: true);
      await browser.toggleFavourite(browser.previewed);
      expect([for (final picture in browser.pictures) picture.name], ['a.jpg', 'd.png']);
      expect(browser.selection.map((picture) => picture.name), ['a.jpg']);
      expect(browser.focused?.name, 'd.png');
    });

    group('moved', () {
      /// Whether a name that's taken is kept beside the one moved, as
      /// "a (2).jpg", rather than replaced.
      var keepBoth = false;

      setUp(() {
        keepBoth = false;
        Browser.transfer = (paths, to, {bool move = false}) async {
          for (final from in paths) {
            var target = p.join(to, p.basename(from));
            if (File(target).existsSync()) {
              if (keepBoth) {
                target = p.join(to, '${p.basenameWithoutExtension(from)} (2)${p.extension(from)}');
              } else {
                File(target).deleteSync();
              }
            }
            File(from).renameSync(target);
          }
          return true;
        };
      });

      tearDown(() => Browser.transfer = NativeImaging.transfer);

      Future<void> moveA() async {
        await favourites.mark([path('a.jpg')], favourite: true);
        browser.click(picture('a.jpg'));
        await browser.copySelection(path('Trip'), move: true);
      }

      test('a favourite moved is still one, where it went', () async {
        await moveA();
        expect(favourites.paths, [path(p.join('Trip', 'a.jpg'))]);
      });

      test('a favourite moved over a picture of the same name is still one', () async {
        await File(path(p.join('Trip', 'a.jpg'))).writeAsString('another picture');
        await moveA();
        expect(favourites.paths, [path(p.join('Trip', 'a.jpg'))]);
      });

      test("a favourite moved beside a picture of the same name doesn't give that one its heart", () async {
        await File(path(p.join('Trip', 'a.jpg'))).writeAsString('another picture');
        keepBoth = true;
        await moveA();
        expect(File(path(p.join('Trip', 'a (2).jpg'))).existsSync(), isTrue);
        expect(favourites.contains(path(p.join('Trip', 'a.jpg'))), isFalse);
      });
    });

    test('a favourite renamed is still one', () async {
      if (!Platform.isWindows) return; // renaming is Windows'
      await favourites.mark([path('a.jpg')], favourite: true);
      browser.click(picture('a.jpg'));
      expect(await browser.renameFocused('beach'), isNull);
      expect(favourites.paths, [path('beach.jpg')]);
    });

    testWidgets('F marks the selection, and its tile has a heart', (tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PictureGrid(browser: browser)),
        ),
      );
      await tester.pump();
      expect(find.byIcon(Icons.favorite_rounded), findsNothing);

      await tester.tap(find.text('b.jpg'));
      await tester.runAsync(() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await favourites.saved;
      });
      await tester.pump();
      expect(favourites.contains(path('b.jpg')), isTrue);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      // The thumbnails' time limits, run out (see filter_test.dart).
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 21));
      }
    });
  });

  group('on a phone', () {
    const channel = MethodChannel('better_image_manager/gallery');

    setUp(() {
      AndroidGallery.forgetAll();
      AndroidGallery.readCameras = (ids) async => [for (final _ in ids) (make: null, model: null)];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'access' ? 'all' : null,
      );
      final day = DateTime(2026, 10, 1).millisecondsSinceEpoch;
      AndroidGallery.entries = () async => [
        GalleryEntry(1, '/storage/emulated/0/DCIM/Camera/IMG_1.jpg', 100, day, day, 0, 0),
        GalleryEntry(2, '/storage/emulated/0/DCIM/Camera/IMG_2.jpg', 100, day + 1000, day + 1000, 0, 0),
        GalleryEntry(3, '/storage/emulated/0/Download/meme.png', 100, 0, day + 2000, 0, 0),
      ];
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('the tab shows the gallery\'s favourites, as the gallery has them', () async {
      await favourites.mark([
        '/storage/emulated/0/Download/meme.png',
        '/storage/emulated/0/DCIM/Camera/IMG_1.jpg',
      ], favourite: true);
      final listing = await const FavouritePictures(within: AndroidGallery()).list();
      final pictures = listing.pictures.cast<LocalPicture>();
      expect([for (final picture in pictures) picture.name], ['meme.png', 'IMG_1.jpg']);
      // With the ids Android knows them by, for their thumbnails and sharing.
      expect([for (final picture in pictures) picture.galleryId], [3, 1]);
    });
  });
}
