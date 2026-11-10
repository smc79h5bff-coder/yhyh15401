# 本包的本地改动

来源：https://github.com/reqable/re-editor  v0.10.0
只保留 `lib/`、`pubspec.yaml`、`LICENSE`、`CHANGELOG.md`、`README.md`。

## 补丁 1：选区变化不再触发整屏段落重排

文件：`lib/src/_code_field.dart`，`_CodeFieldRender.selection` 的 setter

```diff
   set selection(CodeLineSelection value) {
     if (_selection == value) {
       return;
     }
     _selection = value;
     _backgroundRender.find<_CodeCursorLinePainter>().selection = value;
     _backgroundRender.find<_CodeFieldSelectionPainter>().selection = value;
     _foregroundRender.find<_CodeFieldCursorPainter>().position = value.extent;
     if (kIsAndroid || kIsIOS) {
       _foregroundRender.find<_CodeFieldCursorPainter>().willDraw = _selection.isCollapsed;
     }
-    markNeedsLayout();
+    markNeedsPaint();
   }
```

为什么：`markNeedsLayout()` 会让 `performLayout` 走
`_updateDisplayRenderParagraphs`，把可见的一屏段落全部清空重建，每行一次
`TextPainter.layout()`（开了自动换行还要重新折行）。拖动选区手柄、点正文
定位、长按选词时，每次手指移动都付一次 10~30ms，直接掉帧。

选区不参与任何布局计算：段落内容、视口高度、`maxScrollExtent` 只跟文字内容
和滚动位置有关；选区矩形、光标、选区手柄的位置都在 `paint()` 里算
（`_updateSelectionExtentsVisibility` 就在 paint 中）。所以改成
`markNeedsPaint()` 不会让光标或手柄失效。

## 补丁 2：跳回上方不再逐行回扫（大文件跳开头会卡死 / 闪退）

文件：`lib/src/_code_field.dart`，`_updateDisplayRenderParagraphs` 里
`target < _displayParagraphs.first.top` 的分支，以及新增常量 `_kMaxBackwardScan`。

原实现从当前首行往上，一行一行 `_buildParagraph()` 建 `TextPainter` 并
`layout()`，直到累计高度够到 `target` 为止：

```dart
for (int i = _displayParagraphs.first.index - 1; i >= 0; i--) {
  final IParagraph paragraph = _buildParagraph(i, effectiveWidth); // 每行一次 layout
  ...
}
_verticalViewport.correctBy(delta);
```

从文件末尾跳回开头时，`first.index` 接近总行数：9MB / 三十万行的文件要建
三十万个 `TextPainter`，界面直接冻死到被系统杀掉（表现为"卡住然后闪退"）；
3MB 的文件则卡几秒，落在一个错的位置，再被 `correctBy(delta)` 一点点挪回去，
看起来就是"先卡住，然后一段向上滚动的动画"。

改成：

```dart
final CodeLineRenderParagraph head = _displayParagraphs.first;
int startIndex = 0;
double delta = 0;
final bool atVeryTop = target <= paddingTop;
final bool tooFarToScan = !atVeryTop &&
    (head.top - target) / _preferredLineHeight > _kMaxBackwardScan; // 400
if (atVeryTop) {
  startIndex = 0;                       // 顶到最上：第一行必然是 0
} else if (tooFarToScan) {
  final int estimated = ((target - paddingTop) / _preferredLineHeight).floor();
  startIndex = min(max(0, estimated), head.index - 1);  // 估算一步到位
} else {
  ...原逐行回扫...
}
if (startIndex > 0) {
  _verticalViewport.correctBy(delta);   // 原来无条件调用
}
```

两条快速路径分别解决「跳到开头」和「从很远的地方往回跳（拖滚动条横跨全文、
跳到靠前的目标行）」：前者是 O(1)，后者最多扫 400 行，误差由下一帧的常规
分支修正（那时距离已经很近）。

`startIndex == 0` 时不 `correctBy` 是必须的：新首行的 top 本来就是 0，没有
"上面还有多少高度没算进去"，再修正只会把视口顶飞——这曾经是"跳到开头时
先往上冲一下再回来"的原因。

## 补丁 3：查找定位从 O(命中数 × 行数) 降到 O(行数 + 命中数·log 行数)

文件：`lib/src/_code_find.dart`，`_run` 与 `_findPosition`

原实现每个命中都调两次 `_findPosition`，而它是**从第 0 行开始数**的：

```dart
static CodeLinePosition _findPosition(List<String> codeLines, int index) {
  int start = 0;
  int line = 0;
  for (; line < codeLines.length; line++) { ... }   // 永远从头走
}
```

9MB ≈ 30 万行，搜「的」这种字命中十几万处 → 2 × 15万 × 15万 次循环，
isolate 一直烧 CPU，结果永远不回来，界面卡在「搜索中」。

