import 'package:better_image_manager/services/gallery.dart';
import 'package:better_image_manager/services/picture_image.dart';
import 'package:better_image_manager/services/places.dart';
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

  setUp(() {
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
