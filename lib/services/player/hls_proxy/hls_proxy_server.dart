import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:kazumi/request/clients/download_http_client.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/metered_network_service.dart';
import 'package:kazumi/services/player/hls_prefetch_policy.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/media.dart';
import 'package:kazumi/utils/m3u8_ad_filter.dart';
import 'package:kazumi/utils/m3u8_parser.dart';
import 'package:path/path.dart' as path;

/// 一次 [HlsProxy.resolvePlaybackUrl] 的结果状态。
enum HlsProxyStatus {
  /// 代理已生效，播放器应打开本地代理 URL。
  proxied,

  /// 设置中已禁用代理，直接播放原始 URL。
  disabled,

  /// 源不是 HLS（非 http(s) 或直接媒体文件扩展名），不适用。
  notApplicable,

  /// 代理初始化失败，已回退为直接播放原始 URL。
  fallback,
}

/// [HlsProxy.resolvePlaybackUrl] 的返回值。
class HlsProxyResult {
  const HlsProxyResult(
    this.url,
    this.status, {
    this.reason,
  });

  /// 播放器应打开的 URL。
  final String url;

  final HlsProxyStatus status;

  /// 回退原因的可读描述，仅 [HlsProxyStatus.fallback] 时非空。
  final String? reason;
}

/// 本地 HLS 代理。
///
/// ffmpeg/mpv 的 HLS demuxer 一次只用单个连接串行拉取分片，遇到 CDN
/// 单连接限速时缓冲追不上播放速度导致卡顿。此代理在回环地址上提供
/// 改写后的播放列表，并以多连接并行预取分片，绕过单连接限速。
/// 预取范围按当前播放时间和网络类型限制为滑动窗口，不会因为连接很快
/// 而把整个 VOD 一次性下载完。
///
/// 生命周期与播放会话对齐：每次 [resolvePlaybackUrl] 会结束上一个会话
/// 并按需创建新会话；[stop] 结束当前会话并清理磁盘缓存。任何初始化
/// 失败都会回退为直接播放原始 URL，不影响现有行为。
class HlsProxy {
  HlsProxy._();

  static final HlsProxy instance = HlsProxy._();

  static const String _cacheRootName = 'hls_proxy_cache';

  _HlsProxySession? _session;
  bool _cachePurged = false;

  /// Updates the media-time anchor used by the active proxy session. The
  /// proxy deliberately does not use every segment request as an anchor,
  /// because mpv may request far-ahead segments while filling its cache.
  void updatePlaybackPosition(
    Duration position, {
    bool force = false,
  }) {
    _session?.updatePlaybackPosition(position, force: force);
  }

  /// 返回播放器应打开的 URL：代理 URL，或禁用/不适用/初始化失败时的
  /// 原始 URL。
  Future<HlsProxyResult> resolvePlaybackUrl(
    String url,
    Map<String, String> httpHeaders, {
    required bool adBlockerEnabled,
    bool forceHls = false,
    Duration initialPosition = Duration.zero,
  }) async {
    if (!GStorage.getSetting<bool>(SettingsKeys.hlsProxyEnabled)) {
      return HlsProxyResult(url, HlsProxyStatus.disabled);
    }
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return HlsProxyResult(url, HlsProxyStatus.notApplicable);
    }
    if (!forceHls && _hasDirectMediaExtension(uri.path)) {
      return HlsProxyResult(url, HlsProxyStatus.notApplicable);
    }

    await stop();
    await _purgeStaleCache();

