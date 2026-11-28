import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The folder the app keeps its own files in (what it knows about each
/// picture), found once.
///
/// On Windows that folder is named after the app. Before the app was called
/// Glide it was "better_image_manager", so anything left there is moved
/// across the first time, rather than scanning every drive and looking at
/// every picture all over again.
Future<Directory> appDataDirectory() {
  // Once it couldn't be found, said so afresh to each who asks, rather than
  // with the one future that failed: tests ask from one test's zone after
  // another's, and a failure isn't handed across them.
  if (_failure case (final error, final stack)) return Future.error(error, stack);
  if (_found case final found?) return found;
  final finding = _found = _find();
  finding.then(
    (_) {},
    onError: (Object error, StackTrace stack) {
      _failure = (error, stack);
    },
  );
  return finding;
}

Future<Directory>? _found;

/// Why it couldn't be found, if it couldn't.
(Object, StackTrace)? _failure;

/// What the app's own folder was called before it was Glide.
const _oldName = 'better_image_manager';

Future<Directory> _find() async {
  final dir = await getApplicationSupportDirectory();
  if (Platform.isWindows && p.basename(dir.path) != _oldName) {
    try {
      final old = Directory(p.join(dir.parent.path, _oldName));
      if (await old.exists()) {
        await dir.create(recursive: true);
        await for (final entry in old.list()) {
          final to = p.join(dir.path, p.basename(entry.path));
          // Never over something the renamed app has already written.
          if (await FileSystemEntity.type(to) == FileSystemEntityType.notFound) {
            await entry.rename(to);
          }
        }
        if (await old.list().isEmpty) await old.delete();
      }
    } on FileSystemException {
      // Left where it was: the app starts afresh rather than not starting.
    }
  }
  return dir;
}
