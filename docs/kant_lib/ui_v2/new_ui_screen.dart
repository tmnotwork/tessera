// 新UI（左縦バー版）— 既存 MainScreen のレイアウトのみ変更したテスト用画面。
// 上部の共通アプリバーは廃止し、各画面の最上行に旧UIと同様のアクションアイコンを配置。

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../screens/timeline_screen_v2.dart';
import '../screens/inbox_screen.dart';
import '../screens/calendar_screen.dart';
import '../screens/routine_screen.dart';
import '../screens/routine_detail_screen_v2_table.dart';
import '../screens/shortcut_template_screen.dart';
import '../screens/routine_day_review_screen.dart';
import '../models/project.dart';
import '../screens/project_list_screen.dart';
import '../screens/project_settings_screen.dart';
import '../screens/sub_project_management_screen.dart';
import '../screens/weekly_report_screen.dart';
import '../screens/daily_report_screen.dart';
import '../screens/monthly_report_screen.dart';
import '../screens/yearly_report_screen.dart';
import '../screens/db_hub_screen.dart';
import '../screens/inbox_db_screen.dart';
import '../screens/actual_db_screen.dart';
import '../screens/block_db_screen.dart';
import '../screens/project_db_screen.dart';
import '../screens/category_db_screen.dart';
import '../screens/routine_template_v2_db_screen.dart';
import '../screens/routine_task_v2_db_screen.dart';
import '../screens/inbox_task_add_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/project_category_assignment_screen.dart';
import '../models/routine_template_v2.dart';
import '../widgets/app_notifications.dart';
import '../widgets/calendar_settings_panel.dart';
import '../screens/inbox_controller_interface.dart';
import '../services/app_settings_service.dart';
import '../services/actual_task_sync_service.dart';
import '../services/report_csv_export_service.dart';
import '../providers/task_provider.dart';
import '../app/main_screen/timeline_actions.dart';
import '../app/main_screen/report_period.dart';
import '../app/main_screen/report_period_dialog.dart' as rpui;
import '../app/main_screen/report_date_picker.dart' as rpdate;
import '../app/main_screen/routine_reflect.dart';
import '../app/main_screen/sync_for_screen.dart' as sync_helper;
import '../services/auth_service.dart';
import '../services/inbox_task_sync_service.dart';
import '../services/network_manager.dart';
import '../services/main_navigation_service.dart';
import '../services/sync_context.dart';
import '../app/app_material.dart' as appmat;
import '../widgets/report_navigation.dart';
import '../widgets/inbox/inbox_csv_import_dialog.dart';
import '../screens/routine_detail_actions.dart';
import '../screens/timeline_dialogs.dart' as timeline_dialogs;
import '../screens/pomodoro_screen.dart';
import '../utils/unified_screen_dialog.dart';

/// 新UI: 左に縦ナビ（幅≥800px）。幅が狭いときは MainScreen と同様に下部タブ＋ドロワーでスマホ相当UIにする。
class NewUIScreen extends StatefulWidget {
  const NewUIScreen({super.key});

  @override
  State<NewUIScreen> createState() => _NewUIScreenState();
}

class _NewUIScreenState extends State<NewUIScreen> {
  static const double _timelineFabSpacing = 12;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  int _selectedIndex = 0;
  late final TimelineScreenV2Controller _timelineController;
  final InboxScreenController _inboxController = InboxScreenController();
  final ValueNotifier<bool> _projectTwoColumnMode = ValueNotifier(false);
  final ValueNotifier<bool> _projectHideEmpty = ValueNotifier(true);
  final ValueNotifier<bool> _projectFilterVisible = ValueNotifier(false);
  ReportPeriod _reportPeriod = ReportPeriod.daily;
  DateTime? _reportBaseDate = DateTime.now();
  DateTime? _reportRangeStart;
  DateTime? _reportRangeEnd;
  int? _reportRecordStartYearCache;
  String? _reportRecordStartYearUid;

  DateTime _timelineSelectedDate = DateTime.now();
  double _timelineTabRunningBarHeight = 0;
  double _inboxTabRunningBarHeight = 0;
  bool _fabAnimReady = false;
  int? _lastFabSelectedIndex;
  bool? _lastFabRunningVisible;
  bool _inboxShowAssigned = false;
  bool _isAddingBlock = false;
  bool _isStartingBlankActual = false;
  RoutineTemplateV2? _selectedRoutine;
  bool _showSettingsPanel = false;
  bool _showCalendarSettingsPanel = false;
  String? _settingsSubView; // null=設定, 'project_management'=プロジェクト管理
  bool _isForceSyncing = false;
  bool _isExportingReportCsv = false;
  DateTime _calendarFocusedMonthForHolidaySettings = DateTime.now();
  DbSubView _dbSubView = DbSubView.hub;
  Project? _selectedProject;
  /// プロジェクト詳細（埋め込み）のアーカイブ表示フィルタ（AppBar と SubProject で共有）
  bool _projectDetailShowArchived = false;
  final GlobalKey<SubProjectManagementScreenState> _subProjectScreenKey =
      GlobalKey<SubProjectManagementScreenState>();
  Timer? _bgSyncDebounce;
  bool _initialBgSyncScheduled = false;
  bool _startupSyncTrackingActive = true;
  bool _startupSyncNeedsRetry = true;
  bool _startupSyncInFlight = false;
  bool _startupSyncQueued = false;
  int _startupSyncAttempt = 0;
  StreamSubscription<Object?>? _authStateSub;
  StreamSubscription<bool>? _networkSub;
  late final AppLifecycleListener _lifecycleListener;
  /// 狭い画面で下部タブに無い画面（ルーティン/DB/設定等）表示中のとき、タブの選択ハイライト用（MainScreen と同様）
  int _mobileBottomNavIndex = 0;
  static const int _dbTabIndex = 6;
  static const int _calendarTabIndex = 2;
  static const int _reportTabIndex = 5;
  static const int _timelineTabIndex = 0;
  static const int _inboxTabIndex = 1;

