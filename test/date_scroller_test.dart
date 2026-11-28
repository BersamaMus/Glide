import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glide/services/browser.dart';
import 'package:glide/services/library_index.dart';
import 'package:glide/services/places.dart';
import 'package:glide/widgets/picture_grid.dart';
import 'package:native_imaging/native_imaging.dart';
import 'package:path/path.dart' as p;

/// The scroller down the grid's side: dragged to go a long way quickly,
/// saying the month it's at.
void main() {
  late Directory folder;
  late Browser browser;

  /// Ten pictures in each month of 2025, newest first, and after them 80
  /// from June 2019: enough that, scrolled to the end, it's June 2019 at
  /// the top.
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('date_scroller_test');
    Future<void> make(String name, DateTime date) async {
      final file = File(p.join(folder.path, name));
      await file.writeAsString('');
      await file.setLastModified(date);
    }

    for (var month = 1; month <= 12; month++) {
      for (var i = 0; i < 10; i++) {
        await make('m${month}_$i.jpg', DateTime(2025, month, 10 + i));
      }
    }
    for (var i = 0; i < 80; i++) {
      await make('old_$i.jpg', DateTime(2019, 6, 1, 0, i));
    }
    PhotoLibrary.forgetAll();
    await LibraryIndex.at(File(p.join(folder.path, '.index', 'index.json')));
    PhotoLibrary.readDates = (paths) async => [for (final _ in paths) DateTaken.none];
    browser = Browser(PhotoLibrary(folder.path));
    await browser.open(browser.location);
    while (browser.updating) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });

  tearDown(() async {
    browser.dispose();
    PhotoLibrary.forgetAll();
    await LibraryIndex.idle();
    await folder.delete(recursive: true);
  });

  Future<void> show(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PictureGrid(browser: browser)),
      ),
    );
    await tester.pump();
  }

  /// Done with: the thumbnails' time limits, run out (see filter_test.dart).
  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(seconds: 21));
    }
  }

  ScrollPosition grid(WidgetTester tester) => tester.state<ScrollableState>(find.byType(Scrollable).first).position;

  /// What the scroller's saying, beside the grid: not a month's heading in it.
  Finder said(String text) => find.byWidgetPredicate(
    (widget) =>
        widget is Text &&
        widget.data == text &&
        widget.style?.fontWeight == FontWeight.w700 &&
        widget.style?.fontSize == 14,
  );

  /// How visible what the scroller's saying is: 0 once it's faded.
  double opacity(WidgetTester tester, String text) => tester
      .widget<AnimatedOpacity>(find.ancestor(of: said(text), matching: find.byType(AnimatedOpacity)).first)
      .opacity;

  testWidgets('on a PC, its thumb is dragged to the end, saying the month it\'s at, then quiet again', (tester) async {
    await show(tester, const Size(900, 700));
    // Nothing said till it's scrolled.
    expect(said('December 2025'), findsNothing);

    // Taken by the thumb, at the top of the bar just under the header, and
    // dragged all the way down.
    final header = tester.getBottomLeft(find.textContaining('200 pictures')).dy;
    final gesture = await tester.startGesture(Offset(900 - 8, header + 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 1000));
    await tester.pump();
    expect(grid(tester).pixels, grid(tester).maxScrollExtent);
    expect(said('June 2019'), findsOneWidget);
    expect(opacity(tester, 'June 2019'), 1);

    // Let go: still said for a moment, then not.
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(opacity(tester, 'June 2019'), 1);
    await tester.pump(const Duration(seconds: 2));
    expect(opacity(tester, 'June 2019'), 0);

    // Clicked near the top of the bar: back up there, to 2025's months.
    await tester.tapAt(Offset(900 - 8, header + 40));
    await tester.pump();
    expect(grid(tester).pixels, lessThan(grid(tester).maxScrollExtent / 10));
    expect(said('December 2025'), findsOneWidget);

    await done(tester);
  });

  testWidgets('scrolled any other way, it says the month too', (tester) async {
    await show(tester, const Size(900, 700));
    // Down past 2025's first few months: the wheel, as it were.
    grid(tester).jumpTo(2000);
    await tester.pump();
    final at = browser.location.groupLabel(
      browser.location.group(
        // The heading pinned at the top is the month scrolled to.
        browser.pictures.firstWhere((picture) => tester.any(find.text(picture.name).hitTestable())),
      ),
    );
    expect(said(at), findsOneWidget);

    await done(tester);
  });

  testWidgets('on a phone, its handle comes out while the grid\'s scrolled, and can be dragged', (tester) async {
    await show(tester, const Size(400, 800));
    final handle = find.byIcon(Icons.unfold_more_rounded);
    // Out of the way of the pictures till then.
    expect(handle.hitTestable(), findsNothing);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pump();
    expect(handle.hitTestable(), findsOneWidget);

    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 2000));
    await tester.pump();
    expect(grid(tester).pixels, grid(tester).maxScrollExtent);
    expect(said('June 2019'), findsOneWidget);
    await gesture.up();

    // Gone again once it's been left a moment.
    await tester.pump(const Duration(seconds: 2));
    expect(handle.hitTestable(), findsNothing);

    await done(tester);
  });
}
