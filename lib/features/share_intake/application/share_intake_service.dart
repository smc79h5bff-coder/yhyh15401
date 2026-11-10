import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../parser/application/document_parser.dart';
import '../../preprocessing/domain/encoding_type.dart';

/// 分享进来的两个文件解析完成后的结果。
class ShareIntakePayload {
  const ShareIntakePayload({
    required this.leftText,
    required this.rightText,
    required this.leftName,
    required this.rightName,
    required this.leftEncoding,
    required this.rightEncoding,
    required this.leftTempPath,
    required this.rightTempPath,
    required this.sessionDir,
    this.origPathLeft = '',
    this.origPathRight = '',
    this.sourceUriLeft = '',
    this.sourceUriRight = '',
    this.fromDupeBox = false,
  });

  final String leftText;
  final String rightText;
  final String leftName;
  final String rightName;
  final String leftEncoding;
  final String rightEncoding;
  final String leftTempPath;
  final String rightTempPath;

  /// 本次分享专属的缓存目录，对比页关闭后整目录删除。
  final String sessionDir;

  /// 来自 DupeBox 时携带的真实文件路径（SAF/SD 卡可能为空，依赖原生解析）。
  final String origPathLeft;
  final String origPathRight;

  /// 源文件 content:// URI（删除/移动失败时可用于 SAF 写授权兜底）。
  final String sourceUriLeft;
  final String sourceUriRight;

  /// 是否来自 DupeBox（决定是否跳过 5MB 与文本类型护栏、启用删除/回收站）。
  final bool fromDupeBox;
}

/// 分享校验失败（提示语直接给用户看）。
class ShareIntakeException implements Exception {
  const ShareIntakeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 从其他 App 分享进来的文件 → 校验 → 复制 → 解析 → 进入对比页。
///
/// 只处理 Android 的 ACTION_SEND / ACTION_SEND_MULTIPLE。
/// 原生侧：MainActivity.kt 通过 MethodChannel `docdiff/share_intent` 把缓存好的
/// 文件列表喂给 Flutter。这里不引入第三方分享插件，避免 Fluter 3.47 的
/// kernel snapshot 兼容性问题。
class ShareIntakeCoordinator {
  ShareIntakeCoordinator._();

  static final ShareIntakeCoordinator instance = ShareIntakeCoordinator._();

  static const int maxBytes = 5 * 1024 * 1024;
  static const Duration _maxCacheAge = Duration(days: 3);
  static const Duration _aggregateWindow = Duration(milliseconds: 400);

  static const MethodChannel _channel = MethodChannel('docdiff/share_intent');

  static const Set<String> _binaryExtensions = {
    '.docx', '.doc', '.rtf', '.odt', '.wps',
    '.xlsx', '.xls', '.ods', '.pptx', '.ppt', '.odp',
    '.pdf',
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.heic', '.svg',
    '.mp3', '.wav', '.flac', '.aac', '.ogg', '.m4a',
    '.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v',
    '.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz',
    '.jar', '.apk', '.ipa', '.iso',
    '.exe', '.dll', '.so', '.bin', '.deb', '.rpm',
    '.ttf', '.otf', '.woff', '.woff2',
    '.db', '.sqlite', '.sqlite3',
  };

  bool _started = false;
  bool _busy = false;
  Timer? _aggregateTimer;
  final List<_ShareItem> _buffer = <_ShareItem>[];

  String? _lastSignature;
  DateTime? _lastSignatureAt;

  Future<void> Function(ShareIntakePayload)? _onReady;
  Future<void> Function(String)? _onRejected;

  /// 启动监听。必须在 MaterialApp 之内、权限门之外调用。
  Future<void> start({
    required Future<void> Function(ShareIntakePayload) onReady,
    required Future<void> Function(String) onRejected,
  }) async {
    if (!Platform.isAndroid || _started) return;
    _started = true;
    _onReady = onReady;
    _onRejected = onRejected;

    // 清理旧缓存，不阻塞启动。
    unawaited(_cleanupOldSessions());

    _channel.setMethodCallHandler(_onNativeCall);

    // 冷启动时 MainActivity 已经在 configureFlutterEngine 之前收到 intent 并填好
    // pendingShares，那时我们的 handler 还没注册，所以主动拉一次。
    // 原生侧会在 getPendingShares 后清空，保证下次拉不到重复数据。
    final initial = await _poll();
    if (initial.isNotEmpty) _onBatch(initial);
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'onSharesPending') {
      final items = await _poll();
      if (items.isNotEmpty) _onBatch(items);
    }
  }

