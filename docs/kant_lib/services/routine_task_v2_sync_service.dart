import '../models/routine_task_v2.dart';
import '../models/syncable_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'data_sync_service.dart';
import 'routine_task_v2_service.dart';
import 'routine_lamport_clock_service.dart';
import 'app_settings_service.dart';

/// RoutineTaskV2 同期サービス（V2を正）
class RoutineTaskV2SyncService extends DataSyncService<RoutineTaskV2> {
  static final RoutineTaskV2SyncService _instance =
      RoutineTaskV2SyncService._internal();
  factory RoutineTaskV2SyncService() => _instance;
  RoutineTaskV2SyncService._internal() : super('routine_tasks_v2');

  @override
  String? get diffCursorKey => AppSettingsService.keyCursorRoutineTasksV2;

  @override
  RoutineTaskV2 createFromCloudJson(Map<String, dynamic> json) {
    return RoutineTaskV2.fromJson(json);
  }

  @override
  Future<List<RoutineTaskV2>> getLocalItems() async {
    // Web等で post-auth が deferred 初期化より先に走る場合に備え、同期前にボックスを開く
    await RoutineTaskV2Service.ensureOpen();
    // tombstoneも同期対象（削除伝播）
    return RoutineTaskV2Service.debugGetAllRaw();
  }

  @override
  Future<RoutineTaskV2?> getLocalItemByCloudId(String cloudId) async {
    final all = RoutineTaskV2Service.debugGetAllRaw();
    for (final t in all) {
      if (t.cloudId == cloudId) return t;
    }
    return null;
  }

  @override
  Future<void> saveToLocal(RoutineTaskV2 item) async {
    await RoutineLamportClockService.observe(item.version);
    final existing = RoutineTaskV2Service.getById(item.id);
    if (existing == null) {
      await RoutineTaskV2Service.add(item);
      return;
    }
    existing.fromCloudJson(item.toCloudJson());
    existing.cloudId = item.cloudId;
    await RoutineTaskV2Service.update(existing);
  }

  @override
  Future<RoutineTaskV2> handleManualConflict(
      RoutineTaskV2 local, RoutineTaskV2 remote) async {
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
  Future<void> deleteLocalItem(RoutineTaskV2 item) async {
    item.isDeleted = true;
    await RoutineTaskV2Service.update(item);
  }

  static Future<SyncResult> syncAll({bool forceFullSync = false}) async {
    final svc = RoutineTaskV2SyncService();
    return await svc.performSync(forceFullSync: forceFullSync);
  }

  /// テンプレ単位でV2タスクをpull（全件GETを避ける）
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

