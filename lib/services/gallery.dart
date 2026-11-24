import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:native_imaging/native_imaging.dart';

/// How much of the phone's gallery the app may read, on Android.
enum GalleryAccess {
  /// Every picture.
  all,

  /// Only those the user picked (Android 14's "Select photos").
  some,

  /// None yet: the app can ask.
  none,

  /// None, and Android won't ask again: only Settings can give it.
  blocked,
}

/// A picture in the phone's gallery, as Android lists it.
class GalleryEntry {
  const GalleryEntry(this.id, this.path, this.bytes, this.taken, this.modified, this.width, this.height);

  /// Android's id for it (MediaStore's).
  final int id;
  final String path;
  final int bytes;

  /// When it was taken and last changed, in ms since 1970; 0 if unknown.
  final int taken;
  final int modified;

  /// Upright, as shown; 0 if unknown.
  final int width;
  final int height;
}

/// The phone's own pictures on Android, through MainActivity.kt: the
/// gallery (MediaStore), the thumbnails Android keeps of them, and their
/// metadata.
abstract final class Gallery {
  static const _channel = MethodChannel('better_image_manager/gallery');

  static Future<GalleryAccess> access() async => _access(await _channel.invokeMethod<String>('access'));

  /// Asks the user for access (Android's own prompt), and says what they gave.
  static Future<GalleryAccess> askForAccess() async => _access(await _channel.invokeMethod<String>('askForAccess'));

  /// The app's page in Settings, where access can be given once Android
  /// won't ask any more.
  static Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');

  static GalleryAccess _access(String? name) => GalleryAccess.values.asNameMap()[name] ?? GalleryAccess.none;

  /// Every picture the app may read.
  static Future<List<GalleryEntry>> list() async {
    final lists = (await _channel.invokeMapMethod<String, Object?>('list'))!;
    final ids = lists['ids']! as Int64List;
    final paths = (lists['paths']! as List).cast<String>();
    final sizes = lists['sizes']! as Int64List;
    final taken = lists['taken']! as Int64List;
    final modified = lists['modified']! as Int64List;
    final widths = lists['widths']! as Int32List;
    final heights = lists['heights']! as Int32List;
    return [
      for (var i = 0; i < ids.length; i++)
        GalleryEntry(ids[i], paths[i], sizes[i], taken[i], modified[i], widths[i], heights[i]),
    ];
  }

  /// The thumbnail Android keeps of picture [id], upright, as RGBA pixels:
  /// at a square tile's size, its shorter side no more than [size].
  ///
  /// The latest asked for go first, and those waiting too long are dropped
  /// (a [NativeImagingException] that's [NativeImagingException.cancelled]):
  /// scrolled far, the tiles stopped on get theirs before those passed.
  ///
  /// With [background], it waits apart from the tiles' (as
  /// [NativeImaging.thumbnail]'s does): never dropped, fewer at once.
  static Future<DecodedImage> thumbnail(int id, int size, {bool background = false}) =>
      (background ? _backgroundThumbnails : _thumbnails).run(() async {
        final result = (await _channel.invokeMapMethod<String, Object?>('thumbnail', {'id': id, 'size': size}))!;
        return DecodedImage(result['width']! as int, result['height']! as int, result['pixels']! as Uint8List);
      });

  // The same queues as NativeImaging's, given up on after a while too: an
  // answer that never comes (the activity gone) mustn't hold a turn for good.
  static final _thumbnails = Limiter(
    4,
    timeout: const Duration(seconds: 20),
    newestFirst: true,
    maxWaiting: 200,
  );
  static final _backgroundThumbnails = Limiter(2, timeout: const Duration(seconds: 20), newestFirst: true);

  /// Android's share sheet, with the pictures [ids].
  static Future<void> share(List<int> ids) => _channel.invokeMethod<void>('share', {'ids': ids});

  /// Moves the pictures [ids] to Android's trash (where they stay 30 days),
  /// once the user says yes to Android's prompt. False if they said no.
  static Future<bool> trash(List<int> ids) async => await _channel.invokeMethod<bool>('trash', {'ids': ids}) ?? false;

  /// Where picture [id]'s subject is, for the editor's Background: found by
  /// Google's ML Kit, on the phone. See [SubjectMask].
  static Future<SubjectMask> subjectMask(int id) async {
    final result = (await _channel.invokeMapMethod<String, Object?>('subjectMask', {'id': id}))!;
    return SubjectMask(result['width']! as int, result['height']! as int, result['alpha']! as Uint8List);
  }

  /// Saves an edited copy of picture [id] in the gallery, as
  /// [NativeImaging.edit] does on a PC, beside it (or in Pictures/Glide,
  /// where Android won't let the app add pictures). Returns
  /// the copy's id and path.
  static Future<({int id, String path})> saveEditedCopy(
    int id, {
    required int quarterTurns,
    required bool flip,
    required (double, double, double, double) crop,
    required Look look,
    required BackgroundEffect background,
    required int backgroundColor,
    required double blurSpread,
    SubjectMask? mask,
  }) async {
    final (left, top, width, height) = crop;
    final result = (await _channel.invokeMapMethod<String, Object?>('saveEditedCopy', {
      'id': id,
      'quarterTurns': quarterTurns,
      'flip': flip,
      'crop': [left, top, width, height],
      'look': look.values,
      'background': background.index,
      'color': backgroundColor & 0xFFFFFF,
      'blurSpread': blurSpread,
      'mask': mask?.alpha,
      'maskWidth': mask?.width,
      'maskHeight': mask?.height,
    }))!;
    return (id: result['id']! as int, path: result['path']! as String);
  }

  /// Saves a picture the app made (a sticker, a collage) into the gallery,
  /// in Pictures/Glide, as [name] from its [png] bytes.
  /// Returns its id and path.
  static Future<({int id, String path})> saveNew(Uint8List png, String name) async {
    final result = (await _channel.invokeMapMethod<String, Object?>('saveNew', {'png': png, 'name': name}))!;
    return (id: result['id']! as int, path: result['path']! as String);
  }

  /// The camera each of the pictures [ids] was taken on, in order: its maker
  /// and model as its metadata names them (null where it doesn't), or null
  /// for one that couldn't be read just now. Each picture's read for it, as
  /// Android's gallery doesn't keep them: slow over thousands, so read once
  /// and kept (see [AndroidGallery]).
  static Future<List<({String? make, String? model})?>> cameras(List<int> ids) async {
    final result = (await _channel.invokeMapMethod<String, Object?>('cameras', {'ids': ids}))!;
    final makes = (result['makes']! as List).cast<String?>();
    final models = (result['models']! as List).cast<String?>();
    final failed = (result['failed'] as List?)?.cast<bool>();
    return [
      for (var i = 0; i < ids.length; i++)
        if (failed != null && failed[i]) null else (make: makes[i], model: models[i]),
    ];
  }

  /// What picture [id]'s metadata says: camera, settings, where it was taken.
  static Future<PhotoDetails> details(int id) async {
    final values = (await _channel.invokeMapMethod<String, Object?>('details', {'id': id}))!;
    double? number(String key) => (values[key] as num?)?.toDouble();
    return PhotoDetails(
      make: values['make'] as String?,
      model: values['model'] as String?,
      lens: values['lens'] as String?,
      fNumber: number('fnumber'),
      exposure: number('exposure'),
      iso: number('iso')?.round(),
      focalLength: number('focal'),
      focalLength35: number('focal35'),
      latitude: number('latitude'),
      longitude: number('longitude'),
    );
  }
}