    try {
      final session = await _HlsProxySession.start(
        url,
        httpHeaders,
        adBlockerEnabled: adBlockerEnabled,
        initialPosition: initialPosition,
      );
      _session = session;
      KazumiLogger().i(
        'HlsProxy: proxying ${session.segments.length} segments at '
        '${session.indexUrl}',
      );
      return HlsProxyResult(session.indexUrl, HlsProxyStatus.proxied);
    } catch (e, stackTrace) {
      KazumiLogger().w(
        'HlsProxy: unavailable, falling back to direct playback',
        error: e,
        stackTrace: stackTrace,
      );
      return HlsProxyResult(
        url,
        HlsProxyStatus.fallback,
        reason: _describeFallbackReason(e),
      );
    }
  }

  /// 将回退原因转为面向用户的简短描述。
  static String _describeFallbackReason(Object e) {
    if (e is _UnsupportedPlaylistException) {
      switch (e.reason) {
        case 'fMP4/BYTERANGE':
          return '播放列表为 fMP4/BYTERANGE 格式';
        case 'live stream':
          return '直播流暂不支持';
        case 'no segments':
          return '播放列表中没有有效分片';
      }
    }
    if (e is _NotPlaylistException) {
      return '无法获取有效的播放列表';
    }
    return '初始化失败';
  }

  /// 结束当前会话（如有）并清理其缓存目录。
  Future<void> stop() async {
    final session = _session;
    _session = null;
    if (session != null) {
      await session.close();
    }
  }

  /// 每次进程运行只清理一次崩溃遗留的缓存。
  Future<void> _purgeStaleCache() async {
    if (_cachePurged) return;
    _cachePurged = true;
    try {
      final root = Directory(
        path.join(await getPlayerTempPath(), _cacheRootName),
      );
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    } catch (_) {}
  }

  static const Set<String> _directMediaExtensions = {
    '.mp4',
    '.mkv',
    '.flv',
    '.avi',
    '.mov',
    '.webm',
    '.wmv',
    '.ts',
    '.mp3',
    '.m4a',
    '.flac',
    '.ogg',
  };

  static bool _hasDirectMediaExtension(String mediaPath) {
    final dot = mediaPath.lastIndexOf('.');
    if (dot < 0) return false;
    return _directMediaExtensions
        .contains(mediaPath.substring(dot).toLowerCase());
  }
}

class _NotPlaylistException implements Exception {
  final String message;
  const _NotPlaylistException(this.message);
  @override
  String toString() => message;
}

class _UnsupportedPlaylistException implements Exception {
  final String reason;
  const _UnsupportedPlaylistException(this.reason);
  @override
  String toString() => 'Unsupported HLS playlist: $reason';
}

/// 一次分片下载。支持中途加入的订阅者：已收到的字节保存在内存中供
/// 回放，后续字节实时转发，使播放器在下载完成前就能开始消费数据，
/// 避免 mpv 的网络读超时。
class _SegmentFetch {
  _SegmentFetch({
    required this.index,
    required this.url,
    required this.tmpPath,
    required this.finalPath,
  });

  static const int _maxBufferedBytes = 24 * 1024 * 1024;

  final int index;
  final String url;
  final String tmpPath;
  final String finalPath;
  final Completer<void> done = Completer<void>();
  final List<_SegmentSubscriber> subscribers = [];

  /// 已接收字节缓存；分片超过 [_maxBufferedBytes] 时置 null，晚到的
  /// 订阅者改为等待文件落盘。
  List<Uint8List>? buffered = <Uint8List>[];
  int _bufferedBytes = 0;
  int contentLength = -1;
  bool completed = false;
  bool failed = false;

  /// 分片级取消令牌：seek 后移出预取窗口或会话结束时放弃下载。
  final CancelToken cancelToken = CancelToken();

  /// 已放弃（seek 移出窗口或会话关闭），不再重试。
  bool abandoned = false;

  /// 是否已追加过字节。已向订阅者转发过字节的下载无法安全重试
  /// （会重复发送字节），只能整体失败。
  bool bytesAppended = false;

  /// 放弃此下载。
  void abandon() {
    abandoned = true;
    if (!cancelToken.isCancelled) {
      cancelToken.cancel('abandoned');
    }
  }

  /// 是否可以安全地重新下载：从未向订阅者转发过字节。无订阅者时
  /// 已缓冲字节仅用于之后的回放，可直接丢弃。
  bool get canRestart => subscribers.isEmpty || !bytesAppended;

  /// 重试前重置状态，仅可在 [canRestart] 为真时调用。
  void resetForRetry() {
    buffered = <Uint8List>[];
    _bufferedBytes = 0;
    bytesAppended = false;
    contentLength = -1;
  }

  void appendChunk(Uint8List chunk, IOSink sink) {
    sink.add(chunk);
    bytesAppended = true;
    final buffer = buffered;
    if (buffer != null) {
      _bufferedBytes += chunk.length;
      if (_bufferedBytes <= _maxBufferedBytes) {
        buffer.add(chunk);
      } else {
        buffered = null;
      }
    }
    for (final subscriber in subscribers.toList()) {
      _deliver(subscriber, chunk);
    }
  }

