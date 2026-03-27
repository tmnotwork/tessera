import '../models/sub_project.dart';
import '../models/syncable_model.dart';
import 'data_sync_service.dart';
import 'sub_project_service.dart';
import 'device_info_service.dart';
import 'auth_service.dart';
import 'package:flutter/material.dart';
import '../app/app_material.dart';
import '../widgets/conflict_resolution_dialog.dart';
import 'app_settings_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// SubProject同期サービス
class SubProjectSyncService extends DataSyncService<SubProject> {
  static final SubProjectSyncService _instance =
      SubProjectSyncService._internal();
  factory SubProjectSyncService() => _instance;
  SubProjectSyncService._internal() : super('sub_projects');

  @override
  String? get diffCursorKey => AppSettingsService.keyCursorSubProjects;

  @override
  SubProject createFromCloudJson(Map<String, dynamic> json) {
    return SubProject.fromJson(json);
  }

  @override
  Future<List<SubProject>> getLocalItems() async {
    try {
      await SubProjectService.ensureOpen();
      return SubProjectService.getAllSubProjects();
    } catch (e) {
      print('❌ Failed to get local sub projects: $e');
      return [];
    }
  }

  @override
  Future<SubProject?> getLocalItemByCloudId(String cloudId) async {
    try {
      final subProjects = SubProjectService.getAllSubProjects();
      return subProjects.where((sp) => sp.cloudId == cloudId).firstOrNull;
    } catch (e) {
      print('❌ Failed to get local sub project by cloudId: $e');
      return null;
    }
  }

  @override
  Future<void> saveToLocal(SubProject subProject) async {
    try {
      final existingSubProject =
          await getLocalItemByCloudId(subProject.cloudId!);

      if (existingSubProject != null) {
        // tombstone が届いた場合はローカルからも削除する
        if (subProject.isDeleted) {
          await SubProjectService.deleteSubProject(existingSubProject.id);
          return;
        }
        // 既存サブプロジェクトを更新
        final updatedSubProject = existingSubProject.copyWith(
          name: subProject.name,
          description: subProject.description,
          projectId: subProject.projectId,
          project: subProject.project,
          isArchived: subProject.isArchived,
          category: subProject.category,
          lastModified: subProject.lastModified,
          lastSynced: subProject.lastSynced,
          isDeleted: subProject.isDeleted,
          deviceId: subProject.deviceId,
          version: subProject.version,
        );
        await SubProjectService.updateSubProject(updatedSubProject);
      } else {
        // tombstone で既存なし → 追加不要（復活させない）
        if (subProject.isDeleted) return;
        // 新規サブプロジェクトを追加
        await SubProjectService.addSubProject(subProject);
      }
    } catch (e) {
      print(
          '❌ Failed to save subproject locally: ${subProject.name}, error: $e');
      rethrow;
    }
  }

  @override
  Future<SubProject> handleManualConflict(
      SubProject local, SubProject remote) async {
    try {
      final nav = navigatorKey.currentState;
      if (nav != null) {
        final fields = [
          ConflictFieldDiff(
              label: '名称', localValue: local.name, remoteValue: remote.name),
          ConflictFieldDiff(
              label: '説明',
              localValue: local.description ?? '',
              remoteValue: remote.description ?? ''),
          ConflictFieldDiff(
              label: 'カテゴリ',
              localValue: local.category ?? '',
              remoteValue: remote.category ?? ''),
        ];
        final result = await showDialog<String>(
          context: nav.context,
          barrierDismissible: true,
          builder: (ctx) =>
              ConflictResolutionDialog(title: 'サブプロジェクトの競合', fields: fields),
        );
        if (result == 'local') {
          await saveToLocal(local);
          return local;
        }
      }
    } catch (_) {}
    await saveToLocal(remote);
    return remote;
  }

  /// サブプロジェクト作成時の同期対応
  Future<SubProject> createSubProjectWithSync({
    required String name,
    required String projectId,
    String? description,
    String? category,
    String? project,
  }) async {
    try {
      final deviceId = await DeviceInfoService.getDeviceId();
      final userId = AuthService.getCurrentUserId() ?? '';

      // ローカルでサブプロジェクト作成
      final subProject = SubProject(
        id: 'subproject_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}',
        name: name,
        description: description,
        createdAt: DateTime.now(),
        lastModified: DateTime.now(),
        userId: userId,
        projectId: projectId,
        category: category,
        project: project,
        deviceId: deviceId,
        version: 1,
      );

      // ローカル保存
      await SubProjectService.addSubProject(subProject);

      // 同期メタデータを設定
      subProject.markAsModified(deviceId);

      // Firebaseに同期（ネットワークがあれば）
      try {
        await uploadToFirebase(subProject);
      } catch (e) {
        print('⚠️ Failed to sync new sub project to Firebase: $e');
        // ネットワークエラーでもローカル作成は成功とする
      }

      return subProject;
    } catch (e) {
      print('❌ Failed to create sub project with sync: $e');
      rethrow;
    }
  }

  /// サブプロジェクト更新時の同期対応
  Future<void> updateSubProjectWithSync(SubProject subProject) async {
    try {
      final deviceId = await DeviceInfoService.getDeviceId();

      // 同期メタデータを更新
      subProject.markAsModified(deviceId);

      // ローカル更新
      await SubProjectService.updateSubProject(subProject);

      // Firebaseに同期（ネットワークがあれば）
      try {
        await uploadToFirebase(subProject);
      } catch (e) {
        print('⚠️ Failed to sync updated sub project to Firebase: $e');
        // ネットワークエラーでもローカル更新は成功とする
      }
    } catch (e) {
      print('❌ Failed to update sub project with sync: $e');
      rethrow;
    }
  }

