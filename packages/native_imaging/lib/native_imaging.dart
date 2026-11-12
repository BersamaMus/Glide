/// Windows-only help for the image manager: the Recycle Bin, and decoding
/// the pictures Flutter has no codec for (HEIC, AVIF, TIFF, RAW) with
/// Windows Imaging Component. See src/native_imaging.h.
///
/// The native calls block, so each runs in a background isolate.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// A decoded picture: RGBA rows, premultiplied, as Flutter takes them.
class DecodedImage {
  DecodedImage(this.width, this.height, this.pixels);

  final int width;
  final int height;
  final Uint8List pixels;
}

/// When a picture was taken, as far as [NativeImaging.datesTaken] found out.
class DateTaken {
  const DateTaken(DateTime this.date) : onThisPC = true;

  const DateTaken._(this.date, {required this.onThisPC});

  /// Null for [none] and [notHere].
  final DateTime? date;

  /// False for [notHere]: the file wasn't read.
  final bool onThisPC;

  /// The picture doesn't say (a screenshot, say), or couldn't be read.
  static const none = DateTaken._(null, onThisPC: true);

  /// A OneDrive file that's online only: not read, so not downloaded.
  static const notHere = DateTaken._(null, onThisPC: false);
}

/// What a picture says about itself, from its metadata, as far as it does:
/// see [NativeImaging.details].
class PhotoDetails {
  const PhotoDetails({
    this.width,
    this.height,
    this.make,
    this.model,
    this.lens,
    this.fNumber,
    this.exposure,
    this.iso,
    this.focalLength,
    this.focalLength35,
    this.latitude,
    this.longitude,
  });

  factory PhotoDetails._fromLines(List<List<String>> lines) {
    final values = {
      for (final line in lines)
        if (line.length == 2) line[0]: line[1],
    };
    double? number(String key) => double.tryParse(values[key] ?? '');
    return PhotoDetails(
      width: number('width')?.round(),
      height: number('height')?.round(),
      make: values['make'],
      model: values['model'],
      lens: values['lens'],
      fNumber: number('fnumber'),
      exposure: number('exposure'),
      iso: number('iso')?.round(),
      focalLength: number('focal'),
      focalLength35: number('focal35'),
      latitude: number('latitude'),
      longitude: number('longitude'),
    );
  }

  /// Upright, as shown.
  final int? width;
  final int? height;

  /// The camera's maker and model, as it gives them.
  final String? make;
  final String? model;
  final String? lens;

  /// The aperture: 1.8 for f/1.8.
  final double? fNumber;

  /// The shutter speed, in seconds.
  final double? exposure;
  final int? iso;

  /// In millimetres; [focalLength35] as on a 35 mm film camera.
  final double? focalLength;
  final double? focalLength35;

  /// Where it was taken, in degrees: south and west negative.
  final double? latitude;
  final double? longitude;
}

/// What [NativeImaging.edit] does to a picture's background: [colorPop]
/// turns it black and white, so the subject's colours stand out.
enum BackgroundEffect { none, blur, remove, replace, colorPop }

/// How a picture's adjusted and filtered: each setting -1 to 1 (0 leaves it
/// as it was), but [mono] and [fade], 0 to 1. Applied by
/// [NativeImaging.edit], and in the app's preview by its shader, the same
/// way (see src/look.cpp).
class Look {
  const Look({
    this.exposure = 0,
    this.brightness = 0,
    this.contrast = 0,
    this.highlights = 0,
    this.shadows = 0,
    this.vignette = 0,
    this.saturation = 0,
    this.warmth = 0,
    this.tint = 0,
    this.mono = 0,
    this.fade = 0,
  });

  static const none = Look();

  final double exposure;
  final double brightness;
  final double contrast;
  final double highlights;
  final double shadows;

  /// Corners darkened; less than 0, lightened.
  final double vignette;
  final double saturation;

  /// Blue (less than 0) to amber.
  final double warmth;

  /// Green (less than 0) to magenta.
  final double tint;

  /// How black and white.
  final double mono;

  /// Blacks lifted, as an old print.
  final double fade;

