import 'package:flutter/material.dart';

import 'screens/app_shell.dart';
import 'theme.dart';

/// Started with a folder, opens it; with a picture (Open with), opens its
/// folder with it selected.
void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  // Thumbnails are decoded at tile size, so this holds several screens of
  // them without keeping full-size photos around.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 96 << 20
    ..maximumSize = 600;
  runApp(GlideApp(open: args.firstOrNull));
}

class GlideApp extends StatelessWidget {
  const GlideApp({super.key, this.open});

  /// A folder or picture to start with, rather than Pictures.
  final String? open;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Glide',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: AppShell(open: open),
    );
  }
}
