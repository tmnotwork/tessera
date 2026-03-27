import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:meta/meta.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive/hive.dart';
import '../models/actual_task.dart';
import '../models/inbox_task.dart';
import '../models/user.dart';
import '../models/category.dart';
import '../models/project.dart';
import '../models/sub_project.dart';
import '../models/mode.dart';
import '../models/calendar_entry.dart';
import '../models/time_of_day_adapter.dart';
import '../models/work_type.dart';
import '../models/block.dart';
import '../models/routine_task_v2.dart';
import '../models/routine_block_v2.dart';
import '../models/routine_template_v2.dart';
import '../models/synced_day.dart';
import 'inbox_task_service.dart';
import 'actual_task_sync_service.dart';
import 'inbox_task_sync_service.dart';
import 'sync_context.dart';
import 'auth_service.dart';
import 'device_info_service.dart';
import 'app_settings_service.dart';
import 'task_sync_manager.dart';
import 'sync_all_history_service.dart';
import 'sync_kpi.dart';
import 'project_service.dart';
import 'selection_frequency_service.dart';
import '../firebase_options.dart';
import '../app/app_theme.dart';

/// ウィジェットからのタスク追加を処理するサービス
/// 既存のアプリ機能に影響を与えないよう、独立したサービスとして実装
class WidgetService {
  static const _snapshotPrefsKey = 'widget_inbox_items';
  /// Android ホームウィジェットが読むテーマ色（8桁 ARGB 16進文字列の JSON）
  static const _widgetThemePaletteKey = 'widget_theme_palette';
  static const MethodChannel _channel =
      MethodChannel('com.example.task_kant_1/widget');
  static bool _isInitialized = false;
  static StreamSubscription<dynamic>? _inboxWatchSub;
  static Timer? _debounce;
  static bool _adaptersEnsured = false;
  static Completer<bool>? _initializingCompleter;
  static String? _lastInitErrorReason;
  static String? _lastInitErrorMessage;

  /// ウィジェットサービスを初期化
  /// main.dartの初期化処理で呼び出す
  static Future<bool> initialize() async {
    if (_isInitialized) return true;
    if (_initializingCompleter != null) {
      return _initializingCompleter!.future;
    }

    final completer = Completer<bool>();
    _initializingCompleter = completer;

    try {
      _channel.setMethodCallHandler(_handleMethodCall);
      await _ensureHiveAdapters();
      await InboxTaskService.initialize();

      final snapshotResult = await _rebuildSnapshotFromInbox();
      if (snapshotResult['ok'] != true) {
        final reason = snapshotResult['reason'] as String? ?? 'snapshot_failed';
        final message = snapshotResult['message'] as String?;
        _recordInitializationFailure(reason, message);
        completer.complete(false);
        _initializingCompleter = null;
        return completer.future;
      }

      // スナップショットとテーマ色書き込み後にウィジェットへ再描画要求
      // ignore: unawaited_futures
      _requestSystemWidgetRefresh();

      try {
        _inboxWatchSub = InboxTaskService.box.watch().listen((_) {
          _scheduleRefresh();
        });
      } catch (e) {
        // box 監視が利用できなくても致命ではないためログのみ
        // ignore: avoid_print
        print('WidgetService: failed to watch inbox changes - $e');
      }

      _isInitialized = true;
      _lastInitErrorReason = null;
      _lastInitErrorMessage = null;
      completer.complete(true);
    } catch (e) {
      _recordInitializationFailure('notInitialized', e.toString());
      completer.complete(false);
    } finally {
      _initializingCompleter = null;
    }

    return completer.future;
  }

  static Future<void> _ensureHiveAdapters() async {
    if (_adaptersEnsured) return;
    try {
      // Hiveはmain.dart側でinitFlutter済み想定。未初期化でも影響ないように握る。
      // 必要最低限のアダプタのみチェックして登録
      final registrations = <int, Function>{
        0: () => Hive.registerAdapter(UserAdapter()),
        1: () => Hive.registerAdapter(CategoryAdapter()),
        2: () => Hive.registerAdapter(ProjectAdapter()),
        3: () => Hive.registerAdapter(SubProjectAdapter()),
        4: () => Hive.registerAdapter(ModeAdapter()),
        5: () => Hive.registerAdapter(ActualTaskAdapter()),
        6: () => Hive.registerAdapter(CalendarEntryAdapter()),
        10: () => Hive.registerAdapter(TimeOfDayAdapter()),
        16: () => Hive.registerAdapter(TaskCreationMethodAdapter()),
        18: () => Hive.registerAdapter(ActualTaskStatusAdapter()),
        20: () => Hive.registerAdapter(InboxTaskAdapter()),
        26: () => Hive.registerAdapter(WorkTypeAdapter()),
        27: () => Hive.registerAdapter(RoutineBlockV2Adapter()),
        28: () => Hive.registerAdapter(RoutineTaskV2Adapter()),
        29: () => Hive.registerAdapter(RoutineTemplateV2Adapter()),
        99: () => Hive.registerAdapter(BlockAdapter()),
        120: () => Hive.registerAdapter(SyncedDayKindAdapter()),
        121: () => Hive.registerAdapter(SyncedDayStatusAdapter()),
        122: () => Hive.registerAdapter(SyncedDayAdapter()),
      };
      registrations.forEach((typeId, register) {
        try {
          if (!Hive.isAdapterRegistered(typeId)) {
            register();
          }
        } catch (_) {}
      });
    } catch (_) {}
    _adaptersEnsured = true;
  }