  /// サブプロジェクト削除時の同期対応
  Future<void> deleteSubProjectWithSync(String subProjectId) async {
    try {
      final subProjects = SubProjectService.getAllSubProjects();
      final subProject =
          subProjects.where((sp) => sp.id == subProjectId).firstOrNull;
      if (subProject == null) return;

      final deviceId = await DeviceInfoService.getDeviceId();

      // 論理削除マークを設定
      subProject.isDeleted = true;
      subProject.markAsModified(deviceId);

      // ローカル削除
      await SubProjectService.deleteSubProject(subProjectId);

      // Firebaseに削除を同期（ネットワークがあれば）
      try {
        final docId =
            (subProject.cloudId != null && subProject.cloudId!.isNotEmpty)
                ? subProject.cloudId!
                : subProject.id; // cloudIdが無い場合はidでフォールバック
        await deleteFromFirebase(docId);
      } catch (e) {
        print('⚠️ Failed to sync sub project deletion to Firebase: $e');
        // ネットワークエラーでもローカル削除は成功とする
      }
    } catch (e) {
      print('❌ Failed to delete sub project with sync: $e');
      rethrow;
    }
  }

  /// プロジェクト別サブプロジェクト同期
  Future<SyncResult> syncSubProjectsByProject(String projectId) async {
    try {
      print('🔄 Syncing sub projects for project: $projectId');

      // 指定プロジェクトのFirestoreクエリ
      final querySnapshot = await userCollection
          .where('isDeleted', isEqualTo: false)
          .where('projectId', isEqualTo: projectId)
          .get();

      final remoteSubProjects = <SubProject>[];
      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final subProject = createFromCloudJson(data);
          remoteSubProjects.add(subProject);
        } catch (e) {
          print('⚠️ Failed to parse sub project ${doc.id}: $e');
        }
      }

      // ローカルサブプロジェクトとの競合解決
      int syncedCount = 0;
      int failedCount = 0;
      final conflicts = <ConflictResolution>[];

      for (final remoteSubProject in remoteSubProjects) {
        try {
          final localSubProject =
              await getLocalItemByCloudId(remoteSubProject.cloudId!);

          if (localSubProject == null) {
            await saveToLocal(remoteSubProject);
            syncedCount++;
          } else if (localSubProject.hasConflictWith(remoteSubProject)) {
            await resolveConflict(localSubProject, remoteSubProject);
            conflicts.add(ConflictResolution.localNewer); // 簡易的な記録
            syncedCount++;
          }
        } catch (e) {
          print('❌ Failed to process remote sub project: $e');
          failedCount++;
        }
      }

      print(
          '✅ Project sub projects sync completed: $syncedCount synced, $failedCount failed');
      return SyncResult(
        success: failedCount == 0,
        syncedCount: syncedCount,
        failedCount: failedCount,
        conflicts: conflicts,
      );
    } catch (e) {
      print('❌ Project sub projects sync failed: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  /// すべてのSubProjectを同期
  static Future<SyncResult> syncAllSubProjects() async {
    try {
      final syncService = SubProjectSyncService();
      return await syncService.performSync();
    } catch (e) {
      print('❌ Failed to sync all sub projects: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  /// サブプロジェクトの変更を監視
  Stream<List<SubProject>> watchSubProjectChanges() {
    return watchFirebaseChanges();
  }

  /// プロジェクト別サブプロジェクト監視
  Stream<List<SubProject>> watchSubProjectsByProject(String projectId) {
    return userCollection
        .where('isDeleted', isEqualTo: false)
        .where('projectId', isEqualTo: projectId)
        .snapshots()
        .map((snapshot) {
      final items = <SubProject>[];
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final item = createFromCloudJson(data);
          items.add(item);
        } catch (e) {
          print('⚠️ Failed to parse sub project ${doc.id}: $e');
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

  /// ローカルサブプロジェクトを削除する（同期処理で使用）
  @override
  Future<void> deleteLocalItem(SubProject item) async {
    try {
      await SubProjectService.deleteSubProject(item.id);
      print(
          '✅ Local subproject deleted during sync: ${item.name} (id: ${item.id})');
    } catch (e) {
      print('❌ Failed to delete local subproject: ${item.name}, error: $e');
      rethrow;
    }
  }

  /// 差分同期: lastModified >= cursor のサブプロジェクト
  Future<SyncResult> syncSubProjectsSince(DateTime cursorUtc) async {
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
          // tombstone（isDeleted=true）はローカルから削除して復活させない
          final isDeleted = (data['isDeleted'] ?? false) == true;
          if (isDeleted) {
            final local = await getLocalItemByCloudId(doc.id);
            if (local != null) {
              await deleteLocalItem(local);
              synced++;
            }
            continue;
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
        final key = AppSettingsService.keyCursorSubProjects;
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
      return SyncResult(
          success: failed == 0,
          syncedCount: synced,
          failedCount: failed,
          conflicts: conflicts);
    } catch (e) {
      return SyncResult(success: false, error: e.toString(), failedCount: 1);
    }
  }
}
