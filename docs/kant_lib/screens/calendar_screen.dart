import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../widgets/calendar_settings.dart';
import '../widgets/calendar_widget.dart';

import 'timeline_screen_v2.dart';
import 'calendar_screen/day_dual_lane_view.dart';

import '../services/calendar_service.dart';
import '../services/app_settings_service.dart';
import 'calendar_screen/week_view.dart';
import 'calendar_screen/helpers.dart' as helpers;
import 'calendar_screen/event_loader.dart' as event_loader;
import 'calendar_screen/header.dart';

import 'calendar_screen/period_sync.dart';
import '../services/block_sync_service.dart';
import '../services/synced_day_service.dart';
import '../services/timeline_version_service.dart';
import '../services/version_cursor_service.dart';
import '../models/synced_day.dart';
import '../providers/task_provider.dart';
import '../services/block_utilities.dart';
import 'dart:async';

class CalendarScreen extends StatefulWidget {
  final CalendarViewType? initialViewType;
  final ValueChanged<String>? onMobileTitleChanged;
  /// 現在フォーカスされている「月」(yyyy-mm-01に正規化)を通知する。
  /// 休日設定画面など、外部画面へ「見ていた月」を引き継ぐ用途。
  final ValueChanged<DateTime>? onFocusedMonthChanged;
  /// false のときヘッダーに「表示切替」（日/週/月/年）を出さない
  final bool showViewSwitchInHeader;
  /// ヘッダー直下の2行目右端に並べるウィジェット（休日設定・カレンダー設定など）
  final List<Widget>? secondRowTrailingActions;

  const CalendarScreen({
    super.key,
    this.initialViewType,
    this.onMobileTitleChanged,
    this.onFocusedMonthChanged,
    this.showViewSwitchInHeader = true,
    this.secondRowTrailingActions,
  });

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  final DateFormat _monthLabelFormatter = DateFormat('M月', 'ja_JP');
  DateTime _focusedDate = DateTime.now();
  DateTime? _selectedDate;
  CalendarSettings _settings = CalendarSettings(
    showTaskMarkers: false, // 月表示の●マークを非表示
    viewType: CalendarViewType.week, // デフォルトは週表示
  );
  bool _isLoading = false;
  final Set<String> _syncedPeriods = {}; // 同期済み期間を追跡
  bool _useDualLaneDayView = true; // PC向け: 予実2列トグル（初期はグリッド表示）
  bool _userChangedView = false; // ユーザー操作で表示種別を変えたか
  // タイムライン実行中バーの可視状態
  // モバイル向けのカード/グリッド切替・表示対象は AppSettingsService を参照
  bool _syncInProgress = false; // 同期の再入防止用
  String? _lastNotifiedMobileTitle;
  DateTime? _lastNotifiedFocusedMonth;

