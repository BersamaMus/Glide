import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

import 'gallery.dart';

/// Formats Flutter can't decode, which Windows can with its own codecs
/// (some from the Store: HEIF, AVIF and Raw Image Extensions).
const windowsCodecExtensions = {
  '.heic', '.heif', '.avif', '.tif', '.tiff', //
  '.dng', '.cr2', '.cr3', '.nef', '.nrw', '.arw', '.orf', '.rw2', '.raf', '.srw', '.pef',
};

/// Whether [name] (a path, or a phone file's name) needs Windows' codecs.
bool _needsWindowsCodec(String name) =>
    Platform.isWindows && windowsCodecExtensions.contains(p.extension(name).toLowerCase());

/// The picture at [file], decoded so neither side is over [maxSize]: by
/// Flutter where it can, or by Windows.
ImageProvider pictureImage(File file, {required int maxSize}) {
  if (_needsWindowsCodec(file.path)) return WindowsCodecImage(file.path, maxSize);
  return ResizeImage(
    FileImage(file),
    width: maxSize,
    height: maxSize,
    policy: ResizeImagePolicy.fit,
    allowUpscaling: false,
  );
}

/// Formats that may be animated, which Flutter plays.
const animatedExtensions = {'.gif', '.webp'};

/// The picture at [file] for a tile, neither side over [size]. On Windows,
/// got as cheaply as can be (see [WindowsThumbnail]); elsewhere, decoded.
/// Still, even for a GIF: it plays in the preview.
ImageProvider pictureThumbnail(File file, {required int size}) =>
    Platform.isWindows ? WindowsThumbnail(file.path, size) : pictureImage(file, maxSize: size);

/// A tile's thumbnail from Windows: the one File Explorer has kept if it's
/// shown the picture before, else the small preview a camera puts at the
/// start of the file, else the picture decoded at that size. A drive's tens
/// of thousands of photos needn't each be read whole, then, and the newest
/// asked for come first (see [NativeImaging.thumbnail]).
@immutable
class WindowsThumbnail extends ImageProvider<WindowsThumbnail> {
  const WindowsThumbnail(this.path, this.size);

  final String path;
  final int size;

  @override
  Future<WindowsThumbnail> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(WindowsThumbnail key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load(decode), informationCollector: () => [DiagnosticsProperty('Path', path)]);

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    try {
      return await _fromPixels(await NativeImaging.thumbnail(path, size));
    } on Object catch (e) {
      // Dropped as its tile was scrolled past: not worth reading whole.
      if (e is NativeImagingException && e.cancelled) {
        _forget(this);
        rethrow;
      }
      // Windows can't read it (WebP without its codec, say, or the app's
      // own native library missing): Flutter may.
      if (_needsWindowsCodec(path)) rethrow;
      final buffer = await ui.ImmutableBuffer.fromFilePath(path);
      final codec = await decode(
        buffer,
        getTargetSize: (width, height) => width >= height
            ? ui.TargetImageSize(width: width < size ? width : size)
            : ui.TargetImageSize(height: height < size ? height : size),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      return ImageInfo(image: frame.image);
    }
  }

  @override
  bool operator ==(Object other) => other is WindowsThumbnail && other.path == path && other.size == size;

  @override
  int get hashCode => Object.hash(path, size);
}

/// The picture's width and height, upright, without decoding it.
Future<(int, int)?> pictureSize(File file) async {
  try {
    if (_needsWindowsCodec(file.path)) return await NativeImaging.size(file.path);
    final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = (descriptor.width, descriptor.height);
    descriptor.dispose();
    buffer.dispose();
    return size;
  } catch (_) {
    return null;
  }
}

/// The phone file last read whole, by serial and object id: the preview
/// and its details both want it, and it's slow to read over USB.
(String, Future<Uint8List>)? _lastPhoneFile;

/// The file [objectId] on the phone [serial], read whole: once, for the
/// picture previewed.
Future<Uint8List> phoneFile(String serial, String objectId) {
  final key = '$serial\t$objectId';
  if (_lastPhoneFile case (final last, final bytes) when last == key) return bytes;
  final bytes = Phones.read(serial, objectId);
  _lastPhoneFile = (key, bytes);
  // Failed (the phone unplugged, say): read again next time.
  bytes.then((_) {}, onError: (Object _) {
    if (_lastPhoneFile?.$1 == key) _lastPhoneFile = null;
  });
  return bytes;
}

/// A picture on a phone, read over USB: for a [thumbnail], the small JPEG
/// the phone keeps where it has one, which saves reading the whole file.
@immutable
class PhoneImage extends ImageProvider<PhoneImage> {
  const PhoneImage(this.serial, this.objectId, this.name, this.maxSize, {this.thumbnail = false});

  final String serial;
  final String objectId;

