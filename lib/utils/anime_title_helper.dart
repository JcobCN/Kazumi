import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/bangumi_relation.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';

class AnimeTitleHelper {
  AnimeTitleHelper._();

  static const Map<String, String> _chineseToArabicNumber = {
    '一': '1',
    '二': '2',
    '三': '3',
    '四': '4',
    '五': '5',
    '六': '6',
    '七': '7',
    '八': '8',
    '九': '9',
    '十': '10',
  };

  static const Map<String, String> _arabicToChineseNumber = {
    '1': '一',
    '2': '二',
    '3': '三',
    '4': '四',
    '5': '五',
    '6': '六',
    '7': '七',
    '8': '八',
    '9': '九',
    '10': '十',
  };

  /// 正则匹配标题中的主标题和副标题分隔符（空格、全角冒号、半角冒号、连字符、破折号）
  static final RegExp _titleSeparatorRegExp =
      RegExp(r'[\s:：\-—_~～·/]+');

  /// 正则匹配中文季数：第[一二三四五六七八九十]季 / 期
  static final RegExp _chineseSeasonRegExp =
      RegExp(r'第([一二三四五六七八九十]+)([季期])');

  /// 正则匹配阿拉伯数字季数：第[0-9]+季 / 期
  static final RegExp _arabicSeasonRegExp =
      RegExp(r'第(\d+)([季期])');

  /// 正则匹配英文 Season / S 季数：Season 2, Season2, S2, Part 2
  static final RegExp _englishSeasonRegExp =
      RegExp(r'(?:Season|Part|\bS)\s*(\d+)', caseSensitive: false);

  /// 正则匹配括号包裹的内容
  static final RegExp _bracketContentRegExp =
      RegExp(r'[（(【\[](.*?)[）)】\]]');

  /// 提取主标题（当标题包含副标题或季数时提取主干）
  static String? extractMainTitle(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return null;

    // 1. 尝试去除括号后缀：例如 "赌博默示录(破戒录篇)" -> "赌博默示录"
    final withoutBrackets = trimmed.replaceAll(_bracketContentRegExp, ' ').trim();
    if (withoutBrackets.isNotEmpty && withoutBrackets != trimmed) {
      final parts = withoutBrackets.split(_titleSeparatorRegExp);
      if (parts.isNotEmpty && parts.first.trim().length >= 2) {
        return parts.first.trim();
      }
    }

    // 2. 尝试按分隔符分割：例如 "赌博默示录 破戒录篇" -> "赌博默示录"
    final match = _titleSeparatorRegExp.firstMatch(trimmed);
    if (match != null && match.start >= 2) {
      final mainPart = trimmed.substring(0, match.start).trim();
      if (mainPart.isNotEmpty) {
        return mainPart;
      }
    }

    // 3. 尝试去除末尾的季数：例如 "赌博默示录第二季" -> "赌博默示录"
    final seasonMatch = RegExp(r'(?:第[一二三四五六七八九十\d]+[季期]|(?:Season|Part|\bS)\s*\d+)$',
            caseSensitive: false)
        .firstMatch(trimmed);
    if (seasonMatch != null && seasonMatch.start >= 2) {
      final mainPart = trimmed.substring(0, seasonMatch.start).trim();
      if (mainPart.isNotEmpty) {
        return mainPart;
      }
    }

    return null;
  }

  /// 提取副标题/篇章名（例如 "赌博默示录 破戒录篇" -> "破戒录篇"）
  static String? extractSubtitle(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return null;

    // 尝试提取括号内的副标题
    final bracketMatch = _bracketContentRegExp.firstMatch(trimmed);
    if (bracketMatch != null) {
      final content = bracketMatch.group(1)?.trim();
      if (content != null && content.isNotEmpty) {
        return content;
      }
    }

    // 尝试按分隔符提取后半部分
    final separatorMatches = _titleSeparatorRegExp.allMatches(trimmed).toList();
    if (separatorMatches.isNotEmpty) {
      final firstMatch = separatorMatches.first;
      final subPart = trimmed.substring(firstMatch.end).trim();
      if (subPart.isNotEmpty) {
        return subPart;
      }
    }

    return null;
  }