  void subscribe(HttpResponse response) {
    final subscriber = _SegmentSubscriber(response);
    final buffer = buffered;
    if (buffer != null && buffer.isNotEmpty) {
      for (final chunk in buffer) {
        try {
          response.add(chunk);
        } catch (_) {
          return;
        }
      }
      subscriber.headersSent = true;
    }
    subscribers.add(subscriber);
  }

  void _deliver(_SegmentSubscriber subscriber, Uint8List chunk) {
    try {
      subscriber.response.add(chunk);
      subscriber.headersSent = true;
    } catch (_) {
      subscribers.remove(subscriber);
    }
  }

  void finishSuccess() {
    completed = true;
    buffered = null;
    for (final subscriber in subscribers.toList()) {
      try {
        subscriber.response.close().catchError((_) {});
      } catch (_) {}
    }
    subscribers.clear();
    if (!done.isCompleted) done.complete();
  }

  void finishFailure() {
    failed = true;
    buffered = null;
    for (final subscriber in subscribers.toList()) {
      try {
        if (!subscriber.headersSent) {
          subscriber.response.statusCode = 502;
        }
        subscriber.response.close().catchError((_) {});
      } catch (_) {}
    }
    subscribers.clear();
    if (!done.isCompleted) done.complete();
  }
}

class _SegmentSubscriber {
  _SegmentSubscriber(this.response);

  final HttpResponse response;

  /// 是否已向该订阅者写出过字节（响应头随之发出）。
  bool headersSent = false;
}

class _HlsProxySession {
  _HlsProxySession._({
    required this.sessionId,
    required this.segments,
    required this.playlistText,
    required this.cacheDir,
    required this.httpHeaders,
    required this.parallel,
    required this.segmentDurations,
  });

  static const int _maxFetchAttempts = 3;
  static const String _cacheRootName = 'hls_proxy_cache';
  static final RegExp _segmentNamePattern = RegExp(r'^seg_(\d+)\.ts$');
  static final RegExp _keyNamePattern = RegExp(r'^key_(\d+)\.key$');
  static final RegExp _rangePattern = RegExp(r'bytes=(\d*)-(\d*)');

  final DownloadHttpClient _http = DownloadHttpClient.instance;
  final String sessionId;
  final List<M3u8Segment> segments;
  final String playlistText;
  final Directory cacheDir;
  final Map<String, String> httpHeaders;
  final int parallel;
  final List<double> segmentDurations;

  final CancelToken _cancelToken = CancelToken();
  final Map<int, _SegmentFetch> _fetches = {};
  final List<int> _prefetchQueue = [];
  final Map<int, List<Completer<bool>>> _windowWaiters = {};
  int _activeFetchCount = 0;
  int _playbackAnchor = 0;
  int _prefetchGeneration = 0;
  bool _closed = false;
  HttpServer? _server;

  String get indexUrl =>
      'http://127.0.0.1:${_server?.port ?? 0}/p/$sessionId/index.m3u8';

