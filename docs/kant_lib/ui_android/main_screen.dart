// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import '../app/main_screen/report_period.dart';
import '../app/main_screen/report_period_dialog.dart' as rpui;
import '../app/main_screen/report_date_picker.dart' as rpdate;
import 'dart:async';
import '../firebase_options.dart';
import '../models/work_type.dart';
import '../models/user.dart';
import '../models/project.dart';
import '../models/sub_project.dart';
import '../models/category.dart';
import '../models/time_of_day_adapter.dart';
import '../models/actual_task.dart';
import '../models/calendar_entry.dart';
import '../models/mode.dart';
import '../models/inbox_task.dart';
import '../models/block.dart';
import '../models/routine_block_v2.dart';
import '../models/routine_task_v2.dart';
import '../models/routine_template_v2.dart';
import '../models/synced_day.dart';
import '../services/project_service.dart';
import '../services/sub_project_service.dart';
import '../services/category_service.dart';
import '../services/actual_task_service.dart';
import '../services/selection_frequency_service.dart';
import '../services/calendar_service.dart';
import '../services/mode_service.dart';
import '../services/inbox_task_service.dart';
import '../services/inbox_task_sync_service.dart';
import '../services/sync_context.dart';
import '../services/auth_service.dart';
import '../services/category_sync_service.dart';
import '../services/block_service.dart';
import '../services/routine_block_v2_service.dart';
import '../services/routine_task_v2_service.dart';
import '../services/routine_template_v2_service.dart';
import '../services/routine_template_v2_sync_service.dart';
import '../services/routine_block_v2_sync_service.dart';
import '../services/routine_task_v2_sync_service.dart';
import '../services/sync_manager.dart';
import '../services/task_sync_manager.dart';
import '../services/task_batch_sync_manager.dart';
import '../services/task_state_sync_strategy.dart';
import '../services/sync_all_history_service.dart';
import '../services/actual_task_sync_service.dart';
import '../services/device_info_service.dart';
import '../services/network_manager.dart';
import '../providers/task_provider.dart';
import '../screens/timeline_screen_v2.dart';
import '../screens/inbox_screen.dart';
import '../screens/inbox_controller_interface.dart';
import '../screens/inbox_task_add_screen.dart';
import '../screens/calendar_screen.dart';
import '../screens/project_list_screen.dart';
import '../screens/routine_screen.dart';
import '../screens/weekly_report_screen.dart';
import '../screens/daily_report_screen.dart';
import '../screens/monthly_report_screen.dart';
import '../screens/yearly_report_screen.dart';
import '../services/block_outbox_manager.dart';
import '../screens/db_hub_screen.dart';
import '../screens/project_db_screen.dart';
import '../screens/category_db_screen.dart';
import '../screens/inbox_db_screen.dart';
import '../screens/actual_db_screen.dart';
import '../screens/block_db_screen.dart';
import '../screens/routine_template_v2_db_screen.dart';
import '../screens/routine_task_v2_db_screen.dart';
import '../widgets/common_layout.dart';
import '../widgets/report_navigation.dart';
import '../screens/auth_screen.dart';
import '../screens/routine_detail_screen_v2_table.dart';
import '../screens/routine_detail_actions.dart';
import '../screens/routine_day_review_screen.dart';
import '../screens/shortcut_template_screen.dart';
import '../screens/timeline_dialogs.dart' as timeline_dialogs;
import '../screens/pomodoro_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/project_category_assignment_screen.dart';
import '../widgets/app_notifications.dart';
import '../screens/sub_project_management_screen.dart';
import '../screens/holiday_settings_screen.dart';
import '../screens/project_settings_screen.dart';
import '../widgets/calendar_settings_panel.dart';
import '../services/app_settings_service.dart';
import '../services/routine_local_firebase_resync_migration.dart';
import '../services/day_key_service.dart';
import '../app/main_screen/sync_for_screen.dart' as sync_helper;
import '../app/main_screen/timeline_actions.dart';
import '../app/main_screen/routine_reflect.dart';
import '../app/app_material.dart' as appmat;
import '../app/app_theme.dart';
import '../services/notification_service.dart';
import '../services/widget_service.dart';
import '../services/widget_debug_messenger.dart';
import '../core/feature_flags.dart';
import '../services/main_navigation_service.dart';
import '../services/report_csv_export_service.dart';
import '../utils/unified_screen_dialog.dart';
import '../utils/perf_logger.dart';
import '../widgets/inbox/inbox_csv_import_dialog.dart';
import '../app/app_boot_state.dart';

class MainScreen extends StatefulWidget {
  final int? initialIndex;

  const MainScreen({super.key, this.initialIndex});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  static const int _timelineTabIndex = 0;
  static const int _inboxTabIndex = 1;
  static const int _calendarTabIndex = 2;
  static const int _dbTabIndex = 6;
  static const int _settingsTabIndex = 7;
  // タイムラインのFAB（複数並び）用の見た目を揃える
  static const double _timelineFabSpacing = 12;

  late int _selectedIndex;
  DateTime _timelineSelectedDate = DateTime.now();
  late final TimelineScreenV2Controller _timelineController;
  bool _isAddingBlock = false;
  bool _isStartingBlankActual = false;
  // FABアニメ制御:
  // - 許可: 再生バーの表示/非表示でFABが上下する瞬間だけ
  // - 禁止: 初期描画/同期/計測/タブ切替/設定パネル切替など
  bool _fabAnimReady = false; // 初回フレーム描画後にtrue
  bool? _lastFabRunningVisible; // 直前フレームの「再生バー可視」
  int? _lastFabSelectedIndex; // 直前フレームのタブ
  // レポート表示状態
  ReportPeriod _reportPeriod = ReportPeriod.daily;
  DateTime? _reportBaseDate = DateTime.now();
  DateTime? _reportRangeStart;
  DateTime? _reportRangeEnd;
  int? _reportRecordStartYearCache;
  String? _reportRecordStartYearUid;
  /// 再生バー実測高さ（FABオフセット用）。タブごとに保持し、他タブの値が混ざらないようにする。
  double _timelineTabRunningBarHeight = 0;
  double _inboxTabRunningBarHeight = 0;
  bool _isForceSyncing = false;
  bool _isExportingReportCsv = false;
  bool _showCalendarSettingsPanel = false; // カレンダー設定パネル表示切替
  bool _showSettingsPanel = false; // タイムライン設定の中央表示切替
  String? _settingsSubView; // null=設定, 'project_management'=プロジェクト管理
  RoutineTemplateV2? _selectedRoutine;
  Project? _selectedProject;
  bool _projectDetailShowArchived = false;
  final GlobalKey<SubProjectManagementScreenState> _subProjectScreenKey =
      GlobalKey<SubProjectManagementScreenState>();
  String _calendarMobileTitle = 'カレンダー';
  // カレンダーでユーザーが「見ている月」を保持（休日設定へ引き継ぐ用）
  DateTime _calendarFocusedMonthForHolidaySettings = DateTime.now();
  bool get _isSelectedRoutineShortcut =>
      _selectedRoutine != null &&
      (_selectedRoutine!.id == 'shortcut' || _selectedRoutine!.isShortcut);
  // DBタブ内のサブビュー（ハブ or 個別）
  DbSubView _dbSubView = DbSubView.hub;
  // プロジェクト画面用の表示状態（共通AppBarから制御）
  final ValueNotifier<bool> _projectTwoColumnMode = ValueNotifier(false);
  final ValueNotifier<bool> _projectHideEmpty = ValueNotifier(true);
  final ValueNotifier<bool> _projectFilterVisible = ValueNotifier(false);
  late final VoidCallback _persistProjectTwoColumnListener;
  late final VoidCallback _persistProjectHideEmptyListener;
  final InboxScreenController _inboxController = InboxScreenController();
  late List<Map<String, dynamic>> _screens;
  // バックグラウンド同期のデバウンス用
  Timer? _bgSyncDebounce;
  // build() での addPostFrameCallback 連打を防ぐ（read爆発の主因になり得る）
  bool _initialBgSyncScheduled = false;
  bool _startupSyncTrackingActive = true;
  bool _startupSyncNeedsRetry = true;
  bool _startupSyncInFlight = false;
  bool _startupSyncQueued = false;
  int _startupSyncAttempt = 0;
  StreamSubscription<User?>? _authStateSub;
  StreamSubscription<bool>? _networkSub;
  // ライフサイクル監視用
  late final AppLifecycleListener _lifecycleListener;
  // スマホ下部バー（ルーティン/DB除外）の選択状態を保持
  int _mobileBottomNavIndex = 0;
  bool _inboxShowAssigned = false;

