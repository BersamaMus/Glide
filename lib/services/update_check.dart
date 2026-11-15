import 'dart:convert';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where a newer version can be downloaded: the latest release's page,
/// which has the Windows installer, the Android app and what's changed.
final releasesPage = Uri.https('github.com', '/BersamaMus/Glide/releases/latest');

/// Whether Glide looks for a new version when it opens. On unless the user
/// turns it off.
const checkForUpdatesKey = 'check_for_updates';

/// Asks GitHub which version of Glide is the newest, once each time the app
/// opens. Only the question is sent: nothing about the user or their
/// pictures. It's the only thing Glide goes online for.
abstract final class UpdateCheck {
  /// Whether the check is on (it is until turned off).
  static Future<bool> get enabled async => (await SharedPreferences.getInstance()).getBool(checkForUpdatesKey) ?? true;

  static Future<void> setEnabled(bool on) async => (await SharedPreferences.getInstance()).setBool(checkForUpdatesKey, on);

  /// This copy's version, like "1.0.1".
  static Future<String> get currentVersion async => (await PackageInfo.fromPlatform()).version;

  /// The newer version's number, like "1.1.0", or null when this one is the
  /// newest, the check is off, or GitHub couldn't be reached.
  static Future<String?> newerVersion() async {
    try {
      if (!await enabled) return null;
      final latest = await _latestVersion();
      return latest != null && isNewerVersion(latest, await currentVersion) ? latest : null;
    } on Object {
      // Offline, or an answer that isn't GitHub's (a Wi-Fi sign-in page):
      // try again next time.
      return null;
    }
  }

  static Future<String?> _latestVersion() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'Glide (https://github.com/BersamaMus/Glide)';
    try {
      final request = await client.getUrl(Uri.https('api.github.com', '/repos/BersamaMus/Glide/releases/latest'));
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 30));
      final tag = (jsonDecode(body) as Map<String, dynamic>)['tag_name'];
      return tag is String ? tag.replaceFirst(RegExp('^v'), '') : null;
    } finally {
      client.close(force: true);
    }
  }
}

/// Whether version [latest] ("1.1.0") comes after [current] ("1.0.1"),
/// comparing each number in turn, so 1.10.0 is newer than 1.9.0. Anything
/// after a "-" or "+" is ignored, and a missing number counts as 0.
bool isNewerVersion(String latest, String current) {
  List<int> parts(String version) => [
    for (final part in version.split(RegExp('[-+]')).first.trim().split('.')) int.tryParse(part) ?? 0,
  ];
  final a = parts(latest);
  final b = parts(current);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}