  /// In look.h's order.
  List<double> get values => [
    exposure, brightness, contrast, highlights, shadows, vignette, //
    saturation, warmth, tint, mono, fade,
  ];

  bool get isNone => values.every((value) => value == 0);

  /// This with [other] on top, [amount] of it (a filter at its intensity).
  Look plus(Look other, [double amount = 1]) {
    double add(double a, double b, {double low = -1}) => (a + b * amount).clamp(low, 1);
    return Look(
      exposure: add(exposure, other.exposure),
      brightness: add(brightness, other.brightness),
      contrast: add(contrast, other.contrast),
      highlights: add(highlights, other.highlights),
      shadows: add(shadows, other.shadows),
      vignette: add(vignette, other.vignette),
      saturation: add(saturation, other.saturation),
      warmth: add(warmth, other.warmth),
      tint: add(tint, other.tint),
      mono: add(mono, other.mono, low: 0),
      fade: add(fade, other.fade, low: 0),
    );
  }

  Look copyWith({
    double? exposure,
    double? brightness,
    double? contrast,
    double? highlights,
    double? shadows,
    double? vignette,
    double? saturation,
    double? warmth,
    double? tint,
  }) => Look(
    exposure: exposure ?? this.exposure,
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    highlights: highlights ?? this.highlights,
    shadows: shadows ?? this.shadows,
    vignette: vignette ?? this.vignette,
    saturation: saturation ?? this.saturation,
    warmth: warmth ?? this.warmth,
    tint: tint ?? this.tint,
    mono: mono,
    fade: fade,
  );

  @override
  bool operator ==(Object other) =>
      other is Look && Object.hashAll(other.values) == Object.hashAll(values) && _same(other.values, values);

  static bool _same(List<double> a, List<double> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(values);
}

/// How far a background blur spreads, as a fraction of the picture's
/// longest side (a Gaussian's sigma), unless told otherwise.
const defaultBlurSpread = 0.013;

/// Where a picture's subject is, from [NativeImaging.subjectMask]: upright,
/// in the picture's shape (about 1024 pixels on its longest side), a byte a
/// pixel from 0 (background) to 255 (subject).
class SubjectMask {
  SubjectMask(this.width, this.height, this.alpha);

  final int width;
  final int height;
  final Uint8List alpha;
}

/// A native call that failed, with Windows' HRESULT.
class NativeImagingException implements Exception {
  NativeImagingException(this.hresult);

  final int hresult;

  /// The call was given up on: it hadn't finished in time.
  bool get timedOut => hresult == _timedOut;

  /// The call was dropped before it ran: asked for long enough ago (a
  /// thumbnail of a tile since scrolled past) that newer asks went first.
  bool get cancelled => hresult == _cancelled;

  /// Windows has no codec for the format: WINCODEC_ERR_COMPONENTNOTFOUND
  /// without the format's extension from the Store, or
  /// MF_E_TOPO_CODEC_NOT_FOUND for HEIC with the HEIF extension but not HEVC.
  bool get missingCodec => hresult == 0x88982F50 || hresult == 0xC00D5212;

  /// The file's a OneDrive one that's online only: not read, as that
  /// would download it (ERROR_FILE_OFFLINE).
  bool get notHere => hresult == 0x800710FE;

  /// Part of the app's missing from this installation: a model, or ONNX
  /// Runtime (ERROR_FILE_NOT_FOUND, ERROR_MOD_NOT_FOUND).
  bool get notInstalled => hresult == 0x80070002 || hresult == 0x8007007E;

  @override
  String toString() => 'NativeImagingException(0x${hresult.toRadixString(16).padLeft(8, '0')})';
}

abstract final class NativeImaging {
  /// Moves [paths] to the Recycle Bin. False when some were left where they
  /// were (the user said no to deleting where there's no Recycle Bin).
  static Future<bool> recycle(List<String> paths) => Isolate.run(() {
    return using((arena) {
      final array = arena<Pointer<Utf16>>(paths.length);
      for (final (i, path) in paths.indexed) {
        array[i] = path.toNativeUtf16(allocator: arena);
      }
      final aborted = arena<Int32>();
      final hr = _recycle(array, paths.length, aborted);
      // ERROR_CANCELLED, as an HRESULT: the user said no.
      if (hr & 0xFFFFFFFF == 0x800704C7 || aborted.value != 0) return false;
      _check(hr);
      return true;
    });
  });

