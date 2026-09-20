import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/hls_prefetch_policy.dart';

void main() {
  group('HlsPrefetchPolicy', () {
    test('uses five minutes on metered networks', () {
      expect(
        HlsPrefetchPolicy.windowFor(isMetered: true),
        const Duration(minutes: 5),
      );
      expect(HlsPrefetchPolicy.windowSecondsFor(isMetered: true), 300);
    });

    test('uses seven minutes on unmetered networks', () {
      expect(
        HlsPrefetchPolicy.windowFor(isMetered: false),
        const Duration(minutes: 7),
      );
      expect(HlsPrefetchPolicy.windowSecondsFor(isMetered: false), 420);
    });

    test('maps playback time to a segment anchor', () {
      const segments = <double>[10, 10, 10];
      expect(
        HlsPrefetchPolicy.indexForPosition(
          segments,
          position: const Duration(seconds: 10),
        ),
        1,
      );
      expect(
        HlsPrefetchPolicy.indexForPosition(
          segments,
          position: const Duration(seconds: 99),
        ),
        2,
      );
    });

    test('window is calculated from segment durations', () {
      final segments = List<double>.filled(60, 10);
      expect(
        HlsPrefetchPolicy.endIndexFor(
          segments,
          anchor: 0,
          isMetered: true,
        ),
        30,
      );
      expect(
        HlsPrefetchPolicy.endIndexFor(
          segments,
          anchor: 3,
          isMetered: false,
        ),
        45,
      );
    });

    test('always includes one segment and clamps the anchor', () {
      expect(
        HlsPrefetchPolicy.endIndexFor(
          const <double>[0],
          anchor: 99,
          isMetered: true,
        ),
        1,
      );
    });

    test('does not overrun the playlist at the end', () {
      expect(
        HlsPrefetchPolicy.endIndexFor(
          List<double>.filled(2, 10),
          anchor: 1,
          isMetered: true,
        ),
        2,
      );
    });
  });
}
