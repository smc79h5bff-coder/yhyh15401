part of re_editor;

class _CodeFindControllerImpl extends ValueNotifier<CodeFindValue?> implements CodeFindController {

  late final CodeLineEditingController _controller;
  late final _IsolateTasker<_CodeFindPayload, CodeFindResult?> _tasker;
  late final TextEditingController _findInputController;
  late final FocusNode _findInputFocusNode;
  late final TextEditingController _replaceInputController;
  late final FocusNode _replaceInputFocusNode;
  late bool _shouldNotUpdateResults;
  late bool _replacingMatch;

  /// 扫描任务是否还在 isolate 里跑。
  ///
  /// `_tasker` 的队列是 concurrent: 1 且**不丢弃**排队请求，而每个 payload
  /// 都要把整篇 CodeLines 序列化过去。大文件下扫描一次要几秒，如果每次都
  /// 新发一个请求，快速输入会把若干个几十 MB 的副本排进队列，内存直接爆。
  /// 所以这里只保留「最新一个待发」，在跑的回来之后再发。
  /// 单次扫描超过这个时间没回来，就认为 isolate 出问题了，放行新请求。
  static const int _kScanTimeoutMs = 15000;

  bool _scanning = false;
  int _scanStartedAt = 0;
  int _scanToken = 0;
  _CodeFindPayload? _pendingPayload;
  bool _pendingOptionChanged = false;

  _CodeFindControllerImpl(CodeLineEditingController controller, [CodeFindValue? value]) : super(value) {
    _controller = controller is _CodeLineEditingControllerDelegate ? controller.delegate : controller;
    _controller.addListener(_updateResult);
    _tasker = _IsolateTasker<_CodeFindPayload, CodeFindResult?>('CodeFind', _run);
    _findInputController = TextEditingController();
    _findInputController.addListener(_onFindPatternChanged);
    _findInputFocusNode = FocusNode();
    _replaceInputController = TextEditingController();
    _replaceInputFocusNode = FocusNode();
    _shouldNotUpdateResults = false;
    _replacingMatch = false;
    _updateResult();
  }

  @override
  void dispose() {
    super.dispose();
    _controller.removeListener(_updateResult);
    _findInputController.removeListener(_onFindPatternChanged);
    _findInputController.dispose();
    _findInputFocusNode.dispose();
    _replaceInputController.dispose();
    _replaceInputFocusNode.dispose();
    _tasker.close();
  }

  @override
  TextEditingController get findInputController => _findInputController;

  @override
  TextEditingController get replaceInputController => _replaceInputController;

  @override
  FocusNode get findInputFocusNode => _findInputFocusNode;

  @override
  FocusNode get replaceInputFocusNode => _replaceInputFocusNode;

  @override
  List<CodeLineSelection>? get allMatchSelections {
    final List<CodeLineSelection>? matches = value?.result?.matches;
    if (matches == null) {
      return null;
    }
    if (value!.result!.dirty) {
      return null;
    }
    final List<CodeLineSelection> selections = [];
    for (final CodeLineSelection match in matches) {
      final CodeLineSelection? selection = convertMatchToSelection(match);
      if (selection == null) {
        continue;
      }
      selections.add(selection);
    }
    return selections;
  }

  @override
  CodeLineSelection? get currentMatchSelection {
    final CodeLineSelection? currentMatch = value?.result?.currentMatch;
    if (currentMatch == null) {
      return null;
    }
    if (value!.result!.dirty) {
      return null;
    }
    return convertMatchToSelection(currentMatch);
  }

