import '../models/routine_block_v2.dart';
import '../models/syncable_model.dart';
import 'data_sync_service.dart';
import 'routine_block_v2_service.dart';
import 'routine_lamport_clock_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'app_settings_service.dart';

/// RoutineBlockV2 同期サービス（V2を正）
class RoutineBlockV2SyncService extends DataSyncService<RoutineBlockV2> {
  static final RoutineBlockV2SyncService _instance =
      RoutineBlockV2SyncService._internal();
  factory RoutineBlockV2SyncService() => _instance;
  RoutineBlockV2SyncService._internal() : super('routine_blocks_v2');

  @override
  String? get diffCursorKey => AppSettingsService.keyCursorRoutineBlocksV2;

  @override
  RoutineBlockV2 createFromCloudJson(Map<String, dynamic> json) {
    return RoutineBlockV2.fromJson(json);
  }

  @override
  Future<List<RoutineBlockV2>> getLocalItems() async {
    // Web等で post-auth が deferred 初期化より先に走る場合に備え、同期前にボックスを開く
    await RoutineBlockV2Service.ensureOpen();
    // tombstoneも同期対象（削除伝播）
    // 既存サービスは isDeleted を除外する取得しか無いので raw を使用
    return RoutineBlockV2Service.debugGetAllRaw();
  }

  @override
  Future<RoutineBlockV2?> getLocalItemByCloudId(String cloudId) async {
    final all = RoutineBlockV2Service.debugGetAllRaw();
    for (final b in all) {
      if (b.cloudId == cloudId) return b;
    }
    return null;
  }

  @override
  Future<void> saveToLocal(RoutineBlockV2 item) async {
    await RoutineLamportClockService.observe(item.version);
    final existing = RoutineBlockV2Service.getById(item.id);
    if (existing == null) {
      await RoutineBlockV2Service.add(item);
      return;
    }
    existing.fromCloudJson(item.toCloudJson());
    existing.cloudId = item.cloudId;
    await RoutineBlockV2Service.update(existing);
  }

  @override
  Future<RoutineBlockV2> handleManualConflict(
      RoutineBlockV2 local, RoutineBlockV2 remote) async {
    if (remote.version > local.version) {
      await saveToLocal(remote);
      return remote;
    }
    if (local.version > remote.version) {
      await uploadToFirebase(local);
      return local;
    }
    final cmp = local.deviceId.compareTo(remote.deviceId);
    if (cmp < 0) {
      await uploadToFirebase(local);
      return local;
    }
    if (cmp > 0) {
      await saveToLocal(remote);
      return remote;
    }
    await uploadToFirebase(local);
    return local;
  }

  @override
  Future<void> deleteLocalItem(RoutineBlockV2 item) async {
    item.isDeleted = true;
    await RoutineBlockV2Service.update(item);
  }

  static Future<SyncResult> syncAll({bool forceFullSync = false}) async {
    final svc = RoutineBlockV2SyncService();
    return await svc.performSync(forceFullSync: forceFullSync);
  }

  /// テンプレ単位でV2ブロックをpull（全件GETを避ける）
  Future<SyncResult> syncForTemplate(String routineTemplateId) async {
    try {
      final snapshot = await userCollection
          .where('routineTemplateId', isEqualTo: routineTemplateId)
          .get();

      int synced = 0;
      int failed = 0;

      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['id'] ??= doc.id;
          data['cloudId'] = doc.id;
          final remote = createFromCloudJson(data);
          if (remote.isDeleted == true) {
            await deleteLocalItem(remote);
            synced++;
            continue;
          }
          final local = await getLocalItemByCloudId(doc.id);
          if (local == null) {
            await saveToLocal(remote);
            synced++;
            continue;
          }
          if (local.hasConflictWith(remote)) {
            await resolveConflict(local, remote);
            synced++;
          }
        } catch (_) {
          failed++;
        }
      }

      return SyncResult(
        success: failed == 0,
        syncedCount: synced,
        failedCount: failed,
      );
    } catch (e) {
      return SyncResult(success: false, error: e.toString(), failedCount: 1);
    }
  }
}

