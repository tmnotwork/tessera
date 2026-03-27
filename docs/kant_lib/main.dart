// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
// WidgetsFlutterBinding は material.dart にも含まれるため追加importは不要
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'app/main_screen/report_period.dart';
import 'app/main_screen/report_period_dialog.dart' as rpui;
import 'app/main_screen/report_date_picker.dart' as rpdate;
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:ui' show PlatformDispatcher;
import 'firebase_options.dart';
import 'models/work_type.dart';
import 'models/user.dart';
import 'models/project.dart';
import 'models/sub_project.dart';
import 'models/category.dart';
import 'models/time_of_day_adapter.dart';
import 'models/actual_task.dart';
import 'models/calendar_entry.dart';
import 'models/mode.dart';
import 'models/inbox_task.dart';
import 'models/block.dart';
import 'models/routine_block_v2.dart';
import 'models/routine_task_v2.dart';
import 'models/routine_template_v2.dart';
import 'models/synced_day.dart';
// duplicate import removed
import 'services/project_service.dart';
import 'services/sub_project_service.dart';
import 'services/category_service.dart';
import 'services/actual_task_service.dart';
import 'services/selection_frequency_service.dart';
import 'services/calendar_service.dart';
import 'services/mode_service.dart';
import 'services/inbox_task_service.dart';
import 'services/inbox_task_sync_service.dart';
import 'services/sync_context.dart';
import 'services/auth_service.dart';
import 'services/category_sync_service.dart';
import 'services/block_service.dart';
import 'services/routine_block_v2_service.dart';
import 'services/routine_task_v2_service.dart';
import 'services/routine_template_v2_service.dart';
import 'services/routine_template_v2_sync_service.dart';
import 'services/routine_block_v2_sync_service.dart';
import 'services/routine_task_v2_sync_service.dart';
import 'services/sync_manager.dart';
import 'services/task_sync_manager.dart';
import 'services/task_batch_sync_manager.dart';
import 'services/task_state_sync_strategy.dart';
import 'services/sync_all_history_service.dart';
import 'services/actual_task_sync_service.dart';
import 'services/device_info_service.dart';
import 'services/network_manager.dart';
import 'providers/task_provider.dart';
import 'screens/timeline_screen_v2.dart';
import 'screens/inbox_screen.dart';
import 'screens/inbox_controller_interface.dart';
import 'screens/inbox_task_add_screen.dart';
import 'screens/calendar_screen.dart';
import 'screens/project_list_screen.dart';
import 'screens/routine_screen.dart';
import 'screens/weekly_report_screen.dart';
import 'screens/daily_report_screen.dart';
import 'screens/monthly_report_screen.dart';
import 'screens/yearly_report_screen.dart';
import 'services/block_outbox_manager.dart';
import 'screens/db_hub_screen.dart';
import 'screens/project_db_screen.dart';
import 'screens/category_db_screen.dart';
import 'screens/inbox_db_screen.dart';
import 'screens/actual_db_screen.dart';
import 'screens/block_db_screen.dart';
import 'screens/routine_template_v2_db_screen.dart';
import 'screens/routine_task_v2_db_screen.dart';

import 'widgets/common_layout.dart';
import 'widgets/report_navigation.dart';
import 'screens/auth_screen.dart';
import 'screens/routine_detail_screen_v2_table.dart';
import 'screens/routine_detail_actions.dart';
import 'screens/routine_day_review_screen.dart';
import 'screens/shortcut_template_screen.dart';
import 'screens/timeline_dialogs.dart' as timeline_dialogs;
import 'screens/pomodoro_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/project_category_assignment_screen.dart';
import 'widgets/app_notifications.dart';
import 'screens/sub_project_management_screen.dart';
import 'screens/holiday_settings_screen.dart';
import 'screens/project_settings_screen.dart';

import 'widgets/calendar_settings_panel.dart';
import 'services/app_settings_service.dart';
import 'services/routine_local_firebase_resync_migration.dart';
import 'services/day_key_service.dart';
import 'app/main_screen/sync_for_screen.dart' as sync_helper;
import 'app/main_screen/timeline_actions.dart';
import 'app/main_screen/routine_reflect.dart';
import 'app/app_material.dart' as appmat;
import 'app/app_theme.dart';
import 'services/notification_service.dart';
import 'services/widget_service.dart';
import 'services/widget_debug_messenger.dart';
import 'core/feature_flags.dart';
import 'services/main_navigation_service.dart';
import 'services/report_csv_export_service.dart';
import 'utils/unified_screen_dialog.dart';
import 'utils/perf_logger.dart';
import 'widgets/inbox/inbox_csv_import_dialog.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'utils/firestore_web_persistence_stub.dart'
    if (dart.library.html) 'utils/firestore_web_persistence_web.dart'
    as firestore_persistence;