  static Future<Map<String, dynamic>> ensureInitialized() async {
    final ready = await initialize();
    if (ready) {
      return _successResponse();
    }
    return _errorResponse(
      _lastInitErrorReason ?? 'notInitialized',
      message: _lastInitErrorMessage ?? 'WidgetService failed to initialize',
    );
  }

  /// Method Channelからの呼び出しを処理
  static Future<dynamic> _handleMethodCall(MethodCall call) async {
    try {
      switch (call.method) {
        case 'addTask':
          final Map<dynamic, dynamic> args = call.arguments;
          return await _addTaskFromWidget(args);
        case 'listProjects':
          return await _listProjectsFromWidget();
        case 'getTaskDetail':
          final Map<dynamic, dynamic> args = call.arguments;
          return await _getTaskDetailFromWidget(args);
        case 'updateTask':
          final Map<dynamic, dynamic> args = call.arguments;
          return await _updateTaskFromWidget(args);
        case 'deleteTask':
          final Map<dynamic, dynamic> args = call.arguments;
          return await _deleteTaskFromWidget(args);
        case 'completeTask':
          final Map<dynamic, dynamic> args = call.arguments;
          // completeById / completeFirstByTitle の両方に対応
          return await _completeTaskFromWidget(args);
        case 'ensureInitialized':
          return await ensureInitialized();
        case 'refreshAndSync':
          final origin = _extractOrigin(call.arguments);
          return await refreshAndSync(origin: origin);
        case 'refreshWidgetSnapshot':
          return await refreshWidgetSnapshot();
        default:
          throw PlatformException(
            code: 'UNIMPLEMENTED',
            message: 'WidgetService does not implement method ${call.method}',
          );
      }
    } catch (e) {
      print('WidgetService error: $e');
      return false;
    }
  }

  /// 現在の未了インボックスタスクからスナップショットを再構成
  static Future<Map<String, dynamic>> refreshWidgetSnapshot() async {
    if (!_isInitialized) {
      final ready = await initialize();
      if (!ready) {
        return _errorResponse(
          _lastInitErrorReason ?? 'notInitialized',
          message: _lastInitErrorMessage ?? 'WidgetService is not initialized',
        );
      }
    }

    final result = await _rebuildSnapshotFromInbox();
    if (result['ok'] == true) {
      // スナップショット保存後にウィジェットへ更新要求
      // ignore: unawaited_futures
      _requestSystemWidgetRefresh();
    } else {
      // ignore: avoid_print
      print(
          'WidgetService.refreshWidgetSnapshot failed: ${result['reason']} ${result['message'] ?? ''}');
    }
    return result;
  }

