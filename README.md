# Glide

Glide is a photo viewer for Windows and Android that shows the pictures already
on your PC or phone: no accounts, no ads, no internet. Every picture is there, newest first and
grouped by month, without any folders to click through.

<p>
  <img src="docs/img/windows-home.png" alt="Glide on Windows: trips to Venice, Rome and the Italian coast grouped by month, newest first, with a photo of Capri open beside them">
</p>

<table>
  <tr>
    <td width="50%"><img src="docs/img/windows-memories.png" alt="Memories: photos taken on this day in past years, a year at a time"><br><b>Memories:</b> on this day, years ago.</td>
    <td width="50%"><img src="docs/img/windows-compare.png" alt="Two photos of the same Venice canal compared, ten years apart"><br><b>Compare:</b> then and now, side by side.</td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/img/windows-adjust.png" alt="The editor, with light and colour sliders beside a photo of the Italian coast"><br><b>Edit:</b> crop, light, colour and filters.</td>
    <td width="50%"><img src="docs/img/windows-blur.png" alt="The background behind a statue blurred, leaving the statue sharp"><br><b>Background:</b> blur it, colour-pop it or replace it.</td>
  </tr>
</table>

## Download

**Windows 10 and 11:** get `Glide-Setup.exe` from the
[latest release](../../releases/latest), or install it with
[Jeti](https://github.com/BersamaMus/Jeti), which keeps it up to date.

Windows may warn that the installer is from an unknown publisher. Click
**More info**, then **Run anyway**.

**Android 7 and up:** get `Glide.apk` from the same release, or install it with
Jeti for Android. The first time, Android asks you to let your browser (or Jeti)
install apps. On Android, Glide shows the phone's gallery the same way, and saves
edits, stickers and collages as new pictures. Features marked *(Windows)* below
are only on the PC.

## Features

- **Every picture, by month:** dated by when it was taken (from the photo
  itself), not when it was copied. Photos and screenshots can be shown apart,
  and so can each file type.
- **Every source the same way** *(Windows)*: Pictures, your other drives, a USB
  stick, and an Android phone plugged in by cable. Switch between them with
  chips at the top, and watch slow scans fill in as they go.
- **Memories:** what you took on this day in years past.
- **The formats cameras use:** JPG, PNG, GIF, WebP, BMP, HEIC, AVIF, TIFF, and,
  on Windows, RAW files from most cameras (with Windows' own codecs).
- **Edit a copy:** crop, rotate, light and colour adjustments, and filters.
  Blur or replace the background behind the subject, which Glide finds on your
  own device.
- **Make something new:** cut the subject out as a sticker, put a few pictures
  together in a collage, or compare two side by side, then and now.
- **Tidy up** *(Windows)*: rename, copy, move, or send pictures to the Recycle
  Bin, one at a time or many at once, with File Explorer's selection and
  shortcuts. On Android, pictures can be shared or moved to the phone's trash.
- **Open with Glide** *(Windows)*: offered for pictures in File Explorer.

Glide never reads OneDrive files that are only online, so it doesn't download
them.

## Building

Needs Flutter, Visual Studio with C++ (for the Windows side) and the Android
SDK (for the Android side).

```sh
flutter pub get
flutter run -d windows
flutter test
powershell -File windows\installer\build_installer.ps1   # build\installer\Glide-Setup-<version>.exe
flutter build apk --release                             # build\app\outputs\flutter-apk\app-release.apk
```

Release APKs are signed with Glide's own key, which `android/key.properties`
describes (kept out of Git, as is the key). Every APK must be signed with that
same key, or Android won't let it update the Glide already installed, so keep a
backup of both. Without a complete `key.properties`, release builds stop with an
error. To try one out anyway, set `GLIDE_DEBUG_SIGNED_RELEASE=1` and it's signed
with the debug key (never publish that APK).

The first Windows build downloads ONNX Runtime and the IS-Net model (used to
find a picture's subject) into `packages/native_imaging/third_party/`.
Building the installer needs [Inno Setup](https://jrsoftware.org/isinfo.php)
(`winget install JRSoftware.InnoSetup`).

## Releasing

1. Raise `version` in `pubspec.yaml`, both the name and the number after the `+`
   (Android won't install a build whose number isn't higher).
2. Run `windows\installer\build_installer.ps1` and `flutter build apk --release`.
3. Make a release tagged `v` plus the version name, without the build number
   (`1.0.1+2` is tagged `v1.0.1`), and attach the installer renamed to
   `Glide-Setup.exe` and the APK renamed to `Glide.apk`. Jeti, on Windows and
   Android, then offers the update to everyone who has Glide.
