import 'package:hive/hive.dart';
import 'package:flutter/material.dart';

import '../utils/hive_open_with_retry.dart';

class AppSettingsService {
  static const String _boxName = 'app_settings';
  static Box<dynamic>? _box;
  static bool _opening = false;
  // Stored theme selector string. We keep this separate from ThemeMode so
  // switching between multiple dark variants still triggers rebuilds.
  // 初回表示・未設定時はライトミニマルをデフォルトとする
  static final ValueNotifier<String> themeModeKeyNotifier =
      ValueNotifier<String>('black_minimal_light');
  static final ValueNotifier<ThemeMode> themeModeNotifier =
      ValueNotifier(ThemeMode.light);
  static final ValueNotifier<bool> mobileDayUseGridNotifier =
      ValueNotifier(true);
  static final ValueNotifier<int> mobileDayGridWhichNotifier =
      ValueNotifier(0); // 0:予定,1:実績,2:両方
  static final ValueNotifier<bool> calendarShowEventsOnlyNotifier =
      ValueNotifier(false);
  static final ValueNotifier<String> calendarViewTypeNotifier =
      ValueNotifier<String>('month');
  static final ValueNotifier<String> weekStartNotifier =
      ValueNotifier<String>('sunday'); // 'sunday' | 'monday' | ...
  static final ValueNotifier<bool> projectShowProjectsOnlyNotifier =
      ValueNotifier<bool>(false);
  /// プロジェクト・サブプロジェクト選択時のアーカイブ表示: 'hide'=非表示, 'dimmed'=薄く表示
  static final ValueNotifier<String> archivedInSelectDisplayNotifier =
      ValueNotifier<String>('hide');
  /// true = 新UI（左メニュー）、false = 旧UI（下部バー）。mainUiTypeNotifier と連動。
  static final ValueNotifier<bool> useNewUINotifier =
      ValueNotifier<bool>(true);
  /// 'old' = 旧UI（下部バー）, 'new' = 新UI（GitHub版）
  static final ValueNotifier<String> mainUiTypeNotifier =
      ValueNotifier<String>('new');