  static Future<_HlsProxySession> start(
    String m3u8Url,
    Map<String, String> httpHeaders, {
    required bool adBlockerEnabled,
    Duration initialPosition = Duration.zero,
  }) async {
    final cancelToken = CancelToken();
    final http = DownloadHttpClient.instance;

    Future<String> fetchPlaylist(String url) =>
        _fetchPlaylistText(http, url, httpHeaders, cancelToken);

    var mediaUrl = m3u8Url;
    var mediaContent = await fetchPlaylist(m3u8Url);
    if (M3u8Parser.detectType(mediaContent) == M3u8Type.master) {
      final master = M3u8Parser.parseMasterPlaylist(mediaContent, m3u8Url);
      mediaUrl = master.bestVariant.uri;
      mediaContent = await fetchPlaylist(mediaUrl);
    }
    // fMP4 初始化段与 BYTERANGE 分片无法通过简单的整段缓存代理，
    // 回退为直连播放。
    if (mediaContent.contains('#EXT-X-MAP') ||
        mediaContent.contains('#EXT-X-BYTERANGE')) {
      throw const _UnsupportedPlaylistException('fMP4/BYTERANGE');
    }

    final playlist = M3u8Parser.parseMediaPlaylist(mediaContent, mediaUrl);
    if (!playlist.isVod) {
      throw const _UnsupportedPlaylistException('live stream');
    }
    var segments = await M3u8Parser.resolveNestedSegments(
      playlist.segments,
      fetchPlaylist,
    );
    if (adBlockerEnabled) {
      segments = M3u8AdFilter.filterAds(segments);
    }
    if (segments.isEmpty) {
      throw const _UnsupportedPlaylistException('no segments');
    }

    final sessionId = _generateSessionId();
    final cacheDir = Directory(
      path.join(await getPlayerTempPath(), _cacheRootName, sessionId),
    );
    await cacheDir.create(recursive: true);

    final keys = M3u8Parser.extractUniqueKeys(
      M3u8MediaPlaylist(
        segments: segments,
        targetDuration: playlist.targetDuration,
        isVod: true,
      ),
    );
    final keyUriToLocal = <String, String>{};
    for (var i = 0; i < keys.length; i++) {
      final keyPath = path.join(cacheDir.path, 'key_$i.key');
      // 密钥很小，失败大概率是瞬时网络问题，快速重试，避免整个
      // 代理会话因此回退为直连。
      for (var attempt = 1;; attempt++) {
        try {
          await http.download(
            keys[i].uri,
            keyPath,
            headers: httpHeaders,
            cancelToken: cancelToken,
          );
          break;
        } catch (e) {
          if (cancelToken.isCancelled || attempt >= 3) rethrow;
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        }
      }
      keyUriToLocal[keys[i].uri] = 'key_$i.key';
    }

    var targetDuration = adBlockerEnabled
        ? M3u8AdFilter.calculateTargetDuration(segments)
        : playlist.targetDuration;
    if (targetDuration <= 0) {
      targetDuration = M3u8AdFilter.calculateTargetDuration(segments);
    }
    final playlistText = M3u8Parser.buildLocalM3u8(
      segments,
      targetDuration: targetDuration,
      keyUriToLocal: keyUriToLocal,
    );

    // 与下载设置的分片并发滑杆范围（1-10）保持一致。
    final parallel = GStorage.getSetting(SettingsKeys.downloadParallelSegments)
        .clamp(1, 10)
        .toInt();

    final session = _HlsProxySession._(
      sessionId: sessionId,
      segments: segments,
      playlistText: playlistText,
      cacheDir: cacheDir,
      httpHeaders: httpHeaders,
      parallel: parallel,
      segmentDurations: [for (final segment in segments) segment.duration],
    );
    session._playbackAnchor = HlsPrefetchPolicy.indexForPosition(
      session.segmentDurations,
      position: initialPosition,
    );
    await session._bind();
    session._schedulePrefetch(session._playbackAnchor);
    return session;
  }

  static Future<String> _fetchPlaylistText(
    DownloadHttpClient http,
    String url,
    Map<String, String> httpHeaders,
    CancelToken sessionToken,
  ) async {
    final fetchToken = CancelToken();
    try {
      final content = await http.getPlain(
        url,
        headers: httpHeaders,
        receiveTimeout: const Duration(seconds: 15),
        cancelToken: fetchToken,
        onReceiveProgress: (received, _) {
          if (sessionToken.isCancelled) {
            fetchToken.cancel('session cancelled');
          } else if (received > 2 * 1024 * 1024) {
            fetchToken.cancel('too large');
          }
        },
      );
      if (!content.trimLeft().startsWith('#EXTM3U')) {
        throw const _NotPlaylistException('URL is not an M3U8 playlist');
      }
      return content;
    } on NetworkException catch (e) {
      if (sessionToken.isCancelled) rethrow;
      if (e.type == NetworkExceptionType.cancel) {
        throw const _NotPlaylistException(
            'Response too large, not an M3U8 playlist');
      }
      rethrow;
    }
  }

  static String _generateSessionId() {
    final random = Random();
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
        '${random.nextInt(0x7FFFFFFF).toRadixString(36)}';
  }

  static String _segmentFileName(int index) =>
      'seg_${index.toString().padLeft(5, '0')}.ts';

