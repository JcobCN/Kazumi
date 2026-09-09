import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/utils/anime_title_helper.dart';
import 'package:kazumi/utils/async_session.dart';

class PluginSearchService {
  PluginSearchService({
    required this.infoController,
    required this.pluginsController,
  });

  final InfoController infoController;
  final PluginsController pluginsController;
  final RuleCancelToken _cancelToken = RuleCancelToken();

  /// Per-plugin sessions so a replacement query (alias/manual search)
  /// invalidates the write-back of the still-running previous one.
  final Map<String, AsyncSessionOwner> _querySessions = {};

  /// Records the actual keyword that produced search results for each plugin.
  final Map<String, String> _matchedKeywords = {};

  bool _isCancelled = false;

  /// Returns the keyword that produced results for [pluginName], if any.
  String? getMatchedKeyword(String pluginName) => _matchedKeywords[pluginName];

  Future<void> querySource(String keyword, String pluginName) async {
    await querySourceWithCandidates([keyword], pluginName);
  }

  Future<void> querySourceWithCandidates(
    List<String> candidates,
    String pluginName,
  ) async {
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name == pluginName) {
        infoController.pluginSearchResponseList.removeWhere(
          (response) => response.pluginName == pluginName,
        );
        infoController.pluginSearchStatus[pluginName] =
            PluginSearchStatus.pending;
        _matchedKeywords.remove(pluginName);
        await _queryPluginWithCandidates(plugin, candidates);
        return;
      }
    }
  }

  /// Publishes the result page harvested by the captcha webview, skipping
  /// one network round trip. Returns false when the HTML does not parse
  /// into results; callers should fall back to [querySource].
  bool applyHarvestedSearchResult(String pluginName, String html) {
    if (_isCancelled) return false;
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name != pluginName) continue;
      final result = plugin.parseHarvestedSearch(html);
      if (result == null) return false;
      infoController.pluginSearchResponseList.removeWhere(
        (response) => response.pluginName == pluginName,
      );
      infoController.pluginSearchStatus[pluginName] =
          PluginSearchStatus.success;
      pluginsController.validityTracker.markSearchValid(pluginName);
      infoController.pluginSearchResponseList.add(result);
      return true;
    }
    return false;
  }

  Future<void> queryAllSource(String keyword) async {
    await queryAllSourceWithCandidates([keyword]);
  }

  Future<void> queryAllSourceWithCandidates(List<String> candidates) async {
    infoController.pluginSearchResponseList.clear();
    infoController.pluginSearchStatus.clear();
    _matchedKeywords.clear();

    final plugins = List<Plugin>.of(pluginsController.pluginList);
    for (final plugin in plugins) {
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.pending;
    }
    await Future.wait(
      plugins.map((plugin) => _queryPluginWithCandidates(plugin, candidates)),
    );
  }

  Future<void> _queryPluginWithCandidates(
    Plugin plugin,
    List<String> candidates,
  ) async {
    if (_isCancelled) return;
    final session = _querySessions
        .putIfAbsent(plugin.name, AsyncSessionOwner.new)
        .begin();

    final validCandidates = candidates
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toSet()
        .take(6)
        .toList();

    if (validCandidates.isEmpty) {
      if (_isCancelled || session.isStale) return;
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.noResult;
      return;
    }

    final primaryKeyword = validCandidates.first;

    for (var i = 0; i < validCandidates.length; i++) {
      final keyword = validCandidates[i];
      if (_isCancelled || session.isStale) return;

      try {
        final result = await plugin.queryBangumi(
          keyword,
          shouldRethrow: true,
          cancelToken: _cancelToken,
        );
        if (_isCancelled || session.isStale) return;

        if (result.data.isNotEmpty) {
          final rankedData = AnimeTitleHelper.rankSearchResults(
            result.data,
            targetTitle: primaryKeyword,
            aliases: validCandidates,
          );
          final finalResult = PluginSearchResponse(
            pluginName: plugin.name,
            data: rankedData,
          );
          _matchedKeywords[plugin.name] = keyword;
          infoController.pluginSearchStatus[plugin.name] =
              PluginSearchStatus.success;
          pluginsController.validityTracker.markSearchValid(plugin.name);
          infoController.pluginSearchResponseList.add(finalResult);
          return;
        }
      } on NoResultException {
        // 当前候选词无结果，继续尝试下一个候选词变体
        continue;
      } catch (error) {
        if (_isCancelled || session.isStale) return;
        _handleSearchError(plugin, error);
        return;
      }
    }

    // 所有候选词变体均未找到结果
    if (_isCancelled || session.isStale) return;
    KazumiLogger().i(
      'PluginSearchService: no results for ${plugin.name} after trying ${validCandidates.length} candidate(s)',
    );
    infoController.pluginSearchStatus[plugin.name] = PluginSearchStatus.noResult;
  }

  void _handleSearchError(Plugin plugin, Object error) {
    if (error is CaptchaRequiredException) {
      KazumiLogger().i(
        'PluginSearchService: captcha required for ${error.pluginName}',
      );
      infoController.pluginSearchStatus[error.pluginName] =
          PluginSearchStatus.captcha;
      return;
    }
    if (error is NoResultException) {
      KazumiLogger().i(
        'PluginSearchService: no results for ${error.pluginName}',
      );
      infoController.pluginSearchStatus[error.pluginName] =
          PluginSearchStatus.noResult;
      return;
    }
    final name = error is SearchErrorException ? error.pluginName : plugin.name;
    KazumiLogger().w('PluginSearchService: search error for $name');
    infoController.pluginSearchStatus[name] = PluginSearchStatus.error;
  }

  void cancel() {
    _isCancelled = true;
    _cancelToken.cancel();
  }
}