  /// Copies (or with [move], moves) [paths] into the folder [destination],
  /// with Windows' progress window and its "Replace or Skip" choice where a
  /// name's taken. False when some were left where they were (skipped, or
  /// cancelled).
  static Future<bool> transfer(List<String> paths, String destination, {bool move = false}) => Isolate.run(() {
    return using((arena) {
      final array = arena<Pointer<Utf16>>(paths.length);
      for (final (i, path) in paths.indexed) {
        array[i] = path.toNativeUtf16(allocator: arena);
      }
      final aborted = arena<Int32>();
      final hr = _transfer(array, paths.length, destination.toNativeUtf16(allocator: arena), move ? 1 : 0, aborted);
      if (hr & 0xFFFFFFFF == 0x800704C7 || aborted.value != 0) return false;
      _check(hr);
      return true;
    });
  });

  /// When each of [paths] was taken, from its metadata, in order: a time;
  /// [DateTaken.none] if it doesn't say (or couldn't be read); or
  /// [DateTaken.notHere] for a OneDrive file that's online only, which
  /// isn't read as that would download it.
  ///
  /// Given up on (ERROR_TIMEOUT) if a codec hangs over one of them.
  static Future<List<DateTaken>> datesTaken(List<String> paths) => Isolate.run(() {
    return using((arena) {
      final array = arena<Pointer<Utf16>>(paths.length);
      for (final (i, path) in paths.indexed) {
        array[i] = path.toNativeUtf16(allocator: arena);
      }
      final taken = arena<Int64>(paths.length);
      final states = arena<Int32>(paths.length);
      _datesTaken(array, paths.length, taken, states);
      return [
        for (var i = 0; i < paths.length; i++)
          switch (states[i]) {
            0 => DateTaken(DateTime.fromMillisecondsSinceEpoch(taken[i], isUtc: true).toLocal()),
            2 => DateTaken.notHere,
            _ => DateTaken.none,
          },
      ];
    });
  }).timeout(const Duration(minutes: 2), onTimeout: () => throw NativeImagingException(_timedOut));

  /// Saves an edited copy of [source] as [destination]: upright, its
  /// [background] changed where [mask] says it's not the subject (blurred,
  /// removed, or replaced by [backgroundColor], 0xRRGGBB; a blur spreads
  /// [blurSpread] of the picture's longest side) after it's adjusted and
  /// filtered by [look], turned
  /// [quarterTurns] clockwise, flipped left to right with [flip], then
  /// cropped to [crop] (left, top, width, height as fractions of the turned
  /// picture). In [source]'s format, or JPEG with [asJpeg], or PNG with
  /// [asPng]; its metadata (date taken, camera, location) is kept.
  static Future<void> edit(
    String source,
    String destination, {
    int quarterTurns = 0,
    bool flip = false,
    (double, double, double, double) crop = (0, 0, 1, 1),
    bool asJpeg = false,
    bool asPng = false,
    BackgroundEffect background = BackgroundEffect.none,
    int backgroundColor = 0xFFFFFF,
    double blurSpread = defaultBlurSpread,
    SubjectMask? mask,
    Look look = Look.none,
  }) {
    if (background != BackgroundEffect.none && mask == null) throw ArgumentError.notNull('mask');
    return Isolate.run(() {
      using((arena) {
        final (left, top, width, height) = crop;
        final alpha = mask?.alpha;
        final native = alpha == null ? nullptr : arena<Uint8>(alpha.length);
        if (alpha != null) native.asTypedList(alpha.length).setAll(0, alpha);
        final settings = look.values;
        final nativeLook = arena<Float>(settings.length);
        nativeLook.asTypedList(settings.length).setAll(0, settings);
        _check(
          _edit(
            source.toNativeUtf16(allocator: arena),
            destination.toNativeUtf16(allocator: arena),
            quarterTurns,
            flip ? 1 : 0,
            left,
            top,
            width,
            height,
            asPng ? 2 : (asJpeg ? 1 : 0),
            background.index,
            backgroundColor & 0xFFFFFF,
            blurSpread,
            native,
            mask?.width ?? 0,
            mask?.height ?? 0,
            nativeLook,
            settings.length,
          ),
        );
      });
    }).timeout(const Duration(minutes: 2), onTimeout: () => throw NativeImagingException(_timedOut));
  }

