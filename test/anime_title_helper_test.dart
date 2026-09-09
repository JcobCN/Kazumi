import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/utils/anime_title_helper.dart';

void main() {
  group('AnimeTitleHelper.generatePunctuationVariants', () {
    test('空格分隔转冒号、连写、短横线', () {
      final variants =
          AnimeTitleHelper.generatePunctuationVariants('赌博默示录 破戒录篇');

      expect(variants, contains('赌博默示录：破戒录篇'));
      expect(variants, contains('赌博默示录: 破戒录篇'));
      expect(variants, contains('赌博默示录:破戒录篇'));
      expect(variants, contains('赌博默示录破戒录篇'));
      expect(variants, contains('赌博默示录-破戒录篇'));
    });

    test('全角冒号转空格、半角冒号、连写', () {
      final variants =
          AnimeTitleHelper.generatePunctuationVariants('赌博默示录：破戒录篇');

      expect(variants, contains('赌博默示录 破戒录篇'));
      expect(variants, contains('赌博默示录:破戒录篇'));
      expect(variants, contains('赌博默示录破戒录篇'));
    });

    test('半角冒号转空格、全角冒号、连写', () {
      final variants =
          AnimeTitleHelper.generatePunctuationVariants('赌博默示录: 破戒录篇');

      expect(variants, contains('赌博默示录 破戒录篇'));
      expect(variants, contains('赌博默示录：破戒录篇'));
      expect(variants, contains('赌博默示录破戒录篇'));
    });

    test('破折号与括号格式解析', () {
      final dashVariants =
          AnimeTitleHelper.generatePunctuationVariants('赌博默示录 - 破戒录篇');
      expect(dashVariants, contains('赌博默示录 破戒录篇'));
      expect(dashVariants, contains('赌博默示录：破戒录篇'));

      final bracketVariants =
          AnimeTitleHelper.generatePunctuationVariants('赌博默示录(破戒录篇)');
      expect(bracketVariants, contains('赌博默示录 破戒录篇'));
      expect(bracketVariants, contains('赌博默示录：破戒录篇'));
    });
  });

  group('AnimeTitleHelper.generateSeasonVariants', () {
    test('中文季数转阿拉伯数字及 Season/S', () {
      final variants =
          AnimeTitleHelper.generateSeasonVariants('赌博默示录 第二季');

      expect(variants, contains('赌博默示录 第2季'));
      expect(variants, contains('赌博默示录 Season 2'));
      expect(variants, contains('赌博默示录 S2'));
    });

    test('阿拉伯数字季数转中文季数及 Season/S', () {
      final variants =
          AnimeTitleHelper.generateSeasonVariants('赌博默示录 第2季');

      expect(variants, contains('赌博默示录 第二季'));
      expect(variants, contains('赌博默示录 Season 2'));
      expect(variants, contains('赌博默示录 S2'));
    });

    test('英文 Season 转中文和阿拉伯数字季数', () {
      final variants =
          AnimeTitleHelper.generateSeasonVariants('赌博默示录 Season 2');

      expect(variants, contains('赌博默示录 第二季'));
      expect(variants, contains('赌博默示录 第2季'));
    });
  });

  group('AnimeTitleHelper.extractMainTitle & extractSubtitle', () {
    test('提取带空格的标题主干与副标题', () {
      expect(AnimeTitleHelper.extractMainTitle('赌博默示录 破戒录篇'), '赌博默示录');
      expect(AnimeTitleHelper.extractSubtitle('赌博默示录 破戒录篇'), '破戒录篇');
    });

    test('提取带冒号的标题主干与副标题', () {
      expect(AnimeTitleHelper.extractMainTitle('赌博默示录：破戒录篇'), '赌博默示录');
      expect(AnimeTitleHelper.extractSubtitle('赌博默示录：破戒录篇'), '破戒录篇');
      expect(AnimeTitleHelper.extractMainTitle('赌博默示录:破戒录篇'), '赌博默示录');
    });

    test('提取带季数的标题主干', () {
      expect(AnimeTitleHelper.extractMainTitle('赌博默示录 第二季'), '赌博默示录');
      expect(AnimeTitleHelper.extractMainTitle('进击的巨人 Season 2'), '进击的巨人');
    });

    test('无副标题的单一标题返回 null', () {
      expect(AnimeTitleHelper.extractMainTitle('赌博默示录'), isNull);
      expect(AnimeTitleHelper.extractSubtitle('赌博默示录'), isNull);
    });
  });

  group('AnimeTitleHelper.generateSearchCandidates', () {
    test('对 "赌博默示录 破戒录篇" 生成精准候选词序列', () {
      final candidates = AnimeTitleHelper.generateSearchCandidates(
        title: '赌博默示录 破戒录篇',
        originalName: '逆境無頼カイジ 破戒録篇',
        aliases: ['赌博默示录 第二季', '赌博破戒录', '逆境无赖开司 破戒录篇'],
        maxCandidates: 10,
      );

      // 首选词必须为原标题
      expect(candidates.first, '赌博默示录 破戒录篇');

      // 标点变体（中文冒号、紧凑无空格等）
      expect(candidates, contains('赌博默示录：破戒录篇'));
      expect(candidates, contains('赌博默示录破戒录篇'));

      // 季数别名及变体
      expect(candidates, contains('赌博默示录 第二季'));
      expect(candidates, contains('赌博默示录 第2季'));

      // 主标题兜底
      expect(candidates, contains('赌博默示录'));

      // 保证不含空串且不重复
      expect(candidates.toSet().length, candidates.length);
      expect(candidates.every((c) => c.trim().isNotEmpty), isTrue);
    });

    test('空标题安全处理', () {
      final candidates = AnimeTitleHelper.generateSearchCandidates(title: '');
      expect(candidates, isEmpty);
    });
  });

  group('AnimeTitleHelper.rankSearchResults', () {
    test('智能置顶副标题匹配项并排斥其他季数', () {
      final items = [
        SearchItem(name: '赌博默示录 第一季', src: '/play/season1'),
        SearchItem(name: '赌博默示录 第三季', src: '/play/season3'),
        SearchItem(name: '赌博默示录', src: '/play/main'),
        SearchItem(name: '赌博默示录：破戒录篇 全集', src: '/play/season2'),
      ];

      final ranked = AnimeTitleHelper.rankSearchResults(
        items,
        targetTitle: '赌博默示录 破戒录篇',
        aliases: ['赌博默示录 第二季'],
      );

      expect(ranked.first.name, '赌博默示录：破戒录篇 全集');
      expect(ranked.first.src, '/play/season2');

      // 第一季和第三季应该被降权
      final lastTwoNames =
          ranked.sublist(ranked.length - 2).map((e) => e.name).toList();
      expect(lastTwoNames, contains('赌博默示录 第一季'));
      expect(lastTwoNames, contains('赌博默示录 第三季'));
    });
  });
}
