part of re_editor;

abstract class IParagraph {

  double get width;
  double get height;
  double get preferredLineHeight;

  /// [vendored patch] 首行基线相对段落顶部的距离（逻辑像素）。
  ///
  /// 用途：让外部的指示器（行号栏）把数字的基线对齐到正文首行的基线。
  ///
  /// 为什么需要这个：段落行高虽然是统一的 [preferredLineHeight]，但基线位置
  /// 取决于该行实际字符的最大 ascent。中文走系统 CJK 回退字体，ascent 比例
  /// 比 monospace 大，基线比纯数字行低。用「估算行高 + 垂直居中」去对齐行号，
  /// 必然差几像素；直接读真实 baseline 才能对齐。
  double get firstLineBaseline;

  bool get trucated;
  int get length;
  int get lineCount;

  void draw(Canvas canvas, Offset offset);

  TextPosition getPosition(Offset offset);

  TextRange getWord(Offset offset);
  
  InlineSpan? getSpanForPosition(TextPosition position);

  TextRange getRangeForSpan(InlineSpan span);

  TextRange getLineBoundary(TextPosition position);

  Offset? getOffset(TextPosition position);

  List<Rect> getRangeRects(TextRange range);

}