import '../models/block.dart';
import 'block_service.dart';
import 'block_data_validator.dart';
import 'block_utilities.dart';

/// ブロックのローカルデータ管理を担当するクラス
class BlockLocalDataManager {
  /// ローカルのすべてのブロックを取得
  static Future<List<Block>> getLocalItems() async {
    try {
      await BlockService.initialize();
      return BlockService.getAllBlocks();
    } catch (e) {
      print('❌ Failed to get local blocks: $e');
      return [];
    }
  }

  /// CloudIDでローカルブロックを取得
  static Future<Block?> getLocalItemByCloudId(String cloudId) async {
    try {
      final blocks = BlockService.getAllBlocks();

      // 各ブロックを安全にチェック
      for (final block in blocks) {
        try {
          if (block.cloudId == cloudId) {
            return block;
          }
        } catch (e) {
          if (e.toString().contains('RangeError')) {
            continue;
          }
          rethrow;
        }
      }

      return null;
    } catch (e) {
      print('❌ Failed to get local block by cloudId: $e');

      // RangeErrorの場合は、Hiveデータをクリアして再試行
      if (e.toString().contains('RangeError')) {
        try {
          await BlockService.clearAllBlocks();
          return null; // 新しいデータとして扱う
        } catch (clearError) {
          print('❌ Failed to clear corrupted data: $clearError');
        }
      }

      return null;
    }
  }