  /// The file's name, for its type.
  final String name;
  final int maxSize;
  final bool thumbnail;

  @override
  Future<PhoneImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(PhoneImage key, ImageDecoderCallback decode) {
    // A GIF (or WebP) in the preview plays, a frame at a time.
    if (!thumbnail && animatedExtensions.contains(p.extension(name).toLowerCase())) {
      return MultiFrameImageStreamCompleter(
        codec: phoneFile(serial, objectId).then((bytes) => _codec(bytes, decode)),
        scale: 1,
        informationCollector: () => [DiagnosticsProperty('Phone file', name)],
      );
    }
    return OneFrameImageStreamCompleter(
      _load(decode),
      informationCollector: () => [DiagnosticsProperty('Phone file', name)],
    );
  }

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final Uint8List bytes;
    if (thumbnail) {
      try {
        return await _decodeWithFlutter(await Phones.read(serial, objectId, thumbnail: true), decode);
      } on NativeImagingException catch (e) {
        if (e.cancelled) {
          _forget(this);
          rethrow;
        }
        // No thumbnail kept: the whole file, below.
      }
      // Still a tile's: the latest asked for first, dropped if scrolled past,
      // and kept out of the preview's way (and its cache).
      try {
        bytes = await Phones.read(serial, objectId, forTile: true);
      } on NativeImagingException catch (e) {
        if (e.cancelled) _forget(this);
        rethrow;
      }
    } else {
      bytes = await phoneFile(serial, objectId);
    }
    if (!_needsWindowsCodec(name)) return _decodeWithFlutter(bytes, decode);
    final decoded = await NativeImaging.decodeBytes(bytes, maxSize: maxSize);
    return _fromPixels(decoded);
  }

  Future<ImageInfo> _decodeWithFlutter(Uint8List bytes, ImageDecoderCallback decode) async {
    final codec = await _codec(bytes, decode);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return ImageInfo(image: frame.image);
  }

  /// Flutter's decoder for [bytes], with neither side over [maxSize].
  Future<ui.Codec> _codec(Uint8List bytes, ImageDecoderCallback decode) async => decode(
    await ui.ImmutableBuffer.fromUint8List(bytes),
    getTargetSize: (width, height) {
      if (width <= maxSize && height <= maxSize) return ui.TargetImageSize(width: width, height: height);
      return width >= height ? ui.TargetImageSize(width: maxSize) : ui.TargetImageSize(height: maxSize);
    },
  );

  @override
  bool operator ==(Object other) =>
      other is PhoneImage &&
      other.serial == serial &&
      other.objectId == objectId &&
      other.maxSize == maxSize &&
      other.thumbnail == thumbnail;

  @override
  int get hashCode => Object.hash(serial, objectId, maxSize, thumbnail);
}

/// A tile's thumbnail on Android: the one Android keeps of picture [id] in
/// the phone's gallery, as its own Photos app shows, so the picture needn't
/// be read whole. The newest asked for come first (see [Gallery.thumbnail]).
@immutable
class GalleryThumbnail extends ImageProvider<GalleryThumbnail> {
  const GalleryThumbnail(this.id, this.size);

  final int id;
  final int size;

  @override
  Future<GalleryThumbnail> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(GalleryThumbnail key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load(), informationCollector: () => [DiagnosticsProperty('Gallery id', id)]);

  Future<ImageInfo> _load() async {
    try {
      return await _fromPixels(await Gallery.thumbnail(id, size));
    } on NativeImagingException catch (e) {
      if (e.cancelled) _forget(this);
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) => other is GalleryThumbnail && other.id == id && other.size == size;

  @override
  int get hashCode => Object.hash(id, size);
}

/// Takes [key]'s failed load out of the image cache, which would otherwise
/// keep it: a thumbnail dropped as its tile was scrolled past is loaded
/// afresh when it's shown again.
void _forget(Object key) => PaintingBinding.instance.imageCache.evict(key);

/// Pixels from Windows' decoder, as an image.
Future<ImageInfo> _fromPixels(DecodedImage decoded) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(decoded.pixels);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: decoded.width,
    height: decoded.height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return ImageInfo(image: frame.image);
}

/// A picture decoded by Windows Imaging Component.
@immutable
class WindowsCodecImage extends ImageProvider<WindowsCodecImage> {
  const WindowsCodecImage(this.path, this.maxSize);

  final String path;
  final int maxSize;

  @override
  Future<WindowsCodecImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(WindowsCodecImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load(), informationCollector: () => [DiagnosticsProperty('Path', path)]);

  Future<ImageInfo> _load() async => _fromPixels(await NativeImaging.decode(path, maxSize: maxSize));

  @override
  bool operator ==(Object other) => other is WindowsCodecImage && other.path == path && other.maxSize == maxSize;

  @override
  int get hashCode => Object.hash(path, maxSize);
}
