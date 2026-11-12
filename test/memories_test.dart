import 'package:better_image_manager/services/gallery.dart';
import 'package:better_image_manager/services/places.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Memories: this day in years gone by, then every other day that's had
/// pictures in more than one year, made from the gallery's pictures.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('better_image_manager/gallery');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'access' ? 'all' : null,
    );
    Memories.now = () => DateTime(2026, 10, 22, 9);
    var id = 0;
    GalleryEntry taken(String name, DateTime date) =>
        GalleryEntry(++id, '/storage/emulated/0/DCIM/Camera/$name', 1000, date.millisecondsSinceEpoch, date.millisecondsSinceEpoch, 0, 0);
    AndroidGallery.entries = () async => [
      taken('today.jpg', DateTime(2026, 10, 22, 8)),
      taken('today_2023.jpg', DateTime(2023, 10, 22, 12)),
      taken('today_2025_late.jpg', DateTime(2025, 10, 22, 20)),
      taken('today_2025.jpg', DateTime(2025, 10, 22, 10)),
      taken('jan2_2019.jpg', DateTime(2019, 1, 2)),
      taken('jan1_2020.jpg', DateTime(2020, 1, 1)),
      taken('jan1_2018.jpg', DateTime(2018, 1, 1)),
      taken('jan2_2021.jpg', DateTime(2021, 1, 2)),
      // Only one year has a 5 March: not a memory.
      taken('mar5_2022.jpg', DateTime(2022, 3, 5)),
      taken('mar5_2022_too.jpg', DateTime(2022, 3, 5, 1)),
    ];
  });

  tearDown(() {
    Memories.now = DateTime.now;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('puts this day in years before first, then each day by year', () async {
    final memories = Memories(const [AndroidGallery()]);
    final pictures = (await memories.list()).pictures;
    expect(pictures.map((p) => p.name), [
      'today_2025.jpg',
      'today_2025_late.jpg',
      'today_2023.jpg',
      'jan1_2018.jpg',
      'jan1_2020.jpg',
      'jan2_2019.jpg',
      'jan2_2021.jpg',
    ]);
    final headings = {for (final picture in pictures) memories.groupLabel(memories.group(picture))};
    expect(headings, [
      '1 year ago today  ·  22 October 2025',
      '3 years ago today  ·  22 October 2023',
      '1 January 2018',
      '1 January 2020',
      '2 January 2019',
      '2 January 2021',
    ]);
  });

  test('other places still head their pictures by month', () async {
    final pictures = (await const AndroidGallery().list()).pictures;
    const gallery = AndroidGallery();
    expect(gallery.groupLabel(gallery.group(pictures.first)), 'October 2026');
  });
}
