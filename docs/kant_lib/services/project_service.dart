import 'package:hive/hive.dart';

import '../models/project.dart';
import '../utils/hive_open_with_retry.dart';
import 'auth_service.dart';
import 'project_sync_service.dart';
import '../utils/text_normalizer.dart';

class ProjectService {
  static const String _boxName = 'projects';

  /// 睡眠ブロック用のデフォルトプロジェクトID。ユーザーは削除できず、プロジェクト一覧には出さない。
  static const String sleepProjectId = '__sleep__';

  static Box<Project>? _box;
  static bool _opening = false;

  static Future<void> _ensureBoxOpen() async {
    if (_box != null && _box!.isOpen) return;
    if (_opening) {
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 30));
        if (_box != null && _box!.isOpen) return;
      }
      print('⚠️ ProjectService: Box opening timed out, forcing new open attempt');
    }
    _opening = true;
    try {
      _box = await openBoxWithRetry<Project>(_boxName);
    } catch (e, stackTrace) {
      print('❌ ProjectService._ensureBoxOpen() error: $e');
      print('Stack trace: $stackTrace');
      _box = null;
      rethrow;
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

  // Hiveボックスの初期化（通常コードは userId が保管されている前提で動作する）
  static Future<void> initialize() async {
    await _ensureBoxOpen();
  }

  /// 管理者/開発者画面用：ローカルHive内で userId が空のプロジェクトを現在ユーザーで補完する。
  /// 移行時の救済用。通常の initialize では呼ばない。
  static Future<int> runUserIdBackfillForAdmin() async {
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) return 0;
    await _ensureBoxOpen();
    int count = 0;
    for (final p in _projectBox.values) {
      if (p.userId.isEmpty) {
        final updated = p.copyWith(userId: uid);
        await _retryOnIdbClosing(() async => _projectBox.put(p.id, updated));
        count++;
      }
    }
    if (count > 0) await _retryOnIdbClosing(() async => _projectBox.flush());
    return count;
  }

  /// 同期等で getLocalItems の前に呼ぶ。未初期化でもボックスを開いてから取得できるようにする。
  static Future<void> ensureOpen() async => _ensureBoxOpen();

  /// タイムライン等で名前解決する前に参照。未初期化時は行を出さない判定に使う。
  static bool get isReady => _box != null && _box!.isOpen;

  static Box<Project> get _projectBox {
    if (_box == null) {
      throw Exception('ProjectService not initialized');
    }
    return _box!;
  }

  // ユニークIDを生成
  static String _generateId() {
    return 'project_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}';
  }

  // プロジェクトを追加
  static Future<void> addProject(Project project, {bool syncToFirebase = true}) async {
    try {
      await _ensureBoxOpen();
      await _retryOnIdbClosing(
        () async => _projectBox.put(project.id, project),
      );
      await _retryOnIdbClosing(() async => _projectBox.flush());

      // 保存確認
      final savedProject = _projectBox.get(project.id);
      if (savedProject == null) {
        throw Exception('プロジェクトの保存に失敗しました');
      }

      // Firebase同期（非同期で実行、エラーを無視）
      // NOTE: リモート反映（同期適用）では syncToFirebase=false を指定し、
      // 「読んだだけで書く」を避ける。
      if (syncToFirebase) {
        _syncProjectToFirebase(project);
      }
    } catch (e) {
      throw Exception('プロジェクトの保存に失敗しました: $e');
    }
  }

  // プロジェクトを更新
  static Future<void> updateProject(Project project, {bool syncToFirebase = true}) async {
    try {
      await _ensureBoxOpen();
      await _retryOnIdbClosing(
        () async => _projectBox.put(project.id, project),
      );
      await _retryOnIdbClosing(() async => _projectBox.flush());

      // Firebase同期（非同期で実行、エラーを無視）
      // NOTE: リモート反映（同期適用）では syncToFirebase=false を指定し、
      // 「読んだだけで書く」を避ける。
      if (syncToFirebase) {
        _syncProjectToFirebase(project);
      }
    } catch (e) {
      throw Exception('プロジェクトの更新に失敗しました: $e');
    }
  }

  // プロジェクトを削除
  static Future<void> deleteProject(String id, {bool syncToFirebase = true}) async {
    if (isNonDeletableProject(id)) {
      throw Exception('このプロジェクトは削除できません');
    }
    try {
      // 削除前にプロジェクトを取得
      final project = _projectBox.get(id);
      await _ensureBoxOpen();
      await _retryOnIdbClosing(() async => _projectBox.delete(id));
      await _retryOnIdbClosing(() async => _projectBox.flush());

      // Firebase同期（非同期で実行、エラーを無視）
      // NOTE: リモート反映（同期適用）では syncToFirebase=false を指定し、
      // 「読んだだけで書く」を避ける。
      if (syncToFirebase && project != null) {
        _syncProjectDeletion(id);
      }
    } catch (e) {
      throw Exception('プロジェクトの削除に失敗しました: $e');
    }
  }

  /// 現在ユーザーID。null/空のときは読み取りでは他ユーザーデータを返さない。
  static String? get _currentUserId => AuthService.getCurrentUserId();

  // すべてのプロジェクトを取得（現在ユーザー分のみ）
  static List<Project> getAllProjects() {
    try {
      if (_box == null || !_box!.isOpen) {
        return [];
      }
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      return _projectBox.values.where((p) => p.userId == uid).toList();
    } catch (e, stackTrace) {
      print('❌ ProjectService.getAllProjects() error: $e');
      print('Stack trace: $stackTrace');
      return [];
    }
  }

  /// プロジェクト一覧画面用。睡眠デフォルトプロジェクトを除く（一覧に表示しない）。
  static List<Project> getProjectsForList() {
    return getAllProjects().where((p) => p.id != sleepProjectId).toList();
  }

  /// 睡眠プロジェクトが存在しなければ作成して返す（現在ユーザー分・同期しない）。
  static Project _getOrCreateSleepProject(String uid) {
    var p = _projectBox.get(sleepProjectId);
    if (p != null && p.userId == uid) return p;
    final now = DateTime.now();
    p = Project(
      id: sleepProjectId,
      name: '睡眠',
      createdAt: now,
      lastModified: now,
      userId: uid,
    );
    _projectBox.put(sleepProjectId, p);
    _projectBox.flush();
    return p;
  }

  // 正規化名称で検索（アクティブ/アーカイブ含む・現在ユーザー分のみ）
  static Project? findByNormalizedName(String name) {
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) return null;
    final normalized = normalizeProjectName(name);
    try {
      for (final p in _projectBox.values) {
        if (p.userId != uid) continue;
        if (normalizeProjectName(p.name) == normalized) return p;
      }
    } catch (_) {}
    return null;
  }

  // アクティブなプロジェクトを取得（現在ユーザー分のみ）
  static List<Project> getActiveProjects() {
    try {
      if (_box == null || !_box!.isOpen) return [];
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      return _projectBox.values
          .where((project) => project.userId == uid && !project.isArchived)
          .toList();
    } catch (e) {
      return [];
    }
  }

  // アーカイブされたプロジェクトを取得（現在ユーザー分のみ）
  static List<Project> getArchivedProjects() {
    try {
      if (_box == null || !_box!.isOpen) return [];
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      return _projectBox.values
          .where((project) => project.userId == uid && project.isArchived)
          .toList();
    } catch (e) {
      return [];
    }
  }

  // カテゴリでプロジェクトを取得（現在ユーザー分のみ）
  static List<Project> getProjectsByCategory(String category) {
    try {
      if (_box == null || !_box!.isOpen) return [];
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      return _projectBox.values
          .where((project) =>
              project.userId == uid && project.category == category)
          .toList();
    } catch (e) {
      return [];
    }
  }

  // プロジェクトをIDで取得（現在ユーザー所有のみ返す）
  // 睡眠プロジェクトIDの場合は存在しなければ自動作成する。
  static Project? getProjectById(String id) {
    try {
      if (_box == null || !_box!.isOpen) return null;
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return null;
      if (id == sleepProjectId) {
        return _getOrCreateSleepProject(uid);
      }
      final project = _projectBox.get(id);
      if (project == null || project.userId != uid) return null;
      return project;
    } catch (e) {
      return null;
    }
  }

  /// 指定IDがユーザー削除不可のデフォルトプロジェクトか。
  static bool isNonDeletableProject(String id) => id == sleepProjectId;

  // プロジェクトをアーカイブ
  static Future<void> archiveProject(String projectId) async {
    final project = getProjectById(projectId);
    if (project != null) {
      project.archive();
      await updateProject(project);
    }
  }

  // プロジェクトを復元
  static Future<void> unarchiveProject(String projectId) async {
    final project = getProjectById(projectId);
    if (project != null) {
      project.unarchive();
      await updateProject(project);
    }
  }

  // 同期処理は ProjectSyncService に移行済み
  // 以下のメソッドは非推奨です

  // データをクリア
  static Future<void> clearAllData() async {
    final box = await Hive.openBox<Project>(_boxName);
    await box.clear();
  }

  // 統計情報を取得
  static Map<String, int> getStatistics() {
    final allProjects = getAllProjects();
    final activeProjects = getActiveProjects();
    final archivedProjects = getArchivedProjects();

    return {
      'total': allProjects.length,
      'active': activeProjects.length,
      'archived': archivedProjects.length,
    };
  }

  // プロジェクトDBをクリア
  static Future<void> clearAllProjects() async {
    final box = await Hive.openBox<Project>(_boxName);
    await box.clear();
  }

  // 詳細付きプロジェクト作成（同期サービス用）
  static Future<Project> createProjectWithDetails({
    required String name,
    String? description,
    String? category,
  }) async {
    final sanitizedName = name.trim();
    if (sanitizedName.isEmpty) {
      throw ArgumentError('プロジェクト名は必須です');
    }
    // 重複（同名）ガード：既存があればそれを返す（アンアーカイブは呼び出し側で判断）
    final existing = findByNormalizedName(sanitizedName);
    if (existing != null) {
      return existing;
    }

    final userId = AuthService.getCurrentUserId() ?? '';
    final project = Project(
      id: _generateId(),
      name: sanitizedName,
      description: description,
      category: category,
      createdAt: DateTime.now(),
      lastModified: DateTime.now(),
      userId: userId,
    );

    final box = await Hive.openBox<Project>(_boxName);
    await box.put(project.id, project);

    return project;
  }

  // Firebase同期用ヘルパーメソッド（非同期実行、エラーを無視）
  static void _syncProjectToFirebase(Project project) {
    Future.microtask(() async {
      try {
        final syncService = ProjectSyncService();
        await syncService.uploadToFirebase(project);
      } catch (e) {
        // 同期エラーは無視（ローカル操作は成功）
        print('⚠️ Project Firebase sync failed (non-critical): $e');
      }
    });
  }

  static void _syncProjectDeletion(String projectId) {
    Future.microtask(() async {
      try {
        final syncService = ProjectSyncService();
        await syncService.deleteProjectWithSync(projectId);
      } catch (e) {
        // 同期エラーは無視（ローカル操作は成功）
        print('⚠️ Project deletion Firebase sync failed (non-critical): $e');
      }
    });
  }
}