  Future<void> _bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    MeteredNetworkService.listenable.addListener(_onNetworkChanged);
    server.listen(
      (request) {
        unawaited(_handleRequest(request));
      },
      onError: (Object e) {
        KazumiLogger().w('HlsProxy: server error', error: e);
      },
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    MeteredNetworkService.listenable.removeListener(_onNetworkChanged);
    _cancelToken.cancel();
    _prefetchQueue.clear();
    _completeWindowWaiters(false);
    for (final fetch in _fetches.values.toList()) {
      fetch.abandon();
    }
    final server = _server;
    _server = null;
    try {
      await server?.close(force: true);
    } catch (_) {}
    final pending = _fetches.values.map((f) => f.done.future).toList();
    if (pending.isNotEmpty) {
      try {
        await Future.wait(pending).timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    try {
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    } catch (e) {
      KazumiLogger().w('HlsProxy: failed to clean cache dir', error: e);
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (_closed) {
        await _respondError(request, 503);
        return;
      }
      final parts = request.uri.path.split('/');
      if (parts.length != 4 || parts[1] != 'p' || parts[2] != sessionId) {
        await _respondError(request, 404);
        return;
      }
      final name = parts[3];
      if (name == 'index.m3u8') {
        await _servePlaylist(request);
        return;
      }
      final segmentMatch = _segmentNamePattern.firstMatch(name);
      if (segmentMatch != null) {
        await _handleSegmentRequest(request, int.parse(segmentMatch.group(1)!));
        return;
      }
      final keyMatch = _keyNamePattern.firstMatch(name);
      if (keyMatch != null) {
        final file = File(path.join(cacheDir.path, name));
        if (await file.exists()) {
          await _serveFile(request, file,
              contentType: 'application/octet-stream');
        } else {
          await _respondError(request, 404);
        }
        return;
      }
      await _respondError(request, 404);
    } catch (e) {
      KazumiLogger().w('HlsProxy: request handler error', error: e);
      try {
        await _respondError(request, 500);
      } catch (_) {}
    }
  }

  Future<void> _servePlaylist(HttpRequest request) async {
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/vnd.apple.mpegurl',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    final bytes = utf8.encode(playlistText);
    response.contentLength = bytes.length;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    response.add(bytes);
    await response.close();
  }

  Future<void> _handleSegmentRequest(
    HttpRequest request,
    int index,
  ) async {
    if (index < 0 || index >= segments.length) {
      await _respondError(request, 404);
      return;
    }
    // The playback controller updates [_playbackAnchor] on real seeks and
    // during normal playback. Do not use every segment request as the anchor:
    // mpv may request speculative, far-ahead segments while filling its cache.
    // Hold requests at the edge of the window instead of allowing a fast
    // demuxer to turn speculative requests into an unbounded download.
    final file = File(path.join(cacheDir.path, _segmentFileName(index)));
    // A stale request can arrive after a seek. Serving an already cached
    // segment is safe and avoids turning that race into a player error.
    if (await file.exists()) {
      await _serveFile(request, file);
      return;
    }
    if (!await _waitForSegmentInWindow(index)) {
      await _respondError(request, 503);
      return;
    }
    _schedulePrefetch(_playbackAnchor);
    var fetch = _fetches[index];
    if (fetch == null) {
      // 播放器请求优先于预取队列。
      _prefetchQueue.remove(index);
      fetch = _startFetch(index);
    } else if (fetch.buffered == null && !fetch.completed && !fetch.failed) {
      // 分片过大无法从内存回放，等待文件落盘。
      await fetch.done.future;
      if (await file.exists()) {
        await _serveFile(request, file);
      } else {
        await _respondError(request, 502);
      }
      return;
    }
    if (fetch.completed || fetch.failed) {
      if (await file.exists()) {
        await _serveFile(request, file);
        return;
      }
      await _respondError(request, 502);
      return;
    }
    // 订阅进行中的下载：先回放已缓冲字节，再实时跟随下载数据。
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.bufferOutput = false;
    if (fetch.contentLength >= 0) {
      response.contentLength = fetch.contentLength;
    }
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    unawaited(response.done.then((_) {}, onError: (_, __) {}));
    fetch.subscribe(response);
  }

  void _onNetworkChanged() {
    if (_closed) {
      return;
    }
    // A handover from WLAN to cellular must shrink the active window
    // immediately instead of waiting for the next segment request.
    _schedulePrefetch(
      _playbackAnchor,
      seek: true,
      cancelPendingRequests: false,
    );
  }

  void updatePlaybackPosition(
    Duration position, {
    bool force = false,
  }) {
    if (_closed || segmentDurations.isEmpty) {
      return;
    }
    final anchor = HlsPrefetchPolicy.indexForPosition(
      segmentDurations,
      position: position,
    );
    if (anchor == _playbackAnchor) {
      return;
    }
    _playbackAnchor = anchor;
    _schedulePrefetch(
      anchor,
      seek: true,
      cancelPendingRequests: force,
    );
  }

  bool _isSegmentInWindow(int index) {
    final start = max(0, _playbackAnchor - 1);
    final end = HlsPrefetchPolicy.endIndexFor(
      segmentDurations,
      anchor: _playbackAnchor,
      isMetered: MeteredNetworkService.isMetered,
    );
    return index >= start && index < end;
  }

  Future<bool> _waitForSegmentInWindow(int index) {
    if (_isSegmentInWindow(index)) {
      return Future<bool>.value(true);
    }
    if (index < max(0, _playbackAnchor - 1)) {
      return Future<bool>.value(false);
    }
    final waiter = Completer<bool>();
    _windowWaiters.putIfAbsent(index, () => <Completer<bool>>[]).add(waiter);
    return waiter.future;
  }

  void _completeWindowWaiters(bool allowed) {
    final waiters = _windowWaiters.values.expand((items) => items).toList();
    _windowWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete(allowed);
      }
    }
  }