  bool get _isSelectedRoutineShortcut =>
      _selectedRoutine != null &&
      (_selectedRoutine!.id == 'shortcut' || _selectedRoutine!.isShortcut);

  static const _labels = [
    'タイムライン',
    'インボックス',
    'カレンダー',
    'ルーティン',
    'プロジェクト',
    'レポート',
    'DB',
    '設定',
  ];

  static int get _settingsTabIndex => _labels.length - 1;

  bool _requiresTaskMonitoring(int index) => index == _timelineTabIndex;

  void _onNavItemTapped(int i) {
    final oldNeedsMonitoring = _requiresTaskMonitoring(_selectedIndex);
    final newNeedsMonitoring = _requiresTaskMonitoring(i);
    if (oldNeedsMonitoring && !newNeedsMonitoring) {
      try {
        Provider.of<TaskProvider>(context, listen: false)
            .stopWatchingRunningTasks();
      } catch (_) {}
    }
    setState(() {
      _selectedIndex = i;
      if (i != _settingsTabIndex) _settingsSubView = null;
      // MainScreen._selectMainIndex に揃えたタブ切替時の状態リセット
      switch (i) {
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
          unawaited(
            AppSettingsService.setString(
              AppSettingsService.keyLastViewType,
              'month',
            ),
          );
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
    if (!oldNeedsMonitoring && newNeedsMonitoring) {
      try {
        final state = WidgetsBinding.instance.lifecycleState;
        if (state == null || state == AppLifecycleState.resumed) {
          final now = DateTime.now();
          Provider.of<TaskProvider>(context, listen: false)
              .startWatchingRunningTasks(
            fromInclusive: now.subtract(const Duration(hours: 12)),
            toExclusive: now.add(const Duration(hours: 12)),
          );
        }
      } catch (_) {}
    }
    if (i != _calendarTabIndex) _requestBackgroundSync();
    _syncInboxAfterSwitchIfNeeded(i);
  }

  /// MainScreen と同様、インボックスタブへ来た直後に同期を試みる
  void _syncInboxAfterSwitchIfNeeded(int index) {
    if (index != _inboxTabIndex) return;
    Future.microtask(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        final uid = AuthService.getCurrentUserId();
        if (uid != null && uid.isNotEmpty) break;
        await Future.delayed(const Duration(milliseconds: 200));
      }
      if (!mounted) return;
      try {
        final res = await SyncContext.runWithOrigin(
          'NewUIScreen.selectTab(inboxTab)',
          () => InboxTaskSyncService.syncAllInboxTasks(),
        );
        if (!mounted) return;
        if (res.success != true) {
          if (appmat.navigatorKey.currentContext != null) {
            ScaffoldMessenger.of(appmat.navigatorKey.currentContext!).showSnackBar(
              const SnackBar(
                content: Text('インボックスの同期に失敗しました（サーバー応答）。'),
              ),
            );
          }
        }
      } catch (_) {
        if (!mounted) return;
        if (appmat.navigatorKey.currentContext != null) {
          ScaffoldMessenger.of(appmat.navigatorKey.currentContext!).showSnackBar(
            const SnackBar(
              content: Text('インボックスの同期に失敗しました（通信/認証）。'),
            ),
          );
        }
      }
      if (!mounted) return;
      try {
        await Provider.of<TaskProvider>(context, listen: false).refreshTasks();
      } catch (_) {}
    });
  }

  Widget _buildMobileBottomNavigationBar(BuildContext context) {
    const items = [
      BottomNavigationBarItem(icon: Icon(Icons.timeline), label: 'タイムライン'),
      BottomNavigationBarItem(icon: Icon(Icons.inbox), label: 'インボックス'),
      BottomNavigationBarItem(icon: Icon(Icons.calendar_month), label: 'カレンダー'),
      BottomNavigationBarItem(icon: Icon(Icons.folder), label: 'プロジェクト'),
      BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'レポート'),
    ];
    final currentIndex = switch (_selectedIndex) {
      0 => 0,
      1 => 1,
      2 => 2,
      4 => 3,
      5 => 4,
      _ => _mobileBottomNavIndex,
    };
    return BottomNavigationBar(
      currentIndex: currentIndex,
      onTap: (bottomIndex) {
        setState(() => _mobileBottomNavIndex = bottomIndex);
        final int nextIndex = switch (bottomIndex) {
          0 => 0,
          1 => 1,
          2 => 2,
          3 => 4,
          4 => 5,
          _ => 0,
        };
        _onNavItemTapped(nextIndex);
      },
      type: BottomNavigationBarType.fixed,
      items: items,
      selectedLabelStyle: const TextStyle(fontSize: 10),
      unselectedLabelStyle: const TextStyle(fontSize: 10),
    );
  }

