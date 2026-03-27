import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/block.dart';
import '../services/auth_service.dart';
import '../services/block_service.dart';
import '../services/block_sync_service.dart';
import '../services/block_utilities.dart';

/// 削除問題のデバッグ専用サービス
class DebugDeletionService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// ユーザーのコレクション参照を取得
  static CollectionReference get userCollection {
    final userId = AuthService.getCurrentUserId();
    if (userId == null) {
      throw StateError('User not authenticated');
    }
    return _firestore.collection('users').doc(userId).collection('blocks');
  }

  /// 削除前後の詳細な状態チェック
  static Future<void> debugDeletionProcess() async {
    // Step 1: 削除前の状態確認
    await _analyzeCurrentState();

    // Step 2: Firebase直接確認（isDeletedフィルターなし）
    await _analyzeFirebaseDirectly();

    // Step 3: ルーティンブロック削除実行
    await _executeTrackedDeletion();

    // Step 4: 削除直後の状態確認
    await _analyzeCurrentState();

    // Step 5: Firebase直接確認（削除後）
    await _analyzeFirebaseDirectly();

    // Step 6: 強制同期実行
    await _executeForcedSync();

    // Step 7: 同期後の状態確認
    await _analyzeCurrentState();
  }

  /// 現在の状態を詳細分析
  static Future<void> _analyzeCurrentState() async {
    try {
      // ローカル状態とFirebase状態の分析（現在は使用していない）
      // final localBlocks = BlockService.getAllBlocks();
      // final remoteBlocks = await _getFirebaseBlocks(withFilter: true);
    } catch (e) {
      // エラーは無視
    }
  }

  /// Firebase を直接確認（フィルターなし）
  static Future<void> _analyzeFirebaseDirectly() async {
    try {
      print('🔍 Querying Firebase directly (no filters)...');

      final allSnapshot =
          await userCollection.get(const GetOptions(source: Source.server));
      print('📊 Total documents in Firebase: ${allSnapshot.docs.length}');

      int activeCount = 0;
      int deletedCount = 0;
      int routineActiveCount = 0;
      int routineDeletedCount = 0;

      final List<String> routineActiveTitles = [];
      final List<String> routineDeletedTitles = [];

      for (final doc in allSnapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final isDeleted = data['isDeleted'] ?? false;
        final title = data['title'] ?? 'N/A';
        final creationMethod = data['creationMethod'];
        final isRoutine = creationMethod == 'TaskCreationMethod.routine' ||
            creationMethod == 'routine';

        if (isDeleted) {
          deletedCount++;
          if (isRoutine) {
            routineDeletedCount++;
            routineDeletedTitles.add(title);
          }
        } else {
          activeCount++;
          if (isRoutine) {
            routineActiveCount++;
            routineActiveTitles.add(title);
          }
        }
      }

      print('📊 FIREBASE DIRECT ANALYSIS:');
      print('  - Active documents: $activeCount');
      print('  - Deleted documents: $deletedCount');
      print('  - Active routine blocks: $routineActiveCount');
      print('  - Deleted routine blocks: $routineDeletedCount');

      if (routineActiveTitles.isNotEmpty) {
        print(
            '  - Active routine titles: ${routineActiveTitles.take(5).join(", ")}${routineActiveTitles.length > 5 ? "..." : ""}');
      }

      if (routineDeletedTitles.isNotEmpty) {
        print(
            '  - Deleted routine titles: ${routineDeletedTitles.take(5).join(", ")}${routineDeletedTitles.length > 5 ? "..." : ""}');
      }
    } catch (e) {
      print('❌ Error analyzing Firebase directly: $e');
    }
  }

  /// 追跡可能な削除実行
  static Future<void> _executeTrackedDeletion() async {
    try {
      print('🗑️ Executing tracked routine block deletion...');

      // 削除前のスナップショット
      final beforeBlocks = BlockService.getAllBlocks();
      final beforeRoutineBlocks = beforeBlocks
          .where(
            (block) => block.creationMethod == TaskCreationMethod.routine,
          )
          .toList();

      print(
          '📸 Pre-deletion snapshot: ${beforeRoutineBlocks.length} routine blocks');

      // 削除実行
      await BlockSyncService().deleteRoutineBlocksWithSync();

      // 削除後のスナップショット
      final afterBlocks = BlockService.getAllBlocks();
      final afterRoutineBlocks = afterBlocks
          .where(
            (block) => block.creationMethod == TaskCreationMethod.routine,
          )
          .toList();

      print(
          '📸 Post-deletion snapshot: ${afterRoutineBlocks.length} routine blocks');
      print(
          '🔢 Deletion result: ${beforeRoutineBlocks.length - afterRoutineBlocks.length} blocks removed locally');

      // 残ったブロックの詳細
      if (afterRoutineBlocks.isNotEmpty) {
        print('⚠️ Remaining routine blocks:');
        for (final block in afterRoutineBlocks) {
          print(
              '  - "${block.title}" (ID: ${block.id}, cloudId: ${block.cloudId})');
        }
      }
    } catch (e) {
      print('❌ Error in tracked deletion: $e');
    }
  }

  /// 強制同期実行
  static Future<void> _executeForcedSync() async {
    try {
      print('🔄 Executing forced sync...');

      // 同期前のスナップショット
      final beforeBlocks = BlockService.getAllBlocks();
      final beforeRoutineBlocks = beforeBlocks
          .where(
            (block) => block.creationMethod == TaskCreationMethod.routine,
          )
          .toList();

      print(
          '📸 Pre-sync snapshot: ${beforeRoutineBlocks.length} routine blocks');

      // クールダウンをクリアして強制同期
      BlockUtilities.clearDeletionCooldown();
      final syncResult = await BlockSyncService.syncAllBlocks();

      print(
          '🔄 Sync result: success=${syncResult.success}, synced=${syncResult.syncedCount}, failed=${syncResult.failedCount}');

      // 同期後のスナップショット
      final afterBlocks = BlockService.getAllBlocks();
      final afterRoutineBlocks = afterBlocks
          .where(
            (block) => block.creationMethod == TaskCreationMethod.routine,
          )
          .toList();

      print(
          '📸 Post-sync snapshot: ${afterRoutineBlocks.length} routine blocks');
      print(
          '🔢 Sync impact: ${afterRoutineBlocks.length - beforeRoutineBlocks.length} blocks added/removed');

      // 新たに現れたブロックの詳細
      if (afterRoutineBlocks.length > beforeRoutineBlocks.length) {
        print('⚠️ NEW BLOCKS APPEARED AFTER SYNC:');
        final newBlocks = afterRoutineBlocks
            .where((after) =>
                !beforeRoutineBlocks.any((before) => before.id == after.id))
            .toList();

        for (final block in newBlocks) {
          print(
              '  - "${block.title}" (ID: ${block.id}, cloudId: ${block.cloudId})');
        }
      }
    } catch (e) {
      print('❌ Error in forced sync: $e');
    }
  }



  /// 特定のcloudIdの詳細状態確認
  static Future<void> debugSpecificBlock(String cloudId) async {
    try {
      print('🔍 Debugging specific block: $cloudId');

      // Firebase直接確認
      final docRef = userCollection.doc(cloudId);
      final docSnapshot =
          await docRef.get(const GetOptions(source: Source.server));

      if (docSnapshot.exists) {
        final data = docSnapshot.data() as Map<String, dynamic>;
        print('☁️ Firebase document exists:');
        print('  - title: ${data['title']}');
        print('  - isDeleted: ${data['isDeleted']}');
        print('  - creationMethod: ${data['creationMethod']}');
        print('  - lastModified: ${data['lastModified']}');
        print('  - All keys: ${data.keys.toList()}');
      } else {
        print('☁️ Firebase document does not exist');
      }

      // ローカル確認
      final localBlocks = BlockService.getAllBlocks();
      final localBlock =
          localBlocks.where((b) => b.cloudId == cloudId).firstOrNull;

      if (localBlock != null) {
        print('📱 Local block exists:');
        print('  - title: ${localBlock.title}');
        print('  - id: ${localBlock.id}');
        print('  - creationMethod: ${localBlock.creationMethod}');
        print('  - isDeleted: ${localBlock.isDeleted}');
      } else {
        print('📱 Local block does not exist');
      }
    } catch (e) {
      print('❌ Error debugging specific block: $e');
    }
  }
}
