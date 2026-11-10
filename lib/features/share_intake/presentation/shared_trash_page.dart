import 'dart:io';

import 'package:flutter/material.dart';

import '../application/share_intake_service.dart';

/// docdiff 共享回收站入口（文件浏览器「⋯」菜单进入）。
///
/// 展示「docdiff 独立删除」以及「从 DupeBox 导入对比后删除」的全部文件
/// （共享索引里 fromDupeBox 标记区分来源，UI 上用来源标签标注）。
class SharedTrashPage extends StatefulWidget {
  const SharedTrashPage({super.key});

  @override
  State<SharedTrashPage> createState() => _SharedTrashPageState();
}

class _SharedTrashPageState extends State<SharedTrashPage> {
  List<Map<String, dynamic>> _records = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // 读取全部记录（fromDupeBox 为 null 不过滤），让「从 DupeBox 导入后删除」
    // 的文件也在此可见，并用来源标签区分。
    final list = await ShareIntakeCoordinator.readSharedTrash(fromDupeBox: null);
    if (mounted) {
      setState(() {
        _records = list;
        _loading = false;
      });
    }
  }

  Future<void> _restore(Map<String, dynamic> r) async {
    try {
      await ShareIntakeCoordinator.restoreFromSharedTrash(r);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已恢复到原始路径')),
        );
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('恢复失败：$e')),
        );
      }
    }
  }

  Future<void> _purgeOne(Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('永久删除？'),
        content: const Text('该文件将从回收站物理删除，无法再恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Color(0xFFB71C1C),
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ShareIntakeCoordinator.purgeSharedTrashRecord(r);
    if (mounted) await _load();
  }

  Future<void> _purgeAll() async {
    if (_records.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.warning_amber, color: Color(0xFFB71C1C)),
        title: const Text('清空回收站？'),
        content: const Text('全部文件将物理删除，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Color(0xFFB71C1C),
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 清空当前列出的全部记录（含从 DupeBox 导入后删除的）。
    await ShareIntakeCoordinator.purgeAllSharedTrash(fromDupeBox: null);
    if (mounted) await _load();
  }

  String _date(String? iso) {
    if (iso == null) return '';
    try {
      final d = DateTime.parse(iso);
      final two = (int n) => n < 10 ? '0$n' : '$n';
      return '${d.year}-${two(d.month)}-${two(d.day)} '
          '${two(d.hour)}:${two(d.minute)}';
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: '清空回收站',
            onPressed: _records.isNotEmpty ? _purgeAll : null,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.delete_outline, size: 56, color: Colors.grey),
                      SizedBox(height: 12),
                      Text('回收站是空的',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 4),
                      Text('docdiff 删除与从 DupeBox 导入后删除的文件都会出现在这里',
                          style: TextStyle(fontSize: 13)),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _records.length,
                  itemBuilder: (_, i) {
                    final r = _records[i];
                    final name = r['name'] as String? ?? '';
                    final originalPath = r['originalPath'] as String? ?? '';
                    final deletedAt = r['deletedAt'] as String?;
                    final fromDupe = (r['fromDupeBox'] as bool? ?? false);
                    return ListTile(
                      leading: const Icon(Icons.insert_drive_file),
                      title: Text(name),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            originalPath,
                            style: const TextStyle(fontSize: 12),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: fromDupe
                                      ? const Color(0xFFE3F2FD)
                                      : const Color(0xFFF1F1F1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  fromDupe ? '来自 DupeBox' : 'docdiff 删除',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: fromDupe
                                        ? const Color(0xFF1565C0)
                                        : Colors.grey[700],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '删除于 ${_date(deletedAt)}',
                                  style: const TextStyle(fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => _restore(r),
                            child: const Text('恢复',
                                style: TextStyle(color: Color(0xFF2E7D32))),
                          ),
                          TextButton(
                            onPressed: () => _purgeOne(r),
                            child: const Text('删除',
                                style: TextStyle(color: Color(0xFFB71C1C))),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