  @override
  void findMode() {
    _findInputFocusNode.requestFocus();
    final String? autoFilled = _autoFilledPattern();
    _findInputController.removeListener(_onFindPatternChanged);
    if (autoFilled != null) {
      _findInputController.value = TextEditingValue(
        text: autoFilled,
        selection: TextSelection(
          baseOffset: 0,
          extentOffset: autoFilled.length
        )
      );
    } else {
      _findInputController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _findInputController.text.length
      );
    }
    _findInputController.addListener(_onFindPatternChanged);
    final CodeFindValue preValue = value ?? const CodeFindValue.empty();
    value = preValue.copyWith(
      option: preValue.option.copyWith(
        pattern: _findInputController.text
      ),
      result: null,
      searching: true
    );
    _updateResult();
  }

  @override
  void replaceMode() {
    _replaceInputFocusNode.requestFocus();
    final String? autoFilled = _autoFilledPattern();
    _findInputController.removeListener(_onFindPatternChanged);
    if (autoFilled != null) {
      _findInputController.value = TextEditingValue(
        text: autoFilled,
        selection: TextSelection(
          baseOffset: 0,
          extentOffset: autoFilled.length
        )
      );
    } else {
      _findInputController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _findInputController.text.length
      );
    }
    _findInputController.addListener(_onFindPatternChanged);
    final CodeFindValue preValue = value ?? const CodeFindValue.empty();
    value = preValue.copyWith(
      option: preValue.option.copyWith(
        pattern: _findInputController.text,
      ),
      replaceMode: true,
      result: null,
      searching: true
    );
    _updateResult();
  }

  @override
  void focusOnFindInput() {
    _findInputFocusNode.requestFocus();
    _findInputController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _findInputController.text.length
    );
  }

  @override
  void focusOnReplaceInput() {
    _replaceInputFocusNode.requestFocus();
    _replaceInputController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _replaceInputController.text.length
    );
  }

  @override
  void toggleMode() {
    final CodeFindValue? preValue = value;
    if (preValue == null) {
      return;
    }
    value = preValue.copyWith(
      replaceMode: !preValue.replaceMode,
      result: preValue.result
    );
  }

  @override
  void close() {
    value = null;
  }

  @override
  void toggleRegex() {
    final CodeFindOption? option = value?.option;
    if (option == null) {
      return;
    }
    value = value?.copyWith(
      option: option.copyWith(
        regex: !option.regex,
      ),
      result: null,
      searching: true
    );
    _updateResult();
  }

  @override
  void toggleCaseSensitive() {
    final CodeFindOption? option = value?.option;
    if (option == null) {
      return;
    }
    value = value?.copyWith(
      option: option.copyWith(
        caseSensitive: !option.caseSensitive,
      ),
      result: null,
      searching: true
    );
    _updateResult();
  }

  @override
  void previousMatch() {
    final CodeFindResult? result = value?.result;
    if (result == null || result.dirty) {
      return;
    }
    final CodeFindValue newValue = value!.copyWith(
      result: result.previous
    );
    _expandChunkIfNeeded(newValue);
    value = newValue;
    if (result.matches.length == 1) {
      final CodeLineSelection? selection = currentMatchSelection;
      if (selection != null) {
        _controller.makePositionCenterIfInvisible(selection.start);
      }
    }
  }

  @override
  void nextMatch() {
    final CodeFindResult? result = value?.result;
    if (result == null || result.dirty) {
      return;
    }
    final CodeFindValue newValue = value!.copyWith(
      result: result.next
    );
    _expandChunkIfNeeded(newValue);
    value = newValue;
    if (result.matches.length == 1) {
      final CodeLineSelection? selection = currentMatchSelection;
      if (selection != null) {
        _controller.makePositionCenterIfInvisible(selection.start);
      }
    }
  }

  @override
  void replaceMatch() {
    final CodeFindResult? result = value?.result;
    if (result == null || result.dirty) {
      return;
    }
    if (currentMatchSelection == null) {
      _expandChunkIfNeeded(value!);
    }
    final CodeLineSelection? selection = currentMatchSelection;
    if (selection == null) {
      return;
    }
    _replacingMatch = true;
    final CodeLines preCodeLines = _controller.codeLines;
    _controller.replaceSelection(_replaceInputController.text, selection);
    final CodeFindValue newValue = value!.copyWith(
      result: result.next.copyWith(
        dirty: !preCodeLines.equals(_controller.codeLines)
      )
    );
    _expandChunkIfNeeded(newValue);
    value = newValue;
    _replacingMatch = false;
  }

  @override
  Future<bool> replaceAllMatches() async {
    final CodeFindResult? result = value?.result;
    if (result == null || result.matches.isEmpty || result.dirty) {
      return false;
    }
    final CodeFindOption? option = value?.option;
    if (option == null) {
      return false;
    }
    final RegExp? regExp = option.regExp;
    if (regExp == null) {
      return false;
    }
    _replacingMatch = true;
    bool changed = false;
    try {
      changed = await _controller.replaceAll(regExp, _replaceInputController.text);
    } finally {
      _replacingMatch = false;
    }
    // 文本没变（或者等待期间正文被改动而放弃）就不用标脏。
    // 原来是拿 preCodeLine.equals(...) 判断，跨 isolate 后一定是新对象，
    // equals 会误报 true，所以改用 replaceAll 的返回值。
    if (!changed) {
      return false;
    }
    final CodeFindResult? latest = value?.result;
    if (latest != null) {
      value = value!.copyWith(result: latest.copyWith(dirty: true));
    }
    return true;
  }

  @override
  CodeLineSelection? convertMatchToSelection(CodeLineSelection match) {
    final CodeLineIndex baseIndex = _controller.lineIndex2Index(match.baseIndex);
    if (baseIndex.chunkIndex >= 0) {
      // This match is in a collapsed chunk, invisble
      return null;
    }
    final CodeLineIndex extentIndex;
    if (match.isSameLine) {
      extentIndex = baseIndex;
    } else {
      extentIndex = _controller.lineIndex2Index(match.extentIndex);
    }
    if (extentIndex.chunkIndex >= 0) {
      // This match is in a collapsed chunk, invisble
      return null;
    }
    return match.copyWith(
      baseIndex: baseIndex.index,
      extentIndex: extentIndex.index
    );
  }

  void _onFindPatternChanged() {
    final CodeFindOption? option = value?.option;
    if (option == null) {
      return;
    }
    if (_findInputController.text == option.pattern) {
      return;
    }
    value = value?.copyWith(
      option: option.copyWith(
        pattern: _findInputController.text,
      ),
      result: null,
      searching: true
    );
    _updateResult();
  }

  String? _autoFilledPattern() {
    final CodeLineSelection selection = _controller.selection;
    if (selection.isCollapsed || !selection.isSameLine) {
      return null;
    }
    return _controller.selectedText;
  }

  void _updateResult() {
    if (_shouldNotUpdateResults) {
      return;
    }
    final CodeFindOption? option = value?.option;
    if (option == null || option.pattern.isEmpty) {
      value = value?.copyWith(
        result: null,
        searching: false
      );
      return;
    }
    final bool optionChanged = value?.result?.option != option;
    if (!optionChanged && _controller.codeLines.equals(value?.result?.codeLines)) {
      value = value?.copyWith(
        result: value?.result,
        searching: false
      );
      return;
    }
    final _CodeFindPayload payload = _CodeFindPayload(
      codeLines: _controller.codeLines,
      selection: _controller.unfoldLineSelection,
      option: option,
      forwardMatch: !_replacingMatch
    );
    // 有任务在跑：只记下最新这一个，等它回来再发。
    // 不这么做的话，队列会堆上若干个几十 MB 的 CodeLines 副本。
    if (_scanning && _scanTimedOut()) {
      // 上一次扫描长时间没回来（isolate 抛错、被系统回收…）：别把查找
      // 永久卡在「搜索中」，放行新请求。
      _scanning = false;
    }
    if (_scanning) {
      _pendingPayload = payload;
      _pendingOptionChanged = optionChanged;
      return;
    }
    _startScan(payload, optionChanged);
  }

  bool _scanTimedOut() {
    return DateTime.now().millisecondsSinceEpoch - _scanStartedAt >
        _kScanTimeoutMs;
  }

  void _startScan(_CodeFindPayload payload, bool optionChanged) {
    final int token = ++_scanToken;
    _scanning = true;
    _scanStartedAt = DateTime.now().millisecondsSinceEpoch;
    _tasker.run(payload, (result) {
      // 超时之后已经放行了新请求：这次的结果作废，别把新请求的状态清掉。
      if (token != _scanToken) {
        return;
      }
      _scanning = false;
      if (payload.option == value?.option) {
        final CodeFindValue newValue = value!.copyWith(
          result: result,
          searching: false
        );
        if (optionChanged) {
          _expandChunkIfNeeded(newValue);
        }
        value = newValue;
      } else {
        value = value?.copyWith(
          result: null,
          searching: false
        );
      }
      // 扫描期间又来了新请求，补发最新的那一个。
      final _CodeFindPayload? pending = _pendingPayload;
      final bool pendingOptionChanged = _pendingOptionChanged;
      _pendingPayload = null;
      _pendingOptionChanged = false;
      if (pending != null) {
        _startScan(pending, pendingOptionChanged);
      }
    });
  }

  void _expandChunkIfNeeded(CodeFindValue value) {
    _shouldNotUpdateResults = true;
    final CodeLineSelection? match = value.result?.currentMatch;
    if (match != null) {
      _expandChunkIfSelectionInvisible(match);
    }
    _shouldNotUpdateResults = false;
  }

  void _expandChunkIfSelectionInvisible(CodeLineSelection match) {
    if (match.isSameLine) {
      final CodeLineIndex start = _controller.lineIndex2Index(match.startIndex);
      if (start.chunkIndex < 0) {
        return;
      }
      _controller.expandChunk(start.index);
    } else {
      final CodeLineIndex start = _controller.lineIndex2Index(match.startIndex);
      final CodeLineIndex end = _controller.lineIndex2Index(match.endIndex);
      if (start.chunkIndex >= 0) {
        _controller.expandChunk(start.index);
      } else if (end.chunkIndex >= 0) {
        _controller.expandChunk(end.index);
      } else {
        return;
      }
    }
    // If the selection is in a nested chunk, we should expand the chunk from outside one by one
    _expandChunkIfSelectionInvisible(match);
  }

  @pragma('vm:entry-point')
  static CodeFindResult? _run(_CodeFindPayload payload) {
    final RegExp? regExp = payload.option.regExp;
    if (regExp == null) {
      return null;
    }
    final List<String> rawCodeLines = payload.codeLines.toList().fold([], (previousValue, element) {
      previousValue.addAll(element.flat());
      return previousValue;
    });
    // 每行在整篇文本里的起始偏移，一次算好（O(行数)）。
    // 原来 _findPosition 对**每个命中**都从第 0 行回扫，9MB 文件搜常见字
    // 等于 O(命中数 × 行数)，十几万处命中时永远返回不了。
    final List<int> lineStarts = List<int>.filled(rawCodeLines.length, 0);
    {
      int start = 0;
      for (int i = 0; i < rawCodeLines.length; i++) {
        lineStarts[i] = start;
        start += rawCodeLines[i].length + 1;
      }
    }
    final Iterable<Match> matches = regExp.allMatches(rawCodeLines.join(TextLineBreak.lf.value));
    if (matches.isEmpty) {
      return null;
    }
    final List<CodeLineSelection> selections = [];
    for (final Match match in matches) {
      final CodeLinePosition start = _findPosition(lineStarts, match.start);
      final CodeLinePosition end = _findPosition(lineStarts, match.end);
      selections.add(CodeLineSelection(
        baseIndex: start.index,
        baseOffset: start.offset,
        extentIndex: end.index,
        extentOffset: end.offset
      ));
    }
    int index;
    if (payload.forwardMatch) {
      index = selections.length - 1;
      for (; index > 0; index--) {
        if (selections[index].contains(payload.selection)) {
          break;
        }
        if (selections[index].endIndex < payload.selection.startIndex) {
          break;
        }
        if (selections[index].endIndex == payload.selection.startIndex &&
          selections[index].endOffset <= payload.selection.startOffset) {
          break;
        }
      }
    } else {
      index = 0;
      for (; index < selections.length; index++) {
        if (selections[index].contains(payload.selection)) {
          break;
        }
        if (selections[index].startIndex > payload.selection.endIndex) {
          break;
        }
        if (selections[index].startIndex == payload.selection.endIndex &&
          selections[index].startOffset >= payload.selection.endOffset) {
          break;
        }
      }
    }
    return CodeFindResult(
      index: max(min(index, selections.length - 1), 0),
      matches: selections,
      option: payload.option,
      codeLines: payload.codeLines,
      dirty: false
    );
  }

  /// 用行起始偏移表二分定位，替代原来「每个命中都从第 0 行数」。
  static CodeLinePosition _findPosition(List<int> lineStarts, int index) {
    if (lineStarts.isEmpty) {
      return const CodeLinePosition(index: 0, offset: 0);
    }
    // 找最后一个 start <= index 的行。
    int low = 0;
    int high = lineStarts.length - 1;
    while (low < high) {
      final int mid = (low + high + 1) >> 1;
      if (lineStarts[mid] <= index) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return CodeLinePosition(
      index: low,
      offset: index - lineStarts[low],
    );
  }

}

class _CodeFindPayload {

  final CodeLines codeLines;
  final CodeLineSelection selection;
  final CodeFindOption option;
  final bool forwardMatch;

  const _CodeFindPayload({
    required this.codeLines,
    required this.selection,
    required this.option,
    required this.forwardMatch,
  });

}