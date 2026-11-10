import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/file_browser_providers.dart';

/// 顶栏按钮自定义页。
class TopBarLayoutScreen extends ConsumerStatefulWidget {
  const TopBarLayoutScreen({super.key});

  @override
  ConsumerState<TopBarLayoutScreen> createState() =>
      _TopBarLayoutScreenState();
}

class _TopBarLayoutScreenState extends ConsumerState<TopBarLayoutScreen> {
  static const int _maxOnTop = 5;

  late List<BrowserTopBarAction> _order;
  late Set<BrowserTopBarAction> _onTop;

  @override
  void initState() {
    super.initState();
    final parsed = parseTopBarLayout(ref.read(browserTopBarLayoutProvider));
    _order = List.of(parsed.order);
    _onTop = Set.of(parsed.onTopBar);
  }

  void _persist() {
    ref.read(browserTopBarLayoutProvider.notifier).update([
      for (final a in _order) '${a.id}:${_onTop.contains(a) ? 1 : 0}',
    ]);
  }

  Future<void> _resetDefaults() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('恢复默认？'),
        content: const Text('顶栏按钮和菜单的顺序会回到初始状态。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final next = BrowserTopBarLayoutNotifier.defaultLayout();
    ref.read(browserTopBarLayoutProvider.notifier).update(next);
    final parsed = parseTopBarLayout(next);
    setState(() {
      _order = List.of(parsed.order);
      _onTop = Set.of(parsed.onTopBar);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final count = _onTop.length;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: s.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('顶栏按钮'),
        actions: [
          TextButton(
            onPressed: _resetDefaults,
            child: const Text('恢复默认'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: s.surfaceContainerLow,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '拖动左侧手柄调整顺序。\n'
                '开关控制：放在顶栏 / 收进三个点菜单。\n'
                '顶栏最多 $_maxOnTop 个（不含「更多」本身），当前 $count 个。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: s.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
              itemCount: _order.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex--;
                  final item = _order.removeAt(oldIndex);
                  _order.insert(newIndex, item);
                });
                _persist();
              },
              itemBuilder: (ctx, i) {
                final a = _order[i];
                final on = _onTop.contains(a);
                final canTurnOn = on || _onTop.length < _maxOnTop;
                return Padding(
                  key: ValueKey(a.id),
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Material(
                    color: s.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: s.outlineVariant),
                    ),
                    child: ListTile(
                      leading: a == BrowserTopBarAction.dedup
                          ? Image.asset(
                              'assets/images/dupebox_icon.png',
                              width: 22,
                              height: 22,
                            )
                          : Icon(browserTopBarActionIcon(a), color: s.onSurface),
                      title: Text(a.label,
                          style: const TextStyle(fontSize: 14)),
                      subtitle: Text(
                        on ? '顶栏' : '三个点菜单',
                        style: TextStyle(
                          fontSize: 12,
                          color: on ? s.primary : s.onSurfaceVariant,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: on,
                            onChanged: canTurnOn
                                ? (v) {
                                    setState(() {
                                      if (v) {
                                        _onTop.add(a);
                                      } else {
                                        _onTop.remove(a);
                                      }
                                    });
                                    _persist();
                                  }
                                : null,
                          ),
                          ReorderableDragStartListener(
                            index: i,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: Icon(
                                Icons.drag_handle,
                                color: s.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
