import '../models/mode.dart';
import '../models/syncable_model.dart';
import 'data_sync_service.dart';
import 'mode_service.dart';
import 'device_info_service.dart';
import 'auth_service.dart';
import 'app_settings_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';


/// Mode同期サービス
class ModeSyncService extends DataSyncService<Mode> {
  static final ModeSyncService _instance = ModeSyncService._internal();
  factory ModeSyncService() => _instance;
  ModeSyncService._internal() : super('modes');

  @override
  String? get diffCursorKey => AppSettingsService.keyCursorModes;

  @override
  Mode createFromCloudJson(Map<String, dynamic> json) {
    return Mode.fromJson(json);
  }

  @override
  Future<List<Mode>> getLocalItems() async {
    try {
      await ModeService.ensureOpen();
      return ModeService.getAllModes();
    } catch (e) {
      print('❌ Failed to get local modes: $e');
      return [];
    }
  }

  @override
  Future<Mode?> getLocalItemByCloudId(String cloudId) async {
    try {
      final modes = ModeService.getAllModes();
      return modes.where((m) => m.cloudId == cloudId).firstOrNull;
    } catch (e) {
      print('❌ Failed to get local mode by cloudId: $e');
      return null;
    }
  }

  @override
  Future<void> saveToLocal(Mode mode) async {
    try {
      // 既存のモードを確認
      final existingMode = await getLocalItemByCloudId(mode.cloudId!);

      if (existingMode != null) {
        // 既存モードを更新
        existingMode.fromCloudJson(mode.toCloudJson());
        // 同期反映ではlastModifiedを更新しない
        await ModeService.updateMode(existingMode, touchLastModified: false);
      } else {
        // 新規モードを作成
        await ModeService.addMode(mode);
      }

      // print('✅ Saved mode locally: ${mode.name}'); // ログを無効化
    } catch (e) {
      print('❌ Failed to save mode locally: $e');
      rethrow;
    }
  }

  @override
  Future<Mode> handleManualConflict(Mode local, Mode remote) async {
    // Last-Write-Wins戦略：設定データは最新を優先
    print(
        '⚠️ Mode conflict resolved automatically (Last-Write-Wins): ${local.name}');
    print('  Local: ${local.lastModified} (v${local.version})');
    print('  Remote: ${remote.lastModified} (v${remote.version})');

    if (remote.lastModified.isAfter(local.lastModified)) {
      await saveToLocal(remote);
      return remote;
    } else {
      return local;
    }
  }

  /// モード作成時の同期対応
  Future<Mode> createModeWithSync({
    required String name,
    String? description,
    bool isActive = true,
    String? fixedId, // デフォルトモード用のオプション固定ID
  }) async {
    try {
      final deviceId = await DeviceInfoService.getDeviceId();
      final userId = AuthService.getCurrentUserId() ?? '';

      // ローカルでモード作成
      final now = DateTime.now();
      final mode = Mode(
        id: fixedId ?? 'mode_${now.millisecondsSinceEpoch}_${now.microsecond}',
        name: name,
        description: description,
        userId: userId,
        createdAt: now,
        lastModified: now,
        isActive: isActive,
        deviceId: deviceId,
        version: 1,
      );

      // ローカル保存
      await ModeService.addMode(mode);

      // 同期メタデータを設定
      mode.markAsModified(deviceId);

      // Firebaseに同期（ネットワークがあれば）
      try {
        await uploadToFirebase(mode);
      } catch (e) {
        print('⚠️ Failed to sync new mode to Firebase: $e');
        // ネットワークエラーでもローカル作成は成功とする
      }

      return mode;
    } catch (e) {
      print('❌ Failed to create mode with sync: $e');
      rethrow;
    }
  }

