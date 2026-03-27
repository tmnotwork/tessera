import '../models/project.dart';
import '../models/syncable_model.dart';
import 'auth_service.dart';
import 'data_sync_service.dart';
import 'project_service.dart';
import 'device_info_service.dart';
import '../utils/text_normalizer.dart';
import 'package:flutter/material.dart';
import '../app/app_material.dart';
import '../screens/project_conflict_dialog.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'app_settings_service.dart';

/// Project同期サービス
class ProjectSyncService extends DataSyncService<Project> {
  static final ProjectSyncService _instance = ProjectSyncService._internal();
  factory ProjectSyncService() => _instance;
  ProjectSyncService._internal() : super('projects');

  @override
  String? get diffCursorKey => AppSettingsService.keyCursorProjects;

  @override
  Project createFromCloudJson(Map<String, dynamic> json) {
    return Project.fromJson(json);
  }

  @override
  Future<List<Project>> getLocalItems() async {
    try {
      await ProjectService.ensureOpen();
      // 予約済みIDのシステムプロジェクト（__sleep__ 等）はFirestoreへ同期しない
      return ProjectService.getAllProjects()
          .where((p) => p.id != ProjectService.sleepProjectId)
          .toList();
    } catch (e) {
      print('❌ Failed to get local projects: $e');
      return [];
    }
  }

  @override
  Future<Project?> getLocalItemByCloudId(String cloudId) async {
    try {
      final projects = ProjectService.getAllProjects();
      return projects.where((p) => p.cloudId == cloudId).firstOrNull;
    } catch (e) {
      print('❌ Failed to get local project by cloudId: $e');
      return null;
    }
  }

  @override
  Future<void> saveToLocal(Project project) async {
    try {
      Project? existingProject;
      if (project.cloudId != null && project.cloudId!.isNotEmpty) {
        existingProject = await getLocalItemByCloudId(project.cloudId!);
      }

      // フォールバック: normalizedName で統合
      if (existingProject == null) {
        final byName = ProjectService.findByNormalizedName(project.name);
        if (byName != null) {
          existingProject = byName;
        }
      }

      if (existingProject != null) {
        // 既存プロジェクトを更新/マージ
        final updatedProject = existingProject.copyWith(
          name: project.name,
          description: project.description,
          isArchived: project.isArchived,
          category: project.category,
          lastModified: project.lastModified,
          lastSynced: project.lastSynced,
          isDeleted: project.isDeleted,
          deviceId: project.deviceId,
          version: project.version,
          cloudId: project.cloudId ?? existingProject.cloudId,
        );
        // リモート反映（同期適用）ではクラウド同期を起動しない（read→write を防ぐ）
        await ProjectService.updateProject(updatedProject, syncToFirebase: false);
      } else {
        // 新規プロジェクトを追加
        // リモート反映（同期適用）ではクラウド同期を起動しない（read→write を防ぐ）
        await ProjectService.addProject(project, syncToFirebase: false);
      }
    } catch (e) {
      print('❌ Failed to save project locally: ${project.name}, error: $e');
      rethrow;
    }
  }

  @override
  Future<Project> handleManualConflict(Project local, Project remote) async {
    try {
      // UIはアプリのルートナビゲータで開く
      final navigator = navigatorKey.currentState;
      if (navigator != null) {
        final result = await showDialog<String>(
          context: navigator.context,
          barrierDismissible: true,
          builder: (ctx) => ProjectConflictDialog(local: local, remote: remote),
        );

        if (result == 'local') {
          await saveToLocal(local);
          return local;
        }
        // 既定はリモート優先
        await saveToLocal(remote);
        return remote;
      }
    } catch (e) {
      // UI表示に失敗した場合は既定（リモート優先）で継続
    }
    await saveToLocal(remote);
    return remote;
  }

  /// プロジェクト作成時の同期対応
  Future<Project> createProjectWithSync(
    String name, {
    String? description,
    String? category,
  }) async {
    try {
      final sanitizedName = name.trim();
      if (sanitizedName.isEmpty) {
        throw ArgumentError('プロジェクト名は必須です');
      }
      final deviceId = await DeviceInfoService.getDeviceId();

      // 先にローカル重複（同名）を確認して再利用
      final existingLocal = ProjectService.findByNormalizedName(sanitizedName);
      if (existingLocal != null) {
        existingLocal.deviceId = deviceId;
        existingLocal.markAsModified(deviceId);
        try {
          await uploadToFirebase(existingLocal);
        } catch (e) {
          print('⚠️ Failed to sync existing project to Firebase: $e');
        }
        return existingLocal;
      }

      // リモート重複（normalizedName）を確認して採用
      try {
        final normalized = normalizeProjectName(sanitizedName);
        final snapshot = await userCollection
            .where('normalizedName', isEqualTo: normalized)
            .where('isDeleted', isEqualTo: false)
            .limit(1)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 10));
        if (snapshot.docs.isNotEmpty) {
          final doc = snapshot.docs.first;
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          for (final k in const ['createdAt', 'lastModified', 'lastSynced']) {
            final v = data[k];
            if (v is Timestamp) {
              data[k] = v.toDate().toIso8601String();
            }
          }
          final remoteProject = createFromCloudJson(data);
          await saveToLocal(remoteProject);
          return ProjectService.findByNormalizedName(sanitizedName) ??
              remoteProject;
        }
      } catch (e) {
        // ネットワーク/権限等の理由で失敗しても続行（ローカル新規作成へ）
        print('⚠️ Remote duplicate check failed (continuing local create): $e');
      }