  static Future<void> initialize() async {
    if (_box != null && _box!.isOpen) return;
    if (_opening) {
      // Web(IndexedDB) では openBox が並列に走ることがあり、
      // ここで即returnすると「box未オープンなのに settingsReady 扱い」になり得る。
      // 他サービスと同様にオープン完了まで待機する。
      for (int i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (_box != null && _box!.isOpen) return;
        if (!_opening) break;
      }
      if (_box != null && _box!.isOpen) return;
    }
    _opening = true;
    try {
      _box = await openBoxWithRetry<dynamic>(_boxName);
      // initialize theme mode
      final saved = getString(keyThemeMode);
      // Removed theme: 'bright_blue_light' (ライトブルー). Migrate to default light.
      // Avoid calling setString() here to prevent initialize() recursion.
      String? normalizedSaved = saved;
      if (saved == 'bright_blue_light') {
        normalizedSaved = 'light';
        try {
          await _box!.put(keyThemeMode, normalizedSaved);
          await _box!.flush();
        } catch (_) {
          // Best-effort migration; if it fails we still fall back via UI/theme mapping.
        }
      }
      // アプリ初回インストール時はライトミニマルを初期値とする
      final effectiveTheme = (normalizedSaved == null || normalizedSaved.isEmpty)
          ? 'black_minimal_light'
          : normalizedSaved;
      themeModeKeyNotifier.value = effectiveTheme;
      themeModeNotifier.value = _parseThemeMode(effectiveTheme);
      mobileDayUseGridNotifier.value =
          getBool(keyMobileDayUseGrid, defaultValue: true);
      final whichStr = getString(keyMobileDayGridWhich);
      mobileDayGridWhichNotifier.value = int.tryParse(whichStr ?? '') ?? 0;
      calendarShowEventsOnlyNotifier.value =
          getBool(keyCalendarShowEventsOnly, defaultValue: false);
      // week start
      final wk = getString(keyCalendarWeekStart) ?? 'sunday';
      weekStartNotifier.value = wk;
      // Project list UI
      projectShowProjectsOnlyNotifier.value =
          getBool(keyProjectShowProjectsOnly, defaultValue: false);
      // アーカイブ済みの選択肢表示
      final archivedMode = getString(keyArchivedInSelectDisplay) ?? 'hide';
      archivedInSelectDisplayNotifier.value =
          (archivedMode == 'hide' || archivedMode == 'dimmed')
              ? archivedMode
              : 'hide';
      // 現在のカレンダービュー（最後に使用した表示）。無ければデフォルト設定→さらに無ければ月
      final lastView = getString(keyLastViewType);
      if (lastView != null && lastView.isNotEmpty) {
        calendarViewTypeNotifier.value = lastView;
      } else {
        final defView = getString(keyCalendarDefaultViewType) ?? 'month';
        calendarViewTypeNotifier.value = defView;
      }
      // メインUI種別: 未設定なら GitHub版（'new'）を初期値とする。従来の useNewUI が保存されていれば移行。
      final savedUiType = getString(keyMainUiType);
      if (savedUiType == null || savedUiType.isEmpty) {
        final hasLegacyKey = _box!.containsKey(keyUseNewUI);
        final initial = hasLegacyKey
            ? (getBool(keyUseNewUI, defaultValue: true) ? 'new' : 'old') // PCはGitHub新UIを基本とする
            : 'new'; // 初回は GitHub版（新UI・左縦バー）
        mainUiTypeNotifier.value = initial;
        try {
          await _box!.put(keyMainUiType, initial);
          await _box!.flush();
        } catch (_) {}
      } else {
        mainUiTypeNotifier.value = savedUiType;
      }
      // 廃止UIタイプを 'new'（GitHub版）に正規化する
      if (mainUiTypeNotifier.value == 'new_current' ||
          mainUiTypeNotifier.value == 'new_topbar') {
        mainUiTypeNotifier.value = 'new';
        try {
          await _box!.put(keyMainUiType, 'new');
          await _box!.flush();
        } catch (_) {}
      }
      useNewUINotifier.value = mainUiTypeNotifier.value != 'old';
      // レポート時間単位
    } finally {
      _opening = false;
    }
  }

  /// For diagnostics: whether the underlying Hive box is open.
  static bool get isBoxOpen {
    try {
      return _box != null && _box!.isOpen;
    } catch (_) {
      return false;
    }
  }

  /// For diagnostics: whether initialize() is currently opening the box.
  static bool get isOpeningBox => _opening;

  static bool _looksLikeIdbClosing(Object e) {
    final msg = e.toString();
    return msg.contains('database connection is closing') ||
        msg.contains('InvalidStateError') ||
        msg.contains('Failed to execute "transaction"');
  }

  static Future<void> _recoverFromIdbClosing() async {
    try {
      await _box?.close();
    } catch (_) {}
    _box = null;
    _opening = false;
    await initialize();
  }

  static bool getBool(String key, {bool defaultValue = false}) {
    try {
      if (_box == null || !_box!.isOpen) return defaultValue;
      final val = _box!.get(key);
      if (val is bool) return val;
      return defaultValue;
    } catch (e) {
      // Web/IndexedDB: Hive で "database connection is closing" が出ることがある。
      // ここは同期APIのため復旧(reopen)はできないが、次の非同期書込/initializeで回復できるよう
      // box参照を破棄しておく。
      try {
        if (_looksLikeIdbClosing(e)) {
          _box = null;
          _opening = false;
        }
      } catch (_) {}
      return defaultValue;
    }
  }

