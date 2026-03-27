import 'package:hive/hive.dart';

import '../models/sub_project.dart';
import '../utils/hive_open_with_retry.dart';
import 'auth_service.dart';
import 'sub_project_sync_service.dart';

class SubProjectService {
  static const String _boxName = 'subProjects';
  static Box<SubProject>? _box;
  static bool _opening = false;

  static Future<void> _ensureBoxOpen() async {
    if (_box != null && _box!.isOpen) return;
    if (_opening) {
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 30));
        if (_box != null && _box!.isOpen) return;
      }
    }
    _opening = true;
    try {
      _box = await openBoxWithRetry<SubProject>(_boxName);
    } finally {
      _opening = false;
    }
  }

  static Future<T> _retryOnIdbClosing<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('database connection is closing') ||
          msg.contains('InvalidStateError') ||
          msg.contains('Failed to execute "transaction"')) {
        await _ensureBoxOpen();
        return await action();
      }
      rethrow;
    }
  }

  // Hiveボックスの初期化
  static Future<void> initialize() async {
    await _ensureBoxOpen();
  }

  /// 同期等で getLocalItems の前に呼ぶ。未初期化でもボックスを開いてから取得できるようにする。
  static Future<void> ensureOpen() async => _ensureBoxOpen();

  /// タイムライン等で名前解決する前に参照。未初期化時は行を出さない判定に使う。
  static bool get isReady => _box != null && _box!.isOpen;

  // サブプロジェクトを追加
  static Future<void> addSubProject(SubProject subProject) async {
    final trimmedName = subProject.name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError('サブプロジェクト名は必須です');
    }
    subProject.name = trimmedName;
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async => _box!.put(subProject.id, subProject));
    await _retryOnIdbClosing(() async => _box!.flush());

    // 保存確認
    final savedSubProject = _box!.get(subProject.id);
    if (savedSubProject == null) {
      throw Exception('サブプロジェクトの保存に失敗しました');
    }

    // Firebase同期（非同期で実行、エラーを無視）
    _syncSubProjectToFirebase(subProject);
  }

  // サブプロジェクトを更新
  static Future<void> updateSubProject(SubProject subProject) async {
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async => _box!.put(subProject.id, subProject));

    // Firebase同期（非同期で実行、エラーを無視）
    _syncSubProjectToFirebase(subProject);
  }

  // サブプロジェクトを削除
  static Future<void> deleteSubProject(String id) async {
    await _ensureBoxOpen();
    // 削除前にサブプロジェクトを取得
    final subProject = _box!.get(id);
    await _retryOnIdbClosing(() async => _box!.delete(id));

    // Firebase同期（非同期で実行、エラーを無視）
    if (subProject != null) {
      _syncSubProjectDeletion(id);
    }
  }

  static String? get _currentUserId => AuthService.getCurrentUserId();

  // すべてのサブプロジェクトを取得（現在ユーザー分のみ）
  static List<SubProject> getAllSubProjects() {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      final box = Hive.box<SubProject>(_boxName);
      return box.values.where((s) => s.userId == uid).toList();
    } catch (e) {
      return [];
    }
  }

  // アクティブなサブプロジェクトを取得（現在ユーザー分のみ）
  static List<SubProject> getActiveSubProjects() {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      final box = Hive.box<SubProject>(_boxName);
      return box.values
          .where((s) => s.userId == uid && !s.isArchived)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // アーカイブされたサブプロジェクトを取得（現在ユーザー分のみ）
  static List<SubProject> getArchivedSubProjects() {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      final box = Hive.box<SubProject>(_boxName);
      return box.values
          .where((s) => s.userId == uid && s.isArchived)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // プロジェクトIDでサブプロジェクトを取得（現在ユーザー分のみ）
  static List<SubProject> getSubProjectsByProjectId(String projectId) {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      final box = Hive.box<SubProject>(_boxName);
      return box.values
          .where((s) => s.userId == uid && s.projectId == projectId)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // カテゴリでサブプロジェクトを取得（現在ユーザー分のみ）
  static List<SubProject> getSubProjectsByCategory(String category) {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      final box = Hive.box<SubProject>(_boxName);
      return box.values
          .where((s) => s.userId == uid && s.category == category)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // サブプロジェクトをIDで取得（現在ユーザー所有のみ返す）
  static SubProject? getSubProjectById(String id) {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return null;
      final box = Hive.box<SubProject>(_boxName);
      final s = box.get(id);
      if (s == null || s.userId != uid) return null;
      return s;
    } catch (_) {
      return null;
    }
  }

  // 同期処理は SubProjectSyncService に移行済み
  // 以下のメソッドは非推奨です

  // データをクリア
  static Future<void> clearAllData() async {
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async => _box!.clear());
  }

  // 統計情報を取得
  static Map<String, int> getStatistics() {
    final allSubProjects = getAllSubProjects();
    final activeSubProjects = getActiveSubProjects();
    final archivedSubProjects = getArchivedSubProjects();

    return {
      'total': allSubProjects.length,
      'active': activeSubProjects.length,
      'archived': archivedSubProjects.length,
    };
  }

  // Firebase同期用ヘルパーメソッド（非同期実行、エラーを無視）
  static void _syncSubProjectToFirebase(SubProject subProject) {
    Future.microtask(() async {
      try {
        final syncService = SubProjectSyncService();
        await syncService.uploadToFirebase(subProject);
      } catch (e) {
        // 同期エラーは無視（ローカル操作は成功）
        print('⚠️ SubProject Firebase sync failed (non-critical): $e');
      }
    });
  }

  static void _syncSubProjectDeletion(String subProjectId) {
    Future.microtask(() async {
      try {
        final syncService = SubProjectSyncService();
        await syncService.deleteSubProjectWithSync(subProjectId);
      } catch (e) {
        // 同期エラーは無視（ローカル操作は成功）
        print('⚠️ SubProject deletion Firebase sync failed (non-critical): $e');
      }
    });
  }
}