  @override
  void initState() {
    super.initState();
    _timelineController = TimelineScreenV2Controller()
      ..addListener(_onTimelineControllerChanged);
    // 初期インデックスが指定されている場合はそれを使用、そうでなければ0（タイムライン）
    _selectedIndex = widget.initialIndex ?? 0;

    // プロジェクト画面トグルの復元（Hive: AppSettingsService）
    _projectTwoColumnMode.value = AppSettingsService.getBool(
      AppSettingsService.keyProjectTwoColumnMode,
      defaultValue: true,
    );
    _projectHideEmpty.value = AppSettingsService.getBool(
      AppSettingsService.keyProjectHideEmpty,
      defaultValue: true,
    );
    // 変更時に永続化（AppBarのアイコン操作も含めて保存される）
    _persistProjectTwoColumnListener = () {
      try {
        unawaited(
          AppSettingsService.setBool(
            AppSettingsService.keyProjectTwoColumnMode,
            _projectTwoColumnMode.value,
          ).catchError((_) {}),
        );
      } catch (_) {}
    };
    _persistProjectHideEmptyListener = () {
      try {
        unawaited(
          AppSettingsService.setBool(
            AppSettingsService.keyProjectHideEmpty,
            _projectHideEmpty.value,
          ).catchError((_) {}),
        );
      } catch (_) {}
    };
    _projectTwoColumnMode.addListener(_persistProjectTwoColumnListener);
    _projectHideEmpty.addListener(_persistProjectHideEmptyListener);

    // Drawer 等からの「メインタブへ移動」要求を受け取る
    MainNavigationService.request.addListener(_handleMainNavigationRequest);

    // アプリ全体のライフサイクルを監視（タイムライン・インボックス画面のみ監視制御）
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (AppLifecycleState state) {
        // タイムライン/インボックス系の画面のみ監視対象
        final needsMonitoring = _requiresTaskMonitoring(_selectedIndex);

        if (state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive ||
            state == AppLifecycleState.detached) {
          // バックグラウンド移行時：監視対象画面なら停止（通信量・バッテリー節約）
          if (needsMonitoring) {
            try {
              final taskProvider = Provider.of<TaskProvider>(
                context,
                listen: false,
              );
              taskProvider.stopWatchingRunningTasks();
            } catch (_) {}
          }
        } else if (state == AppLifecycleState.resumed) {
          // フォアグラウンド復帰時：監視対象画面なら再開
          if (needsMonitoring) {
            try {
              final taskProvider = Provider.of<TaskProvider>(
                context,
                listen: false,
              );
              final now = DateTime.now();
              taskProvider.startWatchingRunningTasks(
                fromInclusive: now.subtract(const Duration(hours: 12)),
                toExclusive: now.add(const Duration(hours: 12)),
              );
            } catch (_) {}
          }
          if (_startupSyncTrackingActive && _startupSyncNeedsRetry) {
            _requestBackgroundSync();
          }
        }
      },
    );
    _authStateSub = AuthService.authStateChanges.listen((user) {
      // 認証状態変化後に登録月が更新される可能性があるため、
      // レポート年下限キャッシュは都度破棄する。
      _invalidateReportRecordStartYearCache();
      if (!mounted || !_startupSyncTrackingActive || !_startupSyncNeedsRetry) {
        return;
      }
      if (user != null || AuthService.isLoggedIn()) {
        _requestBackgroundSync();
      }
    });
    _networkSub = NetworkManager.connectivityStream.listen((isOnline) {
      if (!mounted || !_startupSyncTrackingActive || !_startupSyncNeedsRetry) {
        return;
      }
      if (isOnline) {
        _requestBackgroundSync();
      }
    });

    // ギャップ実績行を「データが揃ってから」表示するため。表示用 3 サービス ready で 1 回だけ refresh
    displayServicesReady.addListener(_onDisplayServicesReady);
    if (displayServicesReady.value) {
      _onDisplayServicesReady();
    }

    // 画面定義（thisを参照するためinitStateで初期化）
    _screens = [
      {
        'widget': Builder(
          builder: (context) {
            return TimelineScreenV2(
              controller: _timelineController,
              onSelectedDateChanged: (d) =>
                  setState(() => _timelineSelectedDate = d),
              onRunningBarHeightChanged: (height) {
                if ((_timelineTabRunningBarHeight - height).abs() < 0.5) {
                  return;
                }
                setState(() => _timelineTabRunningBarHeight = height);
              },
            );
          },
        ),
        'title': 'タイムライン',
        'showDrawer': false,
        'floatingActionButton': true,
      },
      {
        'widget': InboxScreen(
          controller: _inboxController,
          onRunningBarHeightChanged: (height) {
            if ((_inboxTabRunningBarHeight - height).abs() < 0.5) {
              return;
            }
            setState(() => _inboxTabRunningBarHeight = height);
          },
        ),
        'title': 'インボックス',
        'showDrawer': false,
        'floatingActionButton': true,
      },
      {
        'widget': CalendarScreen(
          onMobileTitleChanged: _handleCalendarMobileTitleChanged,
          onFocusedMonthChanged: (month) {
            // month は yyyy-mm-01 に正規化済み（CalendarScreen側で正規化）
            _calendarFocusedMonthForHolidaySettings = month;
          },
        ),
        'title': 'カレンダー',
        'showDrawer': false,
        'floatingActionButton': false,
      },
      {
        'widget': RoutineScreen(key: RoutineScreen.globalKey),
        'title': 'ルーティン',
        'showDrawer': false,
        'floatingActionButton': false, // ルーティン画面は独自のFABを使用
      },
      {
        'widget': ProjectListScreen(
          twoColumnModeNotifier: _projectTwoColumnMode,
          filterBarVisibleNotifier: _projectFilterVisible,
          hideEmptyProjectsNotifier: _projectHideEmpty,
        ),
        'title': 'プロジェクト',
        'showDrawer': false,
        'floatingActionButton': false, // プロジェクト画面は独自のFABを使用
      },
      {
        'widget':
            const SizedBox.shrink(), // Report tab renders conditionally below
        'title': 'レポート',
        'showDrawer': false,
        'floatingActionButton': false,
      },
      {
        'widget': Builder(
          builder: (context) {
            switch (_dbSubView) {
              case DbSubView.hub:
                return DbHubScreen(
                  onSelect: _handleDbNavigation,
                );
              case DbSubView.inbox:
                return const InboxDbScreen();
              case DbSubView.blocks:
                return const BlockDbScreen();
              case DbSubView.actualBlocks:
                return const ActualDbScreen();
              case DbSubView.projects:
                return const ProjectDbScreen();
              case DbSubView.routineTemplatesV2:
                return const RoutineTemplateV2DbScreen();
              case DbSubView.routineTasksV2:
                return const RoutineTaskV2DbScreen();
              case DbSubView.categories:
                return const CategoryDbScreen();
            }
          },
        ),
        'title': 'DB',
        'showDrawer': false,
        'floatingActionButton': false,
      },
      {
        'widget': Builder(
          builder: (context) {
            if (_settingsSubView == 'project_management') {
              return const ProjectCategoryAssignmentScreen(embedded: true);
            }
            return SettingsScreen(
              embedded: true,
              onNavigateToProjectManagement: () =>
                  setState(() => _settingsSubView = 'project_management'),
            );
          },
        ),
        'title': '設定',
        'showDrawer': false,
        'floatingActionButton': false,
      },
    ];

    // 古いリンク等で範囲外のインデックスが渡されても落とさない
    if (_selectedIndex < 0 || _selectedIndex >= _screens.length) {
      _selectedIndex = _timelineTabIndex;
    }

