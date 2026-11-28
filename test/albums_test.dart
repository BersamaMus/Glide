import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glide/services/browser.dart';
import 'package:glide/services/gallery.dart';
import 'package:glide/services/library_index.dart';
import 'package:glide/services/places.dart';
import 'package:glide/widgets/picture_grid.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

/// Albums: the camera's pictures, screenshots, downloads and apps', each
/// with chips to switch between them, as drives have.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<AlbumKind> albums(String path) => albumsOf(LocalPicture(File(path)));
  const phone = '/storage/emulated/0';

  group('which album a picture is in', () {
    test('the camera\'s, but not screenshots or apps\' under DCIM', () {
      expect(albums('$phone/DCIM/Camera/IMG_20250101_120000.jpg'), [AlbumKind.camera]);
      expect(albums('$phone/DCIM/100ANDRO/DSC_0001.JPG'), [AlbumKind.camera]);
      expect(albums('$phone/DCIM/Screenshots/Screenshot_20250101.png'), [AlbumKind.screenshots]);
      expect(albums('$phone/Pictures/Screenshots/Screenshot_20250101.png'), [AlbumKind.screenshots]);
      expect(albums('$phone/DCIM/Snapchat/Snapchat-123.jpg'), [AlbumKind.snapchat]);
      expect(albums(r'C:\Users\me\Pictures\Camera Roll\WIN_20250101.jpg'), [AlbumKind.camera]);
    });

    test('WhatsApp\'s, where Android has kept them over the years, less its stickers', () {
      expect(albums('$phone/WhatsApp/Media/WhatsApp Images/IMG-20250101-WA0001.jpg'), [AlbumKind.whatsapp]);
      expect(albums('$phone/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/Sent/IMG-20250101-WA0002.jpg'), [
        AlbumKind.whatsapp,
      ]);
      expect(albums('$phone/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Stickers/STK-1.webp'), isEmpty);
      // Saved elsewhere, known by its name: in Downloads too.
      expect(albums('$phone/Download/IMG-20250101-WA0003.jpg'), [AlbumKind.downloads, AlbumKind.whatsapp]);
      expect(albums(r'D:\Stuff\Downloads\WhatsApp Image 2025-01-01 at 10.00.00.jpeg'), [
        AlbumKind.downloads,
        AlbumKind.whatsapp,
      ]);
    });

    test('other apps\', by their folders', () {
      expect(albums('$phone/Pictures/Telegram/IMG_1.jpg'), [AlbumKind.telegram]);
      expect(albums('$phone/Android/media/org.telegram.messenger/Telegram/Telegram Images/1.jpg'), [
        AlbumKind.telegram,
      ]);
      expect(albums(r'C:\Users\me\Downloads\Telegram Desktop\photo_1.jpg'), [AlbumKind.downloads, AlbumKind.telegram]);
      expect(albums('$phone/Pictures/Instagram/IMG_1.jpg'), [AlbumKind.instagram]);
      expect(albums('$phone/Pictures/Messenger/received_1.jpeg'), [AlbumKind.messenger]);
      expect(albums('$phone/Pictures/Facebook/FB_IMG_1.jpg'), [AlbumKind.facebook]);
      expect(albums('$phone/Pictures/Signal/signal-1.jpg'), [AlbumKind.signal]);
      expect(albums('$phone/Pictures/Discord/unknown.png'), [AlbumKind.discord]);
    });

    test('a downloaded picture, and one that\'s in none', () {
      expect(albums('$phone/Download/cat.png'), [AlbumKind.downloads]);
      expect(albums('$phone/Pictures/Holiday/beach.jpg'), isEmpty);
      // A folder named for something else isn't the app's.
      expect(albums('$phone/Pictures/Signal Hill/view.jpg'), isEmpty);
    });
  });

  group('on a phone', () {
    const channel = MethodChannel('better_image_manager/gallery');
    const from = <Location>[AndroidGallery()];

    setUp(() {
      AndroidGallery.forgetAll();
      Album.forgetAll();
      LibraryIndex.unload();
      AndroidGallery.readCameras = (ids) async => [for (final _ in ids) (make: null, model: null)];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'access' ? 'all' : null,
      );
      final day = DateTime(2026, 10, 1).millisecondsSinceEpoch;
      var id = 0;
      GalleryEntry at(String path, int ago) =>
          GalleryEntry(++id, '$phone/$path', 100, day - ago * 86400000, day - ago * 86400000, 0, 0);
      AndroidGallery.entries = () async => [
        at('DCIM/Camera/IMG_1.jpg', 3),
        at('DCIM/Camera/IMG_2.jpg', 1),
        at('Pictures/Screenshots/Screenshot_1.png', 2),
        at('WhatsApp/Media/WhatsApp Images/IMG-20260930-WA0001.jpg', 1),
        at('Download/IMG-20260929-WA0002.jpg', 2),
        at('Pictures/Holiday/beach.jpg', 0),
      ];
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('an album shows its pictures, newest first', () async {
      final listing = await const Album(AlbumKind.whatsapp, from).list();
      expect(
        [for (final picture in listing.pictures) picture.name],
        ['IMG-20260930-WA0001.jpg', 'IMG-20260929-WA0002.jpg'],
      );
      expect((await const Album(AlbumKind.camera, from).list()).pictures.map((picture) => picture.name), [
        'IMG_2.jpg',
        'IMG_1.jpg',
      ]);
    });

    test('chips for the albums with pictures, in order, saying how many', () async {
      const album = Album(AlbumKind.camera, from);
      final sources = (await album.sources()).cast<Album>();
      expect(
        [for (final album in sources) album.kind],
        [AlbumKind.camera, AlbumKind.screenshots, AlbumKind.downloads, AlbumKind.whatsapp],
      );
      expect(
        [for (final album in sources) album.chipLabel],
        ['Camera  2', 'Screenshots  1', 'Downloads  1', 'WhatsApp  2'],
      );
      expect(album.switchable, isTrue);
    });

    test('opens on the album looked at last, while it has pictures, else the first that has', () async {
      expect((await Album.choose(from, preferred: AlbumKind.whatsapp)).kind, AlbumKind.whatsapp);
      expect((await Album.choose(from, preferred: AlbumKind.telegram)).kind, AlbumKind.camera);
      expect((await Album.choose(from)).kind, AlbumKind.camera);

      // Only a screenshot left, once it's been listed again.
      AndroidGallery.entries = () async => [
        GalleryEntry(1, '$phone/Pictures/Screenshots/Screenshot_1.png', 100, 0, 1000, 0, 0),
      ];
      await const Album(AlbumKind.camera, from).list();
      expect((await Album.choose(from)).kind, AlbumKind.screenshots);
    });

    test('one with no pictures says which to show instead, once they have been looked through', () async {
      const telegram = Album(AlbumKind.telegram, from);
      // Not known till something's listed them.
      expect(telegram.instead, isNull);
      await telegram.list();
      expect(telegram.instead?.kind, AlbumKind.camera);
      // One that has pictures stays.
      expect(const Album(AlbumKind.whatsapp, from).instead, isNull);
    });

    testWidgets('on a phone\'s width, the album chosen is scrolled to among the chips', (tester) async {
      late Browser browser;
      await tester.runAsync(() async {
        browser = Browser(const Album(AlbumKind.whatsapp, from));
        await browser.open(browser.location);
      });
      addTearDown(browser.dispose);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PictureGrid(browser: browser, onOpen: (_) {}),
          ),
        ),
      );
      // The chips, once it's been asked which albums have pictures; then
      // the row scrolling (its first frame only starts it).
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // WhatsApp's is the last of four: off the edge, till it's scrolled to.
      final chip = tester.getRect(find.ancestor(of: find.text('WhatsApp  2'), matching: find.byType(ChoiceChip)));
      expect(chip.left, greaterThanOrEqualTo(0));
      expect(chip.right, lessThanOrEqualTo(400));

      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 21));
      }
    });

    test('with none, says what would show', () async {
      AndroidGallery.entries = () async => [GalleryEntry(1, '$phone/Pictures/Holiday/beach.jpg', 100, 0, 1000, 0, 0)];
      final album = await Album.choose(from);
      expect(await album.sources(), isEmpty);
      expect(album.emptyText, startsWith('No albums yet.'));
    });
  });

  group('on a PC', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('albums_test');
      for (final name in [
        p.join('Pictures', 'Screenshots', 'Screenshot 1.png'),
        p.join('Pictures', 'Camera Roll', 'WIN_1.jpg'),
        p.join('Backup', 'WhatsApp Images', 'IMG-20250101-WA0001.jpg'),
      ]) {
        await File(p.join(root.path, name)).create(recursive: true);
      }
      PhotoLibrary.forgetAll();
      Album.forgetAll();
      await LibraryIndex.at(File(p.join(root.path, '.index', 'index.json')));
      PhotoLibrary.readDates = (paths) async => [for (final _ in paths) DateTaken.none];
    });

    tearDown(() async {
      PhotoLibrary.forgetAll();
      await LibraryIndex.idle();
      await root.delete(recursive: true);
    });

    /// Lists [album] until there's nothing left to do.
    Future<Listing> settled(Album album) async {
      var listing = await album.list();
      for (var pending = listing.pending; pending != null; pending = listing.pending) {
        await pending;
        listing = await album.list();
      }
      return listing;
    }

    test('a picture found in Pictures and on its drive is shown once', () async {
      final from = [PhotoLibrary(p.join(root.path, 'Pictures')), PhotoLibrary(root.path)];
      final screenshots = await settled(Album(AlbumKind.screenshots, from));
      expect([for (final picture in screenshots.pictures) picture.name], ['Screenshot 1.png']);
      final sources = (await Album(AlbumKind.screenshots, from).sources()).cast<Album>();
      expect([for (final album in sources) album.chipLabel], ['Camera  1', 'Screenshots  1', 'WhatsApp  1']);
    });
  });
}
