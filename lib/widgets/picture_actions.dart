import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../screens/collage_screen.dart';
import '../screens/compare_screen.dart';
import '../screens/editor_screen.dart';
import '../screens/sticker_screen.dart';
import '../services/browser.dart';
import '../services/places.dart';

// What can be done to the selection, from the preview pane's buttons and the
// keyboard alike, telling the user how it went: and what can be made of it
// (a comparison, a collage, a sticker).

/// Moves the selection to the Recycle Bin (on a phone, Android's trash,
/// once it's asked). Undoable from there, so there's no "Are you sure?" of
/// the app's own.
Future<void> deleteSelection(BuildContext context, Browser browser) async {
  final messenger = ScaffoldMessenger.of(context);
  if (await browser.deleteSelection() case final message?) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Asks for a folder, then copies (or moves) the selection into it.
Future<void> copySelection(BuildContext context, Browser browser, {bool move = false}) async {
  final messenger = ScaffoldMessenger.of(context);
  final count = browser.selectedCount;
  final folder = await getDirectoryPath(
    initialDirectory: picturesFolder,
    confirmButtonText: move ? 'Move here' : 'Copy here',
  );
  if (folder == null || count == 0) return;
  if (await browser.copySelection(folder, move: move) case final message?) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Whether the focused picture can be edited: one on this PC or in the
/// phone's own gallery, selected alone.
bool canEdit(Browser browser) => browser.canDelete && browser.selectedCount == 1 && browser.focused is LocalPicture;

/// Opens the focused picture in the editor.
Future<void> editFocused(BuildContext context, Browser browser) async {
  final picture = browser.focused;
  if (picture is! LocalPicture) return;
  final messenger = ScaffoldMessenger.of(context);
  final message = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => EditorScreen(browser: browser, picture: picture)),
  );
  if (message != null) messenger.showSnackBar(SnackBar(content: Text(message)));
}

/// Whether the selection can be compared: two pictures, then and now.
bool canCompare(Browser browser) => browser.selectedCount == 2;

/// Shows the two selected pictures side by side, or one over the other.
/// Nothing, if they aren't both still shown (one gone since, while the
/// location's listed again).
Future<void> compareSelection(BuildContext context, Browser browser) async {
  if (browser.selection case [final a, final b]) {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CompareScreen(a: a, b: b)));
  }
}

/// Whether the selection can be made into a collage: 2 to 9 pictures.
bool canCollage(Browser browser) =>
    browser.selectedCount >= CollageScreen.fewest && browser.selectedCount <= CollageScreen.most;

/// Makes a collage of the selection.
Future<void> collageSelection(BuildContext context, Browser browser) async {
  final messenger = ScaffoldMessenger.of(context);
  final message = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => CollageScreen(browser: browser, pictures: browser.selection)),
  );
  if (message != null) messenger.showSnackBar(SnackBar(content: Text(message)));
}

/// Whether a sticker can be made of the focused picture: one on this PC
/// (found by IS-Net), or in the phone's own gallery (by ML Kit), alone.
bool canSticker(Browser browser) => switch (browser.focused) {
  final LocalPicture picture when browser.selectedCount == 1 => Platform.isWindows || picture.galleryId != null,
  _ => false,
};

/// Makes a sticker of the focused picture's subject.
Future<void> stickerOfFocused(BuildContext context, Browser browser) async {
  final picture = browser.focused;
  if (picture is! LocalPicture) return;
  final messenger = ScaffoldMessenger.of(context);
  final message = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => StickerScreen(browser: browser, picture: picture)),
  );
  if (message != null) messenger.showSnackBar(SnackBar(content: Text(message)));
}

/// Asks for a new name for the focused picture, keeping its extension.
Future<void> renameFocused(BuildContext context, Browser browser) async {
  final picture = browser.focused;
  if (picture is! LocalPicture) return;
  final controller = TextEditingController(text: p.basenameWithoutExtension(picture.name));
  controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
  String? error;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> submit() async {
          error = await browser.renameFocused(controller.text);
          if (!context.mounted) return;
          if (error == null) {
            Navigator.pop(context);
          } else {
            setState(() {});
          }
        }

        return AlertDialog(
          title: const Text('Rename'),
          content: TextField(
            controller: controller,
            autofocus: true,
            onSubmitted: (_) => submit(),
            decoration: InputDecoration(suffixText: p.extension(picture.name), errorText: error),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: const Text('Rename')),
          ],
        );
      },
    ),
  );
  controller.dispose();
}
