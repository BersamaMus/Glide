import 'package:glide/services/gallery.dart';
import 'package:glide/services/library_index.dart';
import 'package:glide/services/picture_image.dart';
import 'package:glide/services/places.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Android gallery, with Android's side (MainActivity.kt) stood in for.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('better_image_manager/gallery');

  /// What Android says of access, before and after it's asked.
  late String access;
  late String afterAsking;
  late int asked;

  /// The pictures whose cameras Android was asked for, by id.
  final camerasAsked = <int>[];

  /// Lists the gallery until there's nothing left to do (its cameras read).
  Future<Listing> settled() async {
    var listing = await const AndroidGallery().list();
    for (var pending = listing.pending; pending != null; pending = listing.pending) {
      await pending;
      listing = await const AndroidGallery().list();
    }
    return listing;
  }

  setUp(() {
    AndroidGallery.forgetAll();
    // An index of its own, each test: nothing read before.
    LibraryIndex.unload();
    camerasAsked.clear();
    AndroidGallery.readCameras = (ids) async {
      camerasAsked.addAll(ids);
      return [
        for (final id in ids)
          id == 2 ? (make: 'OPPO', model: 'OPPO Find X9 Pro') : (make: null, model: null),
      ];
    };
    asked = 0;
    afterAsking = 'all';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'access':
          return access;
        case 'askForAccess':
          asked++;
          return access = afterAsking;
      }
      return null;
    });
    final day = DateTime(2026, 10, 1).millisecondsSinceEpoch;
    AndroidGallery.entries = () async => [
      // A screenshot (no date taken), a camera photo, an older one.
      GalleryEntry(1, '/storage/emulated/0/Pictures/Screenshots/shot.png', 100, 0, day + 3000, 1080, 2400),
      GalleryEntry(2, '/storage/emulated/0/DCIM/Camera/IMG_2.jpg', 5000000, day + 5000, day + 6000, 4096, 3072),
      GalleryEntry(3, '/storage/emulated/0/DCIM/Camera/IMG_1.jpg', 5000000, day - 86400000, day, 0, 0),
    ];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('lists every picture in the gallery, newest first', () async {
    access = 'all';
    final listing = await const AndroidGallery().list();
    final pictures = listing.pictures.cast<LocalPicture>();
    expect(pictures.map((p) => p.name), ['IMG_2.jpg', 'shot.png', 'IMG_1.jpg']);
    // By when it was taken, or else when it was last changed.
    expect(pictures[1].taken, isNull);
    expect(pictures[1].date, DateTime.fromMillisecondsSinceEpoch(DateTime(2026, 10, 1).millisecondsSinceEpoch + 3000));
    // Sizes as Android knows them; none where it doesn't.
    expect(pictures[0].dimensions, (4096, 3072));
    expect(pictures[2].dimensions, isNull);
    expect(asked, 0);
  });

  test('pictures are kept from one listing to the next, and made anew only once they change', () async {
    access = 'all';
    final first = (await settled()).pictures;
    // Back in the app, the gallery's listed again: the same pictures, not
    // copies of them to work out all over again.
    final again = (await const AndroidGallery().list()).pictures;
    expect([for (final (i, picture) in again.indexed) identical(picture, first[i])], everyElement(isTrue));

    // One's been edited since (it's bigger now), under the same id.
    final entries = await AndroidGallery.entries();
    AndroidGallery.entries = () async => [
      for (final entry in entries)
        entry.id == 2
            ? GalleryEntry(2, entry.path, 6000000, entry.taken, entry.modified, entry.width, entry.height)
            : entry,
    ];
    final after = (await const AndroidGallery().list()).pictures;
    expect(after.first.name, 'IMG_2.jpg');
    expect(identical(after.first, first.first), isFalse);
    expect(after.first.bytes, 6000000);
    expect(identical(after[1], first[1]), isTrue);
  });

  test('reads the camera each picture was taken on behind what is shown, once', () async {
    access = 'all';
    final first = await const AndroidGallery().list();
    // In their places at once, by Android's dates; the cameras still to come.
    expect(first.pictures.map((p) => p.name), ['IMG_2.jpg', 'shot.png', 'IMG_1.jpg']);
    expect(first.work, Work.cameras);
    final listing = await settled();
    expect(listing.work, isNull);
    expect([for (final picture in listing.pictures) picture.camera], ['OPPO Find X9 Pro', null, null]);
    expect(camerasAsked..sort(), [1, 2, 3]);

    // Kept: not read again, though the gallery's listed again.
    camerasAsked.clear();
    const AndroidGallery().forget();
    await settled();
    expect(camerasAsked, isEmpty);
  });

  test('a camera that could not be read is tried again next run, not over and over now', () async {
    access = 'all';
    var failing = true;
    AndroidGallery.readCameras = (ids) async {
      camerasAsked.addAll(ids);
      return [
        for (final id in ids)
          id == 2 && failing ? null : (id == 2 ? (make: 'OPPO', model: 'OPPO Find X9 Pro') : (make: null, model: null)),
      ];
    };
    final listing = await settled();
    expect(listing.work, isNull);
    expect([for (final picture in listing.pictures) picture.camera], [null, null, null]);
    expect(camerasAsked..sort(), [1, 2, 3]);

    // Listed again this run: not asked again.
    camerasAsked.clear();
    const AndroidGallery().forget();
    await settled();
    expect(camerasAsked, isEmpty);

    // Next run it's read, and the others aren't asked for again.
    AndroidGallery.forgetAll();
    failing = false;
    final again = await settled();
    expect(camerasAsked, [2]);
    expect([for (final picture in again.pictures) picture.camera], ['OPPO Find X9 Pro', null, null]);
  });

  test('a lot Android fails over leaves the rest read', () async {
    access = 'all';
    AndroidGallery.readCameras = (ids) async {
      camerasAsked.addAll(ids);
      if (ids.contains(3)) throw PlatformException(code: 'OutOfMemoryError');
      return [for (final id in ids) id == 200 ? (make: 'OPPO', model: 'OPPO Find X9 Pro') : (make: null, model: null)];
    };
    final day = DateTime(2026, 10, 1).millisecondsSinceEpoch;
    AndroidGallery.entries = () async => [
      for (var id = 1; id <= 250; id++)
        GalleryEntry(id, '/storage/emulated/0/DCIM/Camera/IMG_$id.jpg', 5000, day + id, day + id, 0, 0),
    ];
    final listing = await settled();
    expect(listing.work, isNull);
    // The lot with 3 in it failed; those after it were still read.
    expect(camerasAsked.toSet(), {for (var id = 1; id <= 250; id++) id});
    expect([for (final picture in listing.pictures) if (picture.name == 'IMG_200.jpg' || picture.name == 'IMG_3.jpg') picture.camera], ['OPPO Find X9 Pro', null]);
  });

  test('two of Android\'s entries for one path don\'t keep the cameras being read', () async {
    access = 'all';
    final day = DateTime(2026, 10, 1).millisecondsSinceEpoch;
    AndroidGallery.entries = () async => [
      GalleryEntry(1, '/storage/emulated/0/DCIM/Camera/IMG_1.jpg', 5000, day, day, 0, 0),
      GalleryEntry(2, '/storage/emulated/0/DCIM/Camera/IMG_1.jpg', 6000, day, day + 1, 0, 0),
    ];
    final listing = await settled().timeout(const Duration(seconds: 10));
    expect(listing.work, isNull);
    expect(listing.pending, isNull);
    expect(camerasAsked..sort(), [1, 2]);
  });

  test('tiles use the thumbnails Android keeps', () async {
    access = 'all';
    final picture = (await const AndroidGallery().list()).pictures.first;
    expect(picture.thumbnail(256), const GalleryThumbnail(2, 256));
  });

  test('asks for access the first time, and lists what it was given', () async {
    access = 'none';
    afterAsking = 'some';
    final listing = await const AndroidGallery().list();
    expect(asked, 1);
    expect(listing.pictures, hasLength(3));
    expect(const AndroidGallery().subtitle, 'Only the pictures you allowed');
  });

  test('without access: nothing listed, and a way to give it', () async {
    access = 'none';
    afterAsking = 'none';
    final listing = await const AndroidGallery().list();
    expect(listing.pictures, isEmpty);
    expect(const AndroidGallery().emptyAction?.label, 'Allow access');

    // Android won't ask any more: only Settings can give it.
    access = 'blocked';
    expect((await const AndroidGallery().list()).pictures, isEmpty);
    expect(const AndroidGallery().emptyAction?.label, 'Open Settings');
    expect(const AndroidGallery().emptyText, contains('Settings'));
  });
}
