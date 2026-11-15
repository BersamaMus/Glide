import 'dart:io';

import 'package:flutter/material.dart';

import 'screens/app_shell.dart';
import 'theme.dart';

/// Started with a folder, opens it; with a picture (Open with), opens its
/// folder with it selected.
void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  // Thumbnails are decoded at tile size, so this holds many screens of
  // them: scrolled back to, they're there, not got again. The few big
  // pictures kept beside them (see keepPreview) take up to 60 MB or so of
  // it. More on a PC, which has the memory, than on a phone.
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = (Platform.isAndroid ? 128 : 256) << 20
    ..maximumSize = 2000;
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