  /// Where the picture at [path]'s subject is: see [SubjectMask]. Takes a
  /// second or two (more the first time, as the model's loaded).
  static Future<SubjectMask> subjectMask(String path) => Isolate.run(() {
    return using((arena) {
      final w = arena<Int32>(), h = arena<Int32>();
      final out = arena<Pointer<Uint8>>();
      _check(_subjectMask(path.toNativeUtf16(allocator: arena), w, h, out));
      try {
        return SubjectMask(w.value, h.value, Uint8List.fromList(out.value.asTypedList(w.value * h.value)));
      } finally {
        _free(out.value.cast());
      }
    });
  }).timeout(const Duration(minutes: 2), onTimeout: () => throw NativeImagingException(_timedOut));

  /// Decodes the picture at [path], upright, scaled so neither side is over
  /// [maxSize] (0 for its full size).
  static Future<DecodedImage> decode(String path, {int maxSize = 0}) => _decodes.run(() async {
    final (width, height, pixels) = await Isolate.run(() {
      return using((arena) {
        final w = arena<Int32>(), h = arena<Int32>();
        final out = arena<Pointer<Uint8>>();
        _check(_decode(path.toNativeUtf16(allocator: arena), maxSize, w, h, out));
        try {
          final bytes = out.value.asTypedList(w.value * h.value * 4);
          return (w.value, h.value, TransferableTypedData.fromList([bytes]));
        } finally {
          _free(out.value.cast());
        }
      });
    });
    return DecodedImage(width, height, pixels.materialize().asUint8List());
  });

  /// The picture's thumbnail, as File Explorer shows it, neither side over
  /// [size]: from Windows' thumbnail cache, or the small preview a camera
  /// puts in the file, so the whole file needn't be read. Throws if Windows
  /// has none.
  ///
  /// The most recent ask goes first: scrolled through quickly, the tiles
  /// stopped on get theirs before those scrolled past.
  ///
  /// With [background], it waits its turn apart from the tiles' (for work
  /// the app does by itself, such as finding look-alikes): never dropped,
  /// fewer at once, and never in a tile's way.
  static Future<DecodedImage> thumbnail(String path, int size, {bool background = false}) =>
      (background ? _backgroundThumbnails : _thumbnails).run(() async {
        final (width, height, pixels) = await Isolate.run(() {
          return using((arena) {
            final w = arena<Int32>(), h = arena<Int32>();
            final out = arena<Pointer<Uint8>>();
            _check(_thumbnail(path.toNativeUtf16(allocator: arena), size, w, h, out));
            try {
              final bytes = out.value.asTypedList(w.value * h.value * 4);
              return (w.value, h.value, TransferableTypedData.fromList([bytes]));
            } finally {
              _free(out.value.cast());
            }
          });
        });
        return DecodedImage(width, height, pixels.materialize().asUint8List());
      });

  static final _thumbnails = _Limiter(
    4,
    timeout: const Duration(seconds: 20),
    newestFirst: true,
    maxWaiting: _thumbnailsWaiting,
  );

  static final _backgroundThumbnails = _Limiter(2, timeout: const Duration(seconds: 20));

  /// [decode], for a file already read into memory (one from a phone).
  static Future<DecodedImage> decodeBytes(Uint8List bytes, {int maxSize = 0}) => _decodes.run(() async {
    final input = TransferableTypedData.fromList([bytes]);
    final (width, height, pixels) = await Isolate.run(() {
      return using((arena) {
        final data = input.materialize().asUint8List();
        final native = arena<Uint8>(data.length);
        native.asTypedList(data.length).setAll(0, data);
        final w = arena<Int32>(), h = arena<Int32>();
        final out = arena<Pointer<Uint8>>();
        _check(_decodeMemory(native, data.length, maxSize, w, h, out));
        try {
          final decoded = out.value.asTypedList(w.value * h.value * 4);
          return (w.value, h.value, TransferableTypedData.fromList([decoded]));
        } finally {
          _free(out.value.cast());
        }
      });
    });
    return DecodedImage(width, height, pixels.materialize().asUint8List());
  });