  /// モード更新時の同期対応
  Future<void> updateModeWithSync(Mode mode) async {
    try {
      final deviceId = await DeviceInfoService.getDeviceId();

      // 同期メタデータを更新
      mode.markAsModified(deviceId);

      // ローカル更新
      await ModeService.updateMode(mode);

      // Firebaseに同期（ネットワークがあれば）
      try {
        await uploadToFirebase(mode);
      } catch (e) {
        print('⚠️ Failed to sync updated mode to Firebase: $e');
        // ネットワークエラーでもローカル更新は成功とする
      }
    } catch (e) {
      print('❌ Failed to update mode with sync: $e');
      rethrow;
    }
  }

  /// モード削除時の同期対応
  Future<void> deleteModeWithSync(String modeId) async {
    try {
      final modes = ModeService.getAllModes();
      final mode = modes.where((m) => m.id == modeId).firstOrNull;
      if (mode == null) return;

      final deviceId = await DeviceInfoService.getDeviceId();

      // 論理削除マークを設定
      mode.isDeleted = true;
      mode.markAsModified(deviceId);

      // ローカル削除
      await ModeService.deleteMode(modeId);

      // Firebaseに削除を同期（ネットワークがあれば）
      try {
        if (mode.cloudId != null) {
          await deleteFromFirebase(mode.cloudId!);
        }
      } catch (e) {
        print('⚠️ Failed to sync mode deletion to Firebase: $e');
        // ネットワークエラーでもローカル削除は成功とする
      }
    } catch (e) {
      print('❌ Failed to delete mode with sync: $e');
      rethrow;
    }
  }

  /// アクティブ状態の同期対応
  Future<void> setModeActiveWithSync(String modeId, bool isActive) async {
    try {
      final modes = ModeService.getAllModes();
      final mode = modes.where((m) => m.id == modeId).firstOrNull;
      if (mode == null) return;

      mode.isActive = isActive;
      await updateModeWithSync(mode);

      print('✅ Updated mode active state with sync: ${mode.name} -> $isActive');
    } catch (e) {
      print('❌ Failed to update mode active state with sync: $e');
      rethrow;
    }
  }

  /// アクティブモードのみ同期
  Future<SyncResult> syncActiveModes() async {
    try {
      print('🔄 Syncing active modes only');

      // アクティブモードのFirestoreクエリ
      final querySnapshot = await userCollection
          .where('isDeleted', isEqualTo: false)
          .where('isActive', isEqualTo: true)
          .get();

      final remoteModes = <Mode>[];
      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final mode = createFromCloudJson(data);
          remoteModes.add(mode);
        } catch (e) {
          print('⚠️ Failed to parse mode ${doc.id}: $e');
        }
      }

      // ローカルモードとの競合解決
      int syncedCount = 0;
      int failedCount = 0;
      final conflicts = <ConflictResolution>[];

      for (final remoteMode in remoteModes) {
        try {
          final localMode = await getLocalItemByCloudId(remoteMode.cloudId!);

          if (localMode == null) {
            await saveToLocal(remoteMode);
            syncedCount++;
          } else if (localMode.hasConflictWith(remoteMode)) {
            await resolveConflict(localMode, remoteMode);
            conflicts.add(ConflictResolution.localNewer); // 簡易的な記録
            syncedCount++;
          }
        } catch (e) {
          print('❌ Failed to process remote mode: $e');
          failedCount++;
        }
      }