  /// 为给定标题生成标点与分隔符变体（冒号、空格、无空格紧凑、短横线）
  static List<String> generatePunctuationVariants(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return [];

    final variants = <String>[];

    // 处理括号结构：例如 "赌博默示录(破戒录篇)" -> "赌博默示录 破戒录篇", "赌博默示录：破戒录篇"
    if (_bracketContentRegExp.hasMatch(trimmed)) {
      final bracketMatch = _bracketContentRegExp.firstMatch(trimmed)!;
      final before = trimmed.substring(0, bracketMatch.start).trim();
      final inside = bracketMatch.group(1)?.trim() ?? '';
      if (before.isNotEmpty && inside.isNotEmpty) {
        variants.add('$before $inside');
        variants.add('$before：$inside');
        variants.add('$before: $inside');
        variants.add('$before:$inside');
        variants.add('$before$inside');
      }
    }

    // 处理带空格情况：例如 "赌博默示录 破戒录篇"
    if (trimmed.contains(' ')) {
      variants.add(trimmed.replaceAll(RegExp(r'\s+'), '：'));
      variants.add(trimmed.replaceAll(RegExp(r'\s+'), ': '));
      variants.add(trimmed.replaceAll(RegExp(r'\s+'), ':'));
      variants.add(trimmed.replaceAll(RegExp(r'\s+'), ''));
      variants.add(trimmed.replaceAll(RegExp(r'\s+'), '-'));
    }

    // 处理中文冒号情况：例如 "赌博默示录：破戒录篇"
    if (trimmed.contains('：')) {
      variants.add(trimmed.replaceAll('：', ' '));
      variants.add(trimmed.replaceAll('：', ': '));
      variants.add(trimmed.replaceAll('：', ':'));
      variants.add(trimmed.replaceAll('：', ''));
      variants.add(trimmed.replaceAll('：', '-'));
    }

    // 处理半角冒号情况：例如 "赌博默示录: 破戒录篇" 或 "赌博默示录:破戒录篇"
    if (trimmed.contains(':')) {
      variants.add(trimmed.replaceAll(RegExp(r':\s*'), ' '));
      variants.add(trimmed.replaceAll(RegExp(r':\s*'), '：'));
      variants.add(trimmed.replaceAll(RegExp(r':\s*'), ''));
      variants.add(trimmed.replaceAll(RegExp(r':\s*'), '-'));
    }

    // 处理短横线/破折号情况：例如 "赌博默示录 - 破戒录篇"
    if (trimmed.contains('-') || trimmed.contains('——') || trimmed.contains('—')) {
      variants.add(trimmed.replaceAll(RegExp(r'\s*[-———]\s*'), ' '));
      variants.add(trimmed.replaceAll(RegExp(r'\s*[-———]\s*'), '：'));
      variants.add(trimmed.replaceAll(RegExp(r'\s*[-———]\s*'), ':'));
      variants.add(trimmed.replaceAll(RegExp(r'\s*[-———]\s*'), ''));
    }

    return variants;
  }

  /// 为包含季数/期数的标题生成季数表达互转变体（中文数字 <-> 阿拉伯数字 <-> Season/S）
  static List<String> generateSeasonVariants(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return [];

    final variants = <String>[];

    // 1. 中文季数变体：例如 "赌博默示录 第二季" -> "第2季", "Season 2", "S2"
    for (final match in _chineseSeasonRegExp.allMatches(trimmed)) {
      final chineseNum = match.group(1);
      final suffix = match.group(2); // "季" 或 "期"
      final arabicNum = _chineseToArabicNumber[chineseNum];
      if (arabicNum != null) {
        variants.add(trimmed.replaceRange(
          match.start,
          match.end,
          '第$arabicNum$suffix',
        ));
        variants.add(trimmed.replaceRange(
          match.start,
          match.end,
          'Season $arabicNum',
        ));
        variants.add(trimmed.replaceRange(
          match.start,
          match.end,
          'S$arabicNum',
        ));
      }
    }

    // 2. 阿拉伯数字季数变体：例如 "赌博默示录 第2季" -> "第二季", "Season 2", "S2"
    for (final match in _arabicSeasonRegExp.allMatches(trimmed)) {
      final arabicNum = match.group(1);
      final suffix = match.group(2);
      final chineseNum = _arabicToChineseNumber[arabicNum];
      if (chineseNum != null) {
        variants.add(trimmed.replaceRange(
          match.start,
          match.end,
          '第$chineseNum$suffix',
        ));
      }
      variants.add(trimmed.replaceRange(
        match.start,
        match.end,
        'Season $arabicNum',
      ));
      variants.add(trimmed.replaceRange(
        match.start,
        match.end,
        'S$arabicNum',
      ));
    }

    // 3. 英文 Season/S 变体：例如 "赌博默示录 Season 2" -> "第二季", "第2季"
    for (final match in _englishSeasonRegExp.allMatches(trimmed)) {
      final arabicNum = match.group(1);
      if (arabicNum != null) {
        final chineseNum = _arabicToChineseNumber[arabicNum];
        if (chineseNum != null) {
          variants.add(trimmed.replaceRange(
            match.start,
            match.end,
            '第$chineseNum季',
          ));
        }
        variants.add(trimmed.replaceRange(
          match.start,
          match.end,
          '第$arabicNum季',
        ));
      }
    }

    return variants;
  }

