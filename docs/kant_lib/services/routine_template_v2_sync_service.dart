import '../models/routine_template_v2.dart';
import '../models/syncable_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'data_sync_service.dart';
import 'routine_template_v2_service.dart';
import 'routine_lamport_clock_service.dart';
import 'app_settings_service.dart';

/// RoutineTemplateV2 同期サービス
class RoutineTemplateV2SyncService extends DataSyncService<RoutineTemplateV2> {
  static final RoutineTemplateV2SyncService _instance =
      RoutineTemplateV2SyncService._internal();
  factory RoutineTemplateV2SyncService() => _instance;
  RoutineTemplateV2SyncService._internal() : super('routine_templates_v2');

  @override
  String? get diffCursorKey => AppSettingsService.keyCursorRoutineTemplatesV2;

  @override
  RoutineTemplateV2 createFromCloudJson(Map<String, dynamic> json) {
    final t = RoutineTemplateV2.fromJson(json);
    RoutineTemplateV2Service.applyCanonicalShortcutTemplateFlags(t);
    return t;
  }

  @override
  Future<List<RoutineTemplateV2>> getLocalItems() async {
    // Web等で post-auth が deferred 初期化より先に走る場合に備え、同期前にボックスを開く
    await RoutineTemplateV2Service.ensureOpen();
    // tombstone も同期対象（削除伝播）
    return RoutineTemplateV2Service.getAll(includeDeleted: true);
  }

  @override
  Future<RoutineTemplateV2?> getLocalItemByCloudId(String cloudId) async {
    final all = RoutineTemplateV2Service.debugGetAllRaw();
    for (final t in all) {
      if (t.cloudId == cloudId) return t;
    }
    return null;
  }

  @override
  Future<void> saveToLocal(RoutineTemplateV2 item) async {
    RoutineTemplateV2Service.applyCanonicalShortcutTemplateFlags(item);
    await RoutineLamportClockService.observe(item.version);
    final existing = RoutineTemplateV2Service.getById(item.id);
    if (existing == null) {
      await RoutineTemplateV2Service.add(item);
      return;
    }
    existing.fromCloudJson(item.toCloudJson());
    existing.cloudId = item.cloudId;
    RoutineTemplateV2Service.applyCanonicalShortcutTemplateFlags(existing);
    await RoutineTemplateV2Service.update(existing);
  }

  @override
  Future<RoutineTemplateV2> handleManualConflict(
      RoutineTemplateV2 local, RoutineTemplateV2 remote) async {
    // V2: version(Lamport) + deviceId による決定的解決（端末時計に依存しない）
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
  Future<void> deleteLocalItem(RoutineTemplateV2 item) async {
    // 物理削除せず tombstone として残す（復活・巻き戻り防止）
    item.isDeleted = true;
    await RoutineTemplateV2Service.update(item);
  }

  static Future<SyncResult> syncAll({bool forceFullSync = false}) async {
    final svc = RoutineTemplateV2SyncService();
    return await svc.performSync(forceFullSync: forceFullSync);
  }

  /// テンプレ単体だけpull（Routine V2の「テンプレ単位pull」を第一級にする）
  Future<SyncResult> syncById(String templateId) async {
    try {
      final doc = await userCollection.doc(templateId).get();
      if (!doc.exists) {
        return SyncResult(success: true, syncedCount: 0, failedCount: 0);
      }
      final data = doc.data() as Map<String, dynamic>;
      data['id'] ??= doc.id;
      data['cloudId'] = doc.id;
      final remote = createFromCloudJson(data);
      if (remote.isDeleted == true) {
        await deleteLocalItem(remote);
        return SyncResult(success: true, syncedCount: 1, failedCount: 0);
      }
      final local = await getLocalItemByCloudId(doc.id);
      if (local == null) {
        await saveToLocal(remote);
      } else if (local.hasConflictWith(remote)) {
        await resolveConflict(local, remote);
      }
      return SyncResult(success: true, syncedCount: 1, failedCount: 0);
    } catch (e) {
      return SyncResult(success: false, error: e.toString(), failedCount: 1);
    }
  }
}