import 'app/app_boot_state.dart';
import 'ui_android/main_screen.dart';
import 'ui_v2/new_ui_screen.dart' show NewUIScreen;

// 通知クラスは widgets/report_navigation.dart へ移動

// レポート期間選択用の列挙型

/// ネイティブ Android/iOS では旧 UI（MainScreen）を強制。Web は [uiType] 設定に従う。
Widget buildMainHomeForUiType(String uiType) {
  final isNativeMobile = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  final effectiveUiType = isNativeMobile ? 'old' : uiType;
  return switch (effectiveUiType) {
    'old' => const MainScreen(),
    _ => const NewUIScreen(),
  };
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PerfLogger.resetBoot('main.start');
  PerfLogger.mark('main.ensureInitialized.done');

  // Uncaught Error を握って presentError で表示
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    // true = handled（Webでの "Uncaught Error" を減らす）
    return true;
  };

  await runZonedGuarded(
    () async {
      // 日本語ロケールの初期化
      await PerfLogger.time(
        'initializeDateFormatting',
        () => initializeDateFormatting('ja_JP', null),
      );

      // 🌐 Web: ログアウト時はログイン画面だけ即表示。Firebase/Hive はログイン押下時・ログイン成功後にのみ初期化（ログアウト時にクリア済みなので未ログイン時は何も走らせない）
      if (kIsWeb) {
        WidgetDebugMessenger.initialize();
        PerfLogger.mark('runApp.calling', {'webLoginOnly': true});
        runApp(const _WebBootWrapper());
        PerfLogger.mark('runApp.called', {'webLoginOnly': true});
        return;
      }

      // 非Web: 従来どおり Firebase → Hive → runApp
      await _runFullBootSequence();
      bool hiveInitialized = await _runHiveBootSequence();
      WidgetDebugMessenger.initialize();
      PerfLogger.mark('runApp.calling');
      runApp(
        appmat.MyApp(
          hiveInitialized: hiveInitialized,
          home: const AuthWrapper(),
        ),
      );
      PerfLogger.mark('runApp.called', {'hiveInitialized': hiveInitialized});
      _schedulePostBootCallbacks(hiveInitialized);
    },
    (error, stack) {
      PerfLogger.mark('zone.error', {'error': error.toString()});
    },
    // 全ビルドで print をコンソールへ出力（調査用）
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        parent.print(zone, line);
      },
    ),
  );
}

// アダプター登録済みフラグ
bool _adaptersRegistered = false;

/// Firebase + FeatureFlags + Firestore永続化まで（非Web/Web共通）
Future<void> _runFullBootSequence() async {
  await PerfLogger.time(
    'Firebase.initializeApp',
    () => Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ),
  );
  await PerfLogger.time(
      'FeatureFlags.initialize', () => FeatureFlags.initialize());
  await PerfLogger.time(
    'configureFirestorePersistence',
    () => _configureFirestorePersistence(),
  );
}

/// Hive 初期化のみ。戻り値は hiveInitialized。
Future<bool> _runHiveBootSequence() async {
  bool hiveInitialized = false;
  try {
    await PerfLogger.time('Hive.initFlutter', () => Hive.initFlutter());
    await PerfLogger.time(
      'initializeDefensiveWebHive',
      () => _initializeDefensiveWebHive(),
    );
    hiveInitialized = true;
  } catch (e) {
    try {
      await PerfLogger.time(
        'emergencyRecoveryInitialization',
        () => _emergencyRecoveryInitialization(),
      );
      hiveInitialized = true;
    } catch (_) {
      hiveInitialized = false;
    }
  }
  return hiveInitialized;
}

/// Web 用: バックグラウンドで Firebase + Hive を実行し結果を返す（他で未使用の場合は削除可）
Future<({bool hiveInitialized})> _runWebBootSequence() async {
  await _runFullBootSequence();
  final hiveInitialized = await _runHiveBootSequence();
  return (hiveInitialized: hiveInitialized);
}

/// ログイン・登録用: FeatureFlags を短時間で打ち切り、ブロックしない
Future<void> _runFullBootSequenceForLogin() async {
  await PerfLogger.time(
    'Firebase.initializeApp',
    () => Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ),
  );
  try {
    await PerfLogger.time(
      'FeatureFlags.initialize',
      () => FeatureFlags.initialize().timeout(
        const Duration(seconds: 2),
        onTimeout: () => null,
      ),
    );
  } on TimeoutException {
    PerfLogger.mark('FeatureFlags.initialize.timeout', {'path': 'login'});
  }
  await PerfLogger.time(
    'configureFirestorePersistence',
    () => _configureFirestorePersistence(),
  );
}

