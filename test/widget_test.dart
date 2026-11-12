import 'package:flutter/widgets.dart';
import 'package:better_image_manager/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the sidebar and the empty preview pane', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const GlideApp());
    expect(find.text('Pictures'), findsWidgets);
    expect(find.text('Drives'), findsOneWidget);
    expect(find.text('Phone'), findsOneWidget);
    expect(find.text('Select a picture to preview it.'), findsOneWidget);

    // Done with: what was still being looked for, and the time limits on
    // it, run their course.
    await tester.pumpWidget(const SizedBox());
    // Queued thumbnails each start their time limit once the one before
    // them ends: time's moved on till all have.
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(seconds: 21));
    }
  });
}