  /// The picture's width and height, upright, read without decoding it.
  static Future<(int, int)> size(String path) => Isolate.run(() {
    return using((arena) {
      final w = arena<Int32>(), h = arena<Int32>();
      _check(_size(path.toNativeUtf16(allocator: arena), w, h));
      return (w.value, h.value);
    });
  });

  /// What the picture at [path] says about itself: its size, camera,
  /// settings, and where it was taken. Read without decoding it.
  static Future<PhotoDetails> details(String path) => Isolate.run(() {
    return using((arena) {
      final out = arena<Pointer<Utf16>>();
      _check(_details(path.toNativeUtf16(allocator: arena), out));
      return PhotoDetails._fromLines(Phones._lines(out.value));
    });
  }).timeout(const Duration(seconds: 30), onTimeout: () => throw NativeImagingException(_timedOut));

  /// [details], for a file already read into memory (one from a phone).
  static Future<PhotoDetails> detailsOfBytes(Uint8List bytes) {
    final input = TransferableTypedData.fromList([bytes]);
    return Isolate.run(() {
      return using((arena) {
        final data = input.materialize().asUint8List();
        final native = arena<Uint8>(data.length);
        native.asTypedList(data.length).setAll(0, data);
        final out = arena<Pointer<Utf16>>();
        _check(_detailsMemory(native, data.length, out));
        return PhotoDetails._fromLines(Phones._lines(out.value));
      });
    }).timeout(const Duration(seconds: 30), onTimeout: () => throw NativeImagingException(_timedOut));
  }

  /// Decoders (HEIC especially) are slow and use a lot of memory, so a
  /// screenful of thumbnails is decoded a few at a time.
  static final _decodes = _Limiter(3, timeout: const Duration(seconds: 60));

  /// Puts a picture on the clipboard: [rgba] (not premultiplied), [width]
  /// by [height], and the same as a [png], for programs that keep its
  /// transparency.
  static Future<void> copyPicture(Uint8List rgba, int width, int height, Uint8List png) {
    final pixels = TransferableTypedData.fromList([rgba]);
    final encoded = TransferableTypedData.fromList([png]);
    return Isolate.run(() {
      using((arena) {
        final data = pixels.materialize().asUint8List();
        final file = encoded.materialize().asUint8List();
        final nativePixels = arena<Uint8>(data.length);
        nativePixels.asTypedList(data.length).setAll(0, data);
        final nativePng = arena<Uint8>(file.length);
        nativePng.asTypedList(file.length).setAll(0, file);
        _check(_copyPicture(nativePixels, width, height, nativePng, file.length));
      });
    });
  }
}

/// What a drive's plugged into.
enum DriveKind { internal, usb, card }

/// A drive on this PC.
class Drive {
  Drive(this.root, this.kind, this.label, this.bytesTotal, this.bytesFree);

  /// "D:\".
  final String root;
  final DriveKind kind;

  /// Its label (its volume's name); "" if it has none.
  final String label;
  final int bytesTotal;
  final int bytesFree;

  bool get external => kind != DriveKind.internal;

  /// "D:".
  String get letter => root.substring(0, 2);

  /// Its label, or what it is: "Backup", "USB drive".
  String get name => label.isNotEmpty
      ? label
      : switch (kind) {
          DriveKind.internal => 'Local disk',
          DriveKind.usb => 'USB drive',
          DriveKind.card => 'Memory card',
        };

  @override
  bool operator ==(Object other) => other is Drive && other.root == root && other.kind == kind && other.label == label;

  @override
  int get hashCode => Object.hash(root, kind, label);
}

/// The drives on this PC.
abstract final class Drives {
  /// Local drives that are ready (not an empty card reader), internal and
  /// external: told apart by what they're plugged into, as external hard
  /// drives call themselves fixed like internal ones.
  ///
  /// A drive that's failing, or spinning up, can keep it waiting: given up
  /// on after a while (ERROR_TIMEOUT).
  static Future<List<Drive>> list() => _recentDrives.ask(_list);

