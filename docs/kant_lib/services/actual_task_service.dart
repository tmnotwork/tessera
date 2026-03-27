import 'package:hive/hive.dart';
import 'dart:async';
import '../models/actual_task.dart';
import '../models/block.dart';
import 'auth_service.dart';
import 'sync_all_history_service.dart';

class ActualTaskService {
  static Box<ActualTask>? _actualTaskBox;
  static bool _opening = false;
  static DateTime? _lastDiagAtUtc;
  static int? _lastDiagCount;
  static final StreamController<void> _updateController = StreamController<void>.broadcast();
  static Stream<void> get updateStream => _updateController.stream;
  static void _notifyUpdate() {
    try {
      _updateController.add(null);
    } catch (_) {}
  }

  static Future<void> _ensureBoxOpen() async {
    if (_actualTaskBox != null && _actualTaskBox!.isOpen) return;
    if (_opening) {
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 30));
        if (_actualTaskBox != null && _actualTaskBox!.isOpen) return;
      }
    }
    _opening = true;
    try {
      _actualTaskBox = await Hive.openBox<ActualTask>('actual_tasks');
    } finally {
      _opening = false;
    }
  }

  static Future<void> _recordBoxState(String reason) async {
    try {
      final now = DateTime.now().toUtc();
      int count = -1;
      bool isOpen = false;
      try {
        isOpen = _actualTaskBox != null && _actualTaskBox!.isOpen;
        if (isOpen) {
          count = _actualTaskBox!.length;
        }
      } catch (_) {}
      final lastAt = _lastDiagAtUtc;
      final lastCount = _lastDiagCount;
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
        origin: 'ActualTaskService',
        userId: uid,
        extra: <String, dynamic>{
          'box': 'actual_tasks',
          'isOpen': isOpen,
          'opening': _opening,
          'count': count,
        },
      );
    } catch (_) {}
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

  static Box<ActualTask> get actualTaskBox {
    if (_actualTaskBox == null) {
      throw Exception('ActualTaskService not initialized');
    }
    return _actualTaskBox!;
  }

  /// ActualTask changes stream (add/update/delete).
  static Stream<BoxEvent> watchChanges() {
    try {
      return actualTaskBox.watch();
    } catch (_) {
      return const Stream<BoxEvent>.empty();
    }
  }

  // 実績タスク追加
  static Future<void> addActualTask(ActualTask task) async {
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async {
      await actualTaskBox.put(task.id, task);
      await actualTaskBox.flush();
    });
    _notifyUpdate();
  }

  // 実績タスク更新
  static Future<void> updateActualTask(ActualTask task) async {
    await _ensureBoxOpen();
    // start/end が揃っている場合、保存フィールド(actualDuration)も整合させる。
    // これにより、エクスポートや他画面で actualDuration を参照しても齟齬が出ない。
    try {
      final end = task.endTime;
      if (end != null) {
        final mins = end.difference(task.startTime).inMinutes;
        task.actualDuration = mins < 0 ? 0 : mins;
      }
    } catch (_) {}
    // IMPORTANT:
    // ここで lastModified を自動更新すると、
    // - Firestoreから取得したリモートデータをローカルへ反映しただけで lastModified が上がる
    // - needsSync が true になり、次の同期で「差分がある」と判定されて無用な再アップロードが走る
    // - 結果として Firebase 側の lastModified まで意図せず更新される（書き込み増・監査上もNG）
    //
    // lastModified/version/deviceId の更新は「意味のある変更」を行う呼び出し側で
    // `task.markAsModified(...)` を使って明示的に行う。
    await _retryOnIdbClosing(() async {
      await actualTaskBox.put(task.id, task);
      await actualTaskBox.flush();
    });
    _notifyUpdate();
  }

  // 実績タスク更新（lastModified を保持）
  static Future<void> updateActualTaskPreservingLastModified(ActualTask task) async {
    await _ensureBoxOpen();
    // リモート反映やメタデータ更新では lastModified を動かさない。
    // ただし endTime がある場合の派生フィールド(actualDuration)は整合させる。
    try {
      final end = task.endTime;
      if (end != null) {
        final mins = end.difference(task.startTime).inMinutes;
        task.actualDuration = mins < 0 ? 0 : mins;
      }
    } catch (_) {}
    await _retryOnIdbClosing(() async {
      await actualTaskBox.put(task.id, task);
      await actualTaskBox.flush();
    });
    _notifyUpdate();
  }

  // 実績タスク削除
  static Future<void> deleteActualTask(String taskId) async {
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async {
      await actualTaskBox.delete(taskId);
      await actualTaskBox.flush();
    });
    _notifyUpdate();
  }

  static String? get _currentUserId => AuthService.getCurrentUserId();

  // 実績タスク取得（現在ユーザー所有のみ返す）
  static ActualTask? getActualTask(String taskId) {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return null;
      final task = actualTaskBox.get(taskId);
      if (task == null || task.userId != uid) return null;
      return task;
    } catch (e) {
      return null;
    }
  }

  // 全実績タスク取得（現在ユーザー分のみ）
  static List<ActualTask> getAllActualTasks() {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      final list = actualTaskBox.values
          .where((task) => !task.isDeleted && task.userId == uid)
          .toList();
      list.sort((a, b) => a.startTime.compareTo(b.startTime));
      return list;
    } catch (e) {
      return [];
    }
  }

  // 特定日付の実績タスク取得（現在ユーザー分のみ）
  static List<ActualTask> getActualTasksForDate(DateTime date) {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      final list = actualTaskBox.values
          .where((task) =>
              !task.isDeleted &&
              task.userId == uid &&
              task.isTaskForDate(date))
          .toList();
      list.sort((a, b) => a.startTime.compareTo(b.startTime));
      return list;
    } catch (e) {
      return [];
    }
  }

  // 特定プロジェクトの実績タスク取得（現在ユーザー分のみ）
  static List<ActualTask> getActualTasksByProject(String projectId) {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      final list = actualTaskBox.values
          .where((task) =>
              !task.isDeleted &&
              task.userId == uid &&
              task.projectId == projectId)
          .toList();
      list.sort((a, b) => a.startTime.compareTo(b.startTime));
      return list;
    } catch (e) {
      return [];
    }
  }

  // 実行中のタスク取得（現在ユーザー分のみ）
  static List<ActualTask> getRunningTasks() {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      final list = actualTaskBox.values
          .where((task) =>
              !task.isDeleted && task.userId == uid && task.isRunning)
          .toList();
      list.sort((a, b) => a.startTime.compareTo(b.startTime));
      return list;
    } catch (e) {
      return [];
    }
  }

  // 完了したタスク取得（現在ユーザー分のみ）
  static List<ActualTask> getCompletedTasks() {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      final list = actualTaskBox.values
          .where((task) =>
              !task.isDeleted && task.userId == uid && task.isCompleted)
          .toList();
      list.sort((a, b) => a.startTime.compareTo(b.startTime));
      return list;
    } catch (e) {
      return [];
    }
  }

  // 中断したタスク取得（現在ユーザー分のみ）
  static List<ActualTask> getPausedTasks() {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      final list = actualTaskBox.values
          .where((task) =>
              !task.isDeleted && task.userId == uid && task.isPaused)
          .toList();
      list.sort((a, b) => a.startTime.compareTo(b.startTime));
      return list;
    } catch (e) {
      return [];
    }
  }

  // 予定タスクから実績タスクを作成
  static Future<ActualTask> createActualTaskFromBlock(Block block) async {
    await _ensureBoxOpen();
    final now = DateTime.now();
    final actualTask = ActualTask(
      id: now.millisecondsSinceEpoch.toString(),
      title: block.title,
      projectId: block.projectId,
      dueDate: block.dueDate,
      startTime: block.startDateTime,
      memo: block.memo,
      location: block.location,
      createdAt: now,
      lastModified: now,
      userId: AuthService.getCurrentUserId() ?? '',
      blockId: (block.cloudId != null && block.cloudId!.isNotEmpty)
          ? block.cloudId!
          : block.id,
    );

    await addActualTask(actualTask);
    return actualTask;
  }

  // ボックスを閉じる
  static Future<void> close() async {
    await actualTaskBox.close();
  }

  // すべての実績タスクをクリア
  static Future<void> clearAll() async {
    await _ensureBoxOpen();
    await actualTaskBox.clear();
  }
}
