import 'package:hive/hive.dart';
import '../models/inbox_task.dart';
import 'auth_service.dart';
import 'sync_all_history_service.dart';

class InboxTaskService {
  static const String _boxName = 'inbox_tasks';
  static Box<InboxTask>? _box;
  static bool _opening = false;
  static DateTime? _lastDiagAtUtc;
  static int? _lastDiagCount;

  static Future<void> _recordBoxState(String reason) async {
    try {
      final now = DateTime.now().toUtc();
      int count = -1;
      bool isOpen = false;
      try {
        isOpen = _box != null && _box!.isOpen;
        if (isOpen) {
          count = _box!.length;
        }
      } catch (_) {}
      final lastAt = _lastDiagAtUtc;
      final lastCount = _lastDiagCount;
      // 診断ログが多すぎると本命（cursorRead等）が押し出されるため、
      // - count==0 は必ず記録
      // - それ以外は「件数変化」かつ 最短60秒 に制限
      final shouldRecord = count == 0 ||
          ((lastCount == null || lastCount != count) &&
              (lastAt == null ||
                  now.difference(lastAt) > const Duration(seconds: 60)));
      if (!shouldRecord) return;
      _lastDiagAtUtc = now;
      _lastDiagCount = count;

      String? uid;
      try {
        uid = AuthService.getCurrentUserId();
      } catch (_) {
        uid = null;
      }
      await SyncAllHistoryService.recordSimpleEvent(
        type: 'localBoxState',
        reason: reason,
        origin: 'InboxTaskService',
        userId: uid,
        extra: <String, dynamic>{
          'box': _boxName,
          'isOpen': isOpen,
          'opening': _opening,
          'count': count,
        },
      );
    } catch (_) {}
  }

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
      _box = await Hive.openBox<InboxTask>(_boxName);
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

  static Future<void> initialize() async {
    await _ensureBoxOpen();
    await _recordBoxState('initialize');
  }

  static Box<InboxTask> get box => _box!;

  static Future<void> addInboxTask(InboxTask task) async {
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async => box.put(task.id, task));
  }

  static Future<void> updateInboxTask(InboxTask task) async {
    // 呼び出し側で意味のある変更時のみ lastModified を更新する方針へ移行する。
    // ここでは更新しない（アップロード直後の再更新による不要同期を防ぐ）。
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async {
      // 「いつか」指定時は、割当と開始時刻をブランクへ（確実な非表示・非割当化）
      if (task.isSomeday == true) {
        task.startHour = null;
        task.startMinute = null;
        task.blockId = null;
      }
      await box.put(task.id, task);
    });
  }

  /// 同期用: lastModifiedを変更せずにタスクを更新
  /// リモートから採用したデータを保存する際に使用
  static Future<void> updateInboxTaskPreservingLastModified(InboxTask task) async {
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async {
      // 「いつか」指定時は、割当と開始時刻をブランクへ
      if (task.isSomeday == true) {
        task.startHour = null;
        task.startMinute = null;
        task.blockId = null;
      }
      await box.put(task.id, task);
    });
  }

  static Future<void> deleteInboxTask(String id) async {
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async => box.delete(id));
  }

  /// 開発者メニュー用：ローカルHive内で userId が空のインボックスタスクを現在ユーザーで上書きする。
  /// getAllInboxTasks() は userId でフィルタするため、userId が空のタスクは一覧に出ず巻き戻り要因になり得る。救済用。
  static Future<int> runUserIdBackfillForAdmin() async {
    final uid = AuthService.getCurrentUserId();
    if (uid == null || uid.isEmpty) return 0;
    await _ensureBoxOpen();
    int count = 0;
    final all = box.values.toList();
    for (final t in all) {
      if (t.userId.isEmpty) {
        final updated = t.copyWith(userId: uid);
        await _retryOnIdbClosing(() async => box.put(t.id, updated));
        count++;
      }
    }
    if (count > 0) {
      await _retryOnIdbClosing(() async => box.flush());
    }
    return count;
  }

  static String? get _currentUserId => AuthService.getCurrentUserId();

  static List<InboxTask> getAllInboxTasks() {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      return box.values.where((t) => t.userId == uid).toList();
    } catch (_) {
      return [];
    }
  }

  static InboxTask? getInboxTask(String id) {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return null;
      final task = box.get(id);
      if (task == null || task.userId != uid) return null;
      return task;
    } catch (_) {
      return null;
    }
  }

  // 特定日付のインボックスタスク取得（現在ユーザー分のみ）
  static List<InboxTask> getInboxTasksForDate(DateTime date) {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      return box.values
          .where(
            (task) =>
                task.userId == uid &&
                task.executionDate.year == date.year &&
                task.executionDate.month == date.month &&
                task.executionDate.day == date.day,
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  // プロジェクトIDでのインボックスタスク取得（現在ユーザー分のみ）
  static List<InboxTask> getInboxTasksByProjectId(String projectId) {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      return box.values
          .where((task) => task.userId == uid && task.projectId == projectId)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> clearAllInboxTasks() async {
    await _ensureBoxOpen();
    int before = -1;
    try {
      before = box.length;
    } catch (_) {}
    await _retryOnIdbClosing(() async => box.clear());
    int after = -1;
    try {
      after = box.length;
    } catch (_) {}
    try {
      final uid = AuthService.getCurrentUserId();
      await SyncAllHistoryService.recordSimpleEvent(
        type: 'localBoxClear',
        reason: 'clearAllInboxTasks',
        origin: 'InboxTaskService.clearAllInboxTasks',
        userId: uid,
        extra: <String, dynamic>{
          'box': _boxName,
          'beforeCount': before,
          'afterCount': after,
        },
      );
    } catch (_) {}
  }

  static Future<void> close() async {
    await _box?.close();
    await _recordBoxState('close');
  }
}