  static bool _sameStringList(List<String>? a, List<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Canonical フィールド（startAt/dayKeys など）を必要時のみ反映する。
  ///
  /// NOTE:
  /// - 旧スキーマ由来（canonical欠落）のデータで既存値を消さないため、
  ///   incoming が null の場合は既存値を保持する。
  static bool _applyCanonicalIfPresent({
    required Block target,
    required Block incoming,
  }) {
    final hasCanonicalPayload = incoming.startAt != null ||
        incoming.endAtExclusive != null ||
        incoming.dayKeys != null ||
        incoming.monthKeys != null;
    if (!hasCanonicalPayload) return false;

    bool changed = false;
    if (incoming.startAt != null && target.startAt != incoming.startAt) {
      target.startAt = incoming.startAt;
      changed = true;
    }
    if (incoming.endAtExclusive != null &&
        target.endAtExclusive != incoming.endAtExclusive) {
      target.endAtExclusive = incoming.endAtExclusive;
      changed = true;
    }
    if (incoming.dayKeys != null &&
        !_sameStringList(target.dayKeys, incoming.dayKeys)) {
      target.dayKeys = List<String>.from(incoming.dayKeys!);
      changed = true;
    }
    if (incoming.monthKeys != null &&
        !_sameStringList(target.monthKeys, incoming.monthKeys)) {
      target.monthKeys = List<String>.from(incoming.monthKeys!);
      changed = true;
    }
    if (target.allDay != incoming.allDay) {
      target.allDay = incoming.allDay;
      changed = true;
    }
    return changed;
  }

  /// ブロックをローカルに保存
  static Future<void> saveToLocal(Block block) async {
    try {
      // 削除されたブロックは保存しない
      if (block.isDeleted) {
        return;
      }

      // サニタイズして安全な値に
      final sanitizedBlock = BlockDataValidator.sanitizeBlock(block);

      // 既存のブロックを確認（cloudId優先）
      Block? existingBlock;
      try {
        if (sanitizedBlock.cloudId != null &&
            sanitizedBlock.cloudId!.isNotEmpty) {
          existingBlock = await getLocalItemByCloudId(sanitizedBlock.cloudId!);
        }
      } catch (e) {
        if (e.toString().contains('RangeError')) {
          existingBlock = null;
        } else {
          rethrow;
        }
      }

      // cloudIdベースでのみ管理。墓石・自然キーによる抑止やマージは行わない
      if (existingBlock != null) {
        try {
          // 既存更新でも canonical(startAt/dayKeys 等) を落とさないように反映する。
          final cloudId = sanitizedBlock.cloudId ?? '';
          final mergedJson = sanitizedBlock.toCloudJson();
          existingBlock.fromCloudJson(mergedJson);
          _applyCanonicalIfPresent(target: existingBlock, incoming: sanitizedBlock);
          existingBlock.lastModified = sanitizedBlock.lastModified;
          await BlockService.updateBlock(existingBlock);

          // 同一cloudIdの重複ローカルにも canonical を伝播して表示ゆらぎを防ぐ。
          try {
            final all = BlockService.getAllBlocks();
            for (final b in all) {
              if (b.id == existingBlock.id) continue;
              if (b.cloudId != cloudId) continue;
              final changed =
                  _applyCanonicalIfPresent(target: b, incoming: existingBlock);
              if (!changed) continue;
              b.lastModified = existingBlock.lastModified;
              await BlockService.updateBlock(b);
            }
          } catch (_) {}
        } catch (e) {
          print(
              '❌ Failed to update existing block, trying direct replacement: $e');
          await BlockService.deleteBlock(existingBlock.id);
          await BlockService.addBlock(sanitizedBlock);
        }
      } else {
        await BlockService.addBlock(sanitizedBlock);
      }
    } catch (e) {
      print('❌ Failed to save block locally: $e');
      rethrow;
    }
  }

  /// リモートのCloud JSON（正規化済み）をローカルへ一括適用。フル同期専用。flush・通知は各1回。
  static Future<int> applyRemoteJsonToLocalBatch(
    List<Map<String, dynamic>> normalizedJsonList,
  ) async {
    if (normalizedJsonList.isEmpty) return 0;
    try {
      await BlockService.initialize();
      final localBlocks = await getLocalItems();
      final byCloudIdRep = <String, Block>{};
      final byCloudIdAll = <String, List<Block>>{};
      for (final b in localBlocks) {
        final cid = b.cloudId ?? b.id;
        if (cid.isEmpty) continue;
        byCloudIdAll.putIfAbsent(cid, () => []).add(b);
        byCloudIdRep.putIfAbsent(cid, () => b);
      }

      final toAdd = <Block>[];
      final toDelete = <String>[];
      final toUpdateIds = <String>{};
      final toUpdateList = <Block>[];

      for (final normalizedJson in normalizedJsonList) {
        try {
          final cid = (normalizedJson['cloudId'] as String?) ??
              (normalizedJson['id'] as String?);
          if (cid == null || cid.isEmpty) continue;

          final incomingDeleted = (normalizedJson['isDeleted'] ?? false) == true;
          final existingRep = byCloudIdRep[cid];
          final allWithCid = byCloudIdAll[cid];

          if (existingRep == null) {
            if (incomingDeleted) continue;
            final created = Block.fromJson(normalizedJson);
            toAdd.add(created);
            continue;
          }

          if (incomingDeleted) {
            existingRep.isDeleted = true;
            if (normalizedJson['lastModified'] != null) {
              try {
                existingRep.lastModified =
                    DateTime.parse(normalizedJson['lastModified']);
              } catch (_) {}
            }
            if (!toUpdateIds.contains(existingRep.id)) {
              toUpdateIds.add(existingRep.id);
              toUpdateList.add(existingRep);
            }
            continue;
          }

          try {
            existingRep.fromCloudJson(normalizedJson);
            if (normalizedJson['lastModified'] != null) {
              try {
                existingRep.lastModified =
                    DateTime.parse(normalizedJson['lastModified']);
              } catch (_) {}
            }
            if (!toUpdateIds.contains(existingRep.id)) {
              toUpdateIds.add(existingRep.id);
              toUpdateList.add(existingRep);
            }
            if (allWithCid != null) {
              for (final b in allWithCid) {
                if (b.id == existingRep.id) continue;
                bool changed = false;
                if (b.isSkipped != existingRep.isSkipped) {
                  b.isSkipped = existingRep.isSkipped;
                  changed = true;
                }
                if (b.isCompleted != existingRep.isCompleted) {
                  b.isCompleted = existingRep.isCompleted;
                  changed = true;
                }
                if (changed && !toUpdateIds.contains(b.id)) {
                  toUpdateIds.add(b.id);
                  toUpdateList.add(b);
                }
              }
            }
          } catch (_) {
            try {
              if (toUpdateIds.contains(existingRep.id)) {
                toUpdateList.removeWhere((x) => x.id == existingRep.id);
                toUpdateIds.remove(existingRep.id);
              }
              toDelete.add(existingRep.id);
              final created = Block.fromJson(normalizedJson);
              toAdd.add(created);
            } catch (__) {}
          }
        } catch (_) {}
      }

      await BlockService.batchPutBlocks(
        toAdd: toAdd,
        toUpdate: toUpdateList,
        toDelete: toDelete,
      );
      BlockUtilities.notifyTaskProviderUpdate();
      return toAdd.length + toUpdateList.length;
    } catch (e) {
      print('❌ applyRemoteJsonToLocalBatch failed: $e');
      rethrow;
    }
  }

  /// リモートのCloud JSON（正規化済み）をローカルへ適用（欠落キーはローカル値を保持）
  static Future<void> applyRemoteJsonToLocal(Map<String, dynamic> normalizedJson) async {
    try {
      // cloudId または id から既存を取得
      final String? cid = (normalizedJson['cloudId'] as String?) ?? (normalizedJson['id'] as String?);
      if (cid == null || cid.isEmpty) return;

      final existing = await getLocalItemByCloudId(cid);
      final incomingDeleted = (normalizedJson['isDeleted'] ?? false) == true;
      if (existing == null) {
        if (incomingDeleted) return;
        // 存在しない場合は新規作成（fromJsonで生成）
        try {
          final created = Block.fromJson(normalizedJson);
          await BlockService.addBlock(created);
        } catch (e) {
          // 生成に失敗した場合は無視
        }
        return;
      }

      if (incomingDeleted) {
        try {
          existing.isDeleted = true;
          if (normalizedJson['lastModified'] != null) {
            try {
              existing.lastModified = DateTime.parse(normalizedJson['lastModified']);
            } catch (_) {}
          }
          await BlockService.updateBlock(existing);
        } catch (_) {}
        return;
      }

      // 欠落キーは保持されるように fromCloudJson を直接適用
      try {
        existing.fromCloudJson(normalizedJson);
        // lastModified があれば適用
        if (normalizedJson['lastModified'] != null) {
          try {
            existing.lastModified = DateTime.parse(normalizedJson['lastModified']);
          } catch (_) {}
        }
        await BlockService.updateBlock(existing);
        // 追加: 同一cloudIdのローカル複製にも反映
        try {
          final all = BlockService.getAllBlocks();
          for (final b in all) {
            if (b.id == existing.id) continue;
            if (b.cloudId == cid) {
              bool changed = false;
              if (b.isSkipped != existing.isSkipped) { b.isSkipped = existing.isSkipped; changed = true; }
              if (b.isCompleted != existing.isCompleted) { b.isCompleted = existing.isCompleted; changed = true; }
              if (changed) {
                await BlockService.updateBlock(b);
              }
            }
          }
        } catch (_) {}
      } catch (e) {
        // 失敗時は置換フォールバック
        try {
          await BlockService.deleteBlock(existing.id);
          final created = Block.fromJson(normalizedJson);
          await BlockService.addBlock(created);
        } catch (_) {}
      }
    } catch (e) {
      // サイレントに失敗
    }
  }

  /// ローカルブロックを削除する（同期処理で使用）
  static Future<void> deleteLocalItem(Block item) async {
    try {
      // ローカルHiveから削除
      await BlockService.deleteBlock(item.id);

      // TaskProviderに更新を通知
      BlockUtilities.notifyTaskProviderUpdate();
    } catch (e) {
      print('❌ Failed to delete local block: ${item.title}, error: $e');
      rethrow;
    }
  }
}

/// Dynamic proxy to avoid direct imports from DataSyncService
class BlockLocalDataManagerProxy {
  BlockLocalDataManagerProxy._();
  static final instance = BlockLocalDataManagerProxy._();

  Future<void> applyRemoteJsonToLocal(Map<String, dynamic> normalizedJson) {
    return BlockLocalDataManager.applyRemoteJsonToLocal(normalizedJson);
  }
}
