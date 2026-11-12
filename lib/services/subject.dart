import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:native_imaging/native_imaging.dart';

import 'gallery.dart';
import 'places.dart';

// A picture's subject (a person, a pet, a thing), for the editor's
// Background, stickers, and pictures brought to life.

/// Where [picture]'s subject is: on a PC by IS-Net, on a phone by Google's
/// ML Kit. Once each while the app runs (it takes a second or two), for the
/// last few asked about.
Future<SubjectMask> findSubject(LocalPicture picture) {
  final key = picture.id;
  if (_found[key] case final mask?) return mask;
  final mask = switch (picture.galleryId) {
    final id? => Gallery.subjectMask(id),
    null => NativeImaging.subjectMask(picture.file.path),
  };
  _found[key] = mask;
  if (_found.length > 8) _found.remove(_found.keys.first);
  mask.then((_) {}, onError: (Object _) {
    _found.remove(key);
  });
  return mask;
}

final _found = <String, Future<SubjectMask>>{};

/// [mask] as an image: white, see-through where it's background. For
/// cutting the subject out with (BlendMode.dstIn), or as its silhouette.
Future<ui.Image> subjectImage(SubjectMask mask) {
  // Premultiplied, as Flutter takes raw pixels: white at that alpha is the
  // alpha in every channel. (Else filters that read the colours, as the
  // sticker's outline does, see white where it's see-through.)
  final pixels = Uint8List(mask.width * mask.height * 4);
  for (var i = 0; i < mask.alpha.length; i++) {
    pixels.fillRange(i * 4, i * 4 + 4, mask.alpha[i]);
  }
  final image = Completer<ui.Image>();
  ui.decodeImageFromPixels(pixels, mask.width, mask.height, ui.PixelFormat.rgba8888, image.complete);
  return image.future;
}

/// Why the subject couldn't be found, for the user.
String whyNoSubject(Object error) => switch (error) {
  // ERROR_FILE_NOT_FOUND, ERROR_MOD_NOT_FOUND: not shipped with the app.
  NativeImagingException(notInstalled: true) =>
    'Finding the subject isn\'t available: part of it is missing from this installation.',
  NativeImagingException(timedOut: true) => 'Finding the subject took too long.',
  // On a phone: Google Play services fetches ML Kit's model when it's first needed.
  PlatformException(:final message?) when message.toLowerCase().contains('download') =>
    'The subject finder is still downloading. Try again in a minute.',
  PlatformException(:final message) => 'Couldn\'t find the subject of this picture (${message ?? 'unknown error'}).',
  _ => 'Couldn\'t find the subject of this picture ($error).',
};
