import 'package:hive/hive.dart';

import 'app_settings_service.dart';
import 'auth_service.dart';

/// 旧ルーティン Hive（typeId 13 等）を捨て、**Firebase を正**としてローカルを取り直すための 1 回限りマイグレーション。
///
/// - 未ログイン: レガシー box ファイルのみディスクから削除（V2 ローカルは触らない）。
/// - ログイン済み: 上記に加え [routine_tasks_v2] / [routine_blocks_v2] / [routine_templates_v2] を削除し、
///   差分同期カーソルと Lamport カウンタを消して **次回同期でフルに近い取得**へ誘導する。
class RoutineLocalFirebaseResyncMigration {
  RoutineLocalFirebaseResyncMigration._();

  static const List<String> _legacyHiveBoxNames = [
    'routine_tasks',
    'routine_templates',
    'routine_blocks',
    'routine_time_zones',
  ];

  static const List<String> _v2HiveBoxNames = [
    'routine_tasks_v2',
    'routine_blocks_v2',
    'routine_templates_v2',
  ];

  static Future<void> migrateIfNeeded() async {
    await AppSettingsService.initialize();
    if (AppSettingsService.getBool(
      AppSettingsService.keyMigrationRoutineLocalFirebaseResyncV1,
      defaultValue: false,
    )) {
      return;
    }

    for (final name in _legacyHiveBoxNames) {
      await _deleteBoxFromDiskSafe(name);
    }

    final uid = AuthService.getCurrentUserId();
    if (uid != null && uid.isNotEmpty) {
      for (final name in _v2HiveBoxNames) {
        await _deleteBoxFromDiskSafe(name);
      }
      await AppSettingsService.clearRoutineV2ResyncState();
    }

    await AppSettingsService.setBool(
      AppSettingsService.keyMigrationRoutineLocalFirebaseResyncV1,
      true,
    );
  }

  static Future<void> _deleteBoxFromDiskSafe(String name) async {
    try {
      if (Hive.isBoxOpen(name)) {
        await Hive.box(name).close();
      }
    } catch (_) {}
    try {
      await Hive.deleteBoxFromDisk(name);
    } catch (_) {}
  }
}