  // 初期スクロール（現在時刻を中央）用のコントローラとフラグ
  final ScrollController _weekScrollController = ScrollController();
  final ScrollController _dayScrollController = ScrollController();
  bool _weekInitialScrolled = false;
  bool _dayInitialScrolled = false;
  StreamSubscription<BlockRescheduleNotice>? _blockRescheduleSub;
  bool _initialSyncScheduled = false;

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _notifyMobileTitle();
    _notifyFocusedMonth();
  }

  @override
  void initState() {
    super.initState();
    // 画面起動時の初期ビュー指定があれば優先
    if (widget.initialViewType != null) {
      _settings = _settings.copyWith(viewType: widget.initialViewType);
      if (widget.initialViewType == CalendarViewType.day) {
        // Prefer current focus if available to avoid unintended fallback to today
        _selectedDate ??= _focusedDate;
        _dayInitialScrolled = false; // 日表示に入るときに初期スクロールを有効化
      } else {
        _selectedDate = null;
        if (widget.initialViewType == CalendarViewType.week) {
          _weekInitialScrolled = false;
        }
      }
    } else {
      // デフォルトで月表示（ユーザ設定があれば後で上書き）
      setState(() {
        _settings = _settings.copyWith(viewType: CalendarViewType.month);
      });
    }
    // 初期表示時は即時描画のみ行い、同期はviewType確定後に1回だけ行う
    _isLoading = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyMobileTitle(force: true);
      _notifyFocusedMonth(force: true);
      // ブロック時刻変更に伴う「前詰め再配置」のオーバー警告を表示
      _blockRescheduleSub?.cancel();
      _blockRescheduleSub =
          BlockUtilities.rescheduleNoticeStream.listen((notice) {
        if (!mounted) return;
        if (notice.overflowMinutes <= 0) return;
        final label = (notice.blockLabel ?? 'ブロック').trim();
        final msg =
            '$label がオーバーしています（超過${notice.overflowMinutes}分）';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      });
    });
    // 既定値をサービスのグローバル値に合わせる
    _settings = _settings.copyWith(
      hideRoutineBlocksWithoutInboxInMonth:
          CalendarService.hideRoutineBlocksWithoutInboxInMonth,
    );
    // ルーティン非表示設定の変更を監視して即時反映
    CalendarService.hideRoutineNotifier.addListener(() {
      if (!mounted) return;
      setState(() {
        _settings = _settings.copyWith(
          hideRoutineBlocksWithoutInboxInMonth:
              CalendarService.hideRoutineBlocksWithoutInboxInMonth,
        );
      });
    });

    // 「イベントのみ表示」設定の変更を監視して即時反映
    AppSettingsService.calendarShowEventsOnlyNotifier.addListener(() {
      if (!mounted) return;
      setState(() {});
    });

    // 休日設定の変更を監視して即時反映
    CalendarService.holidayChangeNotifier.addListener(() {
      if (!mounted) return;
      setState(() {});
    });

    // Load persisted calendar view settings
    if (widget.initialViewType == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await AppSettingsService.initialize();
        // デフォルト表示設定のみを使用（未設定なら月）
        final defaultView = AppSettingsService.getString(
            AppSettingsService.keyCalendarDefaultViewType);
        final chosen = defaultView != null
            ? (helpers.parseViewType(defaultView) ?? CalendarViewType.month)
            : CalendarViewType.month;
        if (!_userChangedView) {
          setState(() {
            _settings = _settings.copyWith(viewType: chosen);
            if (chosen == CalendarViewType.day) {
              _selectedDate ??= _focusedDate;
            }
          });
          _scheduleInitialSyncIfNeeded();
        }
      });
    } else {
      // initialViewType が指定されている場合は、そのviewTypeで一度だけ同期する
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduleInitialSyncIfNeeded();
      });
    }
  }

  void _scheduleInitialSyncIfNeeded() {
    if (_initialSyncScheduled) return;
    _initialSyncScheduled = true;
    _syncCurrentPeriod();
  }

  @override
  Widget build(BuildContext context) {
    // Hive即時表示: 初回からカレンダー本体を描画し、同期はバックグラウンドで実行
    return Column(
      children: [
        // バックグラウンド同期中は薄いインジケータを表示
        if (_isLoading)
          const LinearProgressIndicator(),
        // モバイルのAppBarから表示種別変更が行われた場合に反映
        ValueListenableBuilder<String>(
          valueListenable: AppSettingsService.calendarViewTypeNotifier,
          builder: (context, value, _) {
            CalendarViewType? next;
            switch (value) {
              case 'day':
                next = CalendarViewType.day;
                break;
              case 'week':
                next = CalendarViewType.week;
                break;
              case 'month':
                next = CalendarViewType.month;
                break;
              case 'year':
                next = CalendarViewType.year;
                break;
            }
            if (next != null && next != _settings.viewType) {
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                if (!mounted) return;
                setState(() {
                  _settings = _settings.copyWith(
                    viewType: next,
                    showYearView: next == CalendarViewType.year,
                  );
                  if (next == CalendarViewType.day) {
                    _selectedDate ??= _focusedDate;
                    _dayInitialScrolled = false;
                  } else {
                    _selectedDate = null;
                    if (next == CalendarViewType.week) {
                      _weekInitialScrolled = false;
                    }
                  }
                });
                await _syncCurrentPeriod();
              });
            }
            return const SizedBox.shrink();
          },
        ),
        // PCのみヘッダーを表示。モバイルはAppBarで切り替えを提供
        LayoutBuilder(builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 800;
          if (isMobile) return const SizedBox.shrink();
          return CalendarHeader(
            viewType: _settings.viewType,
            focusedDate: _focusedDate,
            useDualLaneDayView: _useDualLaneDayView,
            hasSelectedDateInDay: _selectedDate != null,
            showEventsOnly:
                AppSettingsService.calendarShowEventsOnlyNotifier.value,
            onPrevPeriod: _goPrevPeriod,
            onNextPeriod: _goNextPeriod,
            onChangeView: (next) async {
              await AppSettingsService.setString(
                  AppSettingsService.keyLastViewType, next.name);
            },
            onDualLaneChanged: (v) {
              setState(() => _useDualLaneDayView = v);
            },
            onShowEventsOnlyChanged: (v) {
              AppSettingsService.setBool(
                  AppSettingsService.keyCalendarShowEventsOnly, v);
            },
            showViewSwitch: widget.showViewSwitchInHeader,
          );
        }),
        // 2行目: 右端に外から渡されたアクション（休日設定・カレンダー設定など）
        if (widget.secondRowTrailingActions != null &&
            widget.secondRowTrailingActions!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: widget.secondRowTrailingActions!,
            ),
          ),
        // カレンダー表示（モバイルで日/週はスワイプで前後移動可能に）
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isMobile = constraints.maxWidth < 900;

              Widget content;
              if (_settings.viewType == CalendarViewType.day) {
                final DateTime initialDay = _selectedDate ?? _focusedDate;
                final bool showInlineDateNavigation = constraints.maxWidth < 800;
                final bool isDesktop = constraints.maxWidth >= 900;

                // デスクトップ（日表示）は「予実2列」トグルで列数のみを切替え、
                // 表示自体は常にグリッドで統一する（= OFFでもグリッドが消えない）。
                if (isDesktop ||
                    AppSettingsService.mobileDayUseGridNotifier.value) {
                  content = CalendarDayDualLaneView(
                    key: ValueKey('day_${initialDay.toIso8601String()}'),
                    selectedDate: initialDay,
                    settings: _settings,
                    dayScrollController: _dayScrollController,
                    isDayInitialScrolled: () => _dayInitialScrolled,
                    markDayInitialScrolled: () {
                      _dayInitialScrolled = true;
                    },
                    onDateChanged: (d) async {
                      setState(() {
                        _selectedDate = d;
                        _focusedDate = d;
                        _dayInitialScrolled = false;
                      });
                      await _syncCurrentPeriod();
                    },
                    // PCは上部に CalendarHeader があるため非表示
                    showInlineDateNavigation: showInlineDateNavigation,
                    // PCはトグルの値で単列/2列を切替。モバイルは従来どおり（両方/片方）設定に従う。
                    useDualLaneColumns: isDesktop ? _useDualLaneDayView : true,
                  );
                } else {
                  final DateTime initialDay = _selectedDate ?? _focusedDate;
                  content = TimelineScreenV2(
                    key: ValueKey('tl_${initialDay.toIso8601String()}'),
                    initialDate: initialDay,
                    showInlineDateNavigation: showInlineDateNavigation,
                    onSelectedDateChanged: (d) {
                      setState(() {
                        _selectedDate = d;
                      });
                    },
                    onRunningBarVisibleChanged: (v) {},
                  );
                }
                // モバイル日表示はスワイプ対応
                return isMobile ? _wrapWithSwipe(content) : content;
              } else if (_settings.viewType == CalendarViewType.week) {
                content = CalendarWeekView(
                  focusedDate: _focusedDate,
                  settings: _settings,
                  showEventsOnly:
                      AppSettingsService.calendarShowEventsOnlyNotifier.value,
                  weekScrollController: _weekScrollController,
                  isWeekInitialScrolled: () => _weekInitialScrolled,
                  markWeekInitialScrolled: () {
                    _weekInitialScrolled = true;
                  },
                  onTapHeaderGoToDay: (day) async {
                    setState(() {
                      _userChangedView = true;
                      _selectedDate = day;
                      _focusedDate = day;
                    });
                    await AppSettingsService.setString(
                        AppSettingsService.keyLastViewType,
                        CalendarViewType.day.name);
                  },
                );
                // モバイル週表示はスワイプ対応
                return isMobile ? _wrapWithSwipe(content) : content;
              } else {
                // 月・年もモバイルでは左右スワイプで前後移動
                content = CalendarWidget(
                  focusedDate: _focusedDate,
                  selectedDate: _selectedDate,
                  settings: _settings,
                  onDaySelected: _onDaySelectedWithSync,
                  onPageChanged: _onPageChangedWithSync,
                  eventLoader: _getEventsForDay,
                  onYearViewDaySelected: _onYearViewDaySelected,
                  onMonthTitleTap: (monthDate) {
                    setState(() {
                      _userChangedView = true;
                      _focusedDate = monthDate;
                      _settings = _settings.copyWith(
                        viewType: CalendarViewType.month,
                        showYearView: false,
                      );
                      _selectedDate = null;
                    });
                    // Persist month view selection from year view
                    AppSettingsService.setString(
                        AppSettingsService.keyLastViewType,
                        CalendarViewType.month.name);
                  },
                );
                return isMobile ? _wrapWithSwipe(content) : content;
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _wrapWithSwipe(Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) async {
        final v = details.primaryVelocity ?? 0;
        if (v < 0) {
          await _goNextPeriod();
        } else if (v > 0) {
          await _goPrevPeriod();
        }
      },
      child: child,
    );
  }

  void _notifyMobileTitle({bool force = false}) {
    final callback = widget.onMobileTitleChanged;
    if (callback == null) return;
    final String nextTitle =
        _settings.viewType == CalendarViewType.month
            ? _monthLabelFormatter.format(_focusedDate)
            : 'カレンダー';
    if (!force && _lastNotifiedMobileTitle == nextTitle) {
      return;
    }
    _lastNotifiedMobileTitle = nextTitle;
    callback(nextTitle);
  }

  void _notifyFocusedMonth({bool force = false}) {
    final callback = widget.onFocusedMonthChanged;
    if (callback == null) return;
    final month = DateTime(_focusedDate.year, _focusedDate.month, 1);
    final last = _lastNotifiedFocusedMonth;
    if (!force &&
        last != null &&
        last.year == month.year &&
        last.month == month.month) {
      return;
    }
    _lastNotifiedFocusedMonth = month;
    callback(month);
  }

  Future<void> _goNextPeriod() async {
    if (_settings.viewType == CalendarViewType.day) {
      final base = _selectedDate ?? DateTime.now();
      final next = base.add(const Duration(days: 1));
      setState(() {
        _selectedDate = next;
        _focusedDate = next;
        _dayInitialScrolled = false;
      });
      await _syncCurrentPeriod();
    } else if (_settings.viewType == CalendarViewType.week) {
      setState(() {
        _focusedDate = _focusedDate.add(const Duration(days: 7));
      });
      await _syncCurrentPeriod();
    } else if (_settings.viewType == CalendarViewType.month) {
      setState(() {
        _focusedDate = DateTime(_focusedDate.year, _focusedDate.month + 1, 1);
      });
      await _syncCurrentPeriod();
    } else if (_settings.viewType == CalendarViewType.year) {
      setState(() {
        _focusedDate = DateTime(_focusedDate.year + 1, 1, 1);
      });
      await _syncCurrentPeriod();
    }
  }

  Future<void> _goPrevPeriod() async {
    if (_settings.viewType == CalendarViewType.day) {
      final base = _selectedDate ?? DateTime.now();
      final prev = base.subtract(const Duration(days: 1));
      setState(() {
        _selectedDate = prev;
        _focusedDate = prev;
        _dayInitialScrolled = false;
      });
      await _syncCurrentPeriod();
    } else if (_settings.viewType == CalendarViewType.week) {
      setState(() {
        _focusedDate = _focusedDate.subtract(const Duration(days: 7));
      });
      await _syncCurrentPeriod();
    } else if (_settings.viewType == CalendarViewType.month) {
      setState(() {
        _focusedDate = DateTime(_focusedDate.year, _focusedDate.month - 1, 1);
      });
      await _syncCurrentPeriod();
    } else if (_settings.viewType == CalendarViewType.year) {
      setState(() {
        _focusedDate = DateTime(_focusedDate.year - 1, 1, 1);
      });
      await _syncCurrentPeriod();
    }
  }

  void _onYearViewDaySelected(DateTime selectedDay) async {
    final width = MediaQuery.of(context).size.width;
    final isPc = width >= 900;
    setState(() {
      _userChangedView = true;
      _focusedDate = selectedDay;
      _selectedDate = isPc ? null : selectedDay;
    });
    await AppSettingsService.setString(AppSettingsService.keyLastViewType,
        isPc ? CalendarViewType.week.name : CalendarViewType.day.name);
  }

  List<dynamic> _getEventsForDay(DateTime day) {
    return event_loader.getEventsForDay(
      context: context,
      settings: _settings,
      day: day,
    );
  }

  /// 現在の表示期間に応じてスマート同期を実行
  Future<void> _syncCurrentPeriod() async {
    if (_syncInProgress) return;

    _syncInProgress = true;
    setState(() {
      _isLoading = true;
    });

    try {
      final plan = buildPeriodSyncPlan(
        viewType: _settings.viewType,
        focusedDate: _focusedDate,
        selectedDate: _selectedDate,
      );
      final periodKey = plan.periodKey;
      final syncFuture = plan.syncFuture;

      // 期間内の日付リストを取得し、差分判定で「同期すべき日」だけに絞る
      final periodDates = computePeriodDates(
        viewType: _settings.viewType,
        focusedDate: _focusedDate,
        selectedDate: _selectedDate,
      );
      // カーソル以降に変更されたdayVersionsを1クエリで取得（差分同期）
      final cursor =
          await VersionCursorService.load(SyncedDayKind.timeline);
      final feed = await TimelineVersionService.fetchUpdatesSince(
        kind: SyncedDayKind.timeline,
        cursor: cursor,
      );
      final changedDocs = <String, DayVersionDoc>{
        for (final doc in feed.entries) doc.dateKey: doc,
      };

      // 期間内の各日について同期要否を判定
      // - 変更セットにある日: リモートで更新あり → 同期必要
      // - SyncedDayなし or status!=ready or hashなし: 未同期 → 同期必要
      // - それ以外: カーソル以降変更なし → スキップ
      final datesToSync = <DateTime>[];
      final versionDocByDate = <DateTime, DayVersionDoc?>{};

      if (feed.hasMore) {
        // 変更が多すぎてページが溢れた場合は現在期間を全件同期（安全側に倒す）
        for (final date in periodDates) {
          datesToSync.add(date);
          versionDocByDate[date] = null;
        }
      } else {
        for (final date in periodDates) {
          final dateKey = TimelineVersionService.dateKey(date);
          final local =
              await SyncedDayService.get(date, SyncedDayKind.timeline);
          if (changedDocs.containsKey(dateKey)) {
            datesToSync.add(date);
            versionDocByDate[date] = changedDocs[dateKey];
          } else if (local == null ||
              local.status != SyncedDayStatus.ready ||
              local.lastVersionHash == null) {
            datesToSync.add(date);
            versionDocByDate[date] = null;
          }
        }
      }

      // カレンダーエントリの同期と、ブロックは「同期すべき日」だけ取得
      await syncFuture;
      final syncService = BlockSyncService();
      for (final date in datesToSync) {
        await syncService.syncBlocksByDayKey(date);
        var versionDoc = versionDocByDate[date];
        // 初回同期の日はversion docを個別フェッチしてhashを保存
        versionDoc ??= await TimelineVersionService.fetchRemoteDoc(date);
        await SyncedDayService.recordFetch(
          date: date,
          kind: SyncedDayKind.timeline,
          versionHash: versionDoc?.hash,
          versionWriteAt: versionDoc?.lastWriteAt,
        );
      }

      // カーソルを更新（変更があった場合のみ）
      if (feed.entries.isNotEmpty) {
        await VersionCursorService.save(SyncedDayKind.timeline, feed.cursor);
      }

      // 同期結果をUIへ反映
      try {
        if (mounted) {
          await context.read<TaskProvider>().refreshTasks(showLoading: false);
        }
      } catch (_) {}

      _syncedPeriods.add(periodKey);
    } catch (_) {
      // sync error: continue with reduced data
    } finally {
      _syncInProgress = false;
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// ページ変更時の同期
  Future<void> _onPageChangedWithSync(DateTime focusedDay) async {
    setState(() {
      _focusedDate = focusedDay;
    });

    // 新しい期間の同期を実行
    await _syncCurrentPeriod();
  }

  /// 日選択時の同期
  Future<void> _onDaySelectedWithSync(
      DateTime selectedDay, DateTime focusedDay) async {
    final width = MediaQuery.of(context).size.width;
    final isPc = width >= 900;
    setState(() {
      _userChangedView = true;
      _focusedDate = selectedDay;
      _selectedDate = isPc ? null : selectedDay;
    });

    // Notifierへ委譲（切替と同期を一元化）
    await AppSettingsService.setString(AppSettingsService.keyLastViewType,
        isPc ? CalendarViewType.week.name : CalendarViewType.day.name);
  }

  @override
  void dispose() {
    _blockRescheduleSub?.cancel();
    _weekScrollController.dispose();
    _dayScrollController.dispose();
    super.dispose();
  }
}