  /// Looked for every few seconds by more than one part of the app at once:
  /// asks close together share an answer.
  static final _recentDrives = _Recent<List<Drive>>();

  static Future<List<Drive>> _list() => Isolate.run(() {
    return using((arena) {
      final out = arena<Pointer<Utf16>>();
      _check(_drives(out));
      return [
        for (final f in Phones._lines(out.value))
          Drive(f[0], DriveKind.values[int.parse(f[1])], f[2], int.parse(f[3]), int.parse(f[4])),
      ];
    });
  }).timeout(const Duration(seconds: 15), onTimeout: () => throw NativeImagingException(_timedOut));
}

/// A phone connected by USB.
class Phone {
  Phone(this.serial, this.name, this.ready, this.bytesTotal, this.bytesFree);

  /// Stays the same across connections.
  final String serial;
  final String name;

  /// Unlocked and, on Android, in File transfer mode: until then the phone
  /// shows nothing on it.
  final bool ready;
  final int bytesTotal;
  final int bytesFree;
}

/// A file or folder on a phone.
class PhoneEntry {
  PhoneEntry(this.id, this.name, this.isFolder, this.size, this.modified);

  /// WPD's object id: valid while the phone stays connected.
  final String id;
  final String name;
  final bool isFolder;
  final int size;
  final DateTime? modified;
}

/// Phones over USB, through Windows Portable Devices (MTP, and PTP for
/// iPhones). A phone does one request at a time, so these queue up.
abstract final class Phones {
  static Future<List<Phone>> list() => _recentPhones.ask(_list);

  /// Looked for every few seconds by more than one part of the app at once
  /// (and each look takes the phone's attention): asks close together
  /// share an answer.
  static final _recentPhones = _Recent<List<Phone>>();

  static Future<List<Phone>> _list() => _phoneRequests.run(
    () => Isolate.run(() {
      return using((arena) {
        final out = arena<Pointer<Utf16>>();
        _check(_phones(out));
        return [for (final f in _lines(out.value)) Phone(f[0], f[1], f[2] == '1', int.parse(f[3]), int.parse(f[4]))];
      });
    }),
  );

  /// What's in the folder [folderId] on the phone; with no folder, its
  /// storages (internal storage, SD card).
  static Future<List<PhoneEntry>> children(String serial, {String folderId = ''}) => _phoneRequests.run(
    () => Isolate.run(() {
      return using((arena) {
        final out = arena<Pointer<Utf16>>();
        _check(_phoneList(serial.toNativeUtf16(allocator: arena), folderId.toNativeUtf16(allocator: arena), out));
        return [
          for (final f in _lines(out.value))
            PhoneEntry(
              f[0],
              f[1],
              f[2] == '1',
              int.parse(f[3]),
              f[4] == '0' ? null : DateTime.fromMillisecondsSinceEpoch(int.parse(f[4]), isUtc: true).toLocal(),
            ),
        ];
      });
    }),
  );

  /// Reads a whole file off the phone, or with [thumbnail] the small JPEG the
  /// phone keeps of it (an error if it has none).
  ///
  /// Thumbnails take their turn apart from the rest, the latest asked for
  /// first: scrolled far, the tiles stopped on get theirs before those
  /// scrolled past (which, too long waiting, are dropped: see [_Limiter]).
  /// So does a whole file read [forTile], for a tile without a thumbnail.
  static Future<Uint8List> read(String serial, String objectId, {bool thumbnail = false, bool forTile = false}) =>
      (thumbnail || forTile ? _phoneThumbnails : _phoneRequests).run(() async {
        final bytes = await Isolate.run(() {
          return using((arena) {
            final data = arena<Pointer<Uint8>>();
            final length = arena<Int64>();
            _check(
              _phoneRead(
                serial.toNativeUtf16(allocator: arena),
                objectId.toNativeUtf16(allocator: arena),
                thumbnail ? 1 : 0,
                data,
                length,
              ),
            );
            try {
              return TransferableTypedData.fromList([data.value.asTypedList(length.value)]);
            } finally {
              _free(data.value.cast());
            }
          });
        });
        return bytes.materialize().asUint8List();
      });

