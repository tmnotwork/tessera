import '../utils/async_mutex.dart';
import 'retry_scheduler.dart';
import 'task_id_link_repository.dart';
import 'task_outbox_manager.dart';

/// 同期系コンポーネントの統合的な初期化・提供を担うランタイム。
class TaskSyncRuntime {
  TaskSyncRuntime._({
    required this.retryScheduler,
    required this.taskOutboxMutex,
    required this.syncAllMutex,
  });

  static TaskSyncRuntime? _instance;

  final RetryScheduler retryScheduler;
  final AsyncMutex taskOutboxMutex;
  final AsyncMutex syncAllMutex;

  static TaskSyncRuntime get instance {
    final value = _instance;
    if (value == null) {
      throw StateError('TaskSyncRuntime is not initialized');
    }
    return value;
  }

  /// 本番用初期化。
  static Future<TaskSyncRuntime> initialize() async {
    final repository = await TaskIdLinkRepository.initialize();
    final scheduler = RetryScheduler();
    await scheduler.initialize();
    final runtime = TaskSyncRuntime._(
      retryScheduler: scheduler,
      taskOutboxMutex: AsyncMutex(),
      syncAllMutex: AsyncMutex(),
    );
    await TaskOutboxManager.initialize(
      idLinkRepository: repository,
      retryScheduler: scheduler,
    );
    await scheduler.rehydrateFromPersistence();
    await TaskOutboxManager.seedLinksFromLocalData();
    _instance = runtime;
    return runtime;
  }

  /// テスト用の差し替え。
  static void overrideForTest(TaskSyncRuntime runtime) {
    _instance = runtime;
  }

  /// ランタイムを破棄する。
  Future<void> dispose() async {
    retryScheduler.dispose();
    await TaskOutboxManager.dispose();
    _instance = null;
  }
}