  /// ウィジェットからタスクを追加
  static Future<Map<String, dynamic>> _addTaskFromWidget(
      Map<dynamic, dynamic> args) async {
    try {
      final String title = args['title'] as String? ?? '';
      final String? rawProjectId = args['projectId'] as String?;
      final String? projectId =
          rawProjectId != null && rawProjectId.trim().isNotEmpty
              ? rawProjectId.trim()
              : null;
      final int executionTimestamp = args['executionDate'] as int? ??
          DateTime.now().millisecondsSinceEpoch;
      // Duration selection:
      // - If the widget does not explicitly pass a duration, use app setting.
      // - If it passes legacy default (30), always prefer app setting (including 0).
      // - 0 means "unset" in this app (初期値0で統一) -> use app setting.
      int? defaultMinutes;
      try {
        await AppSettingsService.initialize();
        defaultMinutes = AppSettingsService.getInt(
          AppSettingsService.keyTaskDefaultEstimatedMinutes,
          defaultValue: 0,
        );
      } catch (_) {
        // Do not swallow failures as "0". Null means "failed to load settings".
        defaultMinutes = null;
      }

      final dynamic rawDuration = args.containsKey('estimatedDuration')
          ? args['estimatedDuration']
          : null;
      int? normalized;
      if (rawDuration is int) {
        normalized = rawDuration;
      } else if (rawDuration is double) {
        normalized = rawDuration.round();
      }

      int estimatedDuration;
      if (normalized == null || normalized <= 0) {
        estimatedDuration = defaultMinutes ?? 0;
      } else if (normalized == 30 && defaultMinutes != null) {
        // Backward compatibility: treat 30 as "legacy default" for widgets.
        // Important: allow overriding to 0 ("unset") as well.
        estimatedDuration = defaultMinutes;
      } else {
        estimatedDuration = normalized;
      }
      // Safety clamp
      if (estimatedDuration < 0) estimatedDuration = 0;
      if (estimatedDuration > 1440) estimatedDuration = 1440;

      if (title.isEmpty) {
        print('WidgetService: Task title is empty');
        return _errorResponse(
          'missing_title',
          message: 'タイトルが指定されていません',
        );
      }

      try {
        await AuthService.initialize();
      } catch (_) {}
      final waitedUserId =
          await AuthService.waitForUserId(timeout: const Duration(seconds: 4));
      final userId = waitedUserId ?? AuthService.getCurrentUserId();
      if (userId == null || userId.isEmpty) {
        print('WidgetService: No authenticated user; aborting widget addTask');
        return _errorResponse(
          'auth_missing',
          message: 'ログインが必要です',
        );
      }

      // 新しいInboxTaskを作成
      final now = DateTime.now();
      final executionDate =
          DateTime.fromMillisecondsSinceEpoch(executionTimestamp);

      final task = InboxTask(
        id: _generateUniqueId(),
        title: title,
        projectId: projectId,
        executionDate: executionDate,
        estimatedDuration: estimatedDuration,
        createdAt: now,
        lastModified: now,
        userId: userId,
        isCompleted: false,
        isRunning: false,
        deviceId: 'widget_device', // ウィジェット専用デバイスID
      );

      // InboxTaskServiceを使ってタスクを追加
      await InboxTaskService.addInboxTask(task);

      // 追加直後に同期（失敗時は outbox に残して再送）
      unawaited(TaskSyncManager.syncInboxTaskImmediately(
        task,
        'create',
        origin: 'WidgetService.addTaskFromWidget',
      ));

      // スナップショットを更新（未了のインボックスタスクを最大5件）
      await refreshWidgetSnapshot();

      print('WidgetService: Task added successfully - $title');
      final trimmedTitle = title.trim();
      final successMessage =
          trimmedTitle.isEmpty ? 'タスクを追加しました' : '「$trimmedTitle」を追加しました';
      return _successResponse(
        extra: {
          'taskId': task.id,
          'message': successMessage,
        },
      );
    } catch (e) {
      print('WidgetService: Error adding task - $e');
      return _errorResponse(
        'add_failed',
        message: 'タスクの追加に失敗しました',
      );
    }
  }

  static Future<Map<String, dynamic>> _listProjectsFromWidget() async {
    try {
      if (!_isInitialized) {
        final ready = await initialize();
        if (!ready) {
          return _errorResponse(
            _lastInitErrorReason ?? 'notInitialized',
            message: _lastInitErrorMessage ?? 'WidgetService is not initialized',
          );
        }
      }

      try {
        await ProjectService.initialize();
      } catch (_) {}

      final projects = ProjectService.getActiveProjects()
          .where((p) => p.isDeleted != true)
          .toList();

      projects.sort((a, b) {
        final fa = SelectionFrequencyService.getProjectCount(a.id);
        final fb = SelectionFrequencyService.getProjectCount(b.id);
        if (fb != fa) return fb.compareTo(fa); // 多い順
        // 同頻度時は既存sortOrderを次優先にして安定化
        final ao = a.sortOrder ?? 1 << 30;
        final bo = b.sortOrder ?? 1 << 30;
        final byOrder = ao.compareTo(bo);
        if (byOrder != 0) return byOrder;
        return a.name.compareTo(b.name);
      });

      return _successResponse(
        extra: {
          'projects': projects
              .map((p) => {
                    'id': p.id,
                    'name': p.name,
                  })
              .toList(),
        },
      );
    } catch (e) {
      return _errorResponse('list_projects_failed', message: e.toString());
    }
  }