/// Web: 復元とログインボタンが同時に呼んでも 1 回だけ実行する用の共有 Future（二重初期化・競合防止）
Future<void>? _firebaseAuthReadyFuture;

/// ログイン・登録ボタン押下時にのみ実行。Firebase + Auth の最小初期化（Hive は不要）
Future<void> _ensureFirebaseAndAuthForLogin() async {
  _firebaseAuthReadyFuture ??= () async {
    await _runFullBootSequenceForLogin();
    await AuthService.initialize();
  }();
  await _firebaseAuthReadyFuture;
}

/// Web 起動時: Firebase+Auth でセッション復元を試し、復元できれば Hive まで初期化して本編へ。
/// 例外・zone 内の未捕捉エラーも捕捉し、必ず (hasUser, hiveInitialized) を返す。
Future<({bool hasUser, bool hiveInitialized})> _runWebBootForRestore() async {
  try {
    await _ensureFirebaseAndAuthForLogin();
    final uid = AuthService.getCurrentUserId();
    final hasUser = uid != null && uid.isNotEmpty;
    bool hiveInitialized = false;
    if (hasUser) {
      final completer = Completer<bool>();
      runZonedGuarded(
        () async {
          var h = false;
          try {
            // Web: Hive/IndexedDB が遅い場合に何分もスピナーにならないようタイムアウト
            const webHiveTimeout = Duration(seconds: 25);
            h = await _runHiveBootSequence().timeout(
              webHiveTimeout,
              onTimeout: () {
                PerfLogger.mark(
                  'WebBoot.Hive.timeout',
                  {'seconds': webHiveTimeout.inSeconds},
                );
                return false;
              },
            );
          } catch (e) {
            PerfLogger.mark(
              'WebBoot.Hive.error',
              {'error': e.toString()},
            );
          }
          if (!completer.isCompleted) completer.complete(h);
        },
        (error, stack) {
          if (!completer.isCompleted) completer.complete(false);
        },
      );
      hiveInitialized = await completer.future;
    }
    return (hasUser: hasUser, hiveInitialized: hiveInitialized);
  } catch (e, st) {
    return (hasUser: false, hiveInitialized: false);
  }
}

/// [forceDeferredInitOnWeb] Web でセッション復元時に Hive が失敗しても同期を開始するため、
/// deferred init（SyncManager + onDeferredInitComplete）を実行する。
void _schedulePostBootCallbacks(bool hiveInitialized,
    {bool forceDeferredInitOnWeb = false}) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    PerfLogger.mark('firstFrame');
    PerfLogger.mark('NotificationService.deferredInit.scheduled');
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 300), () async {
        try {
          await PerfLogger.time(
            'NotificationService.initialize.deferred',
            () => NotificationService().initialize(),
          );
        } catch (e) {
          // skip
        }
      }),
    );
    final runDeferred = hiveInitialized || forceDeferredInitOnWeb;
    if (runDeferred) {
      const delay = Duration(milliseconds: 200);
      PerfLogger.mark(
        'deferredInit.scheduled',
        {
          'delayMs': delay.inMilliseconds,
          'hiveInitialized': hiveInitialized,
          'forceDeferredInitOnWeb': forceDeferredInitOnWeb,
        },
      );
      unawaited(Future<void>.delayed(delay, _initializeDeferredServices));
    } else {
      PerfLogger.mark(
        'deferredInit.skipped',
        {'reason': 'hiveInitialized=false'},
      );
    }
  });
}

Future<void> _configureFirestorePersistence() async {
  try {
    final firestore = FirebaseFirestore.instance;
    PerfLogger.mark('FirestorePersistence.start', {'kIsWeb': kIsWeb});
    if (kIsWeb) {
      PerfLogger.mark('FirestorePersistence.web.enable.start');
      await firestore_persistence.enableFirestoreWebPersistence(
        firestore,
        const PersistenceSettings(synchronizeTabs: true),
      );
      PerfLogger.mark('FirestorePersistence.web.enable.done');
    } else {
      final currentSettings = firestore.settings;
      firestore.settings = currentSettings.copyWith(persistenceEnabled: true);
      PerfLogger.mark('FirestorePersistence.native.enable');
    }
  } on FirebaseException catch (e) {
    if (kIsWeb &&
        (e.code == 'failed-precondition' || e.code == 'unimplemented')) {
      PerfLogger.mark(
        'FirestorePersistence.web.unavailable',
        {'code': e.code},
      );
    } else {
      PerfLogger.mark(
        'FirestorePersistence.error',
        {'code': e.code, 'message': e.message},
      );
      rethrow;
    }
  } finally {
    AuthService.markFirestorePersistenceReady();
    PerfLogger.mark('FirestorePersistence.ready');
  }
}

