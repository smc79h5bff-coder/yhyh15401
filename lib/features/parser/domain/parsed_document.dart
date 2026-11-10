import '../../preprocessing/domain/encoding_type.dart';
import 'document_format.dart';

/// Result of parsing a source file into a list of paragraphs + metadata.
///
/// Paragraphs are preserved per PRD §2 Module 2 so line-level diff has
/// meaningful boundaries. `encoding` is the *original* detected encoding —
/// preprocessing converts internal storage to UTF-16, but export must write
/// back using this encoding.
class ParsedDocument {
  const ParsedDocument({
    required this.fileName,
    required this.format,
    required this.encoding,
    required List<String> paragraphs,
    required this.byteSize,
    String? plainText,
  })  : _paragraphs = paragraphs,
        _plainText = plainText;

  final String fileName;
  final DocumentFormat format;
  final EncodingType encoding;
  final int byteSize;
  final List<String> _paragraphs;
  final String? _plainText;

  /// 对比/显示用的全文。
  ///
  /// TXT 入口直接传入已规范化的全文（[TxtParser] 一次扫描得出），避免
  /// 「全文切成几万行 → 再 join 回全文」的往返；docx 等入口仍按
  /// paragraphs 现拼，保持原来的语义。
  String get plainText => _plainText ?? _paragraphs.join('\n');

  /// 段列表。TXT 入口的全文本来就是「非空行用 \n 连接」，
  /// 按需切一次即可，不需要再跑正则和过滤。
  List<String> get paragraphs => _plainText == null
      ? _paragraphs
      : (_plainText!.isEmpty ? const <String>[] : _plainText!.split('\n'));

  int get charCount => plainText.length;
}