  static Future<Map<String, dynamic>> _getTaskDetailFromWidget(
      Map<dynamic, dynamic> args) async {
    final String id = args['id'] as String? ?? '';
    if (id.isEmpty) {
      return _errorResponse(
        'missing_id',
        message: 'タスクIDが指定されていません',
      );
    }
    try {
      await InboxTaskService.initialize();
      final task = InboxTaskService.getInboxTask(id);
      if (task == null) {
        return _errorResponse(
          'not_found',
          message: '対象のタスクが見つかりません',
        );
      }
      return _successResponse(
        extra: {
          'task': {
            'id': task.id,
            'title': task.title,
            'memo': task.memo,
            'estimatedDuration': task.estimatedDuration,
            'projectId': task.projectId,
          },
        },
      );
    } catch (e) {
      return _errorResponse('lookup_failed', message: e.toString());
    }
  }

  static Future<Map<String, dynamic>> _updateTaskFromWidget(
      Map<dynamic, dynamic> args) async {
    final String id = args['id'] as String? ?? '';
    final String title = (args['title'] as String? ?? '').trim();
    final String? memo = args['memo'] as String?;
    final bool hasProjectId = args.containsKey('projectId');
    final String? rawProjectId =
        hasProjectId ? args['projectId'] as String? : null;
    final String? projectId =
        rawProjectId != null && rawProjectId.trim().isNotEmpty
            ? rawProjectId.trim()
            : null;
    final int? estimatedDuration =
        _normalizeDurationArg(args['estimatedDuration']);

    if (id.isEmpty) {
      return _errorResponse(
        'missing_id',
        message: 'タスクIDが指定されていません',
      );
    }
    if (title.isEmpty) {
      return _errorResponse(
        'missing_title',
        message: 'タイトルが指定されていません',
      );
    }

    try {
      try {
        await AuthService.initialize();
      } catch (_) {}
      final waitedUserId =
          await AuthService.waitForUserId(timeout: const Duration(seconds: 4));
      final userId = waitedUserId ?? AuthService.getCurrentUserId();
      if (userId == null || userId.isEmpty) {
        return _errorResponse('auth_missing', message: 'ログインが必要です');
      }

      await InboxTaskService.initialize();
      final task = InboxTaskService.getInboxTask(id);
      if (task == null) {
        return _errorResponse(
          'not_found',
          message: '対象のタスクが見つかりません',
        );
      }

      bool modified = false;
      if (task.title != title) {
        task.title = title;
        modified = true;
      }
      if (memo != null && memo != task.memo) {
        task.memo = memo;
        modified = true;
      }
      if (hasProjectId && task.projectId != projectId) {
        task.projectId = projectId;
        modified = true;
      }
      if (estimatedDuration != null &&
          estimatedDuration > 0 &&
          estimatedDuration <= 1440 &&
          task.estimatedDuration != estimatedDuration) {
        task.estimatedDuration = estimatedDuration;
        modified = true;
      }

      if (!modified) {
        return _successResponse(extra: {'message': '変更はありません'});
      }

      try {
        task.markAsModified(await DeviceInfoService.getDeviceId());
      } catch (_) {
        task.lastModified = DateTime.now();
      }
      await InboxTaskService.updateInboxTask(task);
      unawaited(TaskSyncManager.syncInboxTaskImmediately(
        task,
        'update',
        origin: 'WidgetService.updateTaskFromWidget',
      ));
      await refreshWidgetSnapshot();

      final trimmedTitle = title.trim();
      final successMessage =
          trimmedTitle.isEmpty ? 'タスクを更新しました' : '「$trimmedTitle」を更新しました';
      return _successResponse(
        extra: {
          'taskId': task.id,
          'message': successMessage,
        },
      );
    } catch (e) {
      return _errorResponse('update_failed', message: e.toString());
    }
  }

  static Future<Map<String, dynamic>> _deleteTaskFromWidget(
      Map<dynamic, dynamic> args) async {
    final String id = args['id'] as String? ?? '';
    if (id.isEmpty) {
      return _errorResponse(
        'missing_id',
        message: 'タスクIDが指定されていません',
      );
    }
    try {
      try {
        await AuthService.initialize();
      } catch (_) {}
      final waitedUserId =
          await AuthService.waitForUserId(timeout: const Duration(seconds: 4));
      final userId = waitedUserId ?? AuthService.getCurrentUserId();
      if (userId == null || userId.isEmpty) {
        return _errorResponse('auth_missing', message: 'ログインが必要です');
      }

      await InboxTaskService.initialize();
      final task = InboxTaskService.getInboxTask(id);
      if (task == null) {
        return _errorResponse(
          'not_found',
          message: '対象のタスクが見つかりません',
        );
      }

      final title = task.title.trim();
      await InboxTaskSyncService().deleteTaskWithSync(task.id);
      await refreshWidgetSnapshot();

      final successMessage = title.isEmpty ? 'タスクを削除しました' : '「$title」を削除しました';
      return _successResponse(
        extra: {
          'taskId': task.id,
          'message': successMessage,
        },
      );
    } catch (e) {
      return _errorResponse('delete_failed', message: e.toString());
    }
  }

