import 'package:diff_match_patch/diff_match_patch.dart';

import '../domain/diff_entry.dart';
import '../domain/diff_operation.dart';
import '../domain/diff_result.dart';
import 'diff_engine.dart';

/// Line-level diff built on top of diff-match-patch's `diff()`.
///
/// The package version we depend on (diff_match_patch 0.4.1) only exposes
/// the plain character-level `diff()` method — it does NOT ship
/// `diffLinesToChars` / `diffCharsToLines`. To still get line-level speed
/// we do the "lines to chars" mapping ourselves:
///
///   1. Split both texts into lines.
///   2. Intern each distinct line to a single UTF-16 code unit.
///   3. Join the code units into two compact strings.
///   4. Run `dmp.diff()` on those strings — this is where the win is:
///      Myers sees one symbol per *line*, not one per *character*.
///   5. Map each diff chunk back to lines using the interned table.
///
/// Complexity is O(N_lines · D) instead of O(N_chars · D) — on a 20k-line
/// novel with a few hundred changes this is the difference between several
/// seconds and a few hundred milliseconds.
///
/// PRD §2 Module 4.
class LineDiffEngine implements DiffEngine {
  const LineDiffEngine();

  @override
  DiffResult compute(String original, String modified) {
    final a = original.isEmpty ? const <String>[] : original.split('\n');
    final b = modified.isEmpty ? const <String>[] : modified.split('\n');

    if (a.isEmpty && b.isEmpty) {
      return const DiffResult(
        entries: <DiffEntry>[],
        engineType: DiffEngineType.line,
      );
    }

    // Intern distinct lines to single code units (U+0000 is reserved as the
    // "separator" / "not a real symbol" sentinel, so symbols start at 1).
    final interned = <String, int>{};
    final table = <String>['']; // index 0 is a placeholder

    int intern(String line) {
      final hit = interned[line];
      if (hit != null) return hit;
      final id = table.length;
      table.add(line);
      interned[line] = id;
      return id;
    }

    // 顺序 id（从 1 起）→ "安全"单码元：跳过 U+0000（哨兵）与代理区
    // [0xD800,0xDFFF]，避免写成孤立代理或在 >0xFFFF 时溢出。
    // 关键：每行仍只占【一个码元】，dmp 的字符级 diff 才能按码元边界对齐
    // （任意子串都落在行边界上）。
    // 安全码元共 65536 - 1(哨兵) - 2048(代理区) = 63487 个，覆盖绝大多数文档；
    // 超过则需更换 diff 算法（不在本次范围内，见下方退化处理）。
    const int safeLimit = 63487;
    final List<int> idToCu = <int>[];
    final Map<int, int> cuToId = <int, int>{};
    int cuForId(int id) {
      if (id <= safeLimit) {
        while (idToCu.length <= id) {
          var cu = idToCu.isEmpty ? 1 : idToCu.last + 1;
          if (cu >= 0xD800 && cu <= 0xDFFF) cu = 0xE000;
          idToCu.add(cu);
          cuToId[cu] = idToCu.length - 1; // 即当前 id
        }
        return idToCu[id];
      }
      // 极端情况：不同行数超过安全码元池，退化为复用（极罕见，仅影响正确性、
      // 不会崩溃；真正修复需更换 diff 算法）。
      return cuForId((id - 1) % safeLimit + 1);
    }

    final bufA = StringBuffer();
    for (final line in a) {
      bufA.writeCharCode(cuForId(intern(line)));
    }
    final bufB = StringBuffer();
    for (final line in b) {
      bufB.writeCharCode(cuForId(intern(line)));
    }

    final dmp = DiffMatchPatch();
    final diffs = dmp.diff(bufA.toString(), bufB.toString());

    final entries = <DiffEntry>[];
    for (final d in diffs) {
      final op = _mapOp(d.operation);
      // 每个码元对应恰好一行。
      final t = d.text;
      for (var i = 0; i < t.length; i++) {
        final id = cuToId[t.codeUnitAt(i)]!;
        final line = table[id];
        entries.add(_mkEntry(op, line));
      }
    }

    return DiffResult(entries: entries, engineType: DiffEngineType.line);
  }

  DiffEntry _mkEntry(DiffOperation op, String line) {
    switch (op) {
      case DiffOperation.equal:
        return DiffEntry(operation: op, text: line);
      case DiffOperation.insert:
        return DiffEntry(operation: op, text: line, newText: line);
      case DiffOperation.delete:
        return DiffEntry(operation: op, text: line, oldText: line);
      case DiffOperation.replace:
        return DiffEntry(operation: op, text: line);
    }
  }

  DiffOperation _mapOp(int op) {
    switch (op) {
      case DIFF_EQUAL:
        return DiffOperation.equal;
      case DIFF_INSERT:
        return DiffOperation.insert;
      case DIFF_DELETE:
        return DiffOperation.delete;
      default:
        return DiffOperation.equal;
    }
  }
}