  Future<List<_ShareItem>> _poll() async {
    try {
      final raw = await _channel.invokeListMethod<Map>('getPendingShares');
      if (raw == null) return const [];
      return raw
          .map((e) => _ShareItem(
                path: e['path'] as String? ?? '',
                name: e['name'] as String? ?? '',
                origPath: e['origPath'] as String? ?? '',
                uri: e['uri'] as String? ?? '',
                fromDupeBox: e['fromDupeBox'] == 'true',
              ))
          .where((e) => e.path.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  void _onBatch(List<_ShareItem> batch) {
    if (batch.isEmpty) return;
    for (final f in batch) {
      if (_buffer.any((e) => e.path == f.path)) continue;
      _buffer.add(f);
    }
    _aggregateTimer?.cancel();
    _aggregateTimer = Timer(_aggregateWindow, () => unawaited(_drain()));
  }

  Future<void> _drain() async {
    if (_busy) {
      _aggregateTimer?.cancel();
      _aggregateTimer = Timer(
        const Duration(milliseconds: 300),
        () => unawaited(_drain()),
      );
      return;
    }
    final files = List<_ShareItem>.of(_buffer);
    _buffer.clear();
    if (files.isEmpty) return;

    _busy = true;
    try {
      // 10 秒内同签名视为重复投递（冷启动 initial + 热启动事件各投一次）。
      final signature = (files.map((f) => f.path).toList()..sort()).join('|');
      final now = DateTime.now();
      final lastAt = _lastSignatureAt;
      if (signature == _lastSignature &&
          lastAt != null &&
          now.difference(lastAt) < const Duration(seconds: 10)) {
        return;
      }

      final payload = await _buildPayload(files);
      _lastSignature = signature;
      _lastSignatureAt = now;
      final cb = _onReady;
      if (cb != null) await cb(payload);
    } on ShareIntakeException catch (e) {
      await _reject(e.message);
    } catch (e) {
      await _reject('处理分享文件失败：$e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _reject(String message) async {
    final cb = _onRejected;
    if (cb != null) await cb(message);
  }

  Future<ShareIntakePayload> _buildPayload(List<_ShareItem> files) async {
    if (files.length != 2) {
      if (files.isEmpty) {
        throw const ShareIntakeException(
          '没有收到文件。请一次选择两个文本文件分享（纯文本/链接不支持）',
        );
      }
      throw ShareIntakeException(
        '请一次分享两个文本文件（当前收到 ${files.length} 个）',
      );
    }

    final rawLeft = files[0].path;
    final rawRight = files[1].path;
    if (rawLeft == rawRight) {
      throw const ShareIntakeException(
        '两个文件被系统合并成同一个，请换一个分享来源再试',
      );
    }

    final leftName = files[0].name.isEmpty ? p.basename(rawLeft) : files[0].name;
    final rightName = files[1].name.isEmpty ? p.basename(rawRight) : files[1].name;
    if (leftName.toLowerCase() == rightName.toLowerCase()) {
      throw const ShareIntakeException('两个文件同名，无法区分，请改名后再分享');
    }

    // 来自 DupeBox 时跳过 5MB 与文本/二进制护栏（用户已在 DupeBox 内确认文件）。
    if (!files[0].fromDupeBox) {
      _checkExtension(leftName);
      _checkExtension(rightName);
      await _checkSizeAndContent(rawLeft, leftName);
      await _checkSizeAndContent(rawRight, rightName);
    }

    final session = await _newSessionDir();
    final leftCopy = p.join(session.path, leftName);
    final rightCopy = p.join(session.path, rightName);

    try {
      await File(rawLeft).copy(leftCopy);
      await File(rawRight).copy(rightCopy);
    } catch (e) {
      await cleanupSession(session.path);
      throw ShareIntakeException('复制分享文件失败：$e');
    }

    final leftParsed = await DocumentParser.parse(
      fileName: leftName,
      bytes: await File(leftCopy).readAsBytes(),
    );
    final rightParsed = await DocumentParser.parse(
      fileName: rightName,
      bytes: await File(rightCopy).readAsBytes(),
    );

    return ShareIntakePayload(
      leftText: leftParsed.plainText,
      rightText: rightParsed.plainText,
      leftName: leftParsed.fileName,
      rightName: rightParsed.fileName,
      leftEncoding: leftParsed.encoding.label,
      rightEncoding: rightParsed.encoding.label,
      leftTempPath: leftCopy,
      rightTempPath: rightCopy,
      sessionDir: session.path,
      origPathLeft: files[0].origPath,
      origPathRight: files[1].origPath,
      sourceUriLeft: files[0].uri,
      sourceUriRight: files[1].uri,
      fromDupeBox: files[0].fromDupeBox,
    );
  }

  void _checkExtension(String name) {
    final ext = p.extension(name).toLowerCase();
    if (_binaryExtensions.contains(ext)) {
      final label = ext.isEmpty ? '该文件' : ext.substring(1).toUpperCase();
      throw ShareIntakeException(
        '$label 不是文本文件，只支持 .txt / .md / .log 等文本类型',
      );
    }
  }

  Future<void> _checkSizeAndContent(String path, String name) async {
    final file = File(path);
    final length = await file.length();
    if (length > maxBytes) {
      throw ShareIntakeException(
        '$name 有 ${_fmtSize(length)}，超过 ${_fmtSize(maxBytes)} 上限',
      );
    }
    if (length == 0) {
      throw ShareIntakeException('$name 是空文件');
    }

    final raf = await file.open();
    try {
      final head = await raf.read(8192);
      if (!_looksLikeText(head)) {
        throw ShareIntakeException('$name 不是文本文件，已拒绝对比');
      }
    } finally {
      await raf.close();
    }
  }

  static bool _looksLikeText(Uint8List bytes) {
    if (bytes.length >= 2) {
      final b0 = bytes[0];
      final b1 = bytes[1];
      final utf16 = (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF);
      if (utf16) return true;
    }
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0) return false;
    }
    return true;
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  // ==================== 缓存目录 ====================

  static Future<Directory> _sessionsRoot() async {
    final tmp = await getTemporaryDirectory();
    return Directory(p.join(tmp.path, 'share_compare'));
  }

  static Future<Directory> _newSessionDir() async {
    final root = await _sessionsRoot();
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    final dir = Directory(
      p.join(root.path, DateTime.now().millisecondsSinceEpoch.toString()),
    );
    await dir.create(recursive: true);
    return dir;
  }

  static Future<void> _cleanupOldSessions() async {
    try {
      final root = await _sessionsRoot();
      if (!await root.exists()) return;
      final now = DateTime.now();
      await for (final entity in root.list()) {
        if (entity is! Directory) continue;
        try {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > _maxCacheAge) {
            await entity.delete(recursive: true);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 对比页退出后删掉本次会话的临时文件。
  static Future<void> cleanupSession(String? dir) async {
    if (dir == null || dir.isEmpty) return;
    try {
      final d = Directory(dir);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  // ==================== 共享回收站（与 DupeBox 共用外部存储目录） ====================

  /// 外部共享回收站目录（两个 App 都能用 MANAGE_EXTERNAL_STORAGE 访问）。
  static const String sharedTrashDir = '/storage/emulated/0/.dupebox_trash';

  /// 共享回收站索引文件（JSON 数组，记录每个被删文件的原始路径/回收站路径等）。
  static String get sharedTrashIndex => p.join(sharedTrashDir, 'index.json');

  static const MethodChannel _fileOpChannel = MethodChannel('docdiff/file_op');

  /// 把源文件移入共享回收站（复制到回收站 → 删原文件 → 记录索引），失败抛异常。
  /// [fromDupeBox] 记录来源：true = 由 DupeBox 导入对比后删除（应在 DupeBox 回收站可见），
  /// false = docdiff 独立删除（应在 docdiff 回收站入口可见）。
  static Future<void> moveToSharedTrash(
    String srcPath, {
    bool fromDupeBox = false,
  }) async {
    final src = File(srcPath);
    if (!await src.exists()) return;
    final dir = Directory(sharedTrashDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dest = p.join(sharedTrashDir, '${stamp}_${p.basename(srcPath)}');
    await src.copy(dest);
    await src.delete();
    await _appendTrashIndex(<String, dynamic>{
      'originalPath': srcPath,
      'name': p.basename(srcPath),
      'trashPath': dest,
      'deletedAt': DateTime.now().toIso8601String(),
      'sourceApp': 'docdiff',
      'fromDupeBox': fromDupeBox,
    });
  }

  static Future<void> _appendTrashIndex(Map<String, dynamic> record) async {
    final file = File(sharedTrashIndex);
    List<dynamic> list = <dynamic>[];
    if (await file.exists()) {
      try {
        final text = await file.readAsString();
        if (text.trim().isNotEmpty) {
          final decoded = jsonDecode(text);
          if (decoded is List) list = decoded;
        }
      } catch (_) {}
    }
    list.add(record);
    await file.writeAsString(jsonEncode(list));
  }

  /// 通过原生向 DupeBox 发送文件操作广播（path + op=delete|move），失败静默。
  static Future<void> notifyDupeBox(String path, String op) async {
    try {
      await _fileOpChannel.invokeMethod<void>('sendFileOp', <String, dynamic>{
        'path': path,
        'op': op,
      });
    } catch (_) {}
  }

  /// 读取共享回收站索引。
  /// [fromDupeBox] 为 null 时返回全部；为 true/false 时按标记过滤
  /// （true = 由 DupeBox 导入后删除，false = docdiff 独立删除）。
  static Future<List<Map<String, dynamic>>> readSharedTrash({
    bool? fromDupeBox,
  }) async {
    final file = File(sharedTrashIndex);
    if (!await file.exists()) return const [];
    try {
      final text = await file.readAsString();
      if (text.trim().isEmpty) return const [];
      final decoded = jsonDecode(text);
      if (decoded is! List) return const [];
      final list = decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      if (fromDupeBox == null) return list;
      return list.where((e) => (e['fromDupeBox'] as bool? ?? false) == fromDupeBox).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 把共享回收站里的文件恢复到原始路径（原路径已存在则加后缀避免覆盖）。
  static Future<void> restoreFromSharedTrash(Map<String, dynamic> record) async {
    final trashPath = record['trashPath'] as String? ?? '';
    final originalPath = record['originalPath'] as String? ?? '';
    if (trashPath.isEmpty || originalPath.isEmpty) return;
    final src = File(trashPath);
    if (!await src.exists()) return;
    var destPath = originalPath;
    if (await File(destPath).exists()) {
      final dir = p.dirname(originalPath);
      final name = p.basename(originalPath);
      final dot = name.lastIndexOf('.');
      final base = dot > 0 ? name.substring(0, dot) : name;
      final ext = dot > 0 ? name.substring(dot) : '';
      for (var i = 1;; i++) {
        final cand = p.join(dir, '$base (恢复$i)$ext');
        if (!await File(cand).exists()) {
          destPath = cand;
          break;
        }
      }
    }
    await src.copy(destPath);
    await src.delete();
    await _removeTrashIndexRecord(trashPath);
  }

  /// 物理删除共享回收站里的单条记录（文件 + 索引项）。
  static Future<void> purgeSharedTrashRecord(Map<String, dynamic> record) async {
    final trashPath = record['trashPath'] as String? ?? '';
    if (trashPath.isNotEmpty) {
      try {
        await File(trashPath).delete();
      } catch (_) {}
    }
    await _removeTrashIndexRecord(trashPath);
  }

  /// 清空共享回收站（按 [fromDupeBox] 过滤；为 null 时清空全部）。
  static Future<void> purgeAllSharedTrash({bool? fromDupeBox}) async {
    final records = await readSharedTrash(fromDupeBox: fromDupeBox);
    for (final r in records) {
      final trashPath = r['trashPath'] as String? ?? '';
      if (trashPath.isNotEmpty) {
        try {
          await File(trashPath).delete();
        } catch (_) {}
      }
    }
    // 重写索引，仅保留不匹配的项。
    final file = File(sharedTrashIndex);
    if (!await file.exists()) return;
    try {
      final text = await file.readAsString();
      if (text.trim().isEmpty) return;
      final decoded = jsonDecode(text);
      if (decoded is! List) return;
      final keep = decoded.where((e) {
        if (e is! Map) return true;
        if (fromDupeBox == null) return false;
        return (e['fromDupeBox'] as bool? ?? false) != fromDupeBox;
      }).toList();
      await file.writeAsString(jsonEncode(keep));
    } catch (_) {}
  }

  /// 从索引中移除 trashPath 匹配的记录（其余保留）。
  static Future<void> _removeTrashIndexRecord(String trashPath) async {
    if (trashPath.isEmpty) return;
    final file = File(sharedTrashIndex);
    if (!await file.exists()) return;
    try {
      final text = await file.readAsString();
      if (text.trim().isEmpty) return;
      final decoded = jsonDecode(text);
      if (decoded is! List) return;
      final keep = decoded.where((e) => e is! Map || (e['trashPath'] as String? ?? '') != trashPath).toList();
      await file.writeAsString(jsonEncode(keep));
    } catch (_) {}
  }
}

class _ShareItem {
  const _ShareItem({
    required this.path,
    required this.name,
    this.origPath = '',
    this.uri = '',
    this.fromDupeBox = false,
  });

  final String path;
  final String name;
  final String origPath;
  final String uri;
  final bool fromDupeBox;
}