  /// 生成动画搜索的候选词序列（带优先级、去重）
  ///
  /// [title]: 中文名或主标题（如 "赌博默示录 破戒录篇"）
  /// [originalName]: 日文原名（如 "逆境無頼カイジ 破戒録篇"）
  /// [aliases]: Bangumi 的条目别名列表（来自 infobox）
  /// [maxCandidates]: 允许返回的最大候选词数量（默认 10）
  static List<String> generateSearchCandidates({
    required String title,
    String? originalName,
    List<String> aliases = const [],
    int maxCandidates = 10,
  }) {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty) return [];

    final rawCandidates = <String>[];

    // 1. 原始首选词
    rawCandidates.add(trimmedTitle);

    // 预先提取各个维度的变体，以便按多维度交叉排列（解决单一类型耗尽重试名额的问题）
    final punctVariants = generatePunctuationVariants(trimmedTitle);

    // 标点变体拆分：全角冒号、紧凑无符号、半角冒号、其他
    String? fullColonVariant;
    String? compactVariant;
    String? halfColonVariant;
    final otherPunctVariants = <String>[];

    for (final v in punctVariants) {
      if (v.contains('：') && fullColonVariant == null) {
        fullColonVariant = v;
      } else if (!v.contains(' ') &&
          !v.contains('-') &&
          !v.contains(':') &&
          !v.contains('：') &&
          compactVariant == null) {
        compactVariant = v;
      } else if (v.contains(':') &&
          !v.contains(' ') &&
          halfColonVariant == null) {
        halfColonVariant = v;
      } else {
        otherPunctVariants.add(v);
      }
    }

    // 季数别名及变体分析
    final directSeasonAliases = <String>[];
    final derivedSeasonAliases = <String>[];
    final otherAliases = <String>[];

    // 先检查原标题自身是否有季数变体
    final selfSeasonVariants = generateSeasonVariants(trimmedTitle);

    // 再检查别名列表
    for (final alias in aliases) {
      final trimmedAlias = alias.trim();
      if (trimmedAlias.isEmpty || trimmedAlias == trimmedTitle) continue;

      final hasSeason = _chineseSeasonRegExp.hasMatch(trimmedAlias) ||
          _arabicSeasonRegExp.hasMatch(trimmedAlias) ||
          _englishSeasonRegExp.hasMatch(trimmedAlias);

      if (hasSeason) {
        directSeasonAliases.add(trimmedAlias);
        final variants = generateSeasonVariants(trimmedAlias);
        for (final v in variants) {
          if (!v.toLowerCase().contains('season') &&
              !v.toLowerCase().contains('s')) {
            directSeasonAliases.add(v);
          } else {
            derivedSeasonAliases.add(v);
          }
        }
      } else {
        otherAliases.add(trimmedAlias);
      }
    }

    // 主标题提取
    final mainTitle = extractMainTitle(trimmedTitle);

    // 2. 多维度交叉按优先级加入候选词池：
    // (A) 最核心的全角冒号变体（如 "赌博默示录：破戒录篇"）
    if (fullColonVariant != null) rawCandidates.add(fullColonVariant);

    // (B) 最核心的季数变体（如别名或自身中的 "第二季"、"第2季"）
    if (directSeasonAliases.isNotEmpty) {
      rawCandidates.add(directSeasonAliases.first);
    } else if (selfSeasonVariants.isNotEmpty) {
      rawCandidates.add(selfSeasonVariants.first);
    }

    // (C) 紧凑无空格变体（如 "赌博默示录破戒录篇"）
    if (compactVariant != null) rawCandidates.add(compactVariant);

