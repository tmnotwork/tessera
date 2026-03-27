import '../models/block.dart';
import 'data_sync_service.dart';

/// ブロックの変更監視を担当するクラス
class BlockWatcher {
  final DataSyncService<Block> _syncService;

  BlockWatcher(this._syncService);

  /// ブロックの変更を監視
  Stream<List<Block>> watchBlockChanges() {
    return _syncService.watchFirebaseChanges();
  }

  /// 日付別ブロック監視
  Stream<List<Block>> watchBlocksByDate(DateTime date) {
    final dateStr = date.toIso8601String().split('T')[0]; // YYYY-MM-DD形式
    final nextDateStr =
        date.add(const Duration(days: 1)).toIso8601String().split('T')[0];
    return _syncService.userCollection
        .where('executionDate',
            isGreaterThanOrEqualTo: '${dateStr}T00:00:00')
        .where('executionDate', isLessThan: '${nextDateStr}T00:00:00')
        .snapshots()
        .map((snapshot) {
      // キャッシュ由来の初期スナップショットは上位層で無視可能
      final items = <Block>[];
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          if ((data['isDeleted'] ?? false) == true) {
            continue;
          }
          final item = _syncService.createFromCloudJson(data);
          items.add(item);
        } catch (e) {
          print('⚠️ Failed to parse block ${doc.id}: $e');
        }
      }
      return items;
    }).handleError((e, st) {
      // 監視エラーを握ってUI継続（ネットワーク一時障害/認証再水和対策）
      try {
        // ignore: avoid_print
        print('⚠️ Firestore watch error: $e');
      } catch (_) {}
    });
  }

  /// 今日のブロック監視
  Stream<List<Block>> watchTodayBlocks() {
    return watchBlocksByDate(DateTime.now());
  }
}
