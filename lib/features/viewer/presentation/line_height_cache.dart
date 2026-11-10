import 'line_height_calculator.dart';

/// 行高表缓存。
///
/// 用途：同一对文件 + 同样的显示参数（宽度、字号、换行模式等），
/// 第二次打开对比页时直接读缓存，不重算。
///
/// 缓存 key 由这些参数组成：
///   - 内容指纹（两个文件的长度 + 首尾片段，避免拉全文字符串做 hash）
///   - importRevision（用户编辑后会变，自动让缓存失效）
///   - 视图模式
///   - 屏幕宽度（像素）
///   - 正文字号
///   - 是否显示行号（影响左侧栏宽度）
///   - 是否不换行
///   - 设备像素比（避免不同 DPR 设备共用）
///
/// 淘汰策略：LRU，最多保留 8 张表。
/// 内存估算：1 万行 ≈ 320KB，8 张 ≈ 2.5MB。对手机可接受。
class LineHeightCache {
  LineHeightCache._();

  static final LineHeightCache instance = LineHeightCache._();

  static const int _maxEntries = 8;

  final Map<String, LineHeightTable> _cache = <String, LineHeightTable>{};

  LineHeightTable? get(String key) {
    final v = _cache.remove(key);
    if (v != null) {
      // 重新插入到末尾，实现 LRU。
      _cache[key] = v;
    }
    return v;
  }

  void put(String key, LineHeightTable value) {
    if (_cache.containsKey(key)) {
      _cache.remove(key);
    } else if (_cache.length >= _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = value;
  }

  void clear() {
    _cache.clear();
  }

  /// 当前缓存里有几张表（调试用）。
  int get size => _cache.length;
}

/// 构造缓存 key。
///
/// [contentFingerprint] 由调用方算好，一般用"两个文件长度 + 首尾片段"拼成。
/// 不要传完整内容（太慢）。
String buildLineHeightCacheKey({
  required String contentFingerprint,
  required int importRevision,
  required String viewModeName,
  required double viewportWidth,
  required double bodyFontSize,
  required bool showLineNumbers,
  required bool noWrap,
  required double devicePixelRatio,
  required double textScaleFactor,
}) {
  final w = viewportWidth.round();
  final fs = (bodyFontSize * 10).round();
  final dpr = (devicePixelRatio * 100).round();
  // 系统字体缩放（无障碍）会改变实际行高，必须纳入 key，否则命中旧表行高错乱。
  final ts = (textScaleFactor * 1000).round();
  return 'v3|$contentFingerprint|$importRevision|$viewModeName|'
      'w$w|fs$fs|ln$showLineNumbers|nw$noWrap|dpr$dpr|ts$ts';
}

/// 从两份原始文本生成本地指纹。
///
/// 不用真 hash：太慢。用"长度 + 首尾各 32 字符"就够分辨。
/// 碰撞的后果只是缓存命中到错误的表，行高偏一点，不会崩。
String contentFingerprint(String original, String modified) {
  String fp(String s) {
    if (s.length <= 96) return s;
    // ★ 仅首尾 + 两段中段采样拼接后再取一次 hash，显著降低"同长度且首尾相同
    // 但中间不同"导致的碰撞（仍避免对整段文本做全量 hash）。
    const seg = 16;
    final third = s.length ~/ 3;
    final parts = <String>[
      s.substring(0, seg),
      s.substring(third - seg ~/ 2, third + seg ~/ 2),
      s.substring(2 * third - seg ~/ 2, 2 * third + seg ~/ 2),
      s.substring(s.length - seg),
    ];
    final sampled = parts.join('§');
    return '${s.length}|$sampled|${Object.hashAll(parts)}';
  }

  return '${fp(original)}||${fp(modified)}';
}
