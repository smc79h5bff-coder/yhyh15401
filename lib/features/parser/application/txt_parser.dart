import 'dart:typed_data';

import '../../preprocessing/application/encoding_detector.dart';
import '../../preprocessing/domain/encoding_type.dart';
import '../domain/document_format.dart';
import '../domain/parsed_document.dart';

class TxtParser {
  const TxtParser();

  Future<ParsedDocument> parse(
    String fileName,
    Uint8List bytes,
    EncodingType encoding,
  ) async {
    final decoded = await EncodingDetector.decodeChunkedAsync(bytes, encoding);
    return ParsedDocument(
      fileName: fileName,
      format: fileName.toLowerCase().endsWith('.md')
          ? DocumentFormat.markdown
          : DocumentFormat.txt,
      encoding: decoded.encoding,
      // 全文已经在 _normalizeParagraphs 里一次扫描规范化好，
      // 不再构造几万行的 paragraphs 再 join 回来。
      paragraphs: const <String>[],
      plainText: _normalizeParagraphs(decoded.text),
      byteSize: bytes.length,
    );
  }

  /// 等价于原来的
  /// `text.split(RegExp(r'\r?\n')).where((p) => p.isNotEmpty).join('\n')`，
  /// 但只扫一遍、且常见情况（纯 LF、无空行）直接返回原文、零分配。
  ///
  /// 语义必须逐字一致：\r\n 视作一个换行、丢掉完全为空的行、行与行之间
  /// 用 \n 连接；单独出现的 \r（后面没有 \n）属于行内容，要保留。
  static String _normalizeParagraphs(String text) {
    if (!text.contains('\r') &&
        !text.contains('\n\n') &&
        !text.startsWith('\n') &&
        !text.endsWith('\n')) {
      return text;
    }

    final sb = StringBuffer();
    var start = 0;
    var first = true;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) != 0x0A) continue; // 只看 \n
      var end = i;
      // \r?\n：换行前的 \r 属于分隔符，不算进行内容。
      if (end > start && text.codeUnitAt(end - 1) == 0x0D) end--;
      if (end > start) {
        if (!first) sb.write('\n');
        sb.write(text.substring(start, end));
        first = false;
      }
      start = i + 1;
    }
    if (start < text.length) {
      if (!first) sb.write('\n');
      sb.write(text.substring(start));
    }
    return sb.toString();
  }
}
