import 'package:better_image_manager/services/places.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_imaging/native_imaging.dart';

void main() {
  final phone = Phone('SERIAL1', 'Test Phone', true, 128 << 30, 40 << 30);

  /// A phone's folders, as MTP shows them: object id → what's in it. The
  /// device's own top ('') holds its storage.
  late Map<String, List<PhoneEntry>> tree;
  late List<String> visited;

  PhoneEntry folder(String id, String name) => PhoneEntry(id, name, true, 0, null);
  PhoneEntry photo(String id, String name, DateTime date, {int size = 2 << 20}) =>
      PhoneEntry(id, name, false, size, date);

  setUp(() {
    PhonePhotos.forgetAll();
    visited = [];
    tree = {
      '': [folder('s', 'Internal shared storage')],
      's': [
        folder('android', 'Android'),
        folder('music', 'Music'),
        folder('pictures', 'Pictures'),
        folder('dcim', 'DCIM'),
        folder('hidden', '.thumbnails'),
      ],
      'android': [folder('data', 'data'), folder('media', 'media')],
      'data': [photo('junk', 'app_asset.png', DateTime(2025, 1, 1))],
      'media': [folder('wa', 'WhatsApp Images'), folder('stickers', 'WhatsApp Stickers')],
      'wa': [photo('wa1', 'IMG-20250301-WA0001.jpg', DateTime(2025, 3, 1))],
      'stickers': [photo('st1', 'sticker.webp', DateTime(2025, 3, 2))],
      'music': [photo('song', 'notes.txt', DateTime(2025, 1, 1))],
      'pictures': [
        folder('shots', 'Screenshots'),
        photo('empty', 'being_written.jpg', DateTime(2025, 6, 1), size: 0),
      ],
      'shots': [photo('ss1', 'Screenshot_20250510.png', DateTime(2025, 5, 10))],
      'dcim': [folder('camera', 'Camera')],
      'camera': [
        photo('c1', 'IMG_20250702_101500.jpg', DateTime(2025, 7, 2)),
        photo('c2', 'IMG_20250615_090000.heic', DateTime(2025, 6, 15)),
        photo('bad', 'IMG_clock_not_set.jpg', DateTime(2049, 12, 31)),
      ],
      'hidden': [photo('th', 'thumb.jpg', DateTime(2025, 7, 3))],
    };
    PhonePhotos.children = (serial, {folderId = ''}) async {
      visited.add(folderId);
      return tree[folderId] ?? const [];
    };
  });

  Future<Listing> settled(PhonePhotos photos) async {
    var listing = await photos.list();
    for (var pending = listing.pending; pending != null; pending = listing.pending) {
      await pending;
      listing = await photos.list();
    }
    return listing;
  }

  test('shows every photo on the phone, newest first, without apps\' data, stickers or hidden ones', () async {
    final listing = await settled(PhonePhotos(phone));
    expect([for (final picture in listing.pictures) picture.name], [
      'IMG_20250702_101500.jpg',
      'IMG_20250615_090000.heic',
      'Screenshot_20250510.png',
      'IMG-20250301-WA0001.jpg',
      'IMG_clock_not_set.jpg', // its date can't be right: last, undated
    ]);
    expect(listing.pictures.last.date, isNull);
  });

  test('looks through the camera\'s folder first, and apps\' media last', () async {
    await settled(PhonePhotos(phone));
    final order = [for (final id in visited) if (const {'camera', 'shots', 'wa'}.contains(id)) id];
    expect(order, ['camera', 'shots', 'wa']);
    expect(visited, isNot(contains('data')));
    expect(visited, isNot(contains('hidden')));
  });

  test('a locked phone, or none, has nothing to show and says why', () async {
    final locked = PhonePhotos(Phone('SERIAL2', 'Locked Phone', false, 0, 0));
    expect((await locked.list()).pictures, isEmpty);
    expect(locked.emptyText, contains('Unlock Locked Phone'));
    expect(const PhonePhotos.none().emptyText, startsWith('No phone connected'));
    // Unlocked, it's the same phone, as it is now.
    expect(PhonePhotos(Phone('SERIAL2', 'Locked Phone', true, 1, 1)).sameSource(locked), isTrue);
  });

  test('a phone unplugged part way keeps what was found', () async {
    PhonePhotos.children = (serial, {folderId = ''}) async {
      if (folderId == 'pictures') throw NativeImagingException(0x8007048F);
      return tree[folderId] ?? const [];
    };
    final listing = await settled(PhonePhotos(phone));
    expect(listing.pictures.map((picture) => picture.name), contains('IMG_20250702_101500.jpg'));
  });

  test('a look again cut short (the phone locked) keeps what was found before', () async {
    final photos = PhonePhotos(phone);
    final first = await settled(photos);
    expect(first.pictures, hasLength(5));

    // Locked after the camera's folder: the rest can't be read.
    PhonePhotos.children = (serial, {folderId = ''}) async {
      if (folderId == 'pictures') throw NativeImagingException(0x8007048F);
      return tree[folderId] ?? const [];
    };
    photos.forget();
    final again = await settled(photos);
    expect(again.pictures, hasLength(5));
  });
}