      // ローカルでプロジェクト作成
      final project = await ProjectService.createProjectWithDetails(
        name: sanitizedName,
        description: description,
        category: category,
      );

      // 同期メタデータを設定
      project.deviceId = deviceId;
      project.markAsModified(deviceId);

      // Firebaseに同期（ネットワークがあれば）
      try {
        await uploadToFirebase(project);
      } catch (e) {
        print('⚠️ Failed to sync new project to Firebase: $e');
        // ネットワークエラーでもローカル作成は成功とする
      }

      return project;
    } catch (e) {
      print('❌ Failed to create project with sync: $e');
      rethrow;
    }
  }

  /// プロジェクト更新時の同期対応
  Future<void> updateProjectWithSync(Project project) async {
    try {
      final deviceId = await DeviceInfoService.getDeviceId();

      // 同期メタデータを更新
      project.markAsModified(deviceId);

      // ローカル更新
      await ProjectService.updateProject(project);

      // Firebaseに同期（ネットワークがあれば）
      try {
        await uploadToFirebase(project);
      } catch (e) {
        print('⚠️ Failed to sync updated project to Firebase: $e');
        // ネットワークエラーでもローカル更新は成功とする
      }
    } catch (e) {
      print('❌ Failed to update project with sync: $e');
      rethrow;
    }
  }

  /// プロジェクト削除時の同期対応
  Future<void> deleteProjectWithSync(String projectId) async {
    try {
      final project = ProjectService.getProjectById(projectId);
      if (project == null) return;

      final deviceId = await DeviceInfoService.getDeviceId();

      // 論理削除マークを設定
      project.isDeleted = true;
      project.markAsModified(deviceId);

      // ローカル削除
      await ProjectService.deleteProject(projectId);

      // Firebaseに削除を同期（ネットワークがあれば）
      try {
        // cloudIdが未保存の場合でも、初回アップロード時にfallbackとしてidをdocIdにしているため
        // idをフォールバックとして使用して論理削除を試みる
        final docId = (project.cloudId != null && project.cloudId!.isNotEmpty)
            ? project.cloudId!
            : project.id;
        await deleteFromFirebase(docId);
      } catch (e) {
        print('⚠️ Failed to sync project deletion to Firebase: $e');
        // ネットワークエラーでもローカル削除は成功とする
      }
    } catch (e) {
      print('❌ Failed to delete project with sync: $e');
      rethrow;
    }
  }

  /// すべてのプロジェクトを同期
  static Future<SyncResult> syncAllProjects() async {
    try {
      final syncService = ProjectSyncService();
      return await syncService.performSync();
    } catch (e) {
      print('❌ Failed to sync all projects: $e');
      return SyncResult(success: false, error: e.toString(), failedCount: 1);
    }
  }

  /// プロジェクトの変更を監視
  Stream<List<Project>> watchProjectChanges() {
    return watchFirebaseChanges();
  }

  /// ローカルプロジェクトを削除する（同期処理で使用）
  @override
  Future<void> deleteLocalItem(Project item) async {
    try {
      // ローカルHiveから削除
      // 同期適用（リモート削除伝播）ではクラウド側へ書かない
      await ProjectService.deleteProject(item.id, syncToFirebase: false);
      print(
        '✅ Local project deleted during sync: ${item.name} (id: ${item.id})',
      );
    } catch (e) {
      print('❌ Failed to delete local project: ${item.name}, error: $e');
      rethrow;
    }
  }

  /// 差分同期: lastModified >= cursor のプロジェクトのみ適用
  Future<SyncResult> syncProjectsSince(DateTime cursorUtc) async {
    try {
      final from = cursorUtc.subtract(
        const Duration(seconds: 10),
      ); // clock skew tolerance
      final snapshot = await userCollection
          .where('lastModified', isGreaterThanOrEqualTo: from.toIso8601String())
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 15));

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
        final key = AppSettingsService.keyCursorProjects;
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
        conflicts: conflicts,
      );
    } catch (e) {
      return SyncResult(success: false, error: e.toString(), failedCount: 1);
    }
  }

  /// 管理者/開発者画面用：Firebase からプロジェクトを再取得し、userId が無いものに現在ユーザーを付与してローカルに保存する。
  /// 移行時の救済用。通常の同期では呼ばない。
  Future<int> runUserIdCompletionFromFirebase() async {
    final uid = AuthService.getCurrentUserId();
    if (uid == null || uid.isEmpty) return 0;
    await ProjectService.ensureOpen();
    final snapshot = await userCollection
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 25));
    int count = 0;
    for (final doc in snapshot.docs) {
      final raw = doc.data();
      if (raw is! Map<String, dynamic>) continue;
      final data = Map<String, dynamic>.from(raw);
      data['cloudId'] = doc.id;
      if (data['userId'] == null || data['userId'].toString().trim().isEmpty) {
        data['userId'] = uid;
      }
      void norm(String k) {
        final dt = FirestoreHelper.timestampToDateTime(data[k]);
        if (dt != null) data[k] = dt.toIso8601String();
      }
      for (final k in const ['createdAt', 'lastModified', 'lastSynced']) {
        norm(k);
      }
      final item = createFromCloudJson(data);
      await saveToLocal(item);
      count++;
    }
    return count;
  }
}
