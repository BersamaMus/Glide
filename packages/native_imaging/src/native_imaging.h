#pragma once

// What Flutter can't do on Windows by itself: sending files to the Recycle
// Bin, and decoding the pictures it has no codec for (HEIC, AVIF, TIFF and
// cameras' RAW files) through Windows Imaging Component, using whatever
// codecs Windows has installed.
//
// Every call blocks (on the disk, or a slow decoder): call them from a
// background isolate. Each returns an HRESULT, S_OK (0) on success.

#include <stdint.h>

#ifdef _WIN32
#define NI_EXPORT extern "C" __declspec(dllexport)
#else
#define NI_EXPORT extern "C"
#endif

// Moves the files to the Recycle Bin. A file on a drive without one (a USB
// stick) isn't deleted silently: Windows asks first. *aborted is set when
// the user said no to that, or something was left in place.
NI_EXPORT int32_t ni_recycle(const wchar_t **paths, int32_t count, int32_t *aborted);

// Copies (or with move, moves) the files into the folder destination, as
// File Explorer does: with Windows' progress window, and its "Replace or
// Skip" choice where a name is taken. *aborted as for ni_recycle.
NI_EXPORT int32_t ni_transfer(const wchar_t **paths, int32_t count, const wchar_t *destination, int32_t move,
                              int32_t *aborted);

// Decodes the picture's first frame, turned upright, scaled down so neither
// side is over max_size (0 keeps its size). *pixels is RGBA, premultiplied
// (as Flutter takes raw pixels), width * 4 bytes a row; free it with ni_free.
NI_EXPORT int32_t ni_decode(const wchar_t *path, int32_t max_size, int32_t *width, int32_t *height,
                            uint8_t **pixels);

// A thumbnail of the picture for a tile, got as cheaply as can be: the one
// File Explorer has kept, if it's shown the picture before (nothing read);
// else the small preview a camera puts at the start of the file (a few
// kilobytes read); else the picture decoded at that size. Upright, neither
// side over size; *pixels as for ni_decode.
NI_EXPORT int32_t ni_thumbnail(const wchar_t *path, int32_t size, int32_t *width, int32_t *height,
                               uint8_t **pixels);

// ni_decode, for a file already read into memory (a phone's).
NI_EXPORT int32_t ni_decode_memory(const uint8_t *data, int64_t length, int32_t max_size, int32_t *width,
                                   int32_t *height, uint8_t **pixels);

// Saves an edited copy of the picture at source as destination: turned
// upright, rotated quarter_turns clockwise, flipped left to right if
// flip_horizontal, then cropped to the rectangle (left, top, width, height,
// as fractions 0 to 1 of the rotated picture). Written in source's format
// (format 0), or as JPEG (1, for formats Windows can't write) or PNG (2, to
// keep a removed background transparent), with its metadata (date taken,
// camera, location) kept and its orientation tag reset.
//
// Before it's turned, its background can be changed: background 1 blurs it
// (a Gaussian whose sigma is blur_spread of its longest side), 2 removes it
// (transparent), 3 replaces it with background_color (0xRRGGBB), 4 turns it
// black and white (the subject's colours "pop"); 0 leaves it. mask is where the subject is, from ni_subject_mask (mask_width by
// mask_height, the upright picture's shape).
//
// Before that, it's adjusted and filtered by look: look_count floats, in
// look.h's order (exposure, brightness, contrast, highlights, shadows,
// vignette, saturation, warmth, tint, mono, fade); null or all 0 for none.
NI_EXPORT int32_t ni_edit(const wchar_t *source, const wchar_t *destination, int32_t quarter_turns,
                          int32_t flip_horizontal, double crop_left, double crop_top, double crop_width,
                          double crop_height, int32_t format, int32_t background, uint32_t background_color,
                          double blur_spread, const uint8_t *mask, int32_t mask_width, int32_t mask_height,
                          const float *look, int32_t look_count);

