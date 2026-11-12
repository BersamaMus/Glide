import 'dart:convert';
import 'dart:io';

import 'package:better_image_manager/screens/editor_screen.dart';
import 'package:better_image_manager/services/browser.dart';
import 'package:better_image_manager/services/library_index.dart';
import 'package:better_image_manager/services/places.dart';
import 'package:better_image_manager/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A 2 by 2 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR4nGP4z8DwnwEIGBgYGBgYAAAc+AIBdxLXNQAAAABJRU5ErkJggg==',
);

void main() {
  late Directory folder;
  late Browser browser;
  late LocalPicture picture;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('editor_test');
    final file = File(p.join(folder.path, 'photo.png'));
    await file.writeAsBytes(_png);
    PhotoLibrary.forgetAll();
    await LibraryIndex.at(File(p.join(folder.path, '.index', 'index.json')));
    browser = Browser(PhotoLibrary(folder.path));
    picture = LocalPicture(file);
  });

  tearDown(() async {
    browser.dispose();
    PhotoLibrary.forgetAll();
    await LibraryIndex.idle();
    await folder.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: EditorScreen(browser: browser, picture: picture),
      ),
    );
    // Its size read off the file.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
  }

  /// Closes the editor, and lets the thumbnails' timeouts run out.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  /// Whether the app bar's [label] button can be pressed.
  bool enabled(WidgetTester tester, String label) => tester
      .widget<ButtonStyleButton>(
        find.ancestor(
          of: find.descendant(of: find.byType(AppBar), matching: find.text(label)),
          matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
        ),
      )
      .enabled;

  testWidgets('has crop, adjustment, filter and background tabs', (tester) async {
    await open(tester);
    for (final tab in ['Adjustment', 'Filter', 'Background', 'Crop']) {
      await tester.tap(find.text(tab));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: tab);
    }
    expect(find.text('Aspect ratio'), findsOneWidget);
    await close(tester);
  });

  testWidgets('an adjustment is a change to save, and Reset undoes it', (tester) async {
    await open(tester);
    expect(enabled(tester, 'Save'), isFalse);

    await tester.tap(find.text('Adjustment'));
    await tester.pump();
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Color'), findsOneWidget);
    for (final setting in ['Brightness', 'Exposure', 'Contrast', 'Highlights', 'Shadows', 'Vignette']) {
      expect(find.text(setting), findsOneWidget);
    }
    // Brightness up, from its middle towards its end.
    final slider = find.byType(Slider).first;
    await tester.drag(slider, const Offset(60, 0));
    await tester.pump();
    expect(enabled(tester, 'Save'), isTrue);

    await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.text('Reset')));
    await tester.pump();
    expect(enabled(tester, 'Save'), isFalse);
    await close(tester);
  });

  testWidgets('a filter can be chosen, with its intensity', (tester) async {
    await open(tester);
    await tester.tap(find.text('Filter'));
    await tester.pump();
    expect(find.text('Intensity'), findsNothing);

    await tester.tap(find.text('Vivid'));
    await tester.pump();
    expect(find.text('Intensity'), findsOneWidget);
    expect(enabled(tester, 'Save'), isTrue);

    await tester.tap(find.text('Original'));
    await tester.pump();
    expect(find.text('Intensity'), findsNothing);
    expect(enabled(tester, 'Save'), isFalse);
    await close(tester);
  });
}