  static Future<void> setBool(String key, bool value) async {
    await _ensureOpen();
    try {
      await _box!.put(key, value);
      await _box!.flush();
    } catch (e) {
      if (_looksLikeIdbClosing(e)) {
        await _recoverFromIdbClosing();
        await _box!.put(key, value);
        await _box!.flush();
      } else {
        rethrow;
      }
    }
    if (key == keyMobileDayUseGrid) {
      mobileDayUseGridNotifier.value = value;
    }
    if (key == keyCalendarShowEventsOnly) {
      calendarShowEventsOnlyNotifier.value = value;
    }
    if (key == keyProjectShowProjectsOnly) {
      projectShowProjectsOnlyNotifier.value = value;
    }
    if (key == keyUseNewUI) {
      useNewUINotifier.value = value;
    }
  }

  static int getInt(String key, {int defaultValue = 0}) {
    try {
      if (_box == null || !_box!.isOpen) return defaultValue;
      final val = _box!.get(key);
      if (val is int) return val;
      if (val is double) return val.toInt();
      if (val is String) return int.tryParse(val) ?? defaultValue;
      return defaultValue;
    } catch (e) {
      try {
        if (_looksLikeIdbClosing(e)) {
          _box = null;
          _opening = false;
        }
      } catch (_) {}
      return defaultValue;
    }
  }

  static Future<void> setInt(String key, int value) async {
    await _ensureOpen();
    try {
      await _box!.put(key, value);
      await _box!.flush();
    } catch (e) {
      if (_looksLikeIdbClosing(e)) {
        await _recoverFromIdbClosing();
        await _box!.put(key, value);
        await _box!.flush();
      } else {
        rethrow;
      }
    }
  }

  static String? getString(String key) {
    try {
      if (_box == null || !_box!.isOpen) return null;
      final val = _box!.get(key);
      if (val is String) return val;
      return null;
    } catch (e) {
      try {
        if (_looksLikeIdbClosing(e)) {
          _box = null;
          _opening = false;
        }
      } catch (_) {}
      return null;
    }
  }

  static Future<void> setString(String key, String value) async {
    await _ensureOpen();
    try {
      await _box!.put(key, value);
      await _box!.flush();
    } catch (e) {
      if (_looksLikeIdbClosing(e)) {
        await _recoverFromIdbClosing();
        await _box!.put(key, value);
        await _box!.flush();
      } else {
        rethrow;
      }
    }
    if (key == keyMobileDayGridWhich) {
      mobileDayGridWhichNotifier.value = int.tryParse(value) ?? 0;
    }
    if (key == keyLastViewType) {
      calendarViewTypeNotifier.value = value;
    }
    if (key == keyCalendarWeekStart) {
      weekStartNotifier.value = value;
    }
    if (key == keyMainUiType) {
      mainUiTypeNotifier.value = value;
      useNewUINotifier.value = value != 'old';
    }
    if (key == keyArchivedInSelectDisplay) {
      archivedInSelectDisplayNotifier.value =
          (value == 'hide' || value == 'dimmed') ? value : 'hide';
    }
  }

  static Future<void> setArchivedInSelectDisplay(String value) async {
    final normalized = (value == 'hide' || value == 'dimmed') ? value : 'hide';
    await setString(keyArchivedInSelectDisplay, normalized);
    archivedInSelectDisplayNotifier.value = normalized;
  }

  // Theme helpers
  static ThemeMode _parseThemeMode(String? s) {
    switch (s) {
      case 'dark':
      case 'wine':
      case 'teal':
      case 'orange':
      case 'black_minimal':
        return ThemeMode.dark;
      case 'light':
      case 'wine_light':
      case 'teal_light':
      case 'gray_light':
      case 'black_minimal_light':
      // Backward compatibility: removed theme (ライトブルー) should still behave as light mode.
      case 'bright_blue_light':
        return ThemeMode.light;
      default:
        return ThemeMode.system;
    }
  }

  static ThemeMode themeModeFromString(String? s) => _parseThemeMode(s);

  static Future<void> setThemeModeString(String value) async {
    await setString(keyThemeMode, value);
    themeModeKeyNotifier.value = value;
    themeModeNotifier.value = _parseThemeMode(value);
  }

  static Future<void> _ensureOpen() async {
    if (_box != null && _box!.isOpen) return;
    await initialize();
  }

