import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_error_mapper.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/bangumi_mirror_credentials.dart';
import 'package:kazumi/utils/crypto.dart';

class BangumiClient {
  BangumiClient._();

  static final BangumiClient instance = BangumiClient._();

  Future<dynamic> get(
    String url, {
    Map<String, dynamic>? queryParameters,
    bool requiresAuth = false,
    String? accessToken,
    bool includeAuth = true,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await DioFactory.apiDio.get(
        url,
        queryParameters: queryParameters,
        options: Options(
          headers: _headers(
            requiresAuth: requiresAuth,
            accessToken: accessToken,
            includeAuth: includeAuth,
            url: url,
            method: 'GET',
          ),
        ),
        cancelToken: cancelToken,
      );
      return response.data;
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Future<dynamic> post(
    String url, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    bool requiresAuth = false,
    bool includeAuth = true,
    bool bypassMirror = false,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await DioFactory.apiDio.post(
        url,
        data: data,
        queryParameters: queryParameters,
        options: Options(
          headers: _headers(
            requiresAuth: requiresAuth,
            includeAuth: includeAuth,
            url: url,
            method: 'POST',
            data: data,
            bypassMirror: bypassMirror,
          ),
          extra: bypassMirror ? {'bypassMirror': true} : null,
        ),
        cancelToken: cancelToken,
      );
      return response.data;
    } on DioException catch (e) {
      throw await NetworkErrorMapper.mapException(e);
    }
  }

  Map<String, dynamic> _headers({
    required bool requiresAuth,
    String? accessToken,
    required bool includeAuth,
    required String url,
    required String method,
    Object? data,
    bool bypassMirror = false,
  }) {
    final headers = <String, dynamic>{...bangumiHTTPHeader};
    final bangumiSyncEnable =
        GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
    final token = (accessToken ??
            GStorage.getSetting<String>(SettingsKeys.bangumiAccessToken))
        .trim();
    if (includeAuth &&
        (requiresAuth || bangumiSyncEnable) &&
        token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    if (_shouldSignProtectedMirrorRequest(
      url,
      method,
      bypassMirror: bypassMirror,
    )) {
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final body = data == null ? '' : jsonEncode(data);
      headers['X-AppId'] = bangumiMirrorCredentials['id'];
      headers['X-Timestamp'] = timestamp;
      headers['X-Signature'] = generateBangumiMirrorSearchSignature(
        method: method,
        path: Uri.parse(url).path,
        body: body,
        timestamp: timestamp,
      );
    }
    return headers;
  }

  bool _shouldSignProtectedMirrorRequest(
    String url,
    String method, {
    required bool bypassMirror,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }

    final isKazumiMirror =
        uri.host == Uri.parse(ApiEndpoints.bangumiMirrorDomain).host;
    // Explicit requests to the Kazumi mirror must be signed even when the
    // mirror switch is off. `bypassMirror` only disables automatic URL
    // rewriting; it must not disable authentication for an explicit mirror
    // URL.
    if (!isKazumiMirror && bypassMirror) {
      return false;
    }

    final enableBangumiProxy =
        GStorage.getSetting(SettingsKeys.enableBangumiProxy);
    if (!isKazumiMirror && !enableBangumiProxy) {
      return false;
    }

    final path = uri.path;
    if (method == 'POST' && path == '/v0/search/subjects') {
      return true;
    }
    if (method != 'GET') {
      return false;
    }
    return path.startsWith('/p1/subjects/') && path.endsWith('/comments') ||
        path.startsWith('/p1/episodes/') && path.endsWith('/comments') ||
        path.startsWith('/p1/characters/') && path.endsWith('/comments');
  }
}
