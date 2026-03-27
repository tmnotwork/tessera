import '../models/block.dart';
import 'block_service.dart';

/// ブロックの重複整理を担当するクラス
class BlockDeduplicator {
  /// cloudId が同一のローカル重複を整理（最新の1件を残す）
  static Future<int> deduplicateByCloudId(
    Future<void> Function(String blockId) deleteBlockWithSync,
  ) async {
    int removed = 0;
    final blocks = BlockService.getAllBlocks()
        .where(
            (b) => !b.isDeleted && (b.cloudId != null && b.cloudId!.isNotEmpty))
        .toList();
    final map = <String, List<Block>>{};
    for (final b in blocks) {
      (map[b.cloudId!] ??= []).add(b);
    }
    for (final entry in map.entries) {
      final list = entry.value;
      if (list.length <= 1) continue;
      list.sort((a, b) => b.lastModified.compareTo(a.lastModified));
      for (final dup in list.skip(1)) {
        try {
          await deleteBlockWithSync(dup.id);
          removed++;
        } catch (_) {}
      }
    }
    return removed;
  }
}