// Where the picture's subject is (a person, a pet, a thing), and so what's
// its background: upright, about 1024 pixels on its longest side, one byte
// a pixel from 0 (background) to 255 (subject). Free *mask with ni_free.
// The first call loads the model (IS-Net, on ONNX Runtime), which takes a
// second or two; it fails with ERROR_FILE_NOT_FOUND or ERROR_MOD_NOT_FOUND
// if the model or ONNX Runtime wasn't shipped with the app.
NI_EXPORT int32_t ni_subject_mask(const wchar_t *path, int32_t *width, int32_t *height, uint8_t **mask);

// Puts a picture on the clipboard, as a PNG (png_length bytes, for programs
// that keep its transparency) and as a bitmap (rgba: width by height, not
// premultiplied, for the rest).
NI_EXPORT int32_t ni_copy_picture(const uint8_t *rgba, int32_t width, int32_t height, const uint8_t *png,
                                  int64_t png_length);

// When each picture was taken, from its metadata (EXIF's DateTimeOriginal,
// or its equivalent in HEIC and RAW files), as milliseconds since 1970 UTC.
// states[i] says how it went: 0 found (in taken[i]), 1 none recorded (or the
// file couldn't be read), 2 not on this PC (a OneDrive file that's online
// only: reading it would download it, so it isn't).
NI_EXPORT void ni_dates_taken(const wchar_t **paths, int32_t count, int64_t *taken, int32_t *states);

// The picture's width and height as shown, upright, without decoding it.
NI_EXPORT int32_t ni_size(const wchar_t *path, int32_t *width, int32_t *height);

// What the picture says about itself, for the preview's details: one a line,
// key and value split by a tab, in a buffer to free with ni_free. Only what
// it records: width and height (upright); make, model and lens (text);
// fnumber, exposure (seconds), iso, focal and focal35 (mm); latitude and
// longitude (degrees, south and west negative).
NI_EXPORT int32_t ni_details(const wchar_t *path, wchar_t **lines);

// ni_details, for a file already read into memory (a phone's).
NI_EXPORT int32_t ni_details_memory(const uint8_t *data, int64_t length, wchar_t **lines);

// The drives on this PC (drives.cpp), one a line, fields split by tabs, in a
// buffer to free with ni_free: root ("D:\"), kind (0 internal, 1 USB, 2
// memory card), name (its label; "" if it has none), bytes in all, bytes
// free. Local drives only (network drives can stall), and only those ready
// (not an empty card reader). External hard drives call themselves fixed,
// like internal ones, so what they're plugged into is what tells them apart.
NI_EXPORT int32_t ni_drives(wchar_t **lines);

// ---------------------------------------------------------------------------
// Phones connected by USB (phones.cpp). They have no drive letter: Android
// phones speak MTP and iPhones PTP, which Windows exposes through Windows
// Portable Devices. Phones are named by serial number, which stays the same
// across connections; what's on them by WPD object id, which doesn't.
//
// Lists come back as text, one item a line, fields split by tabs, in a
// buffer to free with ni_free. Phone calls wait for the phone, which answers
// one request at a time (other programs' too).
// ---------------------------------------------------------------------------

// The connected phones: serial, name, ready (1 when unlocked and, on
// Android, in File transfer mode; until then it shows no storage), bytes in
// all, bytes free.
NI_EXPORT int32_t ni_phones(wchar_t **lines);

// What's in a folder on the phone: object id, name, folder (1) or file (0),
// size in bytes, modified (milliseconds since 1970, UTC; 0 if unknown).
// An empty folder_id lists the phone's storages (internal storage, SD card).
NI_EXPORT int32_t ni_phone_list(const wchar_t *serial, const wchar_t *folder_id, wchar_t **lines);

// Reads a whole file off the phone, or its thumbnail (a small JPEG the phone
// keeps; fails if it has none). Free *data with ni_free.
NI_EXPORT int32_t ni_phone_read(const wchar_t *serial, const wchar_t *object_id, int32_t thumbnail, uint8_t **data,
                                int64_t *length);

NI_EXPORT void ni_free(void *memory);