    // (D) 主标题回退（如 "赌博默示录"），解决很多只收录主系列或副标题未命中的源
    if (mainTitle != null &&
        mainTitle.length >= 2 &&
        mainTitle != trimmedTitle) {
      rawCandidates.add(mainTitle);
    }

    // (E) 其余直接季数变体（如 "第2季"）
    if (directSeasonAliases.length > 1) {
      rawCandidates.addAll(directSeasonAliases.skip(1));
    }
    if (selfSeasonVariants.length > 1) {
      rawCandidates.addAll(selfSeasonVariants.skip(1));
    }

    // (F) 半角紧凑冒号变体（如 "赌博默示录:破戒录篇"）
    if (halfColonVariant != null) rawCandidates.add(halfColonVariant);

    // (G) 英文季数（Season 2 等）与其它别名
    rawCandidates.addAll(derivedSeasonAliases);
    rawCandidates.addAll(otherAliases);

    // (H) 其余标点符号变体（破折号、空格冒号等）
    rawCandidates.addAll(otherPunctVariants);

    // (I) 日文原名（如 "逆境無頼カイジ 破戒録篇"）
    if (originalName != null) {
      final trimmedOriginal = originalName.trim();
      if (trimmedOriginal.isNotEmpty && trimmedOriginal != trimmedTitle) {
        rawCandidates.add(trimmedOriginal);
        rawCandidates.addAll(generatePunctuationVariants(trimmedOriginal));
      }
    }

    // 去重与规范化（保留顺序）
    final result = <String>[];
    final seen = <String>{};

    for (final candidate in rawCandidates) {
      final clean = candidate.trim();
      if (clean.isEmpty) continue;
      final key = clean.toLowerCase();
      if (seen.add(key)) {
        result.add(clean);
        if (result.length >= maxCandidates) break;
      }
    }