改成先在 isolate 里算一遍「每行起始偏移」，再用二分定位：

```dart
final List<int> lineStarts = List<int>.filled(rawCodeLines.length, 0);
{ int start = 0; for (int i = 0; i < rawCodeLines.length; i++) { ... } }
...
final CodeLinePosition start = _findPosition(lineStarts, match.start);
```

`_findPosition` 现在只接受偏移表，二分找最后一个 `start <= index` 的行。

## 补丁 4：查找请求不再堆积（内存）

文件：`lib/src/_code_find.dart`，`_updateResult` / `_startScan`

`_tasker` 是 `concurrent: 1` 且**不丢弃排队请求**，而每个 payload 都带着
整篇 `CodeLines`。大文件单次扫描要几秒，如果每敲一个字都发一个请求，
队列里会排上若干个几十 MB 的副本，直接 OOM。

改成「在跑的时候只保留最新一个 pending，等回来再补发」，另外：

- `_scanToken` 递增，超时后放行的新请求不会被打回来的旧结果清掉状态。
- `_kScanTimeoutMs`（15s）看门狗：isolate 抛错/被回收时不会把查找永久
  卡在「搜索中」。

## 补丁 5：全部替换挪到 isolate

文件：`lib/src/_code_line.dart`（`replaceAll` + 文件末尾的
`_ReplaceAllPayload` / `_ReplaceAllResult` / `_runReplaceAll` /
`_buildReplacePattern`），`lib/src/code_line.dart` 与 `lib/src/code_find.dart`
的接口签名，`lib/src/_code_find.dart` 的 `replaceAllMatches`。

原实现主线程 `text.replaceAllMapped(...)` + `newText.codeLines`，9MB 要
1~2 秒，整个界面冻住。

改动要点：

1. **接口变成异步**：`Future<bool> replaceAll(...)`、
   `Future<bool> replaceAllMatches()`。返回值表示是否真的替换了。
2. **只传基本类型过去**：`RegExp` 是 native 对象不能跨 isolate，所以传
   source + `caseSensitive/multiLine/unicode/dotAll`，在对面重建。
3. **手动拼 StringBuffer** 而不是 `replaceAllMapped`：需要同时算出光标
   之前的内容长度变化（`delta`）。`replacement` 按字面量写入，和原来
   返回字面量等价（不解析 `$1`）。
4. **拆行也在 isolate 里做**（`newText.codeLines`），回传 `CodeLines`。
5. **加了放弃条件**：等待期间正文被改动（`!identical(codeLines, snapshot.codeLines)`）
   就放弃，不覆盖用户的输入。只比 `codeLines`，光标移动不算改动。
6. **撤销仍是一条**：赋值只在 `runRevocableOp` 里做一次。
7. `replaceAllMatches` 里原来的 `preCodeLine.equals(...)` 判脏改成了用
   返回值——跨 isolate 后必然是新的对象，`equals` 会误报。

## 补丁 6：渲染层缓存 CodeLines.length（滚动/打字热路径）

文件：`lib/src/_code_field.dart`，`_CodeFieldRender`

`CodeLines.length` 是 `segments.fold`（O(段数)），9MB ≈ 30 万行 ≈ 1172 个
segment。`_buildDisplayRenderParagraphs` 的循环里每一行判断一次
`i < _codes.length`，`_updateDisplayRenderParagraphs` 里也多次读
`_codes.length`，滚动/打字每次都付一遍遍历。

改成在 `_CodeFieldRender` 加一个 `_codesLength` 字段，构造和 `set codes`
时各算一次，热路径全部改读 `_codesLength`。

> 注意：`_codes[i]`（operator []）仍是 O(段数) 线性定位，这是更深一层的
> 架构问题（copy-on-write / 索引表），属于高风险改动，本次未做。

## 补丁 7（应用层）：行数缓存 + 长行兜底

文件：`lib/features/file_browser/presentation/single_file_editor_screen.dart`

1. **行数缓存**：`_SelectableLineNumber` 每次滚动/打字都重建，原来每次
   都调 `controller.lineCount` 去 fold 遍历所有 segment。现在页面维护
   `_cachedLineCount`，只在正文变化（`_onControllerChanged` 里
   `identical(lines, _lastLines)` 判定）时重算，行号栏宽度和行号位数都
   从缓存读。

2. **长行兜底**：`CodeEditor` 传入 `maxLengthSingleLineRendering: 2048`。
   之前没传，超长行会让 TextPainter 去算一个超宽段落、横向滚动条被撑到
   几百万像素，测量昂贵。现在单行超过 2048 字符只渲染前 2048 字符。

## 补丁 8：CodeLines.equals 加 identical 短路

