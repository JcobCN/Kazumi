import 'dart:math' as math;

/// Time-based buffering policy for online HLS playback.
///
/// The window is intentionally expressed in media time instead of a fixed
/// number of segments because HLS segment durations vary between sources.
/// Cellular networks use a smaller window to avoid unnecessary traffic, while
/// WLAN/ethernet can keep a little more data ready to reduce rebuffering.
class HlsPrefetchPolicy {
  HlsPrefetchPolicy._();

  static const Duration meteredWindow = Duration(minutes: 5);
  static const Duration unmeteredWindow = Duration(minutes: 7);

  static Duration windowFor({required bool isMetered}) =>
      isMetered ? meteredWindow : unmeteredWindow;

  static int windowSecondsFor({required bool isMetered}) =>
      windowFor(isMetered: isMetered).inSeconds;

  /// Returns the segment containing [position].
  static int indexForPosition(
    List<double> segments, {
    required Duration position,
  }) {
    if (segments.isEmpty) {
      return 0;
    }

    final seconds = math.max(position.inMilliseconds, 0).toDouble() / 1000.0;
    var elapsedSeconds = 0.0;
    for (var index = 0; index < segments.length; index++) {
      elapsedSeconds += math.max(segments[index], 0.001).toDouble();
      if (seconds < elapsedSeconds) {
        return index;
      }
    }
    return segments.length - 1;
  }

  /// Returns the exclusive segment index at the end of the time window that
  /// starts at [anchor]. At least one segment is included when [segments] is
  /// non-empty, even if a malformed playlist reports a zero duration.
  static int endIndexFor(
    List<double> segments, {
    required int anchor,
    required bool isMetered,
  }) {
    if (segments.isEmpty) {
      return 0;
    }

    final start = anchor.clamp(0, segments.length - 1).toInt();
    final targetSeconds = windowFor(isMetered: isMetered).inSeconds.toDouble();
    var elapsedSeconds = 0.0;
    var end = start;

    while (end < segments.length &&
        (end == start || elapsedSeconds < targetSeconds)) {
      // Keep malformed zero-duration entries from making the whole playlist
      // part of the window.
      elapsedSeconds += math.max(segments[end], 0.001).toDouble();
      end++;
    }
    return end;
  }
}