Future<void> _initializeDefensiveWebHive() async {
  PerfLogger.mark('initializeDefensiveWebHive.start');
  // アダプター登録（安全な二重登録防止）
  await PerfLogger.time('Hive.registerAdapters', () async {
    if (!_adaptersRegistered) {
      try {
        // 基本型アダプターから登録（try-catchで個別に処理）
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(TimeOfDayAdapter()),
          'TimeOfDayAdapter',
        );

        // Enumアダプターの安全な登録
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(ActualTaskStatusAdapter()),
          'ActualTaskStatusAdapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(TaskCreationMethodAdapter()),
          'TaskCreationMethodAdapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(WorkTypeAdapter()),
          'WorkTypeAdapter',
        );

        // メインモデルアダプターの安全な登録
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(UserAdapter()),
          'UserAdapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(ProjectAdapter()),
          'ProjectAdapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(ActualTaskAdapter()),
          'ActualTaskAdapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(SubProjectAdapter()),
          'SubProjectAdapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(RoutineBlockV2Adapter()),
          'RoutineBlockV2Adapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(RoutineTaskV2Adapter()),
          'RoutineTaskV2Adapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(RoutineTemplateV2Adapter()),
          'RoutineTemplateV2Adapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(SyncedDayKindAdapter()),
          'SyncedDayKindAdapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(SyncedDayStatusAdapter()),
          'SyncedDayStatusAdapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(SyncedDayAdapter()),
          'SyncedDayAdapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(CalendarEntryAdapter()),
          'CalendarEntryAdapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(CategoryAdapter()),
          'CategoryAdapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(ModeAdapter()),
          'ModeAdapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(InboxTaskAdapter()),
          'InboxTaskAdapter',
        );
        await _safeRegisterAdapter(
          () => Hive.registerAdapter(BlockAdapter()),
          'BlockAdapter',
        );

        _adaptersRegistered = true;
      } catch (e) {
        _adaptersRegistered = true; // Mark as registered to avoid retry loops
      }
    }
  });

  // クリティカルサービスのみ先に初期化（初回描画を優先）
  await PerfLogger.time('Hive.initializeCriticalServices', () async {
    try {
      int successCount = 0;
      Future<bool> initSequential(
          String name, Future<void> Function() fn) async {
        final ok = await _initializeServiceDefensive(name, fn);
        await Future.delayed(const Duration(milliseconds: 60));
        return ok;
      }

      const int totalServices = 2;

      if (await initSequential('AuthService', () => AuthService.initialize())) {
        successCount++;
      }
      if (await initSequential(
        'AppSettingsService',
        () => AppSettingsService.initialize(),
      )) {
        successCount++;
        try {
          await RoutineLocalFirebaseResyncMigration.migrateIfNeeded();
        } catch (_) {}
      }
    } catch (e) {
      // continue
    }
  });

  PerfLogger.mark('initializeDefensiveWebHive.done');
}