    // 画面表示後に、現在のタブに対応するDBのみバックグラウンド同期（デバウンス）
    // NOTE: build() は TaskProvider 通知等で頻繁に呼ばれるため、ここを毎回走らせると
    // on-demand sync が短時間に多重実行され read が爆増する。
    if (!_initialBgSyncScheduled) {
      _initialBgSyncScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fabAnimReady = true;
        _requestBackgroundSync();
        // 初期表示タブがタイムラインの場合、ここで一度だけ監視を開始する。
        // 監視開始は MainScreen が一元管理し、background sync helper 側では行わない（read削減）。
        if (_requiresTaskMonitoring(_selectedIndex)) {
          try {
            final state = WidgetsBinding.instance.lifecycleState;
            final isFg = state == null || state == AppLifecycleState.resumed;
            if (isFg) {
              final taskProvider =
                  Provider.of<TaskProvider>(context, listen: false);
              final now = DateTime.now();
              taskProvider.startWatchingRunningTasks(
                fromInclusive: now.subtract(const Duration(hours: 12)),
                toExclusive: now.add(const Duration(hours: 12)),
              );
            }
          } catch (_) {}
        }
      });
    }
  }

  void _onDisplayServicesReady() {
    if (!displayServicesReady.value || !mounted) return;
    displayServicesReady.removeListener(_onDisplayServicesReady);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        Provider.of<TaskProvider>(context, listen: false)
            .refreshTasks(showLoading: false);
      } catch (_) {}
    });
  }

  void _handleMainNavigationRequest() {
    if (!mounted) return;
    final dest = MainNavigationService.request.value;
    if (dest == null) return;
    MainNavigationService.clear();

    final int nextIndex = switch (dest) {
      MainDestination.timeline => _timelineTabIndex,
      MainDestination.inbox => _inboxTabIndex,
      MainDestination.calendar => _calendarTabIndex,
      MainDestination.routine => 3,
      MainDestination.project => 4,
      MainDestination.report => 5,
      MainDestination.db => _dbTabIndex,
    };

    _selectMainIndex(nextIndex);
  }

  void _selectMainIndex(int index) {
    final fromIndex = _selectedIndex;
    final beforeSettings = _showSettingsPanel;
    final beforeCalendarSettings = _showCalendarSettingsPanel;
    // 画面切り替え時の監視制御（通信量削減）
    final oldNeedsMonitoring = _requiresTaskMonitoring(_selectedIndex);
    final newNeedsMonitoring = _requiresTaskMonitoring(index);

    // 監視が必要な画面から不要な画面に移動する場合は停止
    if (oldNeedsMonitoring && !newNeedsMonitoring) {
      try {
        final taskProvider = Provider.of<TaskProvider>(context, listen: false);
        taskProvider.stopWatchingRunningTasks();
      } catch (_) {}
    }

    setState(() {
      _selectedIndex = index;
      // メニュー押下時は各タブのルートに戻す
      switch (index) {
        case 3: // ルーティン
          _selectedRoutine = null;
          _showSettingsPanel = false;
          _settingsSubView = null;
          break;
        case 4: // プロジェクト
          _selectedProject = null;
          _showSettingsPanel = false;
          _settingsSubView = null;
          break;
        case 2: // カレンダー
          _showCalendarSettingsPanel = false;
          _showSettingsPanel = false;
          _settingsSubView = null;
          // タブから入った直後は常に「月表示」から開始する（瞬間的な日表示への上書きを防止）
          AppSettingsService.setString(
            AppSettingsService.keyLastViewType,
            'month',
          );
          // カレンダー画面は独自の同期処理を持つため、バックグラウンド同期はスキップ
          break;
        case 6: // DB
          _showSettingsPanel = false;
          _settingsSubView = null;
          break;
        case 7: // 設定
          _showSettingsPanel = false;
          _settingsSubView = null;
          break;
        default:
          _showSettingsPanel = false;
          _settingsSubView = null;
          break;
      }
    });

    // タブ/パネル切替でツリー構造が変わると、TimelineScreenV2 が dispose→init し、
    // onDemandSync が再度走って read が増える要因になるため、ここで履歴に残す。
    unawaited(
      SyncAllHistoryService.recordSimpleEvent(
        type: 'navigation',
        reason: 'MainScreen.selectMainIndex',
        origin: 'MainScreen._selectMainIndex',
        extra: <String, dynamic>{
          'fromIndex': fromIndex,
          'toIndex': index,
          'beforeShowSettingsPanel': beforeSettings,
          'afterShowSettingsPanel': _showSettingsPanel,
          'beforeShowCalendarSettingsPanel': beforeCalendarSettings,
          'afterShowCalendarSettingsPanel': _showCalendarSettingsPanel,
        },
      ),
    );

    // 監視が必要な画面に入った場合は開始（フォアグラウンドのみ）
    if (!oldNeedsMonitoring && newNeedsMonitoring) {
      try {
        final state = WidgetsBinding.instance.lifecycleState;
        final isFg = state == null || state == AppLifecycleState.resumed;
        if (isFg) {
          final taskProvider =
              Provider.of<TaskProvider>(context, listen: false);
          final now = DateTime.now();
          taskProvider.startWatchingRunningTasks(
            fromInclusive: now.subtract(const Duration(hours: 12)),
            toExclusive: now.add(const Duration(hours: 12)),
          );
        }
      } catch (_) {}
    }

    // 画面切替直後に、その画面で使うDBのみバックグラウンド同期（デバウンス・一本化）
    // カレンダー画面（index 2）は独自の同期処理を持つためスキップ
    if (index != _calendarTabIndex) {
      _requestBackgroundSync();
    }
  }

  bool _isInboxTab(int index) => index == _inboxTabIndex;

  InboxControllerInterface _controllerForInboxTab(int index) =>
      _inboxController;

  bool _requiresTaskMonitoring(int index) => index == _timelineTabIndex;

  List<Widget> _buildInboxActions(
    BuildContext context,
    InboxControllerInterface controller,
  ) {
    return [
      ValueListenableBuilder<bool>(
        valueListenable: controller.isSyncing,
        builder: (context, syncing, _) => IconButton(
          icon: syncing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                  ),
                )
              : const Icon(Icons.sync),
          tooltip: 'インボックス同期',
          onPressed: syncing ? null : controller.requestSync,
        ),
      ),
      if (MediaQuery.of(context).size.width >= 800)
        IconButton(
          icon: const Icon(Icons.undo),
          tooltip: '過ぎ去ったブロックの割当を未割当に戻す',
          onPressed: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('未割当に戻しますか？'),
                content: const Text(
                  '所属ブロックの終了時刻が現在時刻を過ぎたタスク（未完了）を未割当に戻します（当日分も対象）。ブロックは残します。ブロックに属さない時間指定タスクは、タスク終了時刻を基準にします。',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('キャンセル'),
                  ),
                  ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('実行'),
                  ),
                ],
              ),
            );
            if (confirmed != true) return;
            final provider = context.read<TaskProvider>();
            final count =
                await provider.revertAssignedButIncompleteInboxTasks();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('$count件を未割当に戻しました')),
              );
            }
          },
        ),
      IconButton(
        icon: const Icon(Icons.upload_file),
        tooltip: 'CSVインポート',
        onPressed: () {
          showDialog<bool>(
            context: context,
            builder: (_) => const InboxCsvImportDialog(),
          );
        },
      ),
      IconButton(
        icon: const Icon(Icons.settings),
        tooltip: '設定',
        onPressed: () {
          setState(() {
            _showSettingsPanel = !_showSettingsPanel;
          });
          unawaited(
            SyncAllHistoryService.recordSimpleEvent(
              type: 'navigation',
              reason: 'MainScreen.toggleSettingsPanel',
              origin: 'MainScreen.timelineActions',
              extra: <String, dynamic>{
                'selectedIndex': _selectedIndex,
                'showSettingsPanel': _showSettingsPanel,
              },
            ),
          );
        },
      ),
    ];
  }

  // バックグラウンド同期呼び出しをデバウンスして一本化
  void _requestBackgroundSync() {
    _bgSyncDebounce?.cancel();
    _bgSyncDebounce = Timer(const Duration(milliseconds: 250), () {
      _syncForSelectedScreenInBackground();
    });
  }

  void _onTimelineControllerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _handleCalendarMobileTitleChanged(String title) {
    if (!mounted || _calendarMobileTitle == title) return;
    setState(() => _calendarMobileTitle = title);
  }

  // 現在のレポート期間に応じたタイトル
  String _getReportTitle() {
    final base = _reportBaseDate ?? DateTime.now();
    switch (_reportPeriod) {
      case ReportPeriod.daily:
        return '日次レポート ${DateFormat('yyyy/MM/dd').format(base)}';
      case ReportPeriod.weekly:
        final end = DateTime(base.year, base.month, base.day);
        final start = end.subtract(const Duration(days: 6));
        return '週次レポート ${DateFormat('MM/dd').format(start)} - ${DateFormat('MM/dd').format(end)}';
      case ReportPeriod.monthly:
        return '月次レポート ${DateFormat('yyyy/MM').format(base)}';
      case ReportPeriod.yearly:
        return '年次レポート ${DateFormat('yyyy年').format(base)}';
      case ReportPeriod.custom:
        if (_reportRangeStart != null) {
          final end = _reportRangeEnd ?? _reportRangeStart!;
          final label = _formatRangeLabel(_reportRangeStart!, end);
          return 'カスタム期間レポート $label';
        }
        return 'カスタム期間レポート';
    }
  }

  Widget? _buildTimelineAppBarTitle(
    BuildContext context,
    bool isMobileWidth,
  ) {
    if (_selectedIndex != 0) {
      return null;
    }

    final Color textColor = Theme.of(context).appBarTheme.foregroundColor ??
        Theme.of(context).iconTheme.color ??
        Theme.of(context).colorScheme.onSurface;
    // AppBarのデフォルトタイトルスタイルと同じサイズにする
    final TextStyle titleStyle =
        (Theme.of(context).appBarTheme.titleTextStyle ??
                Theme.of(context).textTheme.titleLarge ??
                const TextStyle())
            .copyWith(
      color: textColor,
      fontWeight: FontWeight.w600,
    );

    final bool controlsEnabled = _timelineController.isAttached;

    final Widget dateLabel = Text(
      _formattedSelectedDate,
      style: titleStyle,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildTimelineAppBarNavButton(
          icon: Icons.chevron_left,
          tooltip: '前日',
          onPressed:
              controlsEnabled ? _timelineController.goToPreviousDay : null,
        ),
        const SizedBox(width: 8),
        Flexible(child: dateLabel),
        const SizedBox(width: 8),
        _buildTimelineAppBarNavButton(
          icon: Icons.chevron_right,
          tooltip: '翌日',
          onPressed: controlsEnabled ? _timelineController.goToNextDay : null,
        ),
      ],
    );
  }

  Widget _buildTimelineAppBarNavButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    );
  }

  DateTime _getMonday(DateTime date) {
    final d = date.toLocal();
    final weekday = d.weekday; // Monday=1
    return DateTime(
      d.year,
      d.month,
      d.day,
    ).subtract(Duration(days: weekday - 1));
  }

  DateTime _dateOnly(DateTime date) {
    final d = date.toLocal();
    return DateTime(d.year, d.month, d.day);
  }

  String _formatRangeLabel(DateTime start, DateTime end) {
    final s = _dateOnly(start);
    final e = _dateOnly(end);
    if (s.year == e.year) {
      final startStr = DateFormat('yyyy/MM/dd').format(s);
      final endStr = DateFormat('MM/dd').format(e);
      return '$startStr - $endStr';
    }
    final startStr = DateFormat('yyyy/MM/dd').format(s);
    final endStr = DateFormat('yyyy/MM/dd').format(e);
    return '$startStr - $endStr';
  }

  DateTime _computeWeekStartForReports(DateTime date) {
    final d = _dateOnly(date);
    final weekStartStr = AppSettingsService.weekStartNotifier.value;
    final int weekStartDow = switch (weekStartStr) {
      'monday' => DateTime.monday,
      'tuesday' => DateTime.tuesday,
      'wednesday' => DateTime.wednesday,
      'thursday' => DateTime.thursday,
      'friday' => DateTime.friday,
      'saturday' => DateTime.saturday,
      'sunday' => DateTime.sunday,
      _ => DateTime.sunday,
    };
    final delta = (d.weekday - weekStartDow + 7) % 7;
    return d.subtract(Duration(days: delta));
  }

  (DateTime, DateTime) _resolveCurrentReportRange() {
    final base = _dateOnly(_reportBaseDate ?? DateTime.now());
    switch (_reportPeriod) {
      case ReportPeriod.daily:
        return (base, base);
      case ReportPeriod.weekly:
        final start = _computeWeekStartForReports(base);
        final end = start.add(const Duration(days: 6));
        return (start, end);
      case ReportPeriod.monthly:
        final start = DateTime(base.year, base.month, 1);
        final end = DateTime(base.year, base.month + 1, 0);
        return (start, end);
      case ReportPeriod.yearly:
        final start = DateTime(base.year, 1, 1);
        final end = DateTime(base.year, 12, 31);
        return (start, end);
      case ReportPeriod.custom:
        final start = _dateOnly(_reportRangeStart ?? base);
        final end = _dateOnly(_reportRangeEnd ?? start);
        if (start.isAfter(end)) return (end, start);
        return (start, end);
    }
  }

  Future<void> _exportCurrentReportCsv() async {
    if (_isExportingReportCsv) return;
    setState(() => _isExportingReportCsv = true);
    try {
      final (start, end) = _resolveCurrentReportRange();
      final result = await ReportCsvExportService.exportRange(
        period: _reportPeriod,
        rangeStartInclusive: start,
        rangeEndInclusive: end,
      );
      if (!mounted) return;

      final message = result.filePath == null
          ? 'レポートCSVをダウンロードしました（${result.rowCount}行）'
          : 'レポートCSVを保存しました: ${result.filePath}（${result.rowCount}行）';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('レポートCSV出力エラー: $e')));
    } finally {
      if (mounted) {
        setState(() => _isExportingReportCsv = false);
      }
    }
  }

  // レポート期間選択ダイアログを表示
  Future<void> _showReportPeriodDialog() async {
    final result = await showDialog<ReportPeriod>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (BuildContext context) {
        ReportPeriod localSelected = _reportPeriod;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(color: Colors.transparent),
              ),
            ),
            Positioned(
              top: kToolbarHeight + MediaQuery.of(context).padding.top,
              left: 16,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(8),
                child: StatefulBuilder(
                  builder: (ctx, setLocal) {
                    return Container(
                      width: 300,
                      decoration: BoxDecoration(
                        color: Theme.of(context).dialogTheme.backgroundColor ??
                            Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              'レポート期間を選択',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          ...ReportPeriod.values.map((period) {
                            return rpui.buildPeriodMenuItem(
                              period: period,
                              groupValue: localSelected,
                              onChanged: (val) {
                                setLocal(() => localSelected = val);
                                // 親側の状態も更新しておく（タイトルなどの即時反映用）
                                setState(() {
                                  _reportPeriod = val;
                                  final now = _dateOnly(DateTime.now());
                                  _reportBaseDate = now;
                                  if (val == ReportPeriod.custom &&
                                      (_reportRangeStart == null ||
                                          _reportRangeEnd == null)) {
                                    _reportRangeStart = now;
                                    _reportRangeEnd = now;
                                  }
                                  // 選択直後でもレポートタブに切替（年などで日付未選択でも使えるように）
                                  _selectedIndex = 5;
                                });
                              },
                              dateSelector: _buildDateSelector(period),
                            );
                          }),
                          const SizedBox(height: 8),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );

    if (result != null) {
      await _navigateToReportScreen(result);
    } else {
      // ユーザーが期間のみ選択して日付未選択で閉じた場合でも、現在の期間でレポートへ遷移
      await _navigateToReportScreen(_reportPeriod);
    }
  }

  // 期間メニューアイテムを構築（日付選択付き）
  // ignore: unused_element
  Widget _buildPeriodMenuItem(ReportPeriod period) => rpui.buildPeriodMenuItem(
        period: period,
        groupValue: _reportPeriod,
        onChanged: (val) {
          setState(() {
            _reportPeriod = val;
            _reportBaseDate = DateTime.now();
          });
        },
        dateSelector: _buildDateSelector(period),
      );

  // 期間に応じた日付選択ウィジェットを構築
  Widget _buildDateSelector(ReportPeriod period) {
    final now = DateTime.now();
    final base = _reportBaseDate ?? now;
    String dateText;
    IconData icon;

    switch (period) {
      case ReportPeriod.daily:
        dateText = DateFormat('MM/dd (E)', 'ja_JP')
            .format(period == _reportPeriod ? base : now);
        icon = Icons.today;
        break;
      case ReportPeriod.weekly:
        final ref = period == _reportPeriod ? base : now;
        final monday = _getMonday(ref);
        final sunday = monday.add(const Duration(days: 6));
        dateText =
            '${DateFormat('MM/dd').format(monday)} - ${DateFormat('MM/dd').format(sunday)}';
        icon = Icons.date_range;
        break;
      case ReportPeriod.monthly:
        dateText =
            DateFormat('yyyy/MM').format(period == _reportPeriod ? base : now);
        icon = Icons.calendar_month;
        break;
      case ReportPeriod.yearly:
        dateText =
            DateFormat('yyyy年').format(period == _reportPeriod ? base : now);
        icon = Icons.calendar_today;
        break;
      case ReportPeriod.custom:
        if (_reportRangeStart != null) {
          final end = _reportRangeEnd ?? _reportRangeStart!;
          dateText = _formatRangeLabel(_reportRangeStart!, end);
        } else {
          dateText = '期間を選択';
        }
        icon = Icons.date_range;
        break;
    }

    return rpui.buildDateSelectorButton(
      icon: icon,
      label: dateText,
      onPressed: () => _showDatePickerForPeriod(period),
    );
  }

  void _invalidateReportRecordStartYearCache() {
    _reportRecordStartYearUid = null;
    _reportRecordStartYearCache = null;
  }

  // 期間に応じた日付選択ダイアログを表示
  Future<int> _resolveReportFirstYear({required int lastYear}) async {
    final uid = AuthService.getCurrentUserId();
    if (uid == null || uid.isEmpty) {
      return lastYear;
    }
    if (_reportRecordStartYearUid == uid &&
        _reportRecordStartYearCache != null) {
      final cached = _reportRecordStartYearCache!;
      if (cached < 1) return 1;
      if (cached > lastYear) return lastYear;
      return cached;
    }

    await AppSettingsService.initialize();
    DateTime? recordStartMonth =
        AppSettingsService.getReportRecordStartMonth(uid);
    // creationTime を初回ログイン時に保存済みなら、recordStartMonth 未作成でも
    // 年下限は復元できるようにしておく（ここでは保存更新は行わない）。
    if (recordStartMonth == null) {
      final createdAt = AppSettingsService.getReportRegistrationCreatedAt(uid);
      if (createdAt != null) {
        recordStartMonth = DateTime(createdAt.year, createdAt.month, 1);
      }
    }

    int firstYear = recordStartMonth?.year ?? lastYear;
    if (firstYear > lastYear) {
      firstYear = lastYear;
    }
    if (recordStartMonth != null) {
      _reportRecordStartYearUid = uid;
      _reportRecordStartYearCache = firstYear;
    } else {
      // 未初期化状態をキャッシュすると、その後ログイン処理で保存されても
      // 同セッションで過去年が出ないまま固定されるためキャッシュしない。
      _invalidateReportRecordStartYearCache();
    }
    return firstYear;
  }

  Future<void> _showDatePickerForPeriod(ReportPeriod period) async {
    final now = DateTime.now();
    int firstYear = now.year;
    final int lastYear = now.year;
    if (period == ReportPeriod.monthly || period == ReportPeriod.yearly) {
      try {
        firstYear = await _resolveReportFirstYear(lastYear: lastYear);
      } catch (_) {}
      if (firstYear > lastYear) {
        firstYear = lastYear;
      }
    }

    final res = await rpdate.showDatePickerForPeriod(
      context: context,
      period: period,
      currentStartDate: _reportRangeStart,
      currentEndDate: _reportRangeEnd,
      currentBaseDate: _reportBaseDate,
      currentPeriod: _reportPeriod,
      firstYear: firstYear,
      lastYear: lastYear,
    );
    if (res == null) return;
    setState(() {
      _reportPeriod = res.period;
      _reportBaseDate = res.baseDate;
      if (res.period == ReportPeriod.custom) {
        _reportRangeStart = res.startDate;
        _reportRangeEnd = res.endDate;
      }
      if (res.switchToReportTab) _selectedIndex = 5;
    });
  }

  // 選択された期間に応じてレポート画面に遷移
  Future<void> _navigateToReportScreen(ReportPeriod period) async {
    switch (period) {
      case ReportPeriod.daily:
        if (_selectedIndex != 5) {
          setState(() => _selectedIndex = 5);
        }
        break;
      case ReportPeriod.weekly:
        if (_selectedIndex != 5) {
          setState(() => _selectedIndex = 5);
        }
        break;
      case ReportPeriod.monthly:
        // 月次レポート画面は実装済み（MonthlyReportScreen）
        if (_selectedIndex != 5) {
          setState(() => _selectedIndex = 5);
        }
        break;
      case ReportPeriod.yearly:
        // 年次レポート画面は実装済み（YearlyReportScreen）
        if (_selectedIndex != 5) {
          setState(() => _selectedIndex = 5);
        }
        break;
      case ReportPeriod.custom:
        // カスタム期間選択は実装済み（日付選択ダイアログで期間設定）
        if (_selectedIndex != 5) {
          setState(() => _selectedIndex = 5);
        }
        break;
    }
  }

  Widget _buildReportScreen() {
    switch (_reportPeriod) {
      case ReportPeriod.daily:
        return DailyReportScreen(initialDate: _reportBaseDate);
      case ReportPeriod.weekly:
        return WeeklyReportScreen(
          initialDate: _reportBaseDate,
          onExportCsv: _exportCurrentReportCsv,
          isExportingCsv: _isExportingReportCsv,
        );
      case ReportPeriod.monthly:
        return MonthlyReportScreen(initialDate: _reportBaseDate);
      case ReportPeriod.yearly:
        return YearlyReportScreen(initialDate: _reportBaseDate);
      case ReportPeriod.custom:
        final start = _reportRangeStart ?? _dateOnly(DateTime.now());
        final end = _reportRangeEnd ?? start;
        return WeeklyReportScreen(
          rangeStart: start,
          rangeEnd: end,
          disableNavigation: true,
          onExportCsv: _exportCurrentReportCsv,
          isExportingCsv: _isExportingReportCsv,
        );
    }
  }

  // 現在選択中の画面で利用するDBのみバックグラウンド同期を実行
  void _syncForSelectedScreenInBackground() {
    if (_startupSyncInFlight) {
      _startupSyncQueued = true;
      return;
    }
    _startupSyncInFlight = true;
    Future.microtask(() async {
      try {
        final outcome = await sync_helper.syncForSelectedScreenInBackground(
          context: context,
          selectedIndex: _selectedIndex,
        );
        if (_selectedIndex == _dbTabIndex) {
          await _syncDbView(_dbSubView, forceHeavy: false);
        }
        if (_startupSyncTrackingActive) {
          final settled = outcome.refreshSucceeded && !outcome.shouldRetry;
          if (settled) {
            _startupSyncNeedsRetry = false;
            _startupSyncTrackingActive = false;
            _startupSyncAttempt = 0;
          } else {
            _startupSyncNeedsRetry = true;
            _startupSyncAttempt++;
            final rawDelayMs = 600 * _startupSyncAttempt;
            final delayMs = rawDelayMs > 5000 ? 5000 : rawDelayMs;
            Future.delayed(Duration(milliseconds: delayMs), () {
              if (!mounted ||
                  !_startupSyncTrackingActive ||
                  !_startupSyncNeedsRetry) {
                return;
              }
              _requestBackgroundSync();
            });
          }
        }
      } catch (_) {
        if (_startupSyncTrackingActive) {
          _startupSyncNeedsRetry = true;
          _startupSyncAttempt++;
          final rawDelayMs = 600 * _startupSyncAttempt;
          final delayMs = rawDelayMs > 5000 ? 5000 : rawDelayMs;
          Future.delayed(Duration(milliseconds: delayMs), () {
            if (!mounted ||
                !_startupSyncTrackingActive ||
                !_startupSyncNeedsRetry) {
              return;
            }
            _requestBackgroundSync();
          });
        }
      } finally {
        _startupSyncInFlight = false;
        if (_startupSyncQueued) {
          _startupSyncQueued = false;
          _requestBackgroundSync();
        }
      }
    });
  }

  Future<void> _syncDbView(
    DbSubView view, {
    required bool forceHeavy,
  }) async {
    await sync_helper.syncDbView(view, forceHeavy: forceHeavy);
  }

  Future<void> _handleDbNavigation(DbSubView view) async {
    await _syncDbView(view, forceHeavy: false); // 差分同期で最新状態に
    if (!mounted) return;
    setState(() => _dbSubView = view);
  }

  /// スワイプ戻り / Android システムバック / iOS インタラクティブポップを、AppBar 戻ると同じ優先度で処理する。
  void _handleBackGesture() {
    if (!mounted) return;
    // 優先度 1: カレンダータブ + カレンダー設定パネル
    if (_selectedIndex == _calendarTabIndex && _showCalendarSettingsPanel) {
      setState(() => _showCalendarSettingsPanel = false);
      return;
    }
    // 優先度 2: 設定パネル表示中（カレンダータブ以外）または設定タブ(7) + サブ画面あり
    if ((_showSettingsPanel && _selectedIndex != _calendarTabIndex) ||
        (_selectedIndex == _settingsTabIndex && _settingsSubView != null)) {
      setState(() {
        if (_settingsSubView != null) {
          _settingsSubView = null;
        } else {
          _showSettingsPanel = false;
        }
      });
      return;
    }
    // 優先度 3: プロジェクト詳細
    if (_selectedIndex == 4 && _selectedProject != null) {
      setState(() => _selectedProject = null);
      return;
    }
    // 優先度 4: DB サブ画面
    if (_selectedIndex == _dbTabIndex && _dbSubView != DbSubView.hub) {
      setState(() => _dbSubView = DbSubView.hub);
      return;
    }
    // 優先度 5: ルーティン詳細
    if (_selectedIndex == 3 && _selectedRoutine != null) {
      setState(() => _selectedRoutine = null);
      return;
    }
    // 優先度 6: タイムライン以外のタブ
    if (_selectedIndex != 0) {
      _selectMainIndex(0);
      return;
    }
    // 優先度 7: タイムライン → 何もしない（アプリを閉じない）
  }

  Future<void> _forceSyncTimeline() async {
    if (_isForceSyncing) return;
    setState(() => _isForceSyncing = true);
    try {
      await TimelineActions.forceSyncTimeline(context);
    } finally {
      if (mounted) setState(() => _isForceSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentScreen = _screens[_selectedIndex];
    final bool isRoutineDetail = _selectedIndex == 3 &&
        _selectedRoutine != null &&
        !_isSelectedRoutineShortcut;
    final bool isShortcutSelected = _selectedIndex == 3 &&
        _selectedRoutine != null &&
        _isSelectedRoutineShortcut;
    final bool isMobileWidth = MediaQuery.of(context).size.width < 800;

    String _routineTitleForAppBar() {
      final r = _selectedRoutine;
      if (r == null) return 'ルーティン';
      final t = r.title.trim();
      if (t.isNotEmpty) return t;
      // ショートカットのタイトルが空の場合のフォールバック
      if (_isSelectedRoutineShortcut) return 'ショートカット';
      return 'ルーティン';
    }

    final String title;
    if (_selectedIndex == 4 && _selectedProject != null) {
      title = _selectedProject!.name;
    } else if (_selectedIndex == 3 && _selectedRoutine != null) {
      title = _routineTitleForAppBar();
    } else if (_selectedIndex == _calendarTabIndex) {
      title = _showCalendarSettingsPanel
          ? 'カレンダー設定'
          : (isMobileWidth ? _calendarMobileTitle : 'カレンダー');
    } else if (_showSettingsPanel || _selectedIndex == _settingsTabIndex) {
      title = _settingsSubView == 'project_management' ? 'プロジェクト管理画面' : '設定';
    } else if (_selectedIndex == 5) {
      title = 'レポート';
    } else if (_selectedIndex == _dbTabIndex) {
      switch (_dbSubView) {
        case DbSubView.hub:
          title = 'DB';
        case DbSubView.inbox:
          title = 'DB / インボックス';
        case DbSubView.blocks:
          title = 'DB / 予定ブロック';
        case DbSubView.actualBlocks:
          title = 'DB / 実績ブロック';
        case DbSubView.projects:
          title = 'DB / プロジェクト';
        case DbSubView.routineTemplatesV2:
          title = 'DB / ルーティンテンプレート（V2）';
        case DbSubView.routineTasksV2:
          title = 'DB / ルーティンタスク（V2）';
        case DbSubView.categories:
          title = 'DB / カテゴリ';
      }
    } else if (isShortcutSelected) {
      title = 'ショートカット';
    } else {
      title = currentScreen['title'] as String? ?? '';
    }
    // タイムラインのAppBarタイトルは固定で「タイムライン」にする（日付/前後ボタンは画面本体へ移動）
    const Widget? timelineTitleWidget = null;

    // 再生バー表示の判定は、タイムライン画面からの通知に依存せず、
    // Providerの実行中タスク有無を直接参照する（インボックスで停止した場合も即時反映）。
    final bool hasRunningTask = context.select<TaskProvider, bool>(
      (p) => p.runningActualTasks.isNotEmpty,
    );

    // タイムライン/インボックスで再生バーが表示されている時はFABの位置を調整
    final bool isTimelineTab = _selectedIndex == _timelineTabIndex;
    final bool isInboxTab = _isInboxTab(_selectedIndex);
    final bool runningVisibleNow = hasRunningTask;
    final isMobile = MediaQuery.of(context).size.width < 800;
    final double fallbackRunningBarHeight = isMobile ? 160.0 : 136.0;
    final double activeRunningBarMeasured = isTimelineTab
        ? _timelineTabRunningBarHeight
        : isInboxTab
            ? _inboxTabRunningBarHeight
            : 0.0;
    final double resolvedRunningBarHeight = activeRunningBarMeasured > 0
        ? activeRunningBarMeasured
        : fallbackRunningBarHeight;

    // Scaffold標準の endFloat 位置（既定マージン）に「追加で」乗せる bottom padding。
    // タイムライン/インボックスとも、再生バーは画面内で実測した高さを使う（未計測時はフォールバック）。
    final bool fabNeedsRunningBarOffset =
        runningVisibleNow && (isTimelineTab || isInboxTab);
    final double fabExtraBottomPadding = fabNeedsRunningBarOffset
        ? resolvedRunningBarHeight
        : isInboxTab
            ? (isMobile ? 16.0 : 0.0)
            : 0.0;

    // 「再生バー可視のON/OFFが変わった瞬間」だけ上下アニメを許可する。
    // - 初回表示（_fabAnimReady=false）はアニメしない
    // - タブ切替（タイムライン↔インボックス等）もアニメしない
    final bool selectedIndexChanged = _lastFabSelectedIndex != null &&
        _lastFabSelectedIndex != _selectedIndex;
    final bool runningVisibleChanged = _lastFabRunningVisible != null &&
        _lastFabRunningVisible != runningVisibleNow;
    final bool allowFabOffsetAnimation = _fabAnimReady &&
        !selectedIndexChanged &&
        runningVisibleChanged &&
        (isTimelineTab || isInboxTab);

    // 次回比較用。描画後に値だけ更新（setState不要）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _lastFabSelectedIndex = _selectedIndex;
      _lastFabRunningVisible = runningVisibleNow;
    });

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBackGesture();
      },
      child: Scaffold(
      // Scaffold側のFABアニメ（出現/位置補間）を無効化し、
      // 必要なときだけ下のAnimatedPaddingで上下移動させる。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: const _NoFabAnimator(),
      body: NotificationListener<RoutineSelectedNotification>(
        onNotification: (n) {
          setState(() => _selectedRoutine = n.routine);
          return true;
        },
        child: NotificationListener<ProjectSelectedNotification>(
          onNotification: (n) {
            setState(() {
              _selectedProject = n.project;
              _projectDetailShowArchived = false;
            });
            return true;
          },
          child: NotificationListener<ProjectUpdatedNotification>(
            onNotification: (n) {
              setState(() {
                if (_selectedProject != null &&
                    _selectedProject!.id == n.project.id) {
                  _selectedProject = n.project;
                }
              });
              return true;
            },
            child: CommonLayout(
              // actions は下のブロックでプラットフォーム別に設定するため、ここでは指定しない
              title: title,
              // PC版でもドロワーを利用できるよう、常に表示する
              showDrawer: false,
              suppressBaseActions:
                  _selectedIndex == _calendarTabIndex || isRoutineDetail,
              titleWidget: timelineTitleWidget,
              leading: _selectedIndex == _calendarTabIndex
                  ? (_showCalendarSettingsPanel
                      ? IconButton(
                          tooltip: '戻る',
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => setState(
                            () => _showCalendarSettingsPanel = false,
                          ),
                        )
                      : null)
                  : (_showSettingsPanel &&
                              _selectedIndex != _calendarTabIndex) ||
                          (_selectedIndex == _settingsTabIndex &&
                              _settingsSubView != null)
                      ? IconButton(
                          tooltip: '戻る',
                          icon: const Icon(Icons.arrow_back),
                          onPressed: () => setState(() {
                            if (_settingsSubView != null) {
                              _settingsSubView = null;
                            } else {
                              _showSettingsPanel = false;
                            }
                          }),
                        )
                      : _selectedIndex == 4 && _selectedProject != null
                          ? IconButton(
                              icon: const Icon(Icons.arrow_back),
                              tooltip: '一覧へ戻る',
                              onPressed: () {
                                setState(() => _selectedProject = null);
                              },
                            )
                          : _selectedIndex == _dbTabIndex &&
                                  _dbSubView != DbSubView.hub
                              ? IconButton(
                                  icon: const Icon(Icons.arrow_back),
                                  tooltip: 'DBメニューへ戻る',
                                  onPressed: () => setState(
                                      () => _dbSubView = DbSubView.hub),
                                )
                              : (_selectedIndex == 3 && _selectedRoutine != null
                                  ? IconButton(
                                      icon: const Icon(Icons.arrow_back),
                                      tooltip: '一覧へ戻る',
                                      onPressed: () {
                                        setState(() => _selectedRoutine = null);
                                      },
                                    )
                                  : null),
              actions: _selectedIndex == 0 && !_showSettingsPanel
                  ? (MediaQuery.of(context).size.width < 800
                      ? [
                          IconButton(
                            icon: _isForceSyncing
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.sync),
                            tooltip: '同期',
                            onPressed:
                                _isForceSyncing ? null : _forceSyncTimeline,
                          ),
                          IconButton(
                            icon: const Icon(Icons.call_merge),
                            tooltip: '過去割当を進行中ブロックへ集約',
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('進行中ブロックに集約しますか？'),
                                  content: const Text(
                                    '過去のブロックに割り当て済みだが未完了のタスクを、現在進行中のブロックへまとめて移動します。',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(false),
                                      child: const Text('キャンセル'),
                                    ),
                                    ElevatedButton(
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(true),
                                      child: const Text('実行'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed != true) return;
                              final provider = context.read<TaskProvider>();
                              final message = await provider
                                  .consolidateAssignedButIncompleteInboxTasksToOngoingBlock();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(message)),
                                );
                              }
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.settings),
                            tooltip: '設定',
                            onPressed: () {
                              setState(() {
                                _showSettingsPanel = !_showSettingsPanel;
                              });
                              unawaited(
                                SyncAllHistoryService.recordSimpleEvent(
                                  type: 'navigation',
                                  reason: 'MainScreen.toggleSettingsPanel',
                                  origin: 'MainScreen.appBar',
                                  extra: <String, dynamic>{
                                    'selectedIndex': _selectedIndex,
                                    'showSettingsPanel': _showSettingsPanel,
                                  },
                                ),
                              );
                            },
                          ),
                        ]
                      : [
                          if (!_showSettingsPanel) ...[
                            IconButton(
                              icon: _isForceSyncing
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.sync),
                              tooltip: '強制同期',
                              onPressed:
                                  _isForceSyncing ? null : _forceSyncTimeline,
                            ),
                            IconButton(
                              icon: const Icon(Icons.call_merge),
                              tooltip: '過去割当を進行中ブロックへ集約',
                              onPressed: () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('進行中ブロックに集約しますか？'),
                                    content: const Text(
                                      '過去のブロックに割り当て済みだが未完了のタスクを、現在進行中のブロックへまとめて移動します。',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(false),
                                        child: const Text('キャンセル'),
                                      ),
                                      ElevatedButton(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(true),
                                        child: const Text('実行'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed != true) return;
                                final provider = context.read<TaskProvider>();
                                final message = await provider
                                    .consolidateAssignedButIncompleteInboxTasksToOngoingBlock();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(message)),
                                  );
                                }
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.settings),
                              tooltip: '設定',
                              onPressed: () {
                                setState(() {
                                  _showSettingsPanel = !_showSettingsPanel;
                                });
                                unawaited(
                                  SyncAllHistoryService.recordSimpleEvent(
                                    type: 'navigation',
                                    reason: 'MainScreen.toggleSettingsPanel',
                                    origin: 'MainScreen.appBar',
                                    extra: <String, dynamic>{
                                      'selectedIndex': _selectedIndex,
                                      'showSettingsPanel': _showSettingsPanel,
                                    },
                                  ),
                                );
                              },
                            ),
                          ],
                        ])
                  : _selectedIndex == _calendarTabIndex
                      ? (MediaQuery.of(context).size.width < 800
                          ? [
                              // モバイル: 表示種類セレクタ（AppBar右）
                              ValueListenableBuilder<String>(
                                valueListenable:
                                    AppSettingsService.calendarViewTypeNotifier,
                                builder: (context, current, _) {
                                  String label;
                                  switch (current) {
                                    case 'day':
                                      label = '日';
                                      break;
                                    case 'week':
                                      label = '週';
                                      break;
                                    case 'year':
                                      label = '年';
                                      break;
                                    case 'month':
                                    default:
                                      label = '月';
                                  }
                                  final fg = Theme.of(context)
                                          .appBarTheme
                                          .foregroundColor ??
                                      Theme.of(context).iconTheme.color ??
                                      Theme.of(context).colorScheme.onSurface;
                                  return PopupMenuButton<String>(
                                    tooltip: '表示切替',
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8),
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surface
                                              .withOpacity(0.08),
                                          borderRadius:
                                              BorderRadius.circular(18),
                                          border: Border.all(
                                            color: fg.withOpacity(0.22),
                                            width: 1,
                                          ),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                label,
                                                style: TextStyle(
                                                  color: fg,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 12,
                                                ),
                                              ),
                                              const SizedBox(width: 2),
                                              Icon(
                                                Icons.arrow_drop_down,
                                                size: 18,
                                                color: fg,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                    onSelected: (value) async {
                                      await AppSettingsService.setString(
                                        AppSettingsService.keyLastViewType,
                                        value,
                                      );
                                      setState(() {});
                                    },
                                    itemBuilder: (ctx) => [
                                      CheckedPopupMenuItem(
                                        value: 'day',
                                        checked: current == 'day',
                                        child: const Text('日'),
                                      ),
                                      CheckedPopupMenuItem(
                                        value: 'week',
                                        checked: current == 'week',
                                        child: const Text('週'),
                                      ),
                                      CheckedPopupMenuItem(
                                        value: 'month',
                                        checked: current == 'month',
                                        child: const Text('月'),
                                      ),
                                      CheckedPopupMenuItem(
                                        value: 'year',
                                        checked: current == 'year',
                                        child: const Text('年'),
                                      ),
                                    ],
                                  );
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.edit_calendar),
                                tooltip: '休日設定',
                                onPressed: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (context) =>
                                          HolidaySettingsScreen(
                                        initialFocusedDay:
                                            _calendarFocusedMonthForHolidaySettings,
                                      ),
                                    ),
                                  );
                                },
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.settings,
                                  color: Theme.of(
                                        context,
                                      ).appBarTheme.foregroundColor ??
                                      Theme.of(context).iconTheme.color ??
                                      Theme.of(context).colorScheme.onSurface,
                                ),
                                tooltip: 'カレンダー設定',
                                onPressed: () {
                                  setState(
                                    () => _showCalendarSettingsPanel =
                                        !_showCalendarSettingsPanel,
                                  );
                                },
                              ),
                            ]
                          : [
                              // PC: 設定のみ（切替はヘッダー右側のボタン）
                              IconButton(
                                icon: const Icon(Icons.edit_calendar),
                                tooltip: '休日設定',
                                onPressed: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (context) =>
                                          HolidaySettingsScreen(
                                        initialFocusedDay:
                                            _calendarFocusedMonthForHolidaySettings,
                                      ),
                                    ),
                                  );
                                },
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.settings,
                                  color: Theme.of(
                                        context,
                                      ).appBarTheme.foregroundColor ??
                                      Theme.of(context).iconTheme.color ??
                                      Theme.of(context).colorScheme.onSurface,
                                ),
                                tooltip: 'カレンダー設定',
                                onPressed: () {
                                  setState(
                                    () => _showCalendarSettingsPanel =
                                        !_showCalendarSettingsPanel,
                                  );
                                },
                              ),
                            ])
                      : _isInboxTab(_selectedIndex)
                          ? _buildInboxActions(
                              context,
                              _controllerForInboxTab(_selectedIndex),
                            )
                          : _selectedIndex == 3
                              ? [
                                  if (_selectedRoutine != null &&
                                      !_isSelectedRoutineShortcut)
                                    IconButton(
                                      icon: const Icon(Icons.visibility),
                                      tooltip: '1日のルーティンをレビュー',
                                      onPressed: () {
                                        final rt = _selectedRoutine;
                                        if (rt == null) return;
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                RoutineDayReviewScreen(
                                              routineTemplateId: rt.id,
                                              routineTitle: rt.title,
                                              routineColorHex: rt.color,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  if (_selectedRoutine != null &&
                                      !_isSelectedRoutineShortcut) ...[
                                    IconButton(
                                      icon: const Icon(Icons.schedule),
                                      tooltip: 'ルーティン反映',
                                      onPressed: () {
                                        final rt = _selectedRoutine;
                                        if (rt != null) {
                                          _showRoutineReflectConfirm(rt);
                                        }
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.event_available),
                                      tooltip: '日付を選んで反映',
                                      onPressed: () {
                                        final rt = _selectedRoutine;
                                        if (rt != null) {
                                          _showRoutineReflectPickDates(rt);
                                        }
                                      },
                                    ),
                                  ],
                                  if (_selectedRoutine != null &&
                                      !_isSelectedRoutineShortcut)
                                    IconButton(
                                      icon: const Icon(Icons.edit),
                                      tooltip: 'ルーティン編集',
                                      onPressed: () {
                                        final rt = _selectedRoutine;
                                        if (rt != null) {
                                          RoutineDetailActions.editRoutine(
                                            context,
                                            rt,
                                            () => setState(() {}),
                                          );
                                        }
                                      },
                                    ),
                                ]
                              : _selectedIndex == 4
                                  ? [
                                      // プロジェクト: 共通AppBarで操作
                                      if (_selectedProject != null) ...[
                                        IconButton(
                                          icon: Icon(
                                            _projectDetailShowArchived
                                                ? Icons.archive
                                                : Icons.archive_outlined,
                                            color: Theme.of(context)
                                                    .appBarTheme
                                                    .foregroundColor ??
                                                Theme.of(context)
                                                    .iconTheme
                                                    .color ??
                                                Theme.of(context)
                                                    .colorScheme
                                                    .onSurface,
                                          ),
                                          tooltip: _projectDetailShowArchived
                                              ? 'アーカイブ済みを表示中（タップで隠す）'
                                              : 'アーカイブ済みを表示',
                                          onPressed: () {
                                            setState(() {
                                              _projectDetailShowArchived =
                                                  !_projectDetailShowArchived;
                                            });
                                          },
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            Icons.edit,
                                            color: Theme.of(context)
                                                    .appBarTheme
                                                    .foregroundColor ??
                                                Theme.of(context)
                                                    .iconTheme
                                                    .color ??
                                                Theme.of(context)
                                                    .colorScheme
                                                    .onSurface,
                                          ),
                                          tooltip: 'プロジェクトを編集',
                                          onPressed: () {
                                            _subProjectScreenKey.currentState
                                                ?.openProjectEdit();
                                          },
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            Icons.refresh,
                                            color: Theme.of(context)
                                                    .appBarTheme
                                                    .foregroundColor ??
                                                Theme.of(context)
                                                    .iconTheme
                                                    .color ??
                                                Theme.of(context)
                                                    .colorScheme
                                                    .onSurface,
                                          ),
                                          tooltip: '再読込',
                                          onPressed: () {
                                            _subProjectScreenKey.currentState
                                                ?.reloadData();
                                          },
                                        ),
                                      ],
                                      IconButton(
                                        icon: Icon(
                                          _projectHideEmpty.value
                                              ? Icons.checklist
                                              : Icons.checklist_rtl,
                                          color: Theme.of(context)
                                                  .appBarTheme
                                                  .foregroundColor ??
                                              Theme.of(context)
                                                  .iconTheme
                                                  .color ??
                                              Theme.of(context)
                                                  .colorScheme
                                                  .onSurface,
                                        ),
                                        tooltip: _projectHideEmpty.value
                                            ? '未実施なしを非表示: ON'
                                            : '未実施なしを非表示: OFF',
                                        onPressed: () {
                                          _projectHideEmpty.value =
                                              !_projectHideEmpty.value;
                                        },
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          _projectFilterVisible.value
                                              ? Icons.filter_alt_off
                                              : Icons.filter_alt,
                                          color: Theme.of(context)
                                                  .appBarTheme
                                                  .foregroundColor ??
                                              Theme.of(context)
                                                  .iconTheme
                                                  .color ??
                                              Theme.of(context)
                                                  .colorScheme
                                                  .onSurface,
                                        ),
                                        tooltip: _projectFilterVisible.value
                                            ? 'フィルターを隠す'
                                            : 'フィルターを表示',
                                        onPressed: () {
                                          _projectFilterVisible.value =
                                              !_projectFilterVisible.value;
                                        },
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.settings),
                                        tooltip: 'プロジェクト設定',
                                        onPressed: () {
                                          Navigator.of(context)
                                              .push<Map<String, dynamic>>(
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  ProjectSettingsScreen(
                                                initialTwoColumn:
                                                    _projectTwoColumnMode.value,
                                                initialHideEmpty:
                                                    _projectHideEmpty.value,
                                              ),
                                            ),
                                          )
                                              .then((res) {
                                            if (res == null) return;
                                            if (res.containsKey('twoColumn')) {
                                              _projectTwoColumnMode.value =
                                                  res['twoColumn'] == true;
                                            }
                                            if (res.containsKey('hideEmpty')) {
                                              _projectHideEmpty.value =
                                                  res['hideEmpty'] == true;
                                            }
                                          });
                                        },
                                      ),
                                    ]
                                  : _selectedIndex == 5
                                      ? null
                                      : _selectedIndex == _dbTabIndex
                                          ? []
                                          : null,
              child: (() {
                // 画面を「差し替え」ると dispose→init が起きやすく、Firestore watch の初回スナップショット（例: dayVersions 最大30件）
                // が繰り返し発生する。設定パネル等は “オーバーレイ” として重ね、元画面の State を維持する。
                final bool showEmbeddedSettingsOverlay =
                    _showSettingsPanel && _selectedIndex != _calendarTabIndex;
                final bool showEmbeddedCalendarSettingsOverlay =
                    _selectedIndex == _calendarTabIndex &&
                        _showCalendarSettingsPanel;
                final bool absorb = showEmbeddedSettingsOverlay ||
                    showEmbeddedCalendarSettingsOverlay;

                final Widget base = _selectedIndex == 3
                    ? Row(
                        children: [
                          Expanded(
                            child: _selectedRoutine == null
                                ? RoutineScreen(key: RoutineScreen.globalKey)
                                : (_isSelectedRoutineShortcut
                                    ? ShortcutTemplateScreen(
                                        routine: _selectedRoutine!,
                                        embedded: true,
                                      )
                                    : RoutineDetailScreenV2Table(
                                        routine: _selectedRoutine!,
                                        embedded: true,
                                      )),
                          ),
                        ],
                      )
                    : _selectedIndex == 4
                        ? Row(
                            children: [
                              Expanded(
                                child: _selectedProject == null
                                    ? ProjectListScreen(
                                        twoColumnModeNotifier:
                                            _projectTwoColumnMode,
                                        filterBarVisibleNotifier:
                                            _projectFilterVisible,
                                        hideEmptyProjectsNotifier:
                                            _projectHideEmpty,
                                      )
                                    : SubProjectManagementScreen(
                                        key: _subProjectScreenKey,
                                        project: _selectedProject!,
                                        embedded: true,
                                        parentShowArchived:
                                            _projectDetailShowArchived,
                                        onParentShowArchivedChanged: (v) {
                                          setState(() =>
                                              _projectDetailShowArchived = v);
                                        },
                                      ),
                              ),
                            ],
                          )
                        : _selectedIndex == 5
                            ? _buildReportScreen()
                            : (_selectedIndex == _dbTabIndex
                                ? () {
                                    switch (_dbSubView) {
                                      case DbSubView.hub:
                                        return DbHubScreen(
                                          onSelect: _handleDbNavigation,
                                        );
                                      case DbSubView.inbox:
                                        return const InboxDbScreen();
                                      case DbSubView.blocks:
                                        return const BlockDbScreen();
                                      case DbSubView.actualBlocks:
                                        return const ActualDbScreen();
                                      case DbSubView.projects:
                                        return const ProjectDbScreen();
                                      case DbSubView.routineTemplatesV2:
                                        return const RoutineTemplateV2DbScreen();
                                      case DbSubView.routineTasksV2:
                                        return const RoutineTaskV2DbScreen();
                                      case DbSubView.categories:
                                        return const CategoryDbScreen();
                                    }
                                  }()
                                : currentScreen['widget'] as Widget);

                return Stack(
                  children: [
                    NotificationListener<ReportPeriodDialogRequestNotification>(
                      onNotification: (_) {
                        if (_selectedIndex == 5) {
                          unawaited(_showReportPeriodDialog());
                        }
                        return true;
                      },
                      child: AbsorbPointer(absorbing: absorb, child: base),
                    ),
                    if (showEmbeddedCalendarSettingsOverlay)
                      const Positioned.fill(child: CalendarSettingsPanel()),
                    if (showEmbeddedSettingsOverlay)
                      Positioned.fill(
                        child: _settingsSubView == 'project_management'
                            ? const ProjectCategoryAssignmentScreen(
                                embedded: true,
                              )
                            : SettingsScreen(
                                embedded: true,
                                onNavigateToProjectManagement: () => setState(
                                    () => _settingsSubView =
                                        'project_management'),
                                onNavigateToRoutine: () => setState(() {
                                  _showSettingsPanel = false;
                                  _selectedIndex = 3;
                                }),
                              ),
                      ),
                  ],
                );
              })(),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SizedBox(
        height: 64,
        child: Builder(
          builder: (context) {
            final bool isMobileWidth = MediaQuery.of(context).size.width < 800;
            final List<BottomNavigationBarItem> items = isMobileWidth
                ? const [
                    BottomNavigationBarItem(
                      icon: Icon(Icons.timeline),
                      label: 'タイムライン',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.inbox),
                      label: 'インボックス',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.calendar_month),
                      label: 'カレンダー',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.folder),
                      label: 'プロジェクト',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.bar_chart),
                      label: 'レポート',
                    ),
                  ]
                : const [
                    BottomNavigationBarItem(
                      icon: Icon(Icons.timeline),
                      label: 'タイムライン',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.inbox),
                      label: 'インボックス',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.calendar_month),
                      label: 'カレンダー',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.schedule),
                      label: 'ルーティン',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.folder),
                      label: 'プロジェクト',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.bar_chart),
                      label: 'レポート',
                    ),
                    BottomNavigationBarItem(
                      icon: Icon(Icons.storage),
                      label: 'DB',
                    ),
                    const BottomNavigationBarItem(
                      icon: Icon(Icons.settings),
                      label: '設定',
                    ),
                  ];
            int currentIndex = _selectedIndex;
            if (isMobileWidth) {
              currentIndex = switch (_selectedIndex) {
                0 => 0,
                1 => 1,
                2 => 2,
                4 => 3,
                5 => 4,
                _ => _mobileBottomNavIndex,
              };
            }
            return BottomNavigationBar(
              currentIndex: currentIndex,
              onTap: (bottomIndex) {
                if (isMobileWidth) {
                  setState(() => _mobileBottomNavIndex = bottomIndex);
                }
                final int nextIndex = isMobileWidth
                    ? switch (bottomIndex) {
                        0 => 0,
                        1 => 1,
                        2 => 2,
                        3 => 4,
                        4 => 5,
                        _ => 0,
                      }
                    : bottomIndex;
                _selectMainIndex(nextIndex);
                if (_isInboxTab(nextIndex)) {
                  Future.microtask(() async {
                    final deadline =
                        DateTime.now().add(const Duration(seconds: 5));
                    while (DateTime.now().isBefore(deadline)) {
                      final uid = AuthService.getCurrentUserId();
                      if (uid != null && uid.isNotEmpty) break;
                      await Future.delayed(const Duration(milliseconds: 200));
                    }
                    try {
                      final res = await SyncContext.runWithOrigin(
                        'MainScreen.selectMainIndex(inboxTab)',
                        () => InboxTaskSyncService.syncAllInboxTasks(),
                      );
                      if (res.success != true) {
                        if (appmat.navigatorKey.currentContext != null) {
                          ScaffoldMessenger.of(
                            appmat.navigatorKey.currentContext!,
                          ).showSnackBar(
                            const SnackBar(
                              content: Text('インボックスの同期に失敗しました（サーバー応答）。'),
                            ),
                          );
                        }
                      }
                    } catch (_) {
                      if (appmat.navigatorKey.currentContext != null) {
                        ScaffoldMessenger.of(
                          appmat.navigatorKey.currentContext!,
                        ).showSnackBar(
                          const SnackBar(
                            content: Text('インボックスの同期に失敗しました（通信/認証）。'),
                          ),
                        );
                      }
                    }
                    try {
                      await Provider.of<TaskProvider>(
                        context,
                        listen: false,
                      ).refreshTasks();
                    } catch (_) {}
                  });
                }
              },
              type: BottomNavigationBarType.fixed,
              items: items,
              selectedLabelStyle: const TextStyle(fontSize: 10),
              unselectedLabelStyle: const TextStyle(fontSize: 10),
            );
          },
        ),
      ),
      floatingActionButton: () {
        final Widget? rawFab = _selectedIndex == 0
            ? Builder(
                builder: (context) {
                  final scheme = Theme.of(context).colorScheme;
                  Widget buildFab({
                    required String heroTag,
                    required String tooltip,
                    required IconData icon,
                    required VoidCallback? onPressed,
                  }) {
                    return FloatingActionButton(
                      heroTag: heroTag,
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      onPressed: onPressed,
                      tooltip: tooltip,
                      child: Icon(icon),
                    );
                  }

                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 空白の実績を再生
                      buildFab(
                        heroTag: 'fab_blank_actual_main',
                        tooltip: '空白の実績を再生',
                        icon: Icons.play_arrow,
                        onPressed: _isStartingBlankActual
                            ? null
                            : _startBlankActualTask,
                      ),
                      const SizedBox(width: _timelineFabSpacing),
                      // ショートカット呼び出し
                      buildFab(
                        heroTag: 'fab_shortcut_main',
                        tooltip: 'ショートカット',
                        icon: Icons.flash_on,
                        onPressed: () => timeline_dialogs
                            .showTimelineShortcutDialog(context),
                      ),
                      const SizedBox(width: _timelineFabSpacing),
                      // ポモドーロ
                      buildFab(
                        heroTag: 'fab_pomodoro_main',
                        tooltip: 'ポモドーロ',
                        icon: Icons.timer_outlined,
                        onPressed: () {
                          final block = context
                              .read<TaskProvider>()
                              .getBlockAtCurrentTime();
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => PomodoroScreen(
                                initialBlock: block,
                              ),
                              fullscreenDialog: true,
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: _timelineFabSpacing),
                      // ブロック追加
                      buildFab(
                        heroTag: 'fab_add_block_main',
                        tooltip: 'ブロックを追加',
                        icon: Icons.event_available,
                        onPressed: _addBlockToTimeline,
                      ),
                    ],
                  );
                },
              )
            : _isInboxTab(_selectedIndex)
                ? Builder(
                    builder: (context) {
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FloatingActionButton(
                            heroTag: 'fab_add_inbox_main',
                            onPressed: () async {
                              final changed =
                                  await showUnifiedScreenDialog<bool>(
                                context: context,
                                builder: (_) => const InboxTaskAddScreen(),
                              );
                              if (changed == true && context.mounted) {
                                await context
                                    .read<TaskProvider>()
                                    .refreshTasks();
                              }
                            },
                            tooltip: 'タスクを追加',
                            child: const Icon(Icons.add),
                          ),
                        ],
                      );
                    },
                  )
                : (currentScreen['floatingActionButton'] == true
                    ? FloatingActionButton(
                        onPressed: _onFloatingActionButtonPressed,
                        child: const Icon(Icons.add),
                      )
                    : null);

        // IMPORTANT:
        // FAB を null にして出し入れすると、Scaffold 側の既定トランジションが走り得る。
        // （タブ切替や設定パネル復帰で「勝手にアニメ」が出る原因）
        //
        // 要件:
        // - FAB 関係でアニメを許可するのは「再生バー表示/非表示で上下にスライドする演出」だけ。
        //
        // 対応:
        // - Scaffold へ渡す FAB は常に“非null”にしておき、
        //   表示/非表示は Offstage で即時切替（アニメ無し）にする。
        final bool hideFab =
            rawFab == null || (_selectedIndex == 0 && _showSettingsPanel);
        final Widget effectiveFab = KeyedSubtree(
          key: const ValueKey('main_fab_host'),
          child: Offstage(
            offstage: hideFab,
            child: rawFab ?? const SizedBox.shrink(),
          ),
        );

        // IMPORTANT:
        // AnimatedPadding 自体を出し入れすると、FABツリーの差し替え扱いになって
        // “スライド以外”の既定トランジションが紛れ込むことがある。
        // 常に同じ構造（AnimatedPadding -> Offstage -> FAB）に固定し、
        // アニメさせたいときだけ duration を有効にする。
        return AnimatedPadding(
          padding: EdgeInsets.only(bottom: fabExtraBottomPadding),
          duration: allowFabOffsetAnimation
              ? const Duration(milliseconds: 220)
              : Duration.zero,
          curve: Curves.easeOutCubic,
          child: effectiveFab,
        );
      }(),
    ),
    );
  }

  @override
  void dispose() {
    displayServicesReady.removeListener(_onDisplayServicesReady);
    MainNavigationService.request.removeListener(_handleMainNavigationRequest);
    _timelineController.removeListener(_onTimelineControllerChanged);
    _timelineController.dispose();
    _lifecycleListener.dispose();
    _authStateSub?.cancel();
    _networkSub?.cancel();
    _bgSyncDebounce?.cancel();
    _inboxController.dispose();
    _projectTwoColumnMode.removeListener(_persistProjectTwoColumnListener);
    _projectHideEmpty.removeListener(_persistProjectHideEmptyListener);
    _projectTwoColumnMode.dispose();
    _projectHideEmpty.dispose();
    _projectFilterVisible.dispose();
    super.dispose();
  }

  void _onFloatingActionButtonPressed() {
    switch (_selectedIndex) {
      case 0: // タイムライン
        _addBlockToTimeline();
        break;
      case _inboxTabIndex: // インボックス
      case 3: // ルーティン
        // ルーティン追加（ルーティン画面で独自に処理）
        break;
      case 4: // プロジェクト
        // プロジェクト追加（既存の処理を維持）
        break;
    }
  }

  // タイムライン画面に予定ブロックを追加
  void _addBlockToTimeline() async {
    if (_isAddingBlock) return; // 連打防止
    setState(() => _isAddingBlock = true);
    try {
      final day = DateTime(
        _timelineSelectedDate.year,
        _timelineSelectedDate.month,
        _timelineSelectedDate.day,
      );
      await TimelineActions.addBlockToTimeline(
        context,
        day: day,
        snackbarLabel: _formattedSelectedDate,
        fullscreen: true, // 全画面表示に統一
      );
    } finally {
      if (mounted) setState(() => _isAddingBlock = false);
    }
  }

  Future<void> _startBlankActualTask() async {
    if (_isStartingBlankActual) return;
    setState(() => _isStartingBlankActual = true);
    try {
      await ActualTaskSyncService().createTaskWithSync(title: '');
      if (mounted) {
        await context.read<TaskProvider>().refreshTasks();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('空白の実績の開始に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isStartingBlankActual = false);
      }
    }
  }

  void _showRoutineReflectConfirm(RoutineTemplateV2 routine) {
    RoutineReflectUI.showConfirmAndReflect(context, routine);
  }

  // ignore: unused_element
  Future<void> _reflectRoutineDirect(RoutineTemplateV2 routine) async {
    await RoutineReflectUI.showConfirmAndReflect(context, routine);
  }

  void _showRoutineReflectPickDates(RoutineTemplateV2 routine) {
    RoutineReflectUI.showPickDatesAndReflect(context, routine);
  }

  // ignore: unused_element
  Future<void> _reflectRoutineForSpecificDates(
    RoutineTemplateV2 routine,
    List<DateTime> dates,
  ) async {
    await RoutineReflectUI.reflectForSpecificDates(context, routine, dates);
  }

  String get _formattedSelectedDate {
    final d = _timelineSelectedDate;
    return '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
  }
}

/// Scaffold標準のFABアニメ（出現/位置補間/回転）を無効化する。
///
/// 位置のアニメは「再生バー表示/非表示の瞬間」だけ AnimatedPadding で明示的に行う。
class _NoFabAnimator extends FloatingActionButtonAnimator {
  const _NoFabAnimator();

  @override
  Offset getOffset({
    required Offset begin,
    required Offset end,
    required double progress,
  }) {
    // 位置補間しない（常にendへスナップ）
    return end;
  }

  @override
  Animation<double> getScaleAnimation({required Animation<double> parent}) {
    // 出現/退場でスケールさせない
    return Tween<double>(begin: 1.0, end: 1.0).animate(parent);
  }

  @override
  Animation<double> getRotationAnimation({required Animation<double> parent}) {
    // 回転させない
    return Tween<double>(begin: 0.0, end: 0.0).animate(parent);
  }
}
