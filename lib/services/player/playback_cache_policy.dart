import 'dart:async';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/metered_network_service.dart';
import 'package:kazumi/services/player/hls_prefetch_policy.dart';
import 'package:kazumi/services/player/low_memory_mode.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:media_kit/media_kit.dart';

class PlaybackCachePolicy {
  PlaybackCachePolicy({
    required bool Function() isLocalPlayback,
    required Player? Function() currentPlayer,
  })  : _isLocalPlayback = isLocalPlayback,
        _currentPlayer = currentPlayer;

  static const int _lowMemoryBufferSize = 2 * 1024 * 1024;
  static const int _defaultBufferSize = 1500 * 1024 * 1024;

  final bool Function() _isLocalPlayback;
  final Player? Function() _currentPlayer;
  final AsyncSerialQueue _writes = AsyncSerialQueue();

  StreamSubscription<void>? _settingsSubscription;
  bool _hlsPlayback = false;

  /// HLS uses a time-based forward window instead of mpv's effectively
  /// unlimited default cache. The value is refreshed when the transport
  /// changes, so a live network handover also changes the window.
  bool get hlsPlayback => _hlsPlayback;

  int get hlsWindowSeconds => HlsPrefetchPolicy.windowSecondsFor(
        isMetered: MeteredNetworkService.isMetered,
      );

  void resetPlaybackType() {
    _hlsPlayback = false;
  }

  Future<void> setHlsPlayback(bool enabled) async {
    _hlsPlayback = enabled;
    await apply();
  }

  bool get networkAutomatic =>
      LowMemoryMode.current == LowMemoryMode.auto &&
      !_isLocalPlayback() &&
      MeteredNetworkService.isMetered;

  int get bufferSize => LowMemoryMode.current.isEnabled(
        isMetered: MeteredNetworkService.isMetered,
        isLocalPlayback: _isLocalPlayback(),
      )
          ? _lowMemoryBufferSize
          : _defaultBufferSize;

  void startWatching() {
    if (_settingsSubscription != null) {
      return;
    }
    _settingsSubscription = LowMemoryMode.watch().listen((_) => _onChanged());
    MeteredNetworkService.listenable.addListener(_onChanged);
  }

  void stopWatching() {
    MeteredNetworkService.listenable.removeListener(_onChanged);
    unawaited(_settingsSubscription?.cancel());
    _settingsSubscription = null;
  }

  Future<void> apply() async {
    final player = _currentPlayer();
    if (player == null) {
      return;
    }
    try {
      final pp = player.platform as NativePlayer;
      // A stale player's initialization must not block its replacement's writes.
      await pp.waitForPlayerInitialization;
      await _writes.run(() async {
        if (!identical(_currentPlayer(), player)) {
          return;
        }
        // For HLS, the time limit is the primary guard. The mobile low-memory
        // byte cap (2 MiB) would otherwise truncate a five-minute window for
        // ordinary video bitrates before the time limit can take effect.
        final size =
            (_hlsPlayback ? _defaultBufferSize : bufferSize).toString();
        await pp.setProperty('demuxer-max-bytes', size);
        // HLS is deliberately a forward sliding window. Keeping a large
        // back-buffer would make already-played segments accumulate until
        // the whole VOD is cached, defeating the purpose of the policy.
        await pp.setProperty(
          'demuxer-max-back-bytes',
          _hlsPlayback ? '0' : size,
        );
        if (_hlsPlayback) {
          final window = hlsWindowSeconds.toString();
          await pp.setProperty('cache', 'yes');
          await pp.setProperty('cache-secs', window);
          await pp.setProperty('demuxer-readahead-secs', window);
        }
      });
    } catch (e) {
      KazumiLogger().w(
        'PlaybackCachePolicy: failed to apply demuxer cache size',
        error: e,
      );
    }
  }

  void _onChanged() {
    unawaited(apply());
  }
}