文件：`lib/src/code_lines.dart`，`CodeLines.equals`

`equals` 没有 `identical` 短路（`operator ==` 有，但 `equals` 是独立方法漏了）。
光标/选区变化时 `codeLines` 复用同一实例，但 `set codes`
（`_code_field.dart`）和 `CodeLineEditingValue ==`（`code_line.dart`）每次
通知都会调 `equals` —— 没有短路就一路走到 `listEquals` 全量比较 30 万行
（O(n)），纯移动光标也付一遍。

在开头补：

```dart
if (identical(this, codeLines)) {
  return true;
}
```

语义安全：同一实例 equals 自己是 `==` 的应有之义，只是补全漏掉的短路。

## 补丁 9：段落暴露首行真实基线（行号与正文对齐）

文件：`lib/src/code_paragraph.dart`（抽象接口）、`lib/src/_code_paragraph.dart`（实现）

原接口只有 `preferredLineHeight`（行高），没有「基线落在哪」。应用层要自己画
行号栏，只能拿「行高 × 0.8 + 垂直居中」去估，中文字符走系统 CJK 回退字体、
ascent 比 monospace 大，段落取各 run 的最大 ascent，于是正文基线比估出来的
位置低几像素，行号看起来总是偏高一点。

加一个 getter，用 `ui.Paragraph.computeLineMetrics().first.baseline` 拿真实
基线（相对段落顶部），并做惰性缓存（段落 layout 完就不再变）：

```dart
double get firstLineBaseline;   // IParagraph
```

实现里空段落没有 line metrics，退回 `preferredLineHeight * 0.8`。

应用层拿 `p.paragraph.firstLineBaseline` 反推行号的 top，让两条基线重合。

## 补丁 10：按行号铺满整行的背景高亮

文件：`lib/src/_code_paragraph.dart`（新增公开类）、`lib/src/_code_field.dart`、
`lib/src/_code_editable.dart`、`lib/src/code_editor.dart`

原有背景层只有两种高亮：选区（`CodeLineSelection`）和查找命中，两者都基于
「字符区间」，画出来只有文字那么宽，而且各自只有一种颜色。应用层「多选行」
需要按行号铺满整行、且要多种颜色（勾选行一种、区间起点另一种），语义对不上。

新增：

1. 公开类 `CodeLineHighlight { Set<int> lines; Color color; }`，带
   `==`/`hashCode`（`setEquals`），供 `listEquals` 判等。
2. `_CodeLineHighlightPainter`，插在 `_backgroundRender` 的 painters **最前面**
   （画在选区、查找命中、光标之下）。按可见段落遍历，`lines.contains(index)`
   O(1) 命中，矩形为 `Rect.fromLTWH(0, top, size.width, paragraph.height)`，
   其中 `top = paragraph.offset.dy - render.paintOffset.dy`（内容坐标 → 视口）。
3. `_CodeFieldRender.highlightLineGroups` setter，判等后只 `notifyListeners()`
   → 重绘、不重排。
4. 参数链：`CodeEditor.highlightLineGroups` →
   `_CodeEditable.highlightLineGroups` → `_CodeField.highlightLineGroups`。

null 或空列表时画家直接 return，不影响任何现有行为。

## 升级到新版本时

1. 用新版本覆盖 `lib/`、`pubspec.yaml`、`CHANGELOG.md`、`README.md`。
2. 重新应用上面的 10 个补丁。定位点：
   - 补丁 1：`grep -n "markNeedsLayout" lib/src/_code_field.dart`（selection setter）
   - 补丁 2：`_code_field.dart` 里 `target < _displayParagraphs.first.top`
   - 补丁 3：`_code_find.dart` 里 `static CodeLinePosition _findPosition`
   - 补丁 4：`_code_find.dart` 里 `void _updateResult()`
   - 补丁 5：`_code_line.dart` 里 `void _replaceAll(`（整段替换成异步版本）
   - 补丁 6：`_code_field.dart` 里 `_codesLength`（`_CodeFieldRender`）
   - 补丁 7：应用层 `single_file_editor_screen.dart` 里 `_cachedLineCount`、
     `maxLengthSingleLineRendering`
   - 补丁 8：`code_lines.dart` 里 `equals` 的 `identical(this, codeLines)` 短路
   - 补丁 9：`code_paragraph.dart` 里 `firstLineBaseline`、
     `_code_paragraph.dart` 里 `_firstLineBaseline`
   - 补丁 10：`_code_field.dart` 里 `_CodeLineHighlightPainter`、
     `highlightLineGroups`
3. 如果上游已经自己改了对应问题，跳过那条，别重复打。
4. 只有全部补丁都有上游版本时才删掉这个目录、`pubspec.yaml` 换回
   `re_editor: ^x.y.z`。