  /// The phone answers one request at a time anyway; two in flight keeps it
  /// busy without a screenful of thumbnails holding up a folder's listing
  /// for long.
  static final _phoneRequests = _Limiter(2, timeout: const Duration(seconds: 60));

  /// Thumbnails, a few tens of milliseconds each: two in flight, so the
  /// phone's never idle between them.
  static final _phoneThumbnails = _Limiter(
    2,
    timeout: const Duration(seconds: 60),
    newestFirst: true,
    maxWaiting: _thumbnailsWaiting,
  );

  /// The tab-separated lines of a list from phones.cpp, freeing it.
  static List<List<String>> _lines(Pointer<Utf16> text) {
    try {
      return [
        for (final line in text.toDartString().split('\n'))
          if (line.isNotEmpty) line.split('\t'),
      ];
    } finally {
      _free(text.cast());
    }
  }
}

/// ERROR_TIMEOUT, as an HRESULT: a call given up on.
const _timedOut = 0x800705B4;

/// ERROR_CANCELLED, as an HRESULT: a call dropped before it ran.
const _cancelled = 0x800704C7;

/// How many thumbnails wait their turn at most: a few screenfuls of tiles,
/// more than a big window shows at once.
const _thumbnailsWaiting = 200;

void _check(int hr) {
  // HRESULTs come back as signed ints; failures have the top bit set.
  if (hr < 0) throw NativeImagingException(hr & 0xFFFFFFFF);
}

final _lib = DynamicLibrary.open('native_imaging.dll');

final _recycle = _lib
    .lookupFunction<
      Int32 Function(Pointer<Pointer<Utf16>>, Int32, Pointer<Int32>),
      int Function(Pointer<Pointer<Utf16>>, int, Pointer<Int32>)
    >('ni_recycle');

final _transfer = _lib
    .lookupFunction<
      Int32 Function(Pointer<Pointer<Utf16>>, Int32, Pointer<Utf16>, Int32, Pointer<Int32>),
      int Function(Pointer<Pointer<Utf16>>, int, Pointer<Utf16>, int, Pointer<Int32>)
    >('ni_transfer');

final _datesTaken = _lib
    .lookupFunction<
      Void Function(Pointer<Pointer<Utf16>>, Int32, Pointer<Int64>, Pointer<Int32>),
      void Function(Pointer<Pointer<Utf16>>, int, Pointer<Int64>, Pointer<Int32>)
    >('ni_dates_taken');

final _edit = _lib
    .lookupFunction<
      Int32 Function(
        Pointer<Utf16>,
        Pointer<Utf16>,
        Int32,
        Int32,
        Double,
        Double,
        Double,
        Double,
        Int32,
        Int32,
        Uint32,
        Double,
        Pointer<Uint8>,
        Int32,
        Int32,
        Pointer<Float>,
        Int32,
      ),
      int Function(
        Pointer<Utf16>,
        Pointer<Utf16>,
        int,
        int,
        double,
        double,
        double,
        double,
        int,
        int,
        int,
        double,
        Pointer<Uint8>,
        int,
        int,
        Pointer<Float>,
        int,
      )
    >('ni_edit');

final _subjectMask = _lib
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Int32>, Pointer<Int32>, Pointer<Pointer<Uint8>>),
      int Function(Pointer<Utf16>, Pointer<Int32>, Pointer<Int32>, Pointer<Pointer<Uint8>>)
    >('ni_subject_mask');

final _decode = _lib
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Int32, Pointer<Int32>, Pointer<Int32>, Pointer<Pointer<Uint8>>),
      int Function(Pointer<Utf16>, int, Pointer<Int32>, Pointer<Int32>, Pointer<Pointer<Uint8>>)
    >('ni_decode');

final _thumbnail = _lib
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Int32, Pointer<Int32>, Pointer<Int32>, Pointer<Pointer<Uint8>>),
      int Function(Pointer<Utf16>, int, Pointer<Int32>, Pointer<Int32>, Pointer<Pointer<Uint8>>)
    >('ni_thumbnail');