  void _notifyWindowWaiters({bool cancelOutside = false}) {
    final start = max(0, _playbackAnchor - 1);
    final end = HlsPrefetchPolicy.endIndexFor(
      segmentDurations,
      anchor: _playbackAnchor,
      isMetered: MeteredNetworkService.isMetered,
    );
    for (final entry in _windowWaiters.entries.toList()) {
      final index = entry.key;
      final inWindow = index >= start && index < end;
      if (inWindow || index < start || cancelOutside) {
        _windowWaiters.remove(index);
        for (final waiter in entry.value) {
          if (!waiter.isCompleted) waiter.complete(inWindow);
        }
      }
    }
  }

  void _schedulePrefetch(
    int anchor, {
    bool seek = false,
    bool cancelPendingRequests = false,
  }) {
    _prefetchQueue.clear();
    final generation = ++_prefetchGeneration;
    final start = anchor.clamp(0, segments.length - 1).toInt();
    final end = HlsPrefetchPolicy.endIndexFor(
      segmentDurations,
      anchor: start,
      isMetered: MeteredNetworkService.isMetered,
    );
    _notifyWindowWaiters(cancelOutside: cancelPendingRequests);
    if (seek) {
      // seek/network handover 后窗口外的进行中下载已无用，放弃以立刻
      // 释放并行额度；否则它们会占满并发数，拖慢当前窗口的首个分片。
      for (final fetch in _fetches.values.toList()) {
        if (fetch.index < start || fetch.index >= end) {
          fetch.abandon();
        }
      }
    }
    // Keep at most one already-played segment for a small backward seek
    // cushion. Without trimming, a long episode would still accumulate every
    // downloaded segment on disk even though the forward window is bounded.
    unawaited(_trimCachedSegments(max(0, start - 1), end, generation));

    for (var j = start; j < end && j < segments.length; j++) {
      if (_fetches.containsKey(j)) continue;
      if (File(path.join(cacheDir.path, _segmentFileName(j))).existsSync()) {
        continue;
      }
      _prefetchQueue.add(j);
    }
    _drainPrefetchQueue();
  }

  Future<void> _trimCachedSegments(
    int start,
    int end,
    int generation,
  ) async {
    try {
      await for (final entity in cacheDir.list()) {
        if (_closed || generation != _prefetchGeneration) return;
        if (entity is! File) continue;
        final match =
            _segmentNamePattern.firstMatch(path.basename(entity.path));
        if (match == null) continue;
        final index = int.tryParse(match.group(1)!);
        if (index == null || (index >= start && index < end)) continue;
        // An in-flight fetch may still be serving the player. It will be
        // cleaned by the next window update after it leaves _fetches.
        if (_fetches.containsKey(index)) continue;
        try {
          await entity.delete();
        } catch (_) {
          // Windows can reject deletion while mpv still has the file open.
        }
      }
    } catch (e) {
      KazumiLogger().w('HlsProxy: failed to trim segment cache', error: e);
    }
  }