Future<void> _initializeDeferredServices() async {
  PerfLogger.mark('deferredInit.start');
  // Phase 1: タイムラインのギャップ実績行で名前解決に使う 3 サービスを最優先で初期化（1秒以内に ready にする）
  await PerfLogger.time('Deferred.initializeDisplayServices', () async {
    try {
      Future<bool> initDefensive(
          String name, Future<void> Function() fn) async {
        final ok = await _initializeServiceDefensive(name, fn);
        await Future.delayed(const Duration(milliseconds: 30));
        return ok;
      }

      await initDefensive('ProjectService', () => ProjectService.initialize());
      await initDefensive(
          'SubProjectService', () => SubProjectService.initialize());
      await initDefensive('ModeService', () => ModeService.initialize());
      displayServicesReady.value = true;
    } catch (e) {
      displayServicesReady.value = true; // 失敗しても true にして行を出しに行く
    }
  });

  // サービス初期化（残り）
  await PerfLogger.time('Deferred.initializeServices', () async {
    try {
      int successCount = 0;
      Future<bool> initSequential(
          String name, Future<void> Function() fn) async {
        final ok = await _initializeServiceDefensive(name, fn);
        await Future.delayed(const Duration(milliseconds: 60));
        return ok;
      }

      const int totalServices = 9; // Phase 1 で Project/SubProject/Mode 済み + SelectionFrequency

      if (await initSequential(
        'RoutineBlockV2Service',
        () => RoutineBlockV2Service.initialize(),
      )) {
        successCount++;
      }
      if (await initSequential(
        'RoutineTaskV2Service',
        () => RoutineTaskV2Service.initialize(),
      )) {
        successCount++;
      }
      if (await initSequential(
        'RoutineTemplateV2Service',
        () => RoutineTemplateV2Service.initialize(),
      )) {
        successCount++;
      }
      // Project/SubProject/Mode は Phase 1 で済み
      if (await initSequential(
          'BlockService', () => BlockService.initialize())) {
        successCount++;
      }
      if (await initSequential(
        'ActualTaskService',
        () => ActualTaskService.initialize(),
      )) {
        successCount++;
      }
      if (await initSequential(
        'SelectionFrequencyService',
        () => SelectionFrequencyService.initialize(),
      )) {
        successCount++;
      }
      if (await initSequential(
        'CalendarService',
        () => CalendarService.initialize(),
      )) {
        successCount++;
      }
      if (await initSequential(
        'CategoryService',
        () => CategoryService.initialize(),
      )) {
        successCount++;
      }
      if (await initSequential(
        'InboxTaskService',
        () => InboxTaskService.initialize(),
      )) {
        successCount++;
      }
    } catch (e) {
      // continue
    }
  });

  try {
    await PerfLogger.time(
      'Deferred.WidgetService.initialize',
      () => WidgetService.initialize(),
    );
  } catch (e) {
    // non-critical
  }

  // 同期サービスの防御的初期化（初回描画後に実行）
  await PerfLogger.time('Deferred.initializeSyncServices', () async {
    try {
      await _safeInitializeService(
        'DeviceInfoService',
        () => DeviceInfoService.initialize(),
      );
      await _safeInitializeService(
        'NetworkManager',
        () => NetworkManager.initialize(),
      );
      await _safeInitializeService(
        'DayKeyService',
        () => DayKeyService.initialize(),
      );
      await _safeInitializeService(
          'SyncManager', () => SyncManager.initialize());
      await _safeInitializeService(
        'TaskSyncManager',
        () => TaskSyncManager.initialize(),
      );
      await _safeInitializeService(
        'TaskBatchSyncManager',
        () => TaskBatchSyncManager.initialize(),
      );
      await _safeInitializeService(
        'BlockOutboxManager',
        () => BlockOutboxManager.initialize(),
      );
      await _safeInitializeService(
        'TaskStateSyncStrategy',
        () => TaskStateSyncStrategy.initialize(),
      );
      // Disable DataTypeSyncScheduler (no auto periodic sync); per-screen sync will be triggered on screen show/switch
      // await _safeInitializeService('DataTypeSyncScheduler', () => DataTypeSyncScheduler.initialize()      );
    } catch (e) {
      // 同期サービスのエラーは非致命的なので続行
    }
  });
  // Web: セッション復元時に emitUser で保留した postAuth（プロジェクトDL等）を ProjectService 準備後に実行
  AuthService.onDeferredInitComplete();
  PerfLogger.mark('deferredInit.done');
}

// アダプター登録を安全に実行するヘルパー
Future<void> _safeRegisterAdapter(
  void Function() registerFunction,
  String adapterName,
) async {
  try {
    registerFunction();
  } catch (e) {
    // 個別のアダプター登録失敗は致命的ではない
  }
}

// Web: マルチタブ時に IndexedDB が遅い場合があるためタイムアウトを延長。ネイティブは 3 秒のまま。
const _serviceInitTimeoutNative = Duration(seconds: 3);
const _serviceInitTimeoutWeb = Duration(seconds: 10);

