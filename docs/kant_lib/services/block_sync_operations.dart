import '../models/block.dart';
import '../models/syncable_model.dart';
import 'data_sync_service.dart';
import 'block_service.dart';
import 'auth_service.dart';
import 'conflict_detector.dart';
import 'block_deduplicator.dart';
import 'block_local_data_manager.dart';
import 'block_cloud_operations.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'app_settings_service.dart';
import 'sync_kpi.dart';

/// ブロック同期操作を担当するクラス
class BlockSyncOperations {
  static String _dayKey(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  static List<List<String>> _chunk(List<String> values, int size) {
    if (values.isEmpty) return const [];
    final out = <List<String>>[];
    for (var i = 0; i < values.length; i += size) {
      final end = (i + size) > values.length ? values.length : (i + size);
      out.add(values.sublist(i, end));
    }
    return out;
  }

  /// dayKeys array-contains-any でのブロック同期（カレンダー週/月などのまとめ取得用）
  /// NOTE: これは “事前取得” 用なので diff deletion はしない（削除は dayKey同期で担保する）。
  static Future<SyncResult> syncBlocksByDayKeysAny(
    List<String> dayKeys,
    DataSyncService<Block> syncService,
  ) async {
    final keys = dayKeys.where((k) => k.length == 10).toSet().toList()..sort();
    if (keys.isEmpty) {
      return SyncResult(
        success: true,
        syncedCount: 0,
        failedCount: 0,
        conflicts: const [],
      );
    }
    int applied = 0;
    int failed = 0;
    // Firestore array-contains-any supports up to 10 values.
    for (final chunk in _chunk(keys, 10)) {
      try {
        final snap = await syncService.userCollection
            .where('dayKeys', arrayContainsAny: chunk)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 25));
        try {
          SyncKpi.queryReads += snap.docs.length;
        } catch (_) {}
        for (final doc in snap.docs) {
          try {
            final data = doc.data() as Map<String, dynamic>;
            data['cloudId'] = doc.id;
            final normalized = Map<String, dynamic>.from(
              BlockCloudOperations.normalizeCloudJson(Map<String, dynamic>.from(data)),
            );
            BlockCloudOperations.normalizeTimestamps(normalized);
            await BlockLocalDataManager.applyRemoteJsonToLocal(normalized);
            applied++;
          } catch (_) {}
        }
      } catch (e) {
        failed++;
        print('⚠️ syncBlocksByDayKeysAny failed for chunk=$chunk: $e');
      }
    }
    return SyncResult(
      success: failed == 0,
      syncedCount: applied,
      failedCount: failed,
      conflicts: const [],
    );
  }

  /// dayKey でのブロック同期（Phase 4）
  static Future<SyncResult> syncBlocksByDayKey(
    DateTime date,
    DataSyncService<Block> syncService,
  ) async {
    final dayKey = _dayKey(date);
    try {
      print('🔄 Syncing blocks for dayKey: $dayKey');

      QuerySnapshot? querySnapshot;
      final sw = Stopwatch()..start();
      querySnapshot = await syncService.userCollection
          .where('dayKeys', arrayContains: dayKey)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 20));
      try {
        SyncKpi.queryReads += querySnapshot.docs.length;
      } catch (_) {}
      print(
          '🕒 SYNC: Block dayKeys query done in ${sw.elapsedMilliseconds} ms');

      final remoteBlocks = <Block>[];
      final remoteJsons = <Map<String, dynamic>>[];
      final remoteCloudIds = <String>{};
      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          remoteCloudIds.add(doc.id);
          final normalized =
              Map<String, dynamic>.from(BlockCloudOperations.normalizeCloudJson(
            Map<String, dynamic>.from(data),
          ));
          BlockCloudOperations.normalizeTimestamps(normalized);
          final block = syncService.createFromCloudJson(data);
          remoteBlocks.add(block);
          remoteJsons.add(normalized);
        } catch (_) {}
      }

      int syncedCount = 0;
      int failedCount = 0;
      final conflicts = <ConflictResolution>[];

      for (var i = 0; i < remoteBlocks.length; i++) {
        final remoteBlock = remoteBlocks[i];
        try {
          final localBlock = await BlockLocalDataManager.getLocalItemByCloudId(
              remoteBlock.cloudId!);
          if (localBlock == null) {
            try {
              await BlockLocalDataManager.applyRemoteJsonToLocal(remoteJsons[i]);
            } catch (_) {
              await BlockLocalDataManager.saveToLocal(remoteBlock);
            }
            syncedCount++;
          } else if (localBlock.hasConflictWith(remoteBlock)) {
            try {
              await BlockLocalDataManager.applyRemoteJsonToLocal(remoteJsons[i]);
            } catch (_) {
              await syncService.resolveConflict(localBlock, remoteBlock);
            }
            conflicts.add(ConflictResolution.localNewer);
            syncedCount++;
          }
        } catch (e) {
          print('❌ Failed to process remote block: $e');
          failedCount++;
        }
      }

      // Phase 8: dayKeys 同期が正なので diff deletion を復帰（移動/短縮で dayKey から外れたものをローカルから外す）
      try {
        final locals = await BlockLocalDataManager.getLocalItems();
        int deleted = 0;
        for (final b in locals) {
          if (b.isDeleted) continue;
          // IMPORTANT:
          // ローカル更新（未同期）を remote diff と誤認して消してしまうと、
          // 「編集しても何も起きない/元に戻る」症状になる。
          // 例: 日付移動（dayKeys変更）→ upload失敗/オフライン → 次の dayKey 同期で remote に無いと判断され削除。
          if (b.needsSync) continue;
          final cid = b.cloudId;
          if (cid == null || cid.isEmpty) continue; // local-onlyは守る
          final keys = b.dayKeys;
          if (keys == null || !keys.contains(dayKey)) continue;
          if (!remoteCloudIds.contains(cid)) {
            await BlockLocalDataManager.deleteLocalItem(b);
            deleted++;
          }
        }
        if (deleted > 0) {
          print('🧹 Block diff deletion: deleted=$deleted dayKey=$dayKey');
        }
      } catch (e) {
        print('⚠️ Block diff deletion failed: $e');
      }

      return SyncResult(
        success: failedCount == 0,
        syncedCount: syncedCount,
        failedCount: failedCount,
        conflicts: conflicts,
      );
    } catch (e) {
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  // Removed in Phase 8: use dayKeys-based sync only.

  /// プロジェクト別ブロック同期
  static Future<SyncResult> syncBlocksByProject(
      String projectId, DataSyncService<Block> syncService) async {
    try {
      print('🔄 Syncing blocks for project: $projectId');

      // 指定プロジェクトのFirestoreクエリ（複合インデックス不要: projectIdのみフィルタし、isDeletedはクライアントで除外）
      final querySnapshot = await syncService.userCollection
          .where('projectId', isEqualTo: projectId)
          .get(const GetOptions(source: Source.server));
      try {
        SyncKpi.queryReads += querySnapshot.docs.length;
      } catch (_) {}

      final remoteBlocks = <Block>[];
      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          if ((data['isDeleted'] ?? false) == true) {
            continue;
          }
          final block = syncService.createFromCloudJson(data);
          remoteBlocks.add(block);
        } catch (e) {
          print('⚠️ Failed to parse block ${doc.id}: $e');
        }
      }

      // ローカルブロックとの競合解決
      int syncedCount = 0;
      int failedCount = 0;
      final conflicts = <ConflictResolution>[];

      for (final remoteBlock in remoteBlocks) {
        try {
          final localBlock = await BlockLocalDataManager.getLocalItemByCloudId(
              remoteBlock.cloudId!);

          if (localBlock == null) {
            await BlockLocalDataManager.saveToLocal(remoteBlock);
            syncedCount++;
          } else if (localBlock.hasConflictWith(remoteBlock)) {
            await syncService.resolveConflict(localBlock, remoteBlock);
            conflicts.add(ConflictResolution.localNewer); // 簡易的な記録
            syncedCount++;
          }
        } catch (e) {
          print('❌ Failed to process remote block: $e');
          failedCount++;
        }
      }

      print(
          '✅ Project blocks sync completed: $syncedCount synced, $failedCount failed');
      return SyncResult(
        success: failedCount == 0,
        syncedCount: syncedCount,
        failedCount: failedCount,
        conflicts: conflicts,
      );
    } catch (e) {
      print('❌ Project blocks sync failed: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  /// ブロック完了状態の同期対応
  static Future<void> markBlockCompletedWithSync(
      String blockId, bool isCompleted, dynamic syncService) async {
    try {
      final blocks = BlockService.getAllBlocks();
      final block = blocks.where((b) => b.id == blockId).firstOrNull;
      if (block == null) return;

      block.isCompleted = isCompleted;
      // 完了更新時はここで確実に更新時刻を上げる（UIでは上げない方針）
      try {
        final deviceId = AuthService.getCurrentUserId() ?? '';
        // deviceId は markAsModified の引数として使う設計
        block.markAsModified(deviceId);
      } catch (_) {}
      await syncService.updateBlockWithSync(block);

      print(
          '✅ Updated block completion status with sync: ${block.title} -> $isCompleted');
    } catch (e) {
      print('❌ Failed to update block completion status with sync: $e');
      rethrow;
    }
  }

  /// Blockの同期処理をオーバーライド（削除直後の再ダウンロード防止）
  static Future<SyncResult> performSync(
    DataSyncService<Block> syncService,
    Future<void> Function(String) deleteBlockWithSync, {
    bool forceFullSync = false,
    bool uploadLocalChanges = true,
  }) async {
    try {
      print('🔄 Starting block-specific sync...');
      print('🔍 DEBUG: Current user ID: ${AuthService.getCurrentUserId()}');
      print('🔍 DEBUG: User logged in: ${AuthService.isLoggedIn()}');

      final localItems = await BlockLocalDataManager.getLocalItems();
      print('🔍 DEBUG: Found ${localItems.length} local items');
      if (localItems.isNotEmpty) {
        print('🔍 DEBUG: First local item: ${localItems.first.title}');
      }

      // 1) ローカルの未同期（outbox相当）を先にアップロード
      int syncedCount = 0;
      int failedCount = 0;
      final conflicts = <ConflictResolution>[];
      if (uploadLocalChanges) {
        for (final localItem in localItems) {
          try {
            if (localItem.needsSync) {
              await syncService.uploadToFirebase(localItem);
              syncedCount++;
            }
          } catch (e) {
            print('❌ Failed to sync local item: $e');
            failedCount++;
          }
        }
      }

      // 2) リモート取得（差分同期が既定）
      DateTime? cursorUtc = forceFullSync
          ? null
          : AppSettingsService.getCursor(AppSettingsService.keyCursorBlocks);

      // 既存端末の移行ケア:
      // - cursor 未設定のまま「汎用同期」を走らせると blocks 全件GETになり得る
      // - ここではローカルに十分な履歴が既にある前提で、ローカルlastModifiedを起点に cursor を種まきして
      //   “初回フル同期”を避ける（read爆発回避が主目的）
      // - ただし端末時計が未来にずれていると取りこぼしになるため、seedは now-5min を上限にクリップする
      if (!forceFullSync && cursorUtc == null && localItems.isNotEmpty) {
        try {
          DateTime? maxLocalUtc;
          for (final b in localItems) {
            final lm = b.lastModified.toUtc();
            if (maxLocalUtc == null || lm.isAfter(maxLocalUtc)) {
              maxLocalUtc = lm;
            }
          }
          if (maxLocalUtc != null) {
            final cap = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
            final seeded = maxLocalUtc!.isAfter(cap) ? cap : maxLocalUtc!;
            await AppSettingsService.setCursor(AppSettingsService.keyCursorBlocks, seeded);
            cursorUtc = seeded;
            print('🧭 Seeded blocks diff cursor from local lastModified (avoid full sync)');
          }
        } catch (_) {}
      }

      if (!forceFullSync && cursorUtc != null) {
        // IMPORTANT:
        // - 全件取得に落とさない（read爆発を防ぐ）
        // - tombstone（isDeleted=true）も削除伝播として拾うため、isDeletedフィルタは掛けない
        final fromUtc = cursorUtc.subtract(const Duration(seconds: 10)); // skew tolerance
        final fromIso = fromUtc.toUtc().toIso8601String();
        const int pageSize = 400;
        DateTime? maxRemoteLastModifiedUtc;
        String? pageAfterLastModifiedIso;
        String? pageAfterDocId;
        int applied = 0;

        while (true) {
          Query query = syncService.userCollection
              .where('lastModified', isGreaterThan: fromIso)
              .orderBy('lastModified')
              .orderBy(FieldPath.documentId)
              .limit(pageSize);

          if (pageAfterLastModifiedIso != null && pageAfterDocId != null) {
            query = query.startAfter([pageAfterLastModifiedIso, pageAfterDocId]);
          }

          QuerySnapshot snap;
          try {
            snap = await query
                .get(const GetOptions(source: Source.server))
                .timeout(const Duration(seconds: 25));
          } catch (e) {
            print('❌ Block diff sync failed (no full fallback): $e');
            return SyncResult(
              success: false,
              error: 'Block diff sync failed: $e',
              failedCount: 1,
              conflicts: const [],
            );
          }
          try {
            SyncKpi.queryReads += snap.docs.length;
          } catch (_) {}

          if (snap.docs.isEmpty) {
            break;
          }

          for (final doc in snap.docs) {
            try {
              final raw = doc.data();
              if (raw is! Map<String, dynamic>) {
                continue;
              }
              final data = Map<String, dynamic>.from(raw);
              final normalized = Map<String, dynamic>.from(
                BlockCloudOperations.normalizeCloudJson({
                  ...data,
                  'cloudId': doc.id,
                }),
              );
              BlockCloudOperations.normalizeTimestamps(normalized);
              await BlockLocalDataManager.applyRemoteJsonToLocal(normalized);
              applied++;

              // max(lastModified) を更新（カーソル前進は取得結果由来のみ）
              try {
                final lmRaw = normalized['lastModified'];
                DateTime? lm;
                if (lmRaw is String) lm = DateTime.tryParse(lmRaw);
                if (lmRaw is Timestamp) lm = lmRaw.toDate();
                if (lm != null) {
                  final utc = lm.toUtc();
                  final cur = maxRemoteLastModifiedUtc;
                  if (cur == null || utc.isAfter(cur)) {
                    maxRemoteLastModifiedUtc = utc;
                  }
                }
              } catch (_) {}
            } catch (e) {
              failedCount++;
              print('❌ Block diff apply failed for doc=${doc.id}: $e');
            }
          }

          // next page cursor (orderBy lastModified + docId)
          final lastDoc = snap.docs.last;
          final lastRaw = lastDoc.data();
          final lastData =
              lastRaw is Map<String, dynamic> ? lastRaw : <String, dynamic>{};
          String? lastLmIso;
          try {
            final raw = lastData['lastModified'];
            if (raw is String) lastLmIso = raw;
            if (raw is Timestamp) lastLmIso = raw.toDate().toIso8601String();
          } catch (_) {}
          // lastModified が取れない場合はページング不能なので打ち切る（ただし全件へは落ちない）
          if (lastLmIso == null || lastLmIso.isEmpty) {
            break;
          }
          pageAfterLastModifiedIso = lastLmIso;
          pageAfterDocId = lastDoc.id;

          if (snap.docs.length < pageSize) {
            break;
          }
        }

        // diff cursor を更新（0件なら進めない）
        if (maxRemoteLastModifiedUtc != null) {
          final key = AppSettingsService.keyCursorBlocks;
          final current = AppSettingsService.getCursor(key);
          var candidate =
              maxRemoteLastModifiedUtc!.toUtc().subtract(const Duration(milliseconds: 1));
          if (candidate.millisecondsSinceEpoch < 0) {
            candidate = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
          }
          if (current != null && candidate.isBefore(current)) {
            candidate = current;
          }
          await AppSettingsService.setCursor(key, candidate);
        }

        print('✅ Block diff sync applied=$applied failed=$failedCount');
        return SyncResult(
          success: failedCount == 0,
          syncedCount: syncedCount + applied,
          failedCount: failedCount,
          conflicts: conflicts,
        );
      }

      // 3) 初回/手動など: フル同期（バッチ適用で短時間化。Firebase への書き込みは発生しない）
      // NOTE: ここでの全件取得は「例外経路」。通常運用では diff cursor が入っている前提。
      List<Block> remoteItems = [];
      remoteItems = await syncService.downloadFromFirebase();
      print('🔍 DEBUG: Downloaded ${remoteItems.length} remote items');
      if (remoteItems.isNotEmpty) {
        print('🔍 DEBUG: First remote item: ${remoteItems.first.title}');
      }

      DateTime? maxRemoteLastModifiedUtc;
      if (remoteItems.isNotEmpty) {
        final normalizedList = <Map<String, dynamic>>[];
        for (final b in remoteItems) {
          try {
            final lm = b.lastModified.toUtc();
            if (maxRemoteLastModifiedUtc == null ||
                lm.isAfter(maxRemoteLastModifiedUtc)) {
              maxRemoteLastModifiedUtc = lm;
            }
          } catch (_) {}
          final m = Map<String, dynamic>.from(b.toJson());
          m['cloudId'] = b.cloudId ?? b.id;
          if (b.startAt != null) {
            m['startAt'] = b.startAt!.toUtc().toIso8601String();
          }
          if (b.endAtExclusive != null) {
            m['endAtExclusive'] =
                b.endAtExclusive!.toUtc().toIso8601String();
          }
          m['allDay'] = b.allDay;
          if (b.dayKeys != null) m['dayKeys'] = b.dayKeys;
          if (b.monthKeys != null) m['monthKeys'] = b.monthKeys;
          normalizedList.add(m);
        }
        try {
          final applied =
              await BlockLocalDataManager.applyRemoteJsonToLocalBatch(
                  normalizedList);
          syncedCount += applied;
          print('✅ Block full sync batch applied: $applied items');
        } catch (e) {
          print('❌ Block full sync batch failed: $e');
          failedCount += 1;
        }
      }

      // フル同期でも cursor を確定（取得結果由来のみ）
      if (maxRemoteLastModifiedUtc != null) {
        final key = AppSettingsService.keyCursorBlocks;
        final current = AppSettingsService.getCursor(key);
        var candidate = maxRemoteLastModifiedUtc!
            .toUtc()
            .subtract(const Duration(milliseconds: 1));
        if (candidate.millisecondsSinceEpoch < 0) {
          candidate = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        }
        if (current != null && candidate.isBefore(current)) {
          candidate = current;
        }
        await AppSettingsService.setCursor(key, candidate);
      }

      // 同期後の重複整理（自然キー単位で集約）
      // まず cloudId 単位で厳密に集約
      try {
        final removedByCloudId =
            await BlockDeduplicator.deduplicateByCloudId(deleteBlockWithSync);
        if (removedByCloudId > 0) {
          print('🧹 DEDUP: Removed $removedByCloudId duplicates by cloudId');
        }
      } catch (e) {
        print('⚠️ DEDUP by cloudId failed: $e');
      }

      // 自然キーによる集約は廃止（ID/cloudIdでのみ管理）

      final result = SyncResult(
        success: true,
        syncedCount: syncedCount,
        failedCount: failedCount,
        conflicts: conflicts,
      );

      print('✅ Block sync completed: ${result}');
      return result;
    } catch (e) {
      print('❌ Block sync failed: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  /// すべてのBlockを同期
  static Future<SyncResult> syncAllBlocks(DataSyncService<Block> syncService,
      bool Function() isSyncing, void Function(bool) setSyncing) async {
    // 既に同期中の場合はスキップ（競合防止）
    if (isSyncing()) {
      print('⚠️ Block sync already in progress, skipping...');
      return SyncResult(
        success: true,
        syncedCount: 0,
        failedCount: 0,
      );
    }

    // クールダウンによる同期スキップは廃止（常に最新を取得）
    setSyncing(true);
    try {
      print('🔒 Block sync started (locked)');
      // NOTE:
      // blocks のアップロードは outbox / CRUD側で行う方針。
      // 全体同期（読取目的）でローカルneedsSyncを拾って自動アップロードすると
      // 「ユーザー無操作でも書き込みが増える」ため、アップロードPhaseを無効化する。
      final result = await syncService.performSync(uploadLocalChanges: false);
      print('🔓 Block sync completed (unlocked)');
      return result;
    } catch (e) {
      print('❌ Failed to sync all blocks: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    } finally {
      setSyncing(false);
    }
  }

  /// 差分同期: lastModified >= cursor のブロックのみ適用（当日範囲に限定）
  static Future<SyncResult> syncBlocksSince(DateTime cursorUtc, DateTime date,
      DataSyncService<Block> syncService) async {
    try {
      final from = cursorUtc.subtract(const Duration(seconds: 5));
      final dayStart = DateTime(date.year, date.month, date.day);
      final dayEndExclusive = dayStart.add(const Duration(days: 1));

      QuerySnapshot? querySnapshot;
      try {
        querySnapshot = await syncService.userCollection
            .where('lastModified',
                isGreaterThanOrEqualTo: from.toIso8601String())
            .get(const GetOptions(source: Source.server));
      } catch (e) {
        querySnapshot = await syncService.userCollection
            .get(const GetOptions(source: Source.server));
      }

      final remoteBlocks = <Block>[];
      final remoteJsons = <Map<String, dynamic>>[];
      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          if ((data['isDeleted'] ?? false) == true) continue;
          final normalized = Map<String, dynamic>.from(
              BlockCloudOperations.normalizeCloudJson(Map<String, dynamic>.from(data)));
          BlockCloudOperations.normalizeTimestamps(normalized);
          final block = syncService.createFromCloudJson(data);
          final d = DateTime(block.executionDate.year,
              block.executionDate.month, block.executionDate.day);
          final inDay = !d.isBefore(dayStart) && d.isBefore(dayEndExclusive);
          if (inDay) {
            remoteBlocks.add(block);
            remoteJsons.add(normalized);
          }
        } catch (_) {}
      }

      int applied = 0;
      for (var i = 0; i < remoteBlocks.length; i++) {
        final remote = remoteBlocks[i];
        try {
          final local = await BlockLocalDataManager.getLocalItemByCloudId(
              remote.cloudId!);
          final shouldApply = () {
            if (local == null) return true;
            return remote.lastModified.isAfter(local.lastModified);
          }();
          if (shouldApply) {
            try {
              await BlockLocalDataManager.applyRemoteJsonToLocal(remoteJsons[i]);
            } catch (_) {
              await BlockLocalDataManager.saveToLocal(remote);
            }
            applied++;
          }
        } catch (_) {}
      }

      return SyncResult(
          success: true,
          syncedCount: applied,
          failedCount: 0,
          conflicts: const []);
    } catch (e) {
      return SyncResult(
          success: false,
          failedCount: 1,
          error: e.toString(),
          conflicts: const []);
    }
  }
}