  /// ウィジェットから完了要求（タイトル一致の先頭を0分実績で完了）
  static Future<Map<String, dynamic>> _completeTaskFromWidget(
      Map<dynamic, dynamic> args) async {
    InboxTask? optimisticTask;
    try {
      await InboxTaskService.initialize();
      try {
        await AuthService.initialize();
      } catch (_) {}
      final resolvedUserId = await AuthService.waitForUserId(
              timeout: const Duration(seconds: 4)) ??
          AuthService.getCurrentUserId();
      if (resolvedUserId == null || resolvedUserId.isEmpty) {
        return _errorResponse(
          'auth_missing',
          message: 'ログインが必要です',
        );
      }

      final String? id = args['id'] as String?;
      InboxTask? t;
      if (id != null && id.isNotEmpty) {
        t = InboxTaskService.getInboxTask(id);
        if (t == null) {
          return _errorResponse(
            'not_found',
            message: '指定したタスクが見つかりません',
          );
        }
        if (t.isSomeday == true || t.isCompleted == true) {
          return _errorResponse(
            'invalid_state',
            message: 'このタスクは完了できません',
          );
        }
      } else {
        final String title = args['title'] as String? ?? '';
        if (title.isEmpty) {
          return _errorResponse(
            'missing_title',
            message: 'タイトルが指定されていません',
          );
        }
        // タイトル一致（後方互換）。未完了・未割当・未Somedayのみ
        final tasks = InboxTaskService.getAllInboxTasks()
            .where((x) => !x.isCompleted)
            .where((x) => x.isSomeday != true)
            .where((x) => (x.startHour == null || x.startMinute == null))
            .where((x) => (x.title == title))
            .toList();
        if (tasks.isEmpty) {
          return _errorResponse(
            'not_found',
            message: '対象のタスクが見つかりません',
          );
        }
        t = tasks.first;
      }

      // まずは楽観的にローカル完了 → 直ちにスナップショット更新（体感待ちを無くす）
      await _optimisticallySetWidgetItemStatus(t.id, isChecked: true);
      t.isCompleted = true;
      try {
        t.markAsModified('widget_device');
      } catch (_) {
        t.lastModified = DateTime.now();
      }
      await InboxTaskService.updateInboxTask(t);
      await refreshWidgetSnapshot();
      optimisticTask = t;

      await ActualTaskSyncService().createCompletedZeroTaskWithSync(
        title: t.title,
        projectId: t.projectId,
        memo: t.memo,
        subProjectId: t.subProjectId,
        subProject: null,
        modeId: null,
        blockName: null,
        sourceInboxTaskId: t.id,
      );
      // 送信失敗時も outbox に残して再送（後で未了へ巻き戻るのを防ぐ）
      unawaited(TaskSyncManager.syncInboxTaskImmediately(
        t,
        'update',
        origin: 'WidgetService.completeTaskFromWidget',
      ));
      final title = t.title.trim();
      final successMessage = title.isEmpty ? 'タスクを完了しました' : '「$title」を完了しました';
      return _successResponse(
        extra: {
          'taskId': t.id,
          'message': successMessage,
        },
      );
    } catch (e) {
      print('WidgetService: Error completing task - $e');
      if (optimisticTask != null) {
        await _revertOptimisticCompletion(optimisticTask);
      }
      return _errorResponse(
        'completion_failed',
        message: 'タスクの完了に失敗しました: ${e.toString()}',
      );
    }
  }

  static Future<void> _revertOptimisticCompletion(InboxTask task) async {
    try {
      await _optimisticallySetWidgetItemStatus(task.id, isChecked: false);
    } catch (_) {}
    try {
      task.isCompleted = false;
      await InboxTaskService.updateInboxTask(task);
    } catch (_) {}
    try {
      await refreshWidgetSnapshot();
    } catch (_) {}
  }

  /// ウィジェットサービスを終了
  static Future<void> dispose() async {
    if (!_isInitialized) return;

    _channel.setMethodCallHandler(null);
    try {
      await _inboxWatchSub?.cancel();
    } catch (_) {}
    _inboxWatchSub = null;
    _debounce?.cancel();
    _debounce = null;
    _isInitialized = false;
  }

  /// ユニークIDを生成（UUIDの代替）
  static String _generateUniqueId() {
    final random = Random();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final randomValue = random.nextInt(999999);
    return 'widget_${timestamp}_$randomValue';
  }