// サービス初期化を安全に実行するヘルパー
Future<bool> _initializeServiceDefensive(
  String serviceName,
  Future<void> Function() initFunction,
) async {
  final startMs = PerfLogger.elapsedMs;
  final timeout = kIsWeb ? _serviceInitTimeoutWeb : _serviceInitTimeoutNative;
  PerfLogger.mark('service.init.start', {'service': serviceName});
  try {
    await initFunction().timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
        'Service initialization timeout',
        timeout,
      ),
    );
    final durMs = PerfLogger.elapsedMs - startMs;
    PerfLogger.mark(
      'service.init.ok',
      {'service': serviceName, 'durMs': durMs},
    );
    return true;
  } catch (e) {
    final durMs = PerfLogger.elapsedMs - startMs;
    PerfLogger.mark(
      'service.init.fail',
      {'service': serviceName, 'durMs': durMs, 'error': e.toString()},
    );

    // IndexedDBやHive関連のエラーは特別に処理
    if (e.toString().contains('minified:') ||
        e.toString().contains('IndexedDB') ||
        e.toString().contains('Instance of') ||
        e.toString().contains('deleteFromDisk') ||
        e.toString().contains('not initialized') ||
        e.toString().contains('HiveError') ||
        e.toString().contains('box') && e.toString().contains('from disk')) {
      // For critical services, try alternative initialization
      if (serviceName.contains('Auth') || serviceName.contains('Template')) {
        try {
          await Future.delayed(const Duration(milliseconds: 500));
          await initFunction().timeout(const Duration(seconds: 120));
          return true;
        } catch (retryError) {
          // fallback also failed
        }
      }
    }

    return false;
  }
}

// より安全なサービス初期化ヘルパー（同期系は完了まで待つためタイムアウトは長め）
const _syncServiceInitTimeout = Duration(seconds: 120);

Future<void> _safeInitializeService(
  String serviceName,
  Future<void> Function() initFunction,
) async {
  final startMs = PerfLogger.elapsedMs;
  PerfLogger.mark('syncService.init.start', {'service': serviceName});
  try {
    await initFunction().timeout(_syncServiceInitTimeout);
    final durMs = PerfLogger.elapsedMs - startMs;
    PerfLogger.mark(
      'syncService.init.ok',
      {'service': serviceName, 'durMs': durMs},
    );
  } catch (e) {
    final durMs = PerfLogger.elapsedMs - startMs;
    PerfLogger.mark(
      'syncService.init.fail',
      {'service': serviceName, 'durMs': durMs, 'error': e.toString()},
    );
  }
}

// 非ブロッキング同期実行（カレンダーデータは除外）

Future<void> _emergencyRecoveryInitialization() async {
  PerfLogger.mark('emergencyRecovery.start');

  // Step 1: 最低限のアダプター登録のみ（try-catchで全て保護）
  try {
    if (!_adaptersRegistered) {
      try {
        if (!Hive.isAdapterRegistered(10)) {
          Hive.registerAdapter(TimeOfDayAdapter());
        }
      } catch (e) {
        // continue
      }

      try {
        if (!Hive.isAdapterRegistered(5)) {
          Hive.registerAdapter(UserAdapter());
        }
      } catch (e) {
        // continue
      }

      _adaptersRegistered = true;
    }
  } catch (e) {
    _adaptersRegistered = true; // ループを避けるため
  }
  PerfLogger.mark(
    'emergencyRecovery.adapters.done',
    {'adaptersRegistered': _adaptersRegistered},
  );

  // Step 2: 認証サービスのみ試行（他は完全スキップ）
  try {
    await PerfLogger.time(
      'AuthService.initialize.emergency',
      () => AuthService.initialize().timeout(const Duration(seconds: 3)),
    );
  } catch (e) {
    // 認証サービスが失敗してもアプリは起動する
  }

  // Step 3: 基本サービスのみ（Hive依存なし）
  final basicServices = [
    ('DeviceInfoService', () => DeviceInfoService.initialize()),
    ('NetworkManager', () => NetworkManager.initialize()),
  ];

  for (final service in basicServices) {
    try {
      await PerfLogger.time(
        'emergencyRecovery.basicService.${service.$1}',
        () => service.$2().timeout(const Duration(seconds: 2)),
      );
    } catch (e) {
      // 各サービスが失敗しても続行
    }
  }

  PerfLogger.mark('emergencyRecovery.done');
}

// Firebase同期の初期化

// moved to app/app_material.dart

/// Web 用: 起動時に Firebase+Auth でセッション復元を試す。復元できれば本編へ、できなければログイン画面。ログイン成功時も本編へ切り替え。
class _WebBootWrapper extends StatefulWidget {
  const _WebBootWrapper();

  @override
  State<_WebBootWrapper> createState() => _WebBootWrapperState();
}

class _WebBootWrapperState extends State<_WebBootWrapper> {
  static bool _postBootScheduled = false;
  bool _bootComplete = false;
  bool _hiveInitialized = false;

  /// localStorage に「ログインしていた痕跡」がある場合のみ true。このときだけ復元を待ちローディング表示。
  late final bool _mightHaveSession;

