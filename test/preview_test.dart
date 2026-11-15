import 'dart:async';

import 'package:better_image_manager/services/picture_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// A big picture, as far as Flutter's cache is concerned: one it's asked
/// for, and keeps. It's decoded when the test says so.
@immutable
class _Preview extends ImageProvider<_Preview> {
  const _Preview(this.name);

  final String name;

  /// Each preview's decoding, finished by [decode].
  static final _decoding = <String, Completer<ImageInfo>>{};

  static Future<void> decode(String name) async {
    final decoding = _decoding[name]!;
    if (!decoding.isCompleted) decoding.complete(ImageInfo(image: await createTestImage()));
  }

  @override
  Future<_Preview> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_Preview key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter((_decoding[name] = Completer<ImageInfo>()).future);

  @override
  bool operator ==(Object other) => other is _Preview && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final cache = PaintingBinding.instance.imageCache;
  bool kept(String name) => cache.containsKey(_Preview(name));

  /// Starts showing the preview [name], as the preview pane does.
  Future<void> start(String name) async {
    final preview = _Preview(name);
    preview.resolve(ImageConfiguration.empty);
    keepPreview(preview);
    await pumpEventQueue();
  }

  /// Shows the preview [name], decoded.
  Future<void> show(String name) async {
    await start(name);
    await _Preview.decode(name);
    await pumpEventQueue();
  }

  setUp(cache.clear);

  test('only the last few previews are kept, leaving the cache to the thumbnails', () async {
    for (final name in ['a', 'b', 'c']) {
      await show(name);
    }
    expect([kept('a'), kept('b'), kept('c')], everyElement(isTrue));

    // A fourth: the one shown longest ago is let go of.
    await show('d');
    expect(kept('a'), isFalse);
    expect([kept('b'), kept('c'), kept('d')], everyElement(isTrue));

    // One gone back to is the newest again, and outlasts those since.
    await show('b');
    await show('e');
    expect(kept('c'), isFalse);
    expect([kept('b'), kept('d'), kept('e')], everyElement(isTrue));
  });

  test('one still being decoded is let go of once it is, not before', () async {
    await start('p1');
    for (final name in ['p2', 'p3', 'p4']) {
      await show(name);
    }
    // Swiped past while decoding: the work isn't thrown away.
    expect(kept('p1'), isTrue);

    await _Preview.decode('p1');
    await pumpEventQueue();
    expect(kept('p1'), isFalse);
    expect([kept('p2'), kept('p3'), kept('p4')], everyElement(isTrue));
  });
}
