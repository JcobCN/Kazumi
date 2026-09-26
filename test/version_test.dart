import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/version.dart';

void main() {
  group('compareVersions', () {
    test('accepts plain version tags and historical fork suffixes', () {
      expect(needUpdate('2.3.1', 'v2.3.2'), isTrue);
      expect(needUpdate('2.3.1', '2.3.1'), isFalse);
      expect(needUpdate('2.3.1', 'v2.3.1-enhance.7'), isTrue);
      expect(needUpdate('2.3.1-enhance.6', 'v2.3.1-enhance.7'), isTrue);
      expect(needUpdate('2.3.1-enhance.7', '2.3.1-enhance.7'), isFalse);
    });

    test('compares numeric core before suffix', () {
      expect(compareVersions('2.10.0', '2.9.99'), greaterThan(0));
      expect(compareVersions('v2.9.99', '2.10.0'), lessThan(0));
      expect(needUpdate('2.3.9', '2.3.10'), isTrue);
    });

    test('treats a later suffix build as newer', () {
      expect(compareVersions('2.3.1-enhance.7', '2.3.1-enhance.6'),
          greaterThan(0));
      expect(compareVersions('2.3.1-enhance.7', '2.3.1'), greaterThan(0));
      expect(compareVersions('2.3.1', '2.3.1-enhance.7'), lessThan(0));
    });

    test('fails closed for malformed versions', () {
      expect(compareVersions('not-a-version', '2.0.0'), 0);
      expect(needUpdate('not-a-version', '2.0.0'), isFalse);
    });
  });
}