  /// 復元が完了した場合に true（_mightHaveSession が true のときのみ意味がある）。
  bool _restoreComplete = false;

  @override
  void initState() {
    super.initState();
    // 同期的に localStorage を読んで初回表示を決定（Firebase 不要）
    AuthService.prepareWebBootAuthHint();
    _mightHaveSession = AuthService.mightHaveStoredSessionForBoot();
    if (_mightHaveSession) {
      // ログイン済みの可能性あり → 復元を待ち、完了までローディング。ログイン画面は出さない。
      _runWebBootForRestore().then((result) {
        if (!mounted) return;
        setState(() {
          _restoreComplete = true;
          if (result.hasUser) {
            _hiveInitialized = result.hiveInitialized;
            _bootComplete = true;
          }
        });
        if (result.hasUser && !_postBootScheduled) {
          _postBootScheduled = true;
          // Web: Hive 失敗時でも deferred init を実行し SyncManager + onDeferredInitComplete で同期を開始する
          _schedulePostBootCallbacks(
            result.hiveInitialized,
            forceDeferredInitOnWeb: kIsWeb,
          );
        }
      }).catchError((e) {
        if (mounted) setState(() => _restoreComplete = true);
      });
    }
    // _mightHaveSession が false のときは復元しない。build で即ログイン画面を表示。
  }

  Future<void> _ensureAuthReady() async {
    await _ensureFirebaseAndAuthForLogin();
  }

  Future<void> _onLoginSuccess() async {
    final hiveInitialized = await _runHiveBootSequence();
    if (!mounted) return;
    setState(() {
      _hiveInitialized = hiveInitialized;
      _bootComplete = true;
    });
    if (!_postBootScheduled) {
      _postBootScheduled = true;
      _schedulePostBootCallbacks(
        hiveInitialized,
        forceDeferredInitOnWeb: kIsWeb,
      );
    }
    // ログイン直後のブロックを避けるため、レポート用 recordStartMonth は Hive 準備後に非同期で設定
    unawaited(AuthService.ensureReportRecordStartMonthWhenReady());
  }

  @override
  Widget build(BuildContext context) {
    if (_bootComplete) {
      return appmat.MyApp(
        hiveInitialized: _hiveInitialized,
        home: const AuthWrapper(),
      );
    }
    // localStorage にセッション痕跡あり → 復元完了までローディング（ログイン画面は出さない）
    if (_mightHaveSession && !_restoreComplete) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.light,
        home: Scaffold(
          body: Center(
            child: CircularProgressIndicator(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      );
    }
    // 未ログイン（痕跡なし）または復元完了で hasUser でない → 即ログイン画面
    return _buildLoginMaterialApp();
  }

  Widget _buildLoginMaterialApp() {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en', 'US'), Locale('ja', 'JP')],
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.light,
      home: AuthScreen(
        ensureAuthReady: _ensureAuthReady,
        onLoginSuccess: _onLoginSuccess,
      ),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});
  static String? _lastAuthViewKey;