  // Keys
  static const String keyHideRoutineBlocksWithoutInboxInMonth =
      'calendar.hideRoutineBlocksWithoutInboxInMonth';
  static const String keyLastViewType = 'calendar.lastViewType';
  static const String keyCalendarDefaultViewType = 'calendar.defaultViewType';
  static const String keyThemeMode =
      'ui.themeMode'; // 'light' | 'dark' | 'wine' | 'wine_light' | 'teal' | 'teal_light' | 'gray_light' | 'orange' | 'system'
  static const String keyUseNewUI = 'ui.useNewUI'; // 非推奨: mainUiType に移行済み
  static const String keyMainUiType = 'ui.mainUiType'; // 'old' | 'new'
  static const String keyMobileDayUseGrid = 'calendar.mobileDay.useGrid';
  static const String keyMobileDayGridWhich =
      'calendar.mobileDay.gridWhich'; // '0' | '1' | '2'
  static const String keyCalendarShowEventsOnly = 'calendar.events.showOnly';
  static const String keyCalendarEventReminderMinutes =
      'calendar.events.reminderMinutes';
  static const String keyCalendarWeekStart =
      'calendar.weekStart'; // 'sunday' | 'monday' | ...
  static const String keyCalendarInitialBreakRatio =
      'calendar.initialBreakRatio'; // 0-100 int

  // Task defaults
  // 0 means "no default / unset" (初期値は0で統一).
  static const String keyTaskDefaultEstimatedMinutes =
      'task.defaultEstimatedMinutes';

  // Project screen preferences
  static const String keyProjectTwoColumnMode = 'project.view.twoColumn';
  static const String keyProjectHideEmpty = 'project.filter.hideEmpty';
  static const String keyProjectShowProjectsOnly =
      'project.view.showProjectsOnly';
  static const String keyArchivedInSelectDisplay =
      'select.archivedDisplay'; // 'hide' | 'dimmed'
  // Diff sync cursors (ISO8601 strings)
  static const String keyCursorProjects = 'cursor.projects.lastModified';
  static const String keyCursorSubProjects = 'cursor.sub_projects.lastModified';
  static const String keyCursorModes = 'cursor.modes.lastModified';
  static const String keyCursorCategories = 'cursor.categories.lastModified';
  static const String keyCursorInbox = 'cursor.inbox_tasks.lastModified';
  static const String keyCursorActual = 'cursor.actual_tasks.lastModified';
  static const String keyCursorBlocks = 'cursor.blocks.lastModified';
  static const String keyCursorRoutineTemplatesV2 =
      'cursor.routine_templates_v2.lastModified';
  static const String keyCursorRoutineBlocksV2 =
      'cursor.routine_blocks_v2.lastModified';
  static const String keyCursorRoutineTasksV2 =
      'cursor.routine_tasks_v2.lastModified';

  /// 1 回限り: 旧ルーティン Hive 削除＋（ログイン時）V2 ローカル破棄後の Firebase 再同期用マイグレーション済みフラグ
  static const String keyMigrationRoutineLocalFirebaseResyncV1 =
      'migration.routine_local_firebase_resync_v1';

  // Report grouping preferences
  static const String keyReportDailyGrouping =
      'report.daily.grouping'; // 'time' | 'project'
  static const String keyReportWeeklyGrouping =
      'report.weekly.grouping'; // 'time' | 'project'
  static const String keyReportMonthlyGrouping =
      'report.monthly.grouping'; // 'time' | 'project'
  static const String keyReportYearlyGrouping =
      'report.yearly.grouping'; // 'time' | 'project'
  static const String keyReportRecordStartMonthPrefix =
      'report.recordStartMonth.'; // + {uid}: YYYY-MM-01
  static const String keyReportRegistrationCreatedAtPrefix =
      'report.registrationCreatedAt.'; // + {uid}: ISO8601(UTC)

  // Final State: account time zone (IANA, e.g. "Asia/Tokyo")
  static const String keyAccountTimeZoneId = 'app.accountTimeZoneId';

