import 'package:hive/hive.dart';

import 'actual_task_service.dart';
import 'app_settings_service.dart';
import 'block_outbox_manager.dart';
import 'block_service.dart';
import 'category_service.dart';
import 'inbox_task_service.dart';
import 'mode_service.dart';
import 'project_service.dart';
import 'retry_scheduler.dart';
import 'routine_block_v2_service.dart';
import 'routine_task_v2_service.dart';
import 'routine_template_v2_service.dart';
import 'sub_project_service.dart';
import 'synced_day_service.dart';
import 'task_batch_queue_store.dart';
import 'task_id_link_repository.dart';
import 'task_outbox_manager.dart';

/// ログアウト時にローカルデータ（Hive）をクリアするサービス
class LocalDataClearService {
  LocalDataClearService._();

  /// すべてのユーザー固有データをクリア
  static Future<void> clearAllUserData() async {
    // 各サービスのクリア処理を並列実行
    await Future.wait([
      _clearActualTasks(),
      _clearBlocks(),
      _clearInboxTasks(),
      _clearProjects(),
      _clearSubProjects(),
      _clearModes(),
      _clearCategories(),
      _clearRoutineTemplatesV2(),
      _clearRoutineTasksV2(),
      _clearRoutineBlocksV2(),
      _clearSyncedDays(),
      _clearTaskOutbox(),
      _clearTaskBatchQueue(),
      _clearBlockOutbox(),
      _clearTaskIdLinks(),
      _clearRetryScheduler(),
      _clearAppSettings(),
    ]);
  }

  static Future<void> _clearActualTasks() async {
    try {
      await ActualTaskService.clearAll();
    } catch (_) {}
  }

  static Future<void> _clearBlocks() async {
    try {
      await BlockService.clearAllBlocks();
    } catch (_) {}
  }

  static Future<void> _clearInboxTasks() async {
    try {
      await InboxTaskService.clearAllInboxTasks();
    } catch (_) {}
  }

  static Future<void> _clearProjects() async {
    try {
      await ProjectService.clearAllData();
    } catch (_) {}
  }

  static Future<void> _clearSubProjects() async {
    try {
      await SubProjectService.clearAllData();
    } catch (_) {}
  }

  static Future<void> _clearModes() async {
    try {
      await ModeService.clearAll();
    } catch (_) {}
  }

  static Future<void> _clearCategories() async {
    try {
      await CategoryService.clearAll();
    } catch (_) {}
  }

  static Future<void> _clearRoutineTemplatesV2() async {
    try {
      await RoutineTemplateV2Service.clearAll();
    } catch (_) {}
  }

  static Future<void> _clearRoutineTasksV2() async {
    try {
      await RoutineTaskV2Service.clearAll();
    } catch (_) {}
  }

  static Future<void> _clearRoutineBlocksV2() async {
    try {
      await RoutineBlockV2Service.clearAll();
    } catch (_) {}
  }

  static Future<void> _clearSyncedDays() async {
    try {
      await SyncedDayService.clear();
    } catch (_) {}
  }

  static Future<void> _clearTaskOutbox() async {
    try {
      await TaskOutboxManager.clear();
    } catch (_) {}
  }

  static Future<void> _clearTaskBatchQueue() async {
    try {
      await TaskBatchQueueStore.clear();
    } catch (_) {}
  }

  static Future<void> _clearBlockOutbox() async {
    try {
      await BlockOutboxManager.clear();
    } catch (_) {}
  }

  static Future<void> _clearTaskIdLinks() async {
    try {
      await TaskIdLinkRepository.clearAll();
    } catch (_) {}
  }

  static Future<void> _clearRetryScheduler() async {
    try {
      await RetryScheduler.clearAll();
    } catch (_) {}
  }

  static Future<void> _clearAppSettings() async {
    try {
      // AppSettingsはユーザー固有設定のみクリア（UI設定は保持）
      await AppSettingsService.clearUserSpecificSettings();
    } catch (_) {}
  }
}