  Widget _buildNavMenuItem(
    BuildContext context,
    int i, {
    VoidCallback? afterTap,
  }) {
    final selected = _selectedIndex == i;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            _onNavItemTapped(i);
            afterTap?.call();
          },
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: selected ? scheme.primary : null,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: scheme.primary.withOpacity(selected ? 0.8 : 0.0),
                width: selected ? 1.5 : 0.0,
              ),
            ),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              style: TextStyle(
                fontSize: 14,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.normal,
                color: selected ? scheme.onPrimary : scheme.onSurface,
              ),
              child: Text(_labels[i]),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _timelineController = TimelineScreenV2Controller();
    _projectTwoColumnMode.value = AppSettingsService.getBool(
      AppSettingsService.keyProjectTwoColumnMode,
      defaultValue: true,
    );
    _projectHideEmpty.value = AppSettingsService.getBool(
      AppSettingsService.keyProjectHideEmpty,
      defaultValue: true,
    );
    MainNavigationService.request.addListener(_handleMainNavigationRequest);
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (AppLifecycleState state) {
        final needsMonitoring = _requiresTaskMonitoring(_selectedIndex);
        if (state == AppLifecycleState.paused ||
            state == AppLifecycleState.inactive ||
            state == AppLifecycleState.detached) {
          if (needsMonitoring) {
            try {
              Provider.of<TaskProvider>(context, listen: false)
                  .stopWatchingRunningTasks();
            } catch (_) {}
          }
        } else if (state == AppLifecycleState.resumed) {
          if (needsMonitoring) {
            try {
              final now = DateTime.now();
              Provider.of<TaskProvider>(context, listen: false)
                  .startWatchingRunningTasks(
                fromInclusive: now.subtract(const Duration(hours: 12)),
                toExclusive: now.add(const Duration(hours: 12)),
              );
            } catch (_) {}
          }
          if (_startupSyncTrackingActive && _startupSyncNeedsRetry && mounted) {
            _requestBackgroundSync();
          }
        }
      },
    );
    _authStateSub = AuthService.authStateChanges.listen((user) {
      if (!mounted || !_startupSyncTrackingActive || !_startupSyncNeedsRetry) return;
      if (user != null || AuthService.isLoggedIn()) _requestBackgroundSync();
    });
    _networkSub = NetworkManager.connectivityStream.listen((isOnline) {
      if (!mounted || !_startupSyncTrackingActive || !_startupSyncNeedsRetry) return;
      if (isOnline) _requestBackgroundSync();
    });
  }

  @override
  void dispose() {
    MainNavigationService.request.removeListener(_handleMainNavigationRequest);
    _lifecycleListener.dispose();
    _authStateSub?.cancel();
    _networkSub?.cancel();
    _bgSyncDebounce?.cancel();
    _projectTwoColumnMode.dispose();
    _projectHideEmpty.dispose();
    _projectFilterVisible.dispose();
    super.dispose();
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
      MainDestination.report => _reportTabIndex,
      MainDestination.db => _dbTabIndex,
    };
    setState(() => _selectedIndex = nextIndex);
    if (nextIndex != _calendarTabIndex) _requestBackgroundSync();
    if (nextIndex == _timelineTabIndex) {
      try {
        final now = DateTime.now();
        Provider.of<TaskProvider>(context, listen: false).startWatchingRunningTasks(
          fromInclusive: now.subtract(const Duration(hours: 12)),
          toExclusive: now.add(const Duration(hours: 12)),
        );
      } catch (_) {}
    }
  }

  void _requestBackgroundSync() {
    _bgSyncDebounce?.cancel();
    _bgSyncDebounce = Timer(const Duration(milliseconds: 250), () {
      _syncForSelectedScreenInBackground();
    });
  }

  Future<void> _syncForSelectedScreenInBackground() async {
    if (_startupSyncInFlight) {
      _startupSyncQueued = true;
      return;
    }
    _startupSyncInFlight = true;
    try {
      final outcome = await sync_helper.syncForSelectedScreenInBackground(
        context: context,
        selectedIndex: _selectedIndex,
        timelineDisplayDate: _selectedIndex == _timelineTabIndex ? _timelineSelectedDate : null,
      );
      if (mounted && _selectedIndex == _dbTabIndex) {
        await sync_helper.syncDbView(_dbSubView, forceHeavy: false);
      }
      if (mounted && _startupSyncTrackingActive) {
        final settled = outcome.refreshSucceeded && !outcome.shouldRetry;
        if (settled) {
          _startupSyncNeedsRetry = false;
          _startupSyncTrackingActive = false;
          _startupSyncAttempt = 0;
        } else {
          _startupSyncNeedsRetry = true;
          _startupSyncAttempt++;
          final delayMs = (_startupSyncAttempt * 600).clamp(0, 5000);
          Future.delayed(Duration(milliseconds: delayMs), () {
            if (!mounted || !_startupSyncTrackingActive || !_startupSyncNeedsRetry) return;
            _requestBackgroundSync();
          });
        }
      }
    } catch (_) {
      if (mounted && _startupSyncTrackingActive) {
        _startupSyncNeedsRetry = true;
        _startupSyncAttempt++;
        final delayMs = (_startupSyncAttempt * 600).clamp(0, 5000);
        Future.delayed(Duration(milliseconds: delayMs), () {
          if (!mounted || !_startupSyncTrackingActive || !_startupSyncNeedsRetry) return;
          _requestBackgroundSync();
        });
      }
    } finally {
      _startupSyncInFlight = false;
      if (_startupSyncQueued && mounted) {
        _startupSyncQueued = false;
        _requestBackgroundSync();
      }
    }
  }

  String get _formattedSelectedDate {
    final d = _timelineSelectedDate;
    return '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _addBlockToTimeline() async {
    if (_isAddingBlock) return;
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
        fullscreen: true,
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

  Widget _buildBodyContent() {
    return NotificationListener<RoutineSelectedNotification>(
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
          child: IndexedStack(
            index: _selectedIndex,
            sizing: StackFit.expand,
            children: [
              TimelineScreenV2(
            controller: _timelineController,
            onSelectedDateChanged: (d) => setState(() => _timelineSelectedDate = d),
            onRunningBarHeightChanged: (height) {
              if ((_timelineTabRunningBarHeight - height).abs() < 0.5) return;
              setState(() => _timelineTabRunningBarHeight = height);
            },
            dateRowLeadingActions: _buildTimelineDateRowLeadingActions(),
          ),
          InboxScreen(
            controller: _inboxController,
            onRunningBarHeightChanged: (height) {
              if ((_inboxTabRunningBarHeight - height).abs() < 0.5) return;
              setState(() => _inboxTabRunningBarHeight = height);
            },
          ),
          CalendarScreen(
            onMobileTitleChanged: (_) {},
            onFocusedMonthChanged: (month) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                setState(() => _calendarFocusedMonthForHolidaySettings = month);
              });
            },
          ),
          _selectedRoutine == null
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
              _selectedProject == null
                  ? ProjectListScreen(
                      twoColumnModeNotifier: _projectTwoColumnMode,
                      filterBarVisibleNotifier: _projectFilterVisible,
                      hideEmptyProjectsNotifier: _projectHideEmpty,
                    )
                  : SubProjectManagementScreen(
                      key: _subProjectScreenKey,
                      project: _selectedProject!,
                      embedded: true,
                      parentShowArchived: _projectDetailShowArchived,
                      onParentShowArchivedChanged: (v) {
                        setState(() => _projectDetailShowArchived = v);
                      },
                    ),
              _buildReportScreen(),
              _buildDbTabBody(),
              _settingsSubView == 'project_management'
                  ? const ProjectCategoryAssignmentScreen(embedded: true)
                  : SettingsScreen(
                      embedded: true,
                      onNavigateToProjectManagement: () =>
                          setState(() => _settingsSubView = 'project_management'),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  String get _routineTitleForAppBar {
    final r = _selectedRoutine;
    if (r == null) return 'ルーティン';
    if (r.id == 'shortcut' || r.isShortcut) return 'ショートカット一覧';
    final t = r.title.trim();
    return t.isEmpty ? '（無題）' : t;
  }

  DateTime _dateOnly(DateTime d) =>
      DateTime(d.year, d.month, d.day);

  DateTime _getMonday(DateTime date) {
    final d = date.toLocal();
    return DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1));
  }

  String _formatRangeLabel(DateTime start, DateTime end) {
    final s = _dateOnly(start);
    final e = _dateOnly(end);
    if (s.year == e.year) {
      return '${DateFormat('yyyy/MM/dd').format(s)} - ${DateFormat('MM/dd').format(e)}';
    }
    return '${DateFormat('yyyy/MM/dd').format(s)} - ${DateFormat('yyyy/MM/dd').format(e)}';
  }

  void _invalidateReportRecordStartYearCache() {
    _reportRecordStartYearUid = null;
    _reportRecordStartYearCache = null;
  }

  Future<int> _resolveReportFirstYear({required int lastYear}) async {
    final uid = AuthService.getCurrentUserId();
    if (uid == null || uid.isEmpty) return lastYear;
    if (_reportRecordStartYearUid == uid && _reportRecordStartYearCache != null) {
      return (_reportRecordStartYearCache!).clamp(1, lastYear);
    }
    await AppSettingsService.initialize();
    DateTime? recordStartMonth = AppSettingsService.getReportRecordStartMonth(uid);
    if (recordStartMonth == null) {
      final createdAt = AppSettingsService.getReportRegistrationCreatedAt(uid);
      if (createdAt != null) recordStartMonth = DateTime(createdAt.year, createdAt.month, 1);
    }
    int firstYear = recordStartMonth?.year ?? lastYear;
    if (firstYear > lastYear) firstYear = lastYear;
    if (recordStartMonth != null) {
      _reportRecordStartYearUid = uid;
      _reportRecordStartYearCache = firstYear;
    }
    return firstYear;
  }

  (DateTime, DateTime) _resolveCurrentReportRange() {
    final base = _dateOnly(_reportBaseDate ?? DateTime.now());
    switch (_reportPeriod) {
      case ReportPeriod.daily:
        return (base, base);
      case ReportPeriod.weekly:
        final start = _computeWeekStartForReports(base);
        return (start, start.add(const Duration(days: 6)));
      case ReportPeriod.monthly:
        return (DateTime(base.year, base.month, 1), DateTime(base.year, base.month + 1, 0));
      case ReportPeriod.yearly:
        return (DateTime(base.year, 1, 1), DateTime(base.year, 12, 31));
      case ReportPeriod.custom:
        final start = _dateOnly(_reportRangeStart ?? base);
        final end = _dateOnly(_reportRangeEnd ?? start);
        return start.isAfter(end) ? (end, start) : (start, end);
    }
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

  Future<void> _showReportPeriodDialog() async {
    final result = await showDialog<ReportPeriod>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) {
        ReportPeriod localSelected = _reportPeriod;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(ctx).pop(),
                child: Container(color: Colors.transparent),
              ),
            ),
            Positioned(
              top: kToolbarHeight + MediaQuery.of(ctx).padding.top,
              left: 16,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(8),
                child: StatefulBuilder(
                  builder: (ctx2, setLocal) {
                    return Container(
                      width: 300,
                      decoration: BoxDecoration(
                        color: Theme.of(ctx).dialogTheme.backgroundColor ?? Theme.of(ctx).colorScheme.surface,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('レポート期間を選択', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500)),
                          ),
                          ...ReportPeriod.values.map((period) => rpui.buildPeriodMenuItem(
                            period: period,
                            groupValue: localSelected,
                            onChanged: (val) {
                              setLocal(() => localSelected = val);
                              setState(() {
                                _reportPeriod = val;
                                _reportBaseDate = _dateOnly(DateTime.now());
                                if (val == ReportPeriod.custom && (_reportRangeStart == null || _reportRangeEnd == null)) {
                                  _reportRangeStart = _reportBaseDate;
                                  _reportRangeEnd = _reportBaseDate;
                                }
                                _selectedIndex = _reportTabIndex;
                              });
                              Navigator.of(ctx).pop(val);
                            },
                            dateSelector: _buildDateSelector(period),
                          )),
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
    if (result != null) await _navigateToReportScreen(result);
    else await _navigateToReportScreen(_reportPeriod);
  }

  Widget _buildDateSelector(ReportPeriod period) {
    final now = DateTime.now();
    final base = _reportBaseDate ?? now;
    String dateText;
    IconData icon;
    switch (period) {
      case ReportPeriod.daily:
        dateText = DateFormat('MM/dd (E)', 'ja_JP').format(period == _reportPeriod ? base : now);
        icon = Icons.today;
        break;
      case ReportPeriod.weekly:
        final ref = period == _reportPeriod ? base : now;
        final monday = _getMonday(ref);
        dateText = '${DateFormat('MM/dd').format(monday)} - ${DateFormat('MM/dd').format(monday.add(const Duration(days: 6)))}';
        icon = Icons.date_range;
        break;
      case ReportPeriod.monthly:
        dateText = DateFormat('yyyy/MM').format(period == _reportPeriod ? base : now);
        icon = Icons.calendar_month;
        break;
      case ReportPeriod.yearly:
        dateText = DateFormat('yyyy年').format(period == _reportPeriod ? base : now);
        icon = Icons.calendar_today;
        break;
      case ReportPeriod.custom:
        dateText = _reportRangeStart != null
            ? _formatRangeLabel(_reportRangeStart!, _reportRangeEnd ?? _reportRangeStart!)
            : '期間を選択';
        icon = Icons.date_range;
        break;
    }
    return rpui.buildDateSelectorButton(icon: icon, label: dateText, onPressed: () => _showDatePickerForPeriod(period));
  }

  Future<void> _showDatePickerForPeriod(ReportPeriod period) async {
    final now = DateTime.now();
    int firstYear = now.year;
    if (period == ReportPeriod.monthly || period == ReportPeriod.yearly) {
      try { firstYear = await _resolveReportFirstYear(lastYear: now.year); } catch (_) {}
      if (firstYear > now.year) firstYear = now.year;
    }
    final res = await rpdate.showDatePickerForPeriod(
      context: context,
      period: period,
      currentStartDate: _reportRangeStart,
      currentEndDate: _reportRangeEnd,
      currentBaseDate: _reportBaseDate,
      currentPeriod: _reportPeriod,
      firstYear: firstYear,
      lastYear: now.year,
    );
    if (res == null) return;
    setState(() {
      _reportPeriod = res.period;
      _reportBaseDate = res.baseDate;
      if (res.period == ReportPeriod.custom) {
        _reportRangeStart = res.startDate;
        _reportRangeEnd = res.endDate;
      }
      _selectedIndex = _reportTabIndex;
    });
  }

  Future<void> _navigateToReportScreen(ReportPeriod period) async {
    if (_selectedIndex != _reportTabIndex) setState(() => _selectedIndex = _reportTabIndex);
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
          onSettingsTap: () => setState(() => _showSettingsPanel = true),
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
          onSettingsTap: () => setState(() => _showSettingsPanel = true),
        );
    }
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('レポートCSV出力エラー: $e')));
    } finally {
      if (mounted) setState(() => _isExportingReportCsv = false);
    }
  }

  Future<void> _handleDbNavigation(DbSubView view) async {
    await sync_helper.syncDbView(view, forceHeavy: false); // 差分同期で最新状態に
    if (!mounted) return;
    setState(() => _dbSubView = view);
  }

  String get _dbSubViewTitle {
    switch (_dbSubView) {
      case DbSubView.hub:
        return 'DB';
      case DbSubView.inbox:
        return 'DB / インボックス';
      case DbSubView.blocks:
        return 'DB / 予定ブロック';
      case DbSubView.actualBlocks:
        return 'DB / 実績ブロック';
      case DbSubView.projects:
        return 'DB / プロジェクト';
      case DbSubView.routineTemplatesV2:
        return 'DB / ルーティンテンプレート（V2）';
      case DbSubView.routineTasksV2:
        return 'DB / ルーティンタスク（V2）';
      case DbSubView.categories:
        return 'DB / カテゴリ';
    }
  }

  Widget _buildDbTabBody() {
    switch (_dbSubView) {
      case DbSubView.hub:
        return DbHubScreen(onSelect: _handleDbNavigation);
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
  }

  List<Widget> _buildTimelineDateRowLeadingActions() {
    final iconColor = Theme.of(context).colorScheme.onSurface;
    return [
      IconButton(
        icon: Icon(Icons.call_merge, color: iconColor),
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
          final message = await provider
              .consolidateAssignedButIncompleteInboxTasksToOngoingBlock();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(message)),
            );
          }
        },
      ),
    ];
  }

  /// 各画面の一番上の行: 旧UIのアプリバーにあったアイコンを配置
  Widget _buildTopActionBar() {
    final showSettingsOverlay = _showSettingsPanel && _selectedIndex != 2;
    final isSettingsBack =
        showSettingsOverlay ||
        (_selectedIndex == _settingsTabIndex && _settingsSubView != null);
    final isRoutineDetail = _selectedIndex == 3 && _selectedRoutine != null;
    final isProjectDetail = _selectedIndex == 4 && _selectedProject != null;
    final isDbSubView = _selectedIndex == 6 && _dbSubView != DbSubView.hub;
    final iconColor = Theme.of(context).colorScheme.onSurface;

    return Material(
      elevation: 0,
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: true,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              if (isSettingsBack) ...[
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '戻る',
                  onPressed: () => setState(() {
                    if (_settingsSubView != null) {
                      _settingsSubView = null;
                    } else {
                      _showSettingsPanel = false;
                    }
                  }),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _settingsSubView == 'project_management'
                          ? 'プロジェクト管理画面'
                          : '設定',
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ] else if (isRoutineDetail) ...[
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _selectedRoutine = null),
                  tooltip: 'ルーティン一覧に戻る',
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _routineTitleForAppBar,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ] else if (isProjectDetail) ...[
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _selectedProject = null),
                  tooltip: '一覧へ戻る',
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _selectedProject!.name.trim().isEmpty
                          ? '（無題）'
                          : _selectedProject!.name,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ] else if (isDbSubView) ...[
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => setState(() => _dbSubView = DbSubView.hub),
                  tooltip: 'DBメニューへ戻る',
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _dbSubViewTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ] else
                const SizedBox(width: 8),
              const Spacer(),
              ..._buildActionIconsForCurrentScreen(iconColor),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildInboxActions(BuildContext context) {
    final controller = _inboxController;
    return [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('割り当て済みも表示', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(width: 4),
          Switch(
            value: _inboxShowAssigned,
            onChanged: (v) => setState(() => _inboxShowAssigned = v),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
      ValueListenableBuilder<bool>(
        valueListenable: controller.isSyncing,
        builder: (context, syncing, _) => IconButton(
          icon: syncing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync),
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
                  '所属ブロックの終了時刻が現在時刻を過ぎたタスク（未完了）を未割当に戻します（当日分も対象）。ブロックは残します。',
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('キャンセル')),
                  ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('実行')),
                ],
              ),
            );
            if (confirmed != true) return;
            final count = await context.read<TaskProvider>().revertAssignedButIncompleteInboxTasks();
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$count件を未割当に戻しました')));
          },
        ),
      IconButton(
        icon: const Icon(Icons.upload_file),
        tooltip: 'CSVインポート',
        onPressed: () => showDialog<bool>(context: context, builder: (_) => const InboxCsvImportDialog()),
      ),
      IconButton(
        icon: const Icon(Icons.settings),
        tooltip: '設定',
        onPressed: () => setState(() => _showSettingsPanel = !_showSettingsPanel),
      ),
    ];
  }

  List<Widget> _buildActionIconsForCurrentScreen(Color iconColor) {
    switch (_selectedIndex) {
      case 0: // タイムライン → アイコンは日付行「全て閉じる」の左に集約のみ
        return [];
      case 1: // インボックス
        return _buildInboxActions(context);
      case 2: // カレンダー → 表示切替は不要。設定類は2行目右端に表示するためここでは空
        return [];
      case 3: // ルーティン
        final actions = <Widget>[];
        if (_selectedRoutine != null && !_isSelectedRoutineShortcut) {
          actions.insertAll(0, [
            IconButton(
              icon: Icon(Icons.visibility, color: iconColor),
              tooltip: '1日のルーティンをレビュー',
              onPressed: () {
                final rt = _selectedRoutine;
                if (rt == null) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RoutineDayReviewScreen(
                      routineTemplateId: rt.id,
                      routineTitle: rt.title,
                      routineColorHex: rt.color,
                    ),
                  ),
                );
              },
            ),
            IconButton(
              icon: Icon(Icons.schedule, color: iconColor),
              tooltip: 'ルーティン反映',
              onPressed: () {
                final rt = _selectedRoutine;
                if (rt != null) RoutineReflectUI.showConfirmAndReflect(context, rt);
              },
            ),
            IconButton(
              icon: Icon(Icons.event_available, color: iconColor),
              tooltip: '日付を選んで反映',
              onPressed: () {
                final rt = _selectedRoutine;
                if (rt != null) RoutineReflectUI.showPickDatesAndReflect(context, rt);
              },
            ),
            IconButton(
              icon: Icon(Icons.edit, color: iconColor),
              tooltip: 'ルーティン編集',
              onPressed: () {
                final rt = _selectedRoutine;
                if (rt != null) {
                  RoutineDetailActions.editRoutine(context, rt, () => setState(() {}));
                }
              },
            ),
          ]);
        }
        return actions;
      case 4: // プロジェクト
        return [
          if (_selectedProject != null) ...[
            IconButton(
              icon: Icon(
                _projectDetailShowArchived
                    ? Icons.archive
                    : Icons.archive_outlined,
                color: iconColor,
              ),
              tooltip: _projectDetailShowArchived
                  ? 'アーカイブ済みを表示中（タップで隠す）'
                  : 'アーカイブ済みを表示',
              onPressed: () => setState(() {
                _projectDetailShowArchived = !_projectDetailShowArchived;
              }),
            ),
            IconButton(
              icon: Icon(Icons.edit, color: iconColor),
              tooltip: 'プロジェクトを編集',
              onPressed: () =>
                  _subProjectScreenKey.currentState?.openProjectEdit(),
            ),
            IconButton(
              icon: Icon(Icons.refresh, color: iconColor),
              tooltip: '再読込',
              onPressed: () =>
                  _subProjectScreenKey.currentState?.reloadData(),
            ),
          ],
          IconButton(
            icon: Icon(
              _projectHideEmpty.value ? Icons.checklist : Icons.checklist_rtl,
              color: iconColor,
            ),
            tooltip: _projectHideEmpty.value ? '未実施なしを非表示: ON' : '未実施なしを非表示: OFF',
            onPressed: () => setState(() => _projectHideEmpty.value = !_projectHideEmpty.value),
          ),
          IconButton(
            icon: Icon(
              _projectFilterVisible.value ? Icons.filter_alt_off : Icons.filter_alt,
              color: iconColor,
            ),
            tooltip: _projectFilterVisible.value ? 'フィルターを隠す' : 'フィルターを表示',
            onPressed: () => setState(() => _projectFilterVisible.value = !_projectFilterVisible.value),
          ),
          IconButton(
            icon: Icon(Icons.settings, color: iconColor),
            tooltip: 'プロジェクト設定',
            onPressed: () {
              Navigator.of(context).push<Map<String, dynamic>>(
                MaterialPageRoute(
                  builder: (_) => ProjectSettingsScreen(
                    initialTwoColumn: _projectTwoColumnMode.value,
                    initialHideEmpty: _projectHideEmpty.value,
                  ),
                ),
              ).then((res) {
                if (res == null) return;
                if (res.containsKey('twoColumn')) {
                  _projectTwoColumnMode.value = res['twoColumn'] == true;
                }
                if (res.containsKey('hideEmpty')) {
                  _projectHideEmpty.value = res['hideEmpty'] == true;
                }
              });
            },
          ),
        ];
      case 5: // レポート
        return [
          IconButton(
            icon: _isExportingReportCsv
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.download, color: iconColor),
            tooltip: '現在の表示範囲をCSV出力',
            onPressed: _isExportingReportCsv ? null : _exportCurrentReportCsv,
          ),
          IconButton(
            icon: Icon(Icons.settings, color: iconColor),
            tooltip: '設定',
            onPressed: () => setState(() => _showSettingsPanel = !_showSettingsPanel),
          ),
        ];
      case 6: // DB
        return [];
      default:
        return [];
    }
  }

  Widget? _buildFloatingActionButton() {
    if (_selectedIndex == 0) {
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
          buildFab(
            heroTag: 'fab_blank_actual_newui',
            tooltip: '空白の実績を再生',
            icon: Icons.play_arrow,
            onPressed: _isStartingBlankActual ? null : _startBlankActualTask,
          ),
          const SizedBox(width: _timelineFabSpacing),
          buildFab(
            heroTag: 'fab_shortcut_newui',
            tooltip: 'ショートカット',
            icon: Icons.flash_on,
            onPressed: () => timeline_dialogs.showTimelineShortcutDialog(context),
          ),
          const SizedBox(width: _timelineFabSpacing),
          buildFab(
            heroTag: 'fab_pomodoro_newui',
            tooltip: 'ポモドーロ',
            icon: Icons.timer_outlined,
            onPressed: () {
              final block = context.read<TaskProvider>().getBlockAtCurrentTime();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PomodoroScreen(initialBlock: block),
                  fullscreenDialog: true,
                ),
              );
            },
          ),
          const SizedBox(width: _timelineFabSpacing),
          buildFab(
            heroTag: 'fab_add_block_newui',
            tooltip: 'ブロックを追加',
            icon: Icons.event_available,
            onPressed: _isAddingBlock ? null : _addBlockToTimeline,
          ),
        ],
      );
    }
    if (_selectedIndex == 1) {
      return FloatingActionButton(
        heroTag: 'fab_add_inbox_newui',
        onPressed: () async {
          final changed = await showUnifiedScreenDialog<bool>(
            context: context,
            builder: (_) => const InboxTaskAddScreen(),
          );
          if (changed == true && context.mounted) {
            await context.read<TaskProvider>().refreshTasks();
          }
        },
        tooltip: 'タスクを追加',
        child: const Icon(Icons.add),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialBgSyncScheduled) {
      _initialBgSyncScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _requestBackgroundSync();
        if (mounted && _requiresTaskMonitoring(_selectedIndex)) {
          try {
            final state = WidgetsBinding.instance.lifecycleState;
            if (state == null || state == AppLifecycleState.resumed) {
              final now = DateTime.now();
              Provider.of<TaskProvider>(context, listen: false)
                  .startWatchingRunningTasks(
                fromInclusive: now.subtract(const Duration(hours: 12)),
                toExclusive: now.add(const Duration(hours: 12)),
              );
            }
          } catch (_) {}
        }
      });
    }

    final showSettingsOverlay = _showSettingsPanel && _selectedIndex != 2;
    final showCalendarSettingsOverlay =
        _selectedIndex == 2 && _showCalendarSettingsPanel;
    final absorb = showSettingsOverlay || showCalendarSettingsOverlay;

    // 既存UIと同様: タイムライン/インボックスで再生バー表示時はFABを上にずらす
    final bool hasRunningTask = context.select<TaskProvider, bool>(
      (p) => p.runningActualTasks.isNotEmpty,
    );
    final bool isTimelineTab = _selectedIndex == 0;
    final bool isInboxTab = _selectedIndex == 1;
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
    final bool fabNeedsRunningBarOffset =
        runningVisibleNow && (isTimelineTab || isInboxTab);
    final double fabExtraBottomPadding = fabNeedsRunningBarOffset
        ? resolvedRunningBarHeight
        : isInboxTab
            ? (isMobile ? 16.0 : 0.0)
            : 0.0;

    // 既存UIと同様: 「再生バー可視のON/OFFが変わった瞬間」だけFABをスムーズにスライドさせる
    final bool selectedIndexChanged = _lastFabSelectedIndex != null &&
        _lastFabSelectedIndex != _selectedIndex;
    final bool runningVisibleChanged = _lastFabRunningVisible != null &&
        _lastFabRunningVisible != runningVisibleNow;
    final bool allowFabOffsetAnimation = _fabAnimReady &&
        !selectedIndexChanged &&
        runningVisibleChanged &&
        (isTimelineTab || isInboxTab);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _lastFabSelectedIndex = _selectedIndex;
      _lastFabRunningVisible = runningVisibleNow;
      if (!_fabAnimReady) _fabAnimReady = true;
    });

    final Widget? rawFab = _buildFloatingActionButton();
    final bool hideFab = rawFab == null || (_selectedIndex == 0 && _showSettingsPanel);
    final Widget effectiveFab = Offstage(
      offstage: hideFab,
      child: rawFab ?? const SizedBox.shrink(),
    );

    return Scaffold(
      key: _scaffoldKey,
      drawer: isMobile
          ? Drawer(
              child: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView(
                        children: List.generate(
                          _labels.length,
                          (i) => _buildNavMenuItem(
                            context,
                            i,
                            afterTap: () => Navigator.of(context).pop(),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Kant',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: 20,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
      appBar: isMobile
          ? AppBar(
              automaticallyImplyLeading: false,
              title: Text(_labels[_selectedIndex]),
              leading: IconButton(
                icon: const Icon(Icons.menu),
                tooltip: 'メニュー',
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
            )
          : null,
      body: NotificationListener<ReportPeriodDialogRequestNotification>(
        onNotification: (_) {
          if (_selectedIndex == _reportTabIndex) unawaited(_showReportPeriodDialog());
          return true;
        },
        child: Row(
        children: [
          if (!isMobile) ...[
            Material(
              elevation: 0,
              child: Container(
                width: 140,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Divider(height: 1, indent: 12, endIndent: 12),
                    Expanded(
                      child: ListView(
                        children: List.generate(
                          _labels.length,
                          (i) => _buildNavMenuItem(context, i),
                        ),
                      ),
                    ),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final barWidth = constraints.maxWidth;
                        final fontSize = barWidth <= 80 ? 21.0 : 29.0;
                        final horizontalPadding = barWidth <= 80 ? 8.0 : 16.0;
                        final scheme = Theme.of(context).colorScheme;
                        return Padding(
                          padding: EdgeInsets.fromLTRB(
                              horizontalPadding, 10, horizontalPadding, 12),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Kant',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: fontSize,
                                height: 1.2,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            const VerticalDivider(width: 1),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if ((_selectedIndex != 0 &&
                        _selectedIndex != 1 &&
                        _selectedIndex != 2 &&
                        _selectedIndex != 5 &&
                        _selectedIndex != _settingsTabIndex &&
                        !(_selectedIndex == 6 && _dbSubView == DbSubView.hub) &&
                        !(_selectedIndex == 3 && _selectedRoutine == null)) ||
                    (_selectedIndex == _settingsTabIndex &&
                        _settingsSubView != null) ||
                    (_showSettingsPanel && _selectedIndex != 2))
                  _buildTopActionBar(),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // 左ナビ付きレイアウトではウィンドウ全体の MediaQuery.size が残るため、
                      // ルーティン編集など「実パネル幅」基準の判定がずれて表固定になる。子にはパネル寸法を渡す。
                      final mq = MediaQuery.of(context);
                      final w = constraints.maxWidth;
                      final h = constraints.maxHeight;
                      final useLocalSize = w.isFinite &&
                          h.isFinite &&
                          w > 0 &&
                          h > 0;
                      final body = Stack(
                        children: [
                          IgnorePointer(
                            ignoring: absorb,
                            child: _buildBodyContent(),
                          ),
                          if (showCalendarSettingsOverlay)
                            const Positioned.fill(
                                child: CalendarSettingsPanel()),
                          if (showSettingsOverlay)
                            Positioned.fill(
                              child: _settingsSubView == 'project_management'
                                  ? const ProjectCategoryAssignmentScreen(
                                      embedded: true,
                                    )
                                  : SettingsScreen(
                                      embedded: true,
                                      onNavigateToProjectManagement: () =>
                                          setState(() => _settingsSubView =
                                              'project_management'),
                                    ),
                            ),
                        ],
                      );
                      if (!useLocalSize) return body;
                      return MediaQuery(
                        data: mq.copyWith(size: Size(w, h)),
                        child: body,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      ),
      bottomNavigationBar: isMobile
          ? SizedBox(
              height: 64,
              child: _buildMobileBottomNavigationBar(context),
            )
          : null,
      floatingActionButton: AnimatedPadding(
        padding: EdgeInsets.only(bottom: fabExtraBottomPadding),
        duration: allowFabOffsetAnimation
            ? const Duration(milliseconds: 220)
            : Duration.zero,
        curve: Curves.easeOutCubic,
        child: effectiveFab,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
}