  @override
  Widget build(BuildContext context) {
    if (!_shouldUseMultiTabFlow()) {
      return _buildLegacyAuthView(context);
    }
    return ValueListenableBuilder<AuthSessionPhase>(
      valueListenable: AuthService.sessionPhase,
      builder: (_, phase, __) {
        return StreamBuilder<User?>(
          stream: AuthService.authStateChanges,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _buildAuthErrorView(context, snapshot.error);
            }
            final loggedIn = snapshot.data != null || AuthService.isLoggedIn();
            final uidReady = (AuthService.getCurrentUserId() ?? '').isNotEmpty;
            // プロジェクト取得に必要な uid が確定してから Main を表示（ログイン直後の取得失敗を防ぐ）
            // rehydrating 中はオーバーレイで待つので uid 未確定でも Main を表示する
            final showMain =
                (loggedIn || phase == AuthSessionPhase.rehydrating) &&
                    (uidReady || phase == AuthSessionPhase.rehydrating);
            final viewKey =
                'multiTab:${phase.name}|loggedIn=$loggedIn|uidReady=$uidReady|showMain=$showMain';
            if (viewKey != _lastAuthViewKey) {
              _lastAuthViewKey = viewKey;
              PerfLogger.mark('AuthWrapper.view', {
                'flow': 'multiTab',
                'phase': phase.name,
                'loggedIn': loggedIn,
                'hasUser': snapshot.data != null,
                'showMain': showMain,
              });
            }
            if (phase == AuthSessionPhase.signedOut) {
              return const AuthScreen();
            }
            if (!showMain) {
              return const AuthScreen();
            }
            return ValueListenableBuilder<String>(
              valueListenable: AppSettingsService.mainUiTypeNotifier,
              builder: (_, uiType, __) {
                final home = buildMainHomeForUiType(uiType);
                return Stack(
                  children: [
                    home,
                    if (phase == AuthSessionPhase.rehydrating)
                      const _FullScreenSessionLoader(),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  bool _shouldUseMultiTabFlow() => FeatureFlags.webMultiTabAuthHold && kIsWeb;

  Widget _buildLegacyAuthView(BuildContext context) {
    return StreamBuilder<User?>(
      stream: AuthService.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _buildAuthErrorView(context, snapshot.error);
        }
        final loggedIn = AuthService.isLoggedIn();
        final hasUser = snapshot.data != null;
        final uidReady = (AuthService.getCurrentUserId() ?? '').isNotEmpty;
        final showMain = (hasUser || loggedIn) && uidReady;
        final viewKey =
            'legacy:loggedIn=$loggedIn|hasUser=$hasUser|uidReady=$uidReady|showMain=$showMain';
        if (viewKey != _lastAuthViewKey) {
          _lastAuthViewKey = viewKey;
          PerfLogger.mark('AuthWrapper.view', {
            'flow': 'legacy',
            'loggedIn': loggedIn,
            'hasUser': hasUser,
            'showMain': showMain,
          });
        }
        if (showMain) {
          return ValueListenableBuilder<String>(
            valueListenable: AppSettingsService.mainUiTypeNotifier,
            builder: (_, uiType, __) => buildMainHomeForUiType(uiType),
          );
        }
        return const AuthScreen();
      },
    );
  }

  Widget _buildAuthErrorView(BuildContext context, Object? error) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error,
              size: 64,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text('エラーが発生しました: $error'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pushReplacementNamed('/');
              },
              child: const Text('再試行'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullScreenSessionLoader extends StatelessWidget {
  const _FullScreenSessionLoader();

  @override
  Widget build(BuildContext context) {
    return const _DelayedFullScreenSessionLoader();
  }
}

class _DelayedFullScreenSessionLoader extends StatefulWidget {
  const _DelayedFullScreenSessionLoader();

  @override
  State<_DelayedFullScreenSessionLoader> createState() =>
      _DelayedFullScreenSessionLoaderState();
}

class _DelayedFullScreenSessionLoaderState
    extends State<_DelayedFullScreenSessionLoader> {
  // 新しいタブを開いた際、FirebaseAuth がIndexedDBからセッションを復元するまで
  // 500ms〜1秒程度かかることがある。その間に rehydrating 表示が出ないよう、
  // 遅延を長めに設定する（偽ログアウト/復元チラつき対策）。
  static const Duration _delay = Duration(milliseconds: 1200);
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_delay, () {
      if (!mounted) return;
      setState(() {
        _visible = true;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) {
      // すぐ復元できるケースでは「復元中」表示をチラつかせない。
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: Container(
        color: Theme.of(context).colorScheme.surface.withOpacity(0.65),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('セッションを復元しています'),
          ],
        ),
      ),
    );
  }
}


// ホームウィジェット用のヘッドレスエントリポイント
// BroadcastReceiver から起動され、UIを立ち上げずに同期とスナップショット更新のみ実行する
@pragma('vm:entry-point')
Future<void> widgetMain() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
  } catch (_) {}
  // Hive初期化とアダプタ登録（ヘッドレス実行時にも必要）
  try {
    // web以外の想定だが、既存の安全登録ルーチンを流用
    // Hive本体初期化
    try {
      await Hive.initFlutter();
    } catch (_) {}
    // 主要アダプタの登録（不足があっても個別に握る）
    try {
      if (!Hive.isAdapterRegistered(20))
        Hive.registerAdapter(InboxTaskAdapter());
    } catch (_) {}
    try {
      if (!Hive.isAdapterRegistered(11))
        Hive.registerAdapter(ActualTaskAdapter());
    } catch (_) {}
  } catch (_) {}
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
    } catch (_) {}
  }
  await FeatureFlags.initialize();
  AuthService.markFirestorePersistenceReady();
  try {
    // ウィジェットでHiveを使うサービスを確実に初期化
    try {
      await InboxTaskService.initialize();
    } catch (_) {}
    try {
      await AuthService.initialize();
    } catch (_) {}
    try {
      await AppSettingsService.initialize();
      await RoutineLocalFirebaseResyncMigration.migrateIfNeeded();
    } catch (_) {}
    await WidgetService.initialize();
  } catch (_) {}
}