    return result;
  }

  /// 搜索结果相关度排序：
  /// 当使用变体（如冒号、无空格、别名或主标题兜底）搜出结果时，
  /// 将最符合目标标题/季数/副标题的结果排在最前面。
  static List<SearchItem> rankSearchResults(
    List<SearchItem> items, {
    required String targetTitle,
    List<String> aliases = const [],
  }) {
    if (items.length <= 1) return items;

    final normalizedTarget = _simplifyForComparison(targetTitle);
    final subtitle = extractSubtitle(targetTitle);
    final normalizedSubtitle =
        subtitle != null ? _simplifyForComparison(subtitle) : null;

    // 提取目标标题或别名中的季数数字（如 2）
    final targetSeasonNumber = _extractSeasonNumber(targetTitle) ??
        aliases
            .map(_extractSeasonNumber)
            .where((num) => num != null)
            .firstOrNull;

    final scoredItems = <({SearchItem item, int score, int originalIndex})>[];

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final itemName = item.name.trim();
      final normalizedItemName = _simplifyForComparison(itemName);
      int score = 0;

      // 1. 完全一致（忽略标点与大小写后）
      if (normalizedItemName == normalizedTarget) {
        score += 200;
      } else if (normalizedItemName.contains(normalizedTarget)) {
        score += 150;
      }

      // 2. 匹配副标题核心关键词（例如 "破戒录"、"破戒录篇"）
      if (normalizedSubtitle != null && normalizedSubtitle.isNotEmpty) {
        if (normalizedItemName.contains(normalizedSubtitle)) {
          score += 120;
        } else {
          // 尝试更短的子串（去除末尾的 "篇"、"章"、"季"）
          final trimmedSub = normalizedSubtitle
              .replaceAll(RegExp(r'[篇章季期编]+$'), '')
              .trim();
          if (trimmedSub.length >= 2 && normalizedItemName.contains(trimmedSub)) {
            score += 100;
          }
        }
      }

      // 3. 匹配别名
      for (final alias in aliases) {
        final cleanAlias = _simplifyForComparison(alias);
        if (cleanAlias.isEmpty) continue;
        if (normalizedItemName == cleanAlias) {
          score += 110;
          break;
        } else if (normalizedItemName.contains(cleanAlias)) {
          score += 80;
          break;
        }
      }

      // 4. 季数匹配加分与互斥减分
      final itemSeasonNumber = _extractSeasonNumber(itemName);
      if (targetSeasonNumber != null) {
        if (itemSeasonNumber == targetSeasonNumber) {
          score += 90;
        } else if (itemSeasonNumber != null &&
            itemSeasonNumber != targetSeasonNumber) {
          // 目标是第二季，但结果明确是第一季/第三季等，扣分！
          score -= 80;
        }
      }

      scoredItems.add((item: item, score: score, originalIndex: i));
    }

    // 稳定排序：得分高排前面，相同得分保持原相对顺序
    scoredItems.sort((a, b) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) return scoreCompare;
      return a.originalIndex.compareTo(b.originalIndex);
    });

    return scoredItems.map((e) => e.item).toList();
  }

  /// 常见非剧集标题的噪点后缀或前缀（如分辨率、完结状态、语言、来源等）
  static final RegExp _noiseTagRegExp = RegExp(
    r'(?:\[|\(|【|\s)*(?:1080[pP]|720[pP]|4[kK]|HD|BD|完结|全集|全\d+[话集]|超清|高清|国语|日语|中字|中配|正片)+(?:\]|\)|】|\s)*',
  );

  /// 清除标题中的视频规格与状态噪点（如 "1080P"、"[完结]"、"全集" 等）
  static String cleanNoise(String title) {
    var cleaned = title.replaceAll(_noiseTagRegExp, ' ').trim();
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned.isEmpty ? title.trim() : cleaned;
  }

  /// 提取标题中的季数阿拉伯数字（公开方法）
  static int? extractSeasonNumber(String title) => _extractSeasonNumber(title);

  /// 根据当前播放/选中的视频源标题与 Bangumi 条目名，解析出最完整且规范的下载项标题。
  /// 解决用户通过主条目（如 "赌博默示录" 或 "xxx"）进入，实际观看并下载的是 "赌博默示录 破戒录篇" 或 "xxx 第二季"
  /// 时，下载列表仅显示主条目名称而缺少副标题或季度信息的问题。
  static String resolveDownloadTitle({
    required String currentTitle,
    required String bangumiName,
  }) {
    final cleanCurrent = cleanNoise(currentTitle);
    final cleanBangumi = bangumiName.trim();

    if (cleanCurrent.isEmpty) return cleanBangumi;
    if (cleanBangumi.isEmpty) return cleanCurrent;

    final simplifiedCurrent = _simplifyForComparison(cleanCurrent);
    final simplifiedBangumi = _simplifyForComparison(cleanBangumi);

    // 1. 如果当前标题与 Bangumi 名完全一致，直接返回
    if (simplifiedCurrent == simplifiedBangumi) {
      return cleanBangumi;
    }

    // 2. 如果当前标题包含了 Bangumi 名（例如 "赌博默示录 破戒录篇" 包含 "赌博默示录"），
    // 优先采用带有副标题/季度的当前标题
    if (simplifiedCurrent.contains(simplifiedBangumi)) {
      return cleanCurrent;
    }

    // 3. 检查当前标题是否仅为季数或纯副标题表达（如 "第二季"、"第2季"、"破戒录篇"）
    final isSeasonOnly = _chineseSeasonRegExp.hasMatch(cleanCurrent) ||
        _arabicSeasonRegExp.hasMatch(cleanCurrent) ||
        _englishSeasonRegExp.hasMatch(cleanCurrent);

    final mainTitle = extractMainTitle(cleanCurrent);
    if (isSeasonOnly || (mainTitle == null && cleanCurrent.length <= 8)) {
      return '$cleanBangumi $cleanCurrent';
    }

    // 4. 如果当前标题有副标题，提取并追加到主条目名
    final subtitle = extractSubtitle(cleanCurrent);
    if (subtitle != null && subtitle.isNotEmpty) {
      final simplifiedSub = _simplifyForComparison(subtitle);
      if (!simplifiedBangumi.contains(simplifiedSub)) {
        return '$cleanBangumi $subtitle';
      }
    }

    // 5. 兜底返回去噪后的当前播放标题
    return cleanCurrent;
  }

  /// 从 Bangumi 关联条目列表（前传/续集等）中寻找与当前选中的视频源标题匹配的条目。
  /// 例如：用户在 "赌博默示录" (ID: 2145) 的选源弹窗中点击了 "赌博默示录 破戒录篇"，
  /// 算法将从关联列表中匹配到续集 "逆境無頼カイジ 破戒録篇" (ID: 10972)，从而为播放和下载关联正确的季数元数据与独立 ID。
  static BangumiItem? findMatchingRelation({
    required String searchTitle,
    required List<BangumiRelation> relations,
  }) {
    if (relations.isEmpty) return null;

    final cleanTitle = cleanNoise(searchTitle);
    final simplifiedTitle = _simplifyForComparison(cleanTitle);
    final targetSeason = extractSeasonNumber(cleanTitle);
    final targetSubtitle = extractSubtitle(cleanTitle);
    final simplifiedSubtitle = targetSubtitle != null
        ? _simplifyForComparison(targetSubtitle)
        : null;

    for (final rel in relations) {
      final item = rel.bangumiItem;
      final simplifiedName = _simplifyForComparison(item.name);
      final simplifiedNameCn = _simplifyForComparison(item.nameCn);

      // (A) 完全或包含匹配
      if (simplifiedTitle == simplifiedNameCn ||
          simplifiedTitle == simplifiedName ||
          (simplifiedTitle.length >= 4 &&
              (simplifiedNameCn.contains(simplifiedTitle) ||
                  simplifiedTitle.contains(simplifiedNameCn)))) {
        return item;
      }

      // (B) 别名匹配
      for (final alias in item.alias) {
        final simplifiedAlias = _simplifyForComparison(alias);
        if (simplifiedAlias.isEmpty) continue;
        if (simplifiedTitle == simplifiedAlias ||
            simplifiedTitle.contains(simplifiedAlias)) {
          return item;
        }
      }

      // (C) 季数匹配（例如 relation 是 "续集"，且 searchTitle 是 "第二季"）
      if (targetSeason != null) {
        final relSeason = extractSeasonNumber(item.nameCn) ??
            extractSeasonNumber(item.name) ??
            (rel.relation == '续集' ? 2 : null);
        if (relSeason == targetSeason) {
          return item;
        }
      }

      // (D) 副标题匹配（例如 "破戒录篇"）
      if (simplifiedSubtitle != null && simplifiedSubtitle.length >= 2) {
        if (simplifiedNameCn.contains(simplifiedSubtitle) ||
            simplifiedName.contains(simplifiedSubtitle)) {
          return item;
        }
      }
    }

    return null;
  }

  /// 为播放页与下载流程解析目标 BangumiItem：
  /// 若选中的视频源标题指向关联季度（如破戒录篇/第二季），则优先关联正确的关联条目；
  /// 若无关联条目，则更新条目展示名为包含季度/副标题的完整标题，避免元数据丢失。
  static BangumiItem resolvePlaybackBangumiItem({
    required BangumiItem currentBangumiItem,
    required List<BangumiRelation> relations,
    required String searchTitle,
  }) {
    final matchedRelation = findMatchingRelation(
      searchTitle: searchTitle,
      relations: relations,
    );

    if (matchedRelation != null) {
      return matchedRelation;
    }

    final resolvedTitle = resolveDownloadTitle(
      currentTitle: searchTitle,
      bangumiName: currentBangumiItem.nameCn.isNotEmpty
          ? currentBangumiItem.nameCn
          : currentBangumiItem.name,
    );

    if (resolvedTitle != currentBangumiItem.nameCn &&
        resolvedTitle.isNotEmpty) {
      return currentBangumiItem.copyWith(nameCn: resolvedTitle);
    }

    return currentBangumiItem;
  }

  /// 提取标题中的季数阿拉伯数字（如 "第二季" -> 2, "第2季" -> 2, "Season 2" -> 2）
  static int? _extractSeasonNumber(String title) {
    final chineseMatch = _chineseSeasonRegExp.firstMatch(title);
    if (chineseMatch != null) {
      final numStr = _chineseToArabicNumber[chineseMatch.group(1)];
      if (numStr != null) return int.tryParse(numStr);
    }
    final arabicMatch = _arabicSeasonRegExp.firstMatch(title);
    if (arabicMatch != null) {
      return int.tryParse(arabicMatch.group(1) ?? '');
    }
    final englishMatch = _englishSeasonRegExp.firstMatch(title);
    if (englishMatch != null) {
      return int.tryParse(englishMatch.group(1) ?? '');
    }
    return null;
  }

  /// 简化字符串用于模糊比对（去除所有标点、空白，转小写）
  static String _simplifyForComparison(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[\s:：\-—_~～·/!！?？(（)）[【\]】]+'), '');
  }
}