  void _drainPrefetchQueue() {
    while (_prefetchQueue.isNotEmpty && _activeFetchCount < parallel) {
      final index = _prefetchQueue.removeAt(0);
      if (_fetches.containsKey(index)) continue;
      if (File(path.join(cacheDir.path, _segmentFileName(index)))
          .existsSync()) {
        continue;
      }
      _startFetch(index);
    }
  }

  _SegmentFetch _startFetch(int index) {
    final segPath = path.join(cacheDir.path, _segmentFileName(index));
    final fetch = _SegmentFetch(
      index: index,
      url: segments[index].uri,
      tmpPath: '$segPath.tmp',
      finalPath: segPath,
    );
    _fetches[index] = fetch;
    _activeFetchCount++;
    unawaited(_runFetch(fetch));
    return fetch;
  }

  Future<void> _runFetch(_SegmentFetch fetch) async {
    try {
      for (var attempt = 1;; attempt++) {
        try {
          final response = await _http.getStream(
            fetch.url,
            headers: httpHeaders,
            cancelToken: fetch.cancelToken,
          );
          fetch.contentLength = int.tryParse(
                response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
              ) ??
              -1;
          final sink = File(fetch.tmpPath).openWrite();
          try {
            await for (final chunk in response.data!.stream) {
              fetch.appendChunk(chunk, sink);
            }
            await sink.flush();
            await sink.close();
          } catch (e) {
            try {
              await sink.close();
            } catch (_) {}
            rethrow;
          }
          await File(fetch.tmpPath).rename(fetch.finalPath);
          fetch.finishSuccess();
          return;
        } catch (e) {
          // 会话关闭或分片被放弃（seek 移出窗口）不算失败。
          final cancelled =
              _cancelToken.isCancelled || fetch.abandoned || _closed;
          // 已向订阅者转发过字节且仍有订阅者的下载无法安全重试，
          // 直接失败，由播放器重新请求触发全新下载。先同步完成判定
          // 与状态重置，再做带 await 的临时文件清理，避免清理间隙
          // 到达的新订阅者回放到即将被丢弃的旧字节。
          final retry =
              !cancelled && attempt < _maxFetchAttempts && fetch.canRestart;
          if (retry) {
            fetch.resetForRetry();
          } else {
            fetch.finishFailure();
            if (!cancelled) {
              KazumiLogger().w(
                'HlsProxy: segment ${fetch.index} fetch failed '
                'after $attempt attempt(s)',
                error: e,
              );
            }
          }
          try {
            final tmp = File(fetch.tmpPath);
            if (await tmp.exists()) await tmp.delete();
          } catch (_) {}
          if (!retry) {
            return;
          }
        }
        await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
      }
    } finally {
      _fetches.remove(fetch.index);
      _activeFetchCount--;
      _drainPrefetchQueue();
    }
  }

  Future<void> _serveFile(
    HttpRequest request,
    File file, {
    String contentType = 'video/mp2t',
  }) async {
    final length = await file.length();
    final response = request.response;
    var start = 0;
    var end = length - 1;
    var partial = false;
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null && length > 0) {
      final match = _rangePattern.firstMatch(rangeHeader);
      if (match != null) {
        final startStr = match.group(1)!;
        final endStr = match.group(2)!;
        if (startStr.isEmpty && endStr.isNotEmpty) {
          final n = int.tryParse(endStr);
          if (n != null) {
            start = length > n ? length - n : 0;
            partial = true;
          }
        } else if (startStr.isNotEmpty) {
          final s = int.tryParse(startStr);
          if (s != null && s >= length) {
            response.statusCode = 416;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes */$length',
            );
            await response.close();
            return;
          }
          if (s != null) {
            start = s;
            if (endStr.isNotEmpty) {
              final e = int.tryParse(endStr);
              if (e != null && e < length) end = e;
            }
            partial = true;
          }
        }
      }
    }
    response.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
    response.contentLength = end - start + 1;
    response.headers.set(HttpHeaders.contentTypeHeader, contentType);
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (partial) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$length',
      );
    }
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    await response.addStream(file.openRead(start, end + 1));
    await response.close();
  }

  Future<void> _respondError(HttpRequest request, int status) async {
    try {
      request.response.statusCode = status;
      await request.response.close();
    } catch (_) {}
  }
}
