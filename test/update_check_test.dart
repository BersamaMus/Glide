import 'package:glide/services/update_check.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a higher number in any place is newer', () {
    expect(isNewerVersion('1.0.2', '1.0.1'), isTrue);
    expect(isNewerVersion('1.1.0', '1.0.9'), isTrue);
    expect(isNewerVersion('2.0.0', '1.99.99'), isTrue);
  });

  test('numbers are compared as numbers, not text', () {
    expect(isNewerVersion('1.10.0', '1.9.0'), isTrue);
    expect(isNewerVersion('1.9.0', '1.10.0'), isFalse);
  });

  test('the same or an older version is not newer', () {
    expect(isNewerVersion('1.0.1', '1.0.1'), isFalse);
    expect(isNewerVersion('1.0.0', '1.0.1'), isFalse);
  });

  test('a missing number counts as 0, and build numbers are ignored', () {
    expect(isNewerVersion('1.1', '1.0.9'), isTrue);
    expect(isNewerVersion('1.0', '1.0.0'), isFalse);
    expect(isNewerVersion('1.0.1+2', '1.0.1'), isFalse);
  });
}