      print(
          '✅ Active modes sync completed: $syncedCount synced, $failedCount failed');
      return SyncResult(
        success: failedCount == 0,
        syncedCount: syncedCount,
        failedCount: failedCount,
        conflicts: conflicts,
      );
    } catch (e) {
      print('❌ Active modes sync failed: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  /// すべてのModeを同期
  static Future<SyncResult> syncAllModes() async {
    try {
      final syncService = ModeSyncService();
      return await syncService.performSync();
    } catch (e) {
      print('❌ Failed to sync all modes: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  /// モードの変更を監視
  Stream<List<Mode>> watchModeChanges() {
    return watchFirebaseChanges();
  }

  /// アクティブモード監視
  Stream<List<Mode>> watchActiveModes() {
    return userCollection
        .where('isDeleted', isEqualTo: false)
        .where('isActive', isEqualTo: true)
        .snapshots()
        .map((snapshot) {
      final items = <Mode>[];
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final item = createFromCloudJson(data);
          items.add(item);
        } catch (e) {
          print('⚠️ Failed to parse mode ${doc.id}: $e');
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

  /// デフォルトモードを同期対応で一括作成
  static Future<void> createDefaultModesWithSync() async {
    print('🎯 Creating default modes with sync...');
    final service = ModeSyncService();

    // デフォルトモードのデータ（要求仕様に合わせて更新）
    final defaultModes = [
      {'id': 'mode_focus', 'name': '集中', 'description': '集中して取り組むタスク'},
      {'id': 'mode_gap', 'name': 'スキマ時間', 'description': '短時間でできるタスク'},
      {'id': 'mode_audio', 'name': '耳だけ', 'description': '音声のみでできるタスク'},
    ];

    // 既存のモードをチェックして、存在しないもののみ作成
    for (final modeData in defaultModes) {
      final existingMode = ModeService.getModeById(modeData['id']!);
      if (existingMode == null) {
        // 同期対応でデフォルトモードを作成
        await service.createModeWithSync(
          name: modeData['name']!,
          description: modeData['description'],
          fixedId: modeData['id']!, // 固定IDを使用
        );
        print('✅ Created default mode with sync: ${modeData['name']}');
      }
    }

    print('🎯 Default modes creation with sync completed');
  }

  /// ローカルモードを削除する（同期処理で使用）
  @override
  Future<void> deleteLocalItem(Mode item) async {
    try {
      // ローカルHiveから削除
      await ModeService.deleteMode(item.id, touchLastModified: false);
      print('✅ Local mode deleted during sync: ${item.name} (id: ${item.id})');
    } catch (e) {
      print('❌ Failed to delete local mode: ${item.name}, error: $e');
      rethrow;
    }
  }

  /// 差分同期: lastModified >= cursor のモード
  Future<SyncResult> syncModesSince(DateTime cursorUtc) async {
    try {
      final from = cursorUtc.subtract(const Duration(seconds: 10));
      final snapshot = await userCollection
          .where('lastModified', isGreaterThanOrEqualTo: from.toIso8601String())
          .get();

      int synced = 0;
      int failed = 0;
      final conflicts = <ConflictResolution>[];
      DateTime? maxRemoteLastModifiedUtc;
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final lmRaw = data['lastModified'];
          DateTime? lm;
          if (lmRaw is Timestamp) {
            lm = lmRaw.toDate().toUtc();
          } else if (lmRaw is DateTime) {
            lm = lmRaw.toUtc();
          } else if (lmRaw is String) {
            lm = DateTime.tryParse(lmRaw)?.toUtc();
          }
          if (lm != null) {
            final currentMax = maxRemoteLastModifiedUtc;
            if (currentMax == null || lm.isAfter(currentMax)) {
              maxRemoteLastModifiedUtc = lm;
            }
          }
          final remote = createFromCloudJson(data);
          final local = await getLocalItemByCloudId(remote.cloudId!);
          if (local == null) {
            await saveToLocal(remote);
            synced++;
          } else if (local.hasConflictWith(remote)) {
            await resolveConflict(local, remote);
            conflicts.add(ConflictResolution.remoteNewer);
            synced++;
          }
        } catch (_) {
          failed++;
        }
      }
      // IMPORTANT: 端末時刻でカーソル前進しない（取得結果由来の最大値のみ）
      final latest = maxRemoteLastModifiedUtc;
      if (latest != null) {
        final key = AppSettingsService.keyCursorModes;
        final current = AppSettingsService.getCursor(key);
        var candidate = latest.subtract(const Duration(milliseconds: 1));
        if (candidate.millisecondsSinceEpoch < 0) {
          candidate = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        }
        if (current != null && candidate.isBefore(current)) {
          candidate = current;
        }
        await AppSettingsService.setCursor(key, candidate);
      }
      return SyncResult(success: failed == 0, syncedCount: synced, failedCount: failed, conflicts: conflicts);
    } catch (e) {
      return SyncResult(success: false, error: e.toString(), failedCount: 1);
    }
  }
}
