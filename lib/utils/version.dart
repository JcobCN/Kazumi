import 'dart:math';

/// Returns true when [remoteVersion] should be treated as newer than
/// [localVersion]. Release tags may optionally contain a leading `v` and a
/// distribution suffix, for example `v2.3.1-enhance.7`.
bool needUpdate(String localVersion, String remoteVersion) {
  return compareVersions(remoteVersion, localVersion) > 0;
}

/// Compares two application versions using the numeric version core first.
///
/// The project publishes fork/distribution builds with suffixes such as
/// `-enhance.7`. A suffixed build is considered newer than the same unsuffixed
/// base version so a `2.3.1` installation can update to
/// `v2.3.1-enhance.7`. This is intentional and differs from strict SemVer
/// prerelease ordering.
int compareVersions(String leftVersion, String rightVersion) {
  final left = _parseVersion(leftVersion);
  final right = _parseVersion(rightVersion);
  if (left == null || right == null) return 0;

  final maxLength = max(left.core.length, right.core.length);
  for (var i = 0; i < maxLength; i++) {
    final leftSegment = i < left.core.length ? left.core[i] : 0;
    final rightSegment = i < right.core.length ? right.core[i] : 0;
    if (leftSegment != rightSegment) {
      return leftSegment.compareTo(rightSegment);
    }
  }

  return _compareSuffix(left.suffix, right.suffix);
}

({List<int> core, String suffix})? _parseVersion(String version) {
  final match =
      RegExp(r'^[vV]?(\d+(?:\.\d+)*)(.*)$').firstMatch(version.trim());
  if (match == null) return null;

  final core =
      match.group(1)!.split('.').map(int.parse).toList(growable: false);
  return (core: core, suffix: match.group(2) ?? '');
}

int _compareSuffix(String left, String right) {
  if (left == right) return 0;
  if (left.isEmpty) return -1;
  if (right.isEmpty) return 1;

  final leftTokens = _suffixTokens(left);
  final rightTokens = _suffixTokens(right);
  final maxLength = max(leftTokens.length, rightTokens.length);
  for (var i = 0; i < maxLength; i++) {
    if (i >= leftTokens.length) return -1;
    if (i >= rightTokens.length) return 1;

    final comparison = _compareSuffixToken(leftTokens[i], rightTokens[i]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

List<String> _suffixTokens(String suffix) {
  return suffix
      .replaceFirst(RegExp(r'^[.+-]'), '')
      .split(RegExp(r'[.+-]'))
      .where((token) => token.isNotEmpty)
      .toList(growable: false);
}

int _compareSuffixToken(String left, String right) {
  final leftNumber = int.tryParse(left);
  final rightNumber = int.tryParse(right);
  if (leftNumber != null && rightNumber != null) {
    return leftNumber.compareTo(rightNumber);
  }
  if (leftNumber != null) return 1;
  if (rightNumber != null) return -1;
  return left.toLowerCase().compareTo(right.toLowerCase());
}