final _decodeMemory = _lib
    .lookupFunction<
      Int32 Function(Pointer<Uint8>, Int64, Int32, Pointer<Int32>, Pointer<Int32>, Pointer<Pointer<Uint8>>),
      int Function(Pointer<Uint8>, int, int, Pointer<Int32>, Pointer<Int32>, Pointer<Pointer<Uint8>>)
    >('ni_decode_memory');

final _drives = _lib.lookupFunction<Int32 Function(Pointer<Pointer<Utf16>>), int Function(Pointer<Pointer<Utf16>>)>(
  'ni_drives',
);

final _phones = _lib.lookupFunction<Int32 Function(Pointer<Pointer<Utf16>>), int Function(Pointer<Pointer<Utf16>>)>(
  'ni_phones',
);

final _phoneList = _lib
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Pointer<Utf16>>),
      int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Pointer<Utf16>>)
    >('ni_phone_list');

final _phoneRead = _lib
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Int32, Pointer<Pointer<Uint8>>, Pointer<Int64>),
      int Function(Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Pointer<Uint8>>, Pointer<Int64>)
    >('ni_phone_read');

final _size = _lib
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Int32>, Pointer<Int32>),
      int Function(Pointer<Utf16>, Pointer<Int32>, Pointer<Int32>)
    >('ni_size');

final _details = _lib
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Pointer<Utf16>>),
      int Function(Pointer<Utf16>, Pointer<Pointer<Utf16>>)
    >('ni_details');

final _detailsMemory = _lib
    .lookupFunction<
      Int32 Function(Pointer<Uint8>, Int64, Pointer<Pointer<Utf16>>),
      int Function(Pointer<Uint8>, int, Pointer<Pointer<Utf16>>)
    >('ni_details_memory');

final _copyPicture = _lib
    .lookupFunction<
      Int32 Function(Pointer<Uint8>, Int32, Int32, Pointer<Uint8>, Int64),
      int Function(Pointer<Uint8>, int, int, Pointer<Uint8>, int)
    >('ni_copy_picture');

final _free = _lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('ni_free');

/// One answer for asks close together: what's asked within [fresh] of the
/// last ask gets its answer (still coming, or come) rather than asking again.
/// A failed answer isn't kept.
class _Recent<T> {
  _Recent({this.fresh = const Duration(seconds: 2)});

  final Duration fresh;
  Future<T>? _answer;
  final _since = Stopwatch();

  Future<T> ask(Future<T> Function() question) {
    if (_answer case final answer? when _since.elapsed < fresh) return answer;
    _since
      ..reset()
      ..start();
    final answer = _answer = question();
    answer.then(
      (_) {},
      onError: (Object _) {
        if (identical(_answer, answer)) _answer = null;
      },
    );
    return answer;
  }
}

/// Runs at most [max] tasks at once; the rest wait their turn: in the order
/// they came, or with [newestFirst] the latest first.
///
/// A task that hasn't finished after [timeout] (a codec, a drive or a phone
/// that's stopped answering) is given up on: it fails with ERROR_TIMEOUT and
/// its turn goes to the next, so one that hangs can't hold the rest up for
/// ever. (Its isolate can't be stopped from here; it's left to finish, or
/// not.)
///
/// With [maxWaiting], no more than that wait: past it, the oldest is given
/// up on (ERROR_CANCELLED) without being run. For thumbnails, newest first:
/// those of tiles scrolled past long since aren't worth the time.
class _Limiter {
  _Limiter(this.max, {required this.timeout, this.newestFirst = false, this.maxWaiting});

  final int max;
  final Duration timeout;
  final bool newestFirst;
  final int? maxWaiting;
  var _running = 0;
  final _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running >= max) {
      final turn = Completer<void>();
      _waiting.add(turn);
      if (maxWaiting case final most? when _waiting.length > most) {
        _waiting.removeFirst().completeError(NativeImagingException(_cancelled));
      }
      await turn.future;
    }
    _running++;
    try {
      return await task().timeout(timeout, onTimeout: () => throw NativeImagingException(_timedOut));
    } finally {
      _running--;
      if (_waiting.isNotEmpty) (newestFirst ? _waiting.removeLast() : _waiting.removeFirst()).complete();
    }
  }
}