  // Generic cursor helpers
  static Future<void> setCursor(String key, DateTime value) async {
    await setString(key, value.toUtc().toIso8601String());
  }

  static DateTime? getCursor(String key) {
    final s = getString(key);
    if (s == null || s.isEmpty) return null;
    return DateTime.tryParse(s)?.toUtc();
  }

  static String reportRecordStartMonthKeyForUser(String userId) =>
      '$keyReportRecordStartMonthPrefix$userId';

  static String reportRegistrationCreatedAtKeyForUser(String userId) =>
      '$keyReportRegistrationCreatedAtPrefix$userId';

  static DateTime? getReportRegistrationCreatedAt(String userId) {
    if (userId.isEmpty) return null;
    final raw = getString(reportRegistrationCreatedAtKeyForUser(userId));
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    return parsed.toLocal();
  }

  static Future<void> setReportRegistrationCreatedAtIfAbsent(
    String userId,
    DateTime createdAt,
  ) async {
    if (userId.isEmpty) return;
    final key = reportRegistrationCreatedAtKeyForUser(userId);
    final existing = getString(key);
    if (existing != null && existing.isNotEmpty) return;
    await setString(key, createdAt.toUtc().toIso8601String());
  }

  static DateTime? getReportRecordStartMonth(String userId) {
    if (userId.isEmpty) return null;
    final raw = getString(reportRecordStartMonthKeyForUser(userId));
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    final local = parsed.toLocal();
    return DateTime(local.year, local.month, 1);
  }

  static Future<void> setReportRecordStartMonth(
    String userId,
    DateTime monthStart,
  ) async {
    if (userId.isEmpty) return;
    final normalized = DateTime(monthStart.year, monthStart.month, 1);
    final y = normalized.year.toString().padLeft(4, '0');
    final m = normalized.month.toString().padLeft(2, '0');
    await setString(reportRecordStartMonthKeyForUser(userId), '$y-$m-01');
  }

  /// ルーティン V2 の差分同期カーソルと Lamport を消す（ローカル box 削除に合わせて呼ぶ）
  static Future<void> clearRoutineV2ResyncState() async {
    await initialize();
    final box = _box;
    if (box == null) return;
    try {
      await box.delete(keyCursorRoutineTemplatesV2);
      await box.delete(keyCursorRoutineBlocksV2);
      await box.delete(keyCursorRoutineTasksV2);
      // [RoutineLamportClockService] のキーと一致させること
      await box.delete('routine.v2.lamport_counter');
      await box.flush();
    } catch (_) {}
  }

  /// ユーザー固有の設定をクリア（ログアウト時用）
  ///
  /// ログアウト時に以下も削除する:
  /// - 初回フル同期済みフラグ（sync.projects.* / sync.blocks.*）
  ///   再ログイン時にクラウドからプロジェクト等を再取得するため。
  /// - 差分同期カーソル（cursor.*）
  ///   別ユーザーや同一ユーザー再ログイン時にフル同期させるため。
  static Future<void> clearUserSpecificSettings() async {
    await initialize();
    final box = _box;
    if (box == null) return;
    final keysToRemove = <dynamic>[];
    for (final key in box.keys) {
      if (key is String) {
        if (key.startsWith('report_record_start_month_') ||
            key.startsWith('report_registration_created_at_') ||
            key.startsWith('sync.projects.initialFullSyncDone.') ||
            key.startsWith('sync.projects.initialFullSyncAttemptAt.') ||
            key.startsWith('sync.blocks.initialFullSyncDone.') ||
            key.startsWith('sync.blocks.initialFullSyncAttemptAt.') ||
            key.startsWith('sync.postAuthFullSyncDone.') ||
            key.startsWith('sync.postAuthFullSyncAttemptAt.') ||
            key.startsWith('cursor.')) {
          keysToRemove.add(key);
        }
      }
    }
    for (final key in keysToRemove) {
      await box.delete(key);
    }
  }
}