  static void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final result = await refreshWidgetSnapshot();
      if (result['ok'] != true) {
        // ignore: avoid_print
        print('WidgetService: debounced snapshot failed ${result['reason']}');
      }
    });
  }

  static Map<String, String> _extractStatusesFromSnapshot(String? raw) {
    final map = <String, String>{};
    if (raw == null || raw.isEmpty) return map;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final entry in decoded) {
          if (entry is String) {
            final parts = entry.split('|');
            if (parts.length >= 2 && parts.first.isNotEmpty) {
              map[parts.first] = parts[1];
            }
          }
        }
      }
    } catch (_) {}
    return map;
  }

  static Future<void> _optimisticallySetWidgetItemStatus(
    String id, {
    required bool isChecked,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final snapshot = prefs.getString(_snapshotPrefsKey);
      if (snapshot == null || snapshot.isEmpty) return;

      final decoded = jsonDecode(snapshot);
      if (decoded is! List) return;

      bool modified = false;
      final updated = <String>[];
      for (final entry in decoded) {
        if (entry is! String) continue;
        final parts = entry.split('|').toList();
        if (parts.isEmpty) continue;
        if (parts.first == id) {
          while (parts.length < 3) {
            parts.add('');
          }
          final nextStatus = isChecked ? '1' : '0';
          if (parts[1] != nextStatus) {
            parts[1] = nextStatus;
            modified = true;
          }
          updated.add(parts.join('|'));
        } else {
          updated.add(entry);
        }
      }

      if (!modified) return;

      await prefs.setString(_snapshotPrefsKey, jsonEncode(updated));
      await prefs.reload();
      // ignore: unawaited_futures
      _requestSystemWidgetRefresh();
    } catch (_) {}
  }

  static Future<void> _requestSystemWidgetRefresh() async {
    try {
      const control = MethodChannel('com.example.task_kant_1/widget_control');
      await control.invokeMethod('refreshWidgets');
    } catch (_) {}
  }

  /// Firestore→Hive 同期を試みたうえでスナップショットを更新（オフライン時はHiveのみ）
  static Future<Map<String, dynamic>> refreshAndSync({String? origin}) async {
    final historyId = await SyncAllHistoryService.recordEventStart(
      type: 'widgetSync',
      reason: 'widget refreshAndSync',
      origin: origin != null && origin.isNotEmpty
          ? 'WidgetService.refreshAndSync:$origin'
          : 'WidgetService.refreshAndSync',
      extra: <String, dynamic>{
        'originArg': origin,
      },
    );
    final ready = await initialize();
    if (!ready) {
      final reason = _lastInitErrorReason ?? 'notInitialized';
      await SyncAllHistoryService.recordFailed(
        id: historyId,
        error: reason,
        extra: <String, dynamic>{
          'message': _lastInitErrorMessage,
        },
      );
      return _errorResponse(
        reason,
        message: _lastInitErrorMessage ?? 'WidgetService is not initialized',
      );
    }
    try {
      final result = await _refreshAndSyncInternal(origin: origin)
          .timeout(const Duration(seconds: 30));
      if (result['ok'] == true) {
        await SyncAllHistoryService.recordFinish(
          id: historyId,
          success: true,
          extra: <String, dynamic>{
            'resultOk': true,
          },
        );
      } else {
        await SyncAllHistoryService.recordFinish(
          id: historyId,
          success: false,
          error: '${result['reason'] ?? 'unknown'}',
          extra: <String, dynamic>{
            'resultOk': false,
            'reason': result['reason'],
            'message': result['message'],
          },
        );
      }
      return result;
    } on TimeoutException catch (e) {
      print('WidgetService.refreshAndSync: timeout');
      await SyncAllHistoryService.recordFailed(
        id: historyId,
        error: 'timeout',
        extra: <String, dynamic>{
          'message': e.message,
        },
      );
      await refreshWidgetSnapshot();
      return _errorResponse('timeout', message: e.message ?? 'timeout');
    }
  }

  static Future<Map<String, dynamic>> _refreshAndSyncInternal(
      {String? origin}) async {
    try {
      await InboxTaskService.initialize();

      await _ensureFirebaseInitialized();

      try {
        await AuthService.initialize();
      } catch (_) {}

      bool hasRealUser = false;
      try {
        hasRealUser = await _waitForExistingNonAnonymousUser(
          timeout: const Duration(seconds: 8),
          poll: const Duration(milliseconds: 200),
        );
      } catch (_) {}

      final currentUser = firebase_auth.FirebaseAuth.instance.currentUser;
      if (!hasRealUser) {
        final shouldAbort = currentUser == null || currentUser.isAnonymous;
        if (shouldAbort) {
          print('WidgetService.refreshAndSync: no authenticated user.');
          return _errorResponse('auth_missing', message: 'ログインが必要です');
        }
      }

      try {
        // read削減: ウィジェット起点でのフル同期は禁止。差分同期（cursor）を優先する。
        await SyncContext.runWithOrigin(
          'WidgetService.refreshAndSync',
          () => InboxTaskSyncService.syncAllInboxTasks(forceFullSync: false),
        );
      } catch (e) {
        print('WidgetService.refreshAndSync: sync warning $e');
      }

      final snapshotResult = await refreshWidgetSnapshot();
      if (snapshotResult['ok'] != true) {
        return snapshotResult;
      }
      return _successResponse();
    } catch (e) {
      print('WidgetService.refreshAndSync: error=$e');
      await refreshWidgetSnapshot();
      return _errorResponse('exception', message: e.toString());
    }
  }

  /// FirebaseAuth の再水和で既存の「非匿名ユーザー」が復元されるのを短時間待つ
  static Future<bool> _waitForExistingNonAnonymousUser({
    required Duration timeout,
    required Duration poll,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final u = firebase_auth.FirebaseAuth.instance.currentUser;
        if (u != null && (u.isAnonymous == false)) {
          return true;
        }
      } catch (_) {}
      await Future.delayed(poll);
    }
    return false;
  }

  static Future<void> _ensureFirebaseInitialized() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }
    } catch (_) {
      try {
        if (Firebase.apps.isEmpty) {
          await Firebase.initializeApp();
        }
      } catch (e) {
        rethrow;
      }
    }
  }

  static Future<Map<String, dynamic>> _rebuildSnapshotFromInbox() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _persistWidgetThemePalette(prefs);
      final previousSnapshot = prefs.getString(_snapshotPrefsKey);
      final previousStatuses = _extractStatusesFromSnapshot(previousSnapshot);
      final items = _buildSnapshotItems(previousStatuses);
      await prefs.setString(_snapshotPrefsKey, jsonEncode(items));
      await prefs.reload();
      return _successResponse(extra: {'count': items.length});
    } catch (e) {
      return _errorResponse('prefs_write_failed', message: e.toString());
    }
  }

  static String _colorToHexArgb8(Color c) {
    final a = (c.a * 255.0).round().clamp(0, 255);
    final r = (c.r * 255.0).round().clamp(0, 255);
    final g = (c.g * 255.0).round().clamp(0, 255);
    final b = (c.b * 255.0).round().clamp(0, 255);
    final u = (a << 24) | (r << 16) | (g << 8) | b;
    return u.toRadixString(16).padLeft(8, '0');
  }

  static ThemeData _resolveWidgetMirrorTheme() {
    var key = AppSettingsService.themeModeKeyNotifier.value;
    try {
      final s = AppSettingsService.getString(AppSettingsService.keyThemeMode);
      if (s != null && s.isNotEmpty) key = s;
    } catch (_) {}

    final mode = AppSettingsService.themeModeFromString(key);
    var platformBrightness = Brightness.light;
    try {
      platformBrightness =
          SchedulerBinding.instance.platformDispatcher.platformBrightness;
    } catch (_) {}
    final useDark = mode == ThemeMode.dark ||
        (mode == ThemeMode.system && platformBrightness == Brightness.dark);

    if (useDark) {
      return switch (key) {
        'wine' => buildWineDarkTheme(),
        'teal' => buildTealDarkTheme(),
        'orange' => buildOrangeDarkTheme(),
        'black_minimal' => buildBlackMinimalDarkTheme(),
        _ => buildDarkTheme(),
      };
    }
    return switch (key) {
      'gray_light' => buildGrayLightTheme(),
      'wine_light' => buildWineLightTheme(),
      'teal_light' => buildTealLightTheme(),
      'black_minimal_light' => buildBlackMinimalLightTheme(),
      'bright_blue_light' => buildLightTheme(),
      _ => buildLightTheme(),
    };
  }

  static Map<String, String> _widgetPaletteHexJson(ThemeData t) {
    final cs = t.colorScheme;
    final barBg = t.appBarTheme.backgroundColor ?? cs.primary;
    final barFg = t.appBarTheme.foregroundColor ??
        t.appBarTheme.titleTextStyle?.color ??
        cs.onSurface;
    final divider = t.dividerTheme.color ?? cs.outlineVariant;
    return {
      'headerBg': _colorToHexArgb8(barBg),
      'headerFg': _colorToHexArgb8(barFg),
      'bodyBg': _colorToHexArgb8(cs.surface),
      'itemText': _colorToHexArgb8(cs.onSurface),
      'divider': _colorToHexArgb8(divider),
      'accent': _colorToHexArgb8(cs.primary),
    };
  }

  static Future<void> _persistWidgetThemePalette(SharedPreferences prefs) async {
    try {
      await AppSettingsService.initialize();
    } catch (_) {}
    try {
      final theme = _resolveWidgetMirrorTheme();
      await prefs.setString(
        _widgetThemePaletteKey,
        jsonEncode(_widgetPaletteHexJson(theme)),
      );
    } catch (e) {
      // ignore: avoid_print
      print('WidgetService: persist widget theme palette failed: $e');
    }
  }

  /// 現在のテーマ設定に合わせてウィジェット用の色を書き込み、Android ウィジェットを再描画する。
  static Future<void> syncWidgetThemePaletteToNative() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _persistWidgetThemePalette(prefs);
      await prefs.reload();
      await _requestSystemWidgetRefresh();
    } catch (e) {
      // ignore: avoid_print
      print('WidgetService.syncWidgetThemePaletteToNative: $e');
    }
  }

  static List<String> _buildSnapshotItems(
      Map<String, String> previousStatuses) {
    final tasks = _gatherActiveInboxTasks();
    return tasks.map((t) {
      final title = t.title.isEmpty ? '(無題)' : t.title;
      final status = previousStatuses[t.id] ?? '0';
      return '${t.id}|$status|$title';
    }).toList();
  }

  static List<InboxTask> _gatherActiveInboxTasks() {
    var filtered = InboxTaskService.getAllInboxTasks()
        .where((t) => t.isDeleted != true)
        .where((t) => t.isCompleted != true)
        .where((t) => t.isSomeday != true)
        .where((t) => t.startHour == null || t.startMinute == null)
        .toList();

    try {
      final Map<String, List<InboxTask>> byCid = {};
      final List<InboxTask> noCid = [];
      for (final t in filtered) {
        final cid = t.cloudId ?? '';
        if (cid.isEmpty) {
          noCid.add(t);
        } else {
          (byCid[cid] ??= []).add(t);
        }
      }
      final List<InboxTask> cloudCollapsed = [];
      for (final entry in byCid.entries) {
        final list = entry.value;
        if (list.length == 1) {
          cloudCollapsed.add(list.first);
        } else {
          list.sort((a, b) => b.lastModified.compareTo(a.lastModified));
          cloudCollapsed.add(list.first);
        }
      }
      cloudCollapsed.addAll(noCid);

      final Map<String, List<InboxTask>> byId = {};
      for (final t in cloudCollapsed) {
        (byId[t.id] ??= []).add(t);
      }
      final List<InboxTask> idCollapsed = [];
      for (final entry in byId.entries) {
        final list = entry.value;
        if (list.length == 1) {
          idCollapsed.add(list.first);
        } else {
          list.sort((a, b) => b.lastModified.compareTo(a.lastModified));
          idCollapsed.add(list.first);
        }
      }
      filtered = idCollapsed;
    } catch (_) {}

    return filtered;
  }

  static void _recordInitializationFailure(String reason, String? message) {
    _isInitialized = false;
    _lastInitErrorReason = reason;
    _lastInitErrorMessage = message;
    try {
      _inboxWatchSub?.cancel();
    } catch (_) {}
    _inboxWatchSub = null;
  }

  static Map<String, dynamic> _successResponse({Map<String, dynamic>? extra}) {
    return {
      'ok': true,
      if (extra != null) ...extra,
    };
  }

  static String? _extractOrigin(dynamic raw) {
    if (raw is Map) {
      final value = raw['origin'];
      if (value is String && value.isNotEmpty) {
        return value;
      }
    } else if (raw is String && raw.isNotEmpty) {
      return raw;
    }
    return null;
  }

  static int? _normalizeDurationArg(dynamic raw) {
    if (raw is int) return raw;
    if (raw is double) return raw.round();
    return null;
  }

  static String _originLabel(String? origin) {
    if (origin == null || origin.isEmpty) return 'origin=unknown';
    return 'origin=$origin';
  }

  static Map<String, dynamic> _errorResponse(
    String reason, {
    String? message,
    Map<String, dynamic>? extra,
  }) {
    return {
      'ok': false,
      'reason': reason,
      if (message != null && message.isNotEmpty) 'message': message,
      if (extra != null) ...extra,
    };
  }

  @visibleForTesting
  static Map<String, String> debugExtractStatuses(String? raw) =>
      _extractStatusesFromSnapshot(raw);

  @visibleForTesting
  static Future<void> debugOptimisticallySetStatus(
    String id, {
    required bool isChecked,
  }) =>
      _optimisticallySetWidgetItemStatus(id, isChecked: isChecked);
}
