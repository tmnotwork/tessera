import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// import '../services/actual_task_service.dart';
import '../services/project_service.dart';
import 'package:fl_chart/fl_chart.dart';
import '../widgets/report_navigation.dart';
import '../services/app_settings_service.dart';
import '../app/reporting/report_data_repository.dart';
import '../app/reporting/y_axis_scale.dart';
import '../services/sync_manager.dart';
import '../services/report_sync_service.dart';

// WeekNavigationNotification は ../widgets/report_navigation.dart で定義

class WeeklyReportScreen extends StatefulWidget {
  final DateTime? initialDate;
  final DateTime? rangeStart;
  final DateTime? rangeEnd;
  final bool disableNavigation;
  final VoidCallback? onExportCsv;
  final bool isExportingCsv;
  final VoidCallback? onSettingsTap;

  const WeeklyReportScreen({
    super.key,
    this.initialDate,
    this.rangeStart,
    this.rangeEnd,
    this.disableNavigation = false,
    this.onExportCsv,
    this.isExportingCsv = false,
    this.onSettingsTap,
  });

  @override
  State<WeeklyReportScreen> createState() => _WeeklyReportScreenState();
}

class _WeeklyReportScreenState extends State<WeeklyReportScreen> {
  static const String _otherProjectId = '__other__';
  late DateTime _weekStart; // start of range
  int _rangeDays = 7;
  DateTime? _highlightDate; // 強調表示する基準日（カレンダーで選択された日）
  Map<DateTime, Map<String, int>> _minutesByDayProject =
      {}; // day -> projectId -> minutes
  Map<String, int> _weeklyProjectTotals = {}; // projectId -> minutes
  Map<DateTime, Map<String, int>> _plannedMinutesByDayProject =
      {}; // day -> projectId -> planned minutes
  Map<String, int> _weeklyProjectTotalsPlanned =
      {}; // projectId -> planned minutes
  bool _loading = true;
  bool _showOverlayTooltip = false;
  String _overlayTooltipText = '';
  /// 選択した棒の上にツールチップを出すためのタッチ位置（親Stack座標）
  Offset? _tooltipOffset;
  // リアルタイム購読は行わず、明示操作時のみ再読込（ちらつき防止）
  // 'time' | 'project'
  String _groupingMode = 'time';
  static const Set<DataSyncTarget> _reportTargets = {
    DataSyncTarget.actualTasks,
    DataSyncTarget.blocks,
  };
  final ReportDataRepository _reportRepo = ReportDataRepository.instance;
  StreamSubscription<void>? _repoSubscription;
  // 差分同期はアプリバーに移動したため、この画面内では同期状態表示を持たない

  String _formatMinutes(int minutes) {
    // レポート画面は表示形式を HH:MM に統一（例: 01:05）
    final sign = minutes < 0 ? '-' : '';
    final v = minutes.abs();
    final h = v ~/ 60;
    final m = v % 60;
    final hh = h.toString().padLeft(2, '0'); // 100時間超でもそのまま表示
    final mm = m.toString().padLeft(2, '0');
    return '$sign$hh:$mm';
  }

  DateTime _dateOnly(DateTime dt) {
    final d = dt.toLocal();
    return DateTime(d.year, d.month, d.day);
  }

  bool get _isCustomRange =>
      widget.rangeStart != null && widget.rangeEnd != null;

  bool get _navigationEnabled => !widget.disableNavigation && !_isCustomRange;

  void _applyCustomRange(DateTime start, DateTime end) {
    final startDay = _dateOnly(start);
    final endDay = _dateOnly(end);
    final normalizedStart = startDay.isBefore(endDay) ? startDay : endDay;
    final normalizedEnd = startDay.isBefore(endDay) ? endDay : startDay;
    _weekStart = normalizedStart;
    _rangeDays = normalizedEnd.difference(normalizedStart).inDays + 1;
    if (_rangeDays < 1) _rangeDays = 1;
    _highlightDate = null;
  }

  @override
  void initState() {
    super.initState();
    if (_isCustomRange) {
      _applyCustomRange(widget.rangeStart!, widget.rangeEnd!);
    } else {
      final base = _dateOnly(widget.initialDate ?? DateTime.now());
      _weekStart = _computeWeekStart(base);
      _rangeDays = 7;
      _highlightDate = base;
    }
    _groupingMode = AppSettingsService.getString(
            AppSettingsService.keyReportWeeklyGrouping) ??
        'time';
    _repoSubscription = _reportRepo.changes.listen((_) {
      if (!mounted) return;
      _refreshFromHive();
    });
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant WeeklyReportScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_isCustomRange) {
      final startChanged = widget.rangeStart != oldWidget.rangeStart;
      final endChanged = widget.rangeEnd != oldWidget.rangeEnd;
      if (startChanged || endChanged) {
        _applyCustomRange(
          widget.rangeStart ?? DateTime.now(),
          widget.rangeEnd ?? DateTime.now(),
        );
        unawaited(_load());
      }
    } else {
      final newBase = _dateOnly(widget.initialDate ?? DateTime.now());
      final currentBase = _highlightDate != null
          ? _dateOnly(_highlightDate!)
          : _dateOnly(_getEnd(_weekStart));
      if (newBase != currentBase) {
        _weekStart = _computeWeekStart(newBase);
        _rangeDays = 7;
        _highlightDate = newBase;
        unawaited(_load());
      }
    }
  }

  DateTime _getEnd(DateTime start) =>
      start.add(Duration(days: _rangeDays - 1));

  DateTime _computeWeekStart(DateTime date) {
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
    final delta = (date.weekday - weekStartDow + 7) % 7;
    final startOfWeek = date.subtract(Duration(days: delta));
    return DateTime(startOfWeek.year, startOfWeek.month, startOfWeek.day);
  }

  Future<void> _load({bool runSync = true}) async {
    setState(() => _loading = true);

    // 期間を計算（開始日は date-only、end は exclusive）
    final start = _weekStart;
    final end = start.add(Duration(days: _rangeDays));

    // 同期を実行（表示前に必ず完了させる）
    if (runSync) {
      try {
        final result = await ReportSyncService.ensureRange(start: start, end: end);
        if (!result.success) {
          // エラー時は再試行 UI を表示
          if (mounted) {
            setState(() {
              _loading = false;
            });
          }
          // エラーは表示するが、ローカルデータは表示する
          // TODO: エラー表示UIを追加
        }
      } catch (e) {
        // エラー時もローカルデータは表示する
        if (mounted) {
          setState(() {
            _loading = false;
          });
        }
        // TODO: エラー表示UIを追加
      }
    }

    // 表示直前にキャッシュを再構築（タイムラインでブロック変更後も「開いただけ」で最新を表示）
    _reportRepo.refreshCache();
    // 同期完了後、ローカル集計を表示
    final data = _reportRepo.loadWeeklySummary(
      _weekStart,
      days: _rangeDays,
    );
    if (mounted) {
      setState(() {
        _minutesByDayProject = data.actualByDayProject.map(
          (key, value) => MapEntry(key, Map<String, int>.from(value)),
        );
        _plannedMinutesByDayProject = data.plannedByDayProject.map(
          (key, value) => MapEntry(key, Map<String, int>.from(value)),
        );
        _weeklyProjectTotals =
            Map<String, int>.from(data.weeklyActualTotals);
        _weeklyProjectTotalsPlanned =
            Map<String, int>.from(data.weeklyPlannedTotals);
        _loading = false;
      });
    }
  }

  void _changeWeek(int deltaWeeks) {
    setState(() {
      _weekStart = _weekStart.add(Duration(days: _rangeDays * deltaWeeks));
    });
    unawaited(_load());
  }

  String _periodLabel() {
    // 日付のみに正規化して表示（タイムゾーンで空欄にならないように。モック同様に明示的な DateTime で確実に）
    final start = DateTime(_weekStart.year, _weekStart.month, _weekStart.day);
    final end = _getEnd(start);
    final endDate = DateTime(end.year, end.month, end.day);
    const locale = 'ja_JP';
    if (_isCustomRange) {
      if (start.year == endDate.year) {
        final startStr = DateFormat('yyyy/MM/dd', locale).format(start);
        final endStr = DateFormat('MM/dd', locale).format(endDate);
        return '$startStr - $endStr';
      }
      final startStr = DateFormat('yyyy/MM/dd', locale).format(start);
      final endStr = DateFormat('yyyy/MM/dd', locale).format(endDate);
      return '$startStr - $endStr';
    }
    final fmt = DateFormat('MM/dd', locale);
    return '${fmt.format(start)} - ${fmt.format(endDate)}';
  }

  Widget _buildPeriodNavigator() {
    final scheme = Theme.of(context).colorScheme;
    // 背景と同化しないよう、明示的なコントラスト色（ライト: 濃い黒、ダーク: 明るい白）
    final labelColor = scheme.brightness == Brightness.dark
        ? const Color(0xFFEEEEEE)
        : const Color(0xFF1D1D1D);
    final labelStyle =
        Theme.of(context).textTheme.titleSmall?.copyWith(
              color: labelColor,
              fontWeight: FontWeight.w600,
            ) ??
            TextStyle(color: labelColor, fontWeight: FontWeight.w600, fontSize: 14);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hoverOverlay =
        isDark ? scheme.onSurface.withOpacity(0.08) : scheme.surfaceContainerHigh;
    final pressedOverlay =
        isDark ? scheme.onSurface.withOpacity(0.12) : scheme.surfaceContainerHighest;

    Color _overlayFor(Set<WidgetState> states, bool enabled) {
      if (!enabled) return Colors.transparent;
      if (states.contains(WidgetState.pressed)) return pressedOverlay;
      if (states.contains(WidgetState.hovered) || states.contains(WidgetState.focused)) {
        return hoverOverlay;
      }
      return Colors.transparent;
    }

    Widget buildSegment({
      required Widget child,
      required VoidCallback? onTap,
      required BorderRadius borderRadius,
      EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 10),
      String? tooltip,
    }) {
      final segment = InkWell(
        onTap: onTap,
        mouseCursor:
            onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
        borderRadius: borderRadius,
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => _overlayFor(states, onTap != null),
        ),
        child: Container(
          height: 36,
          padding: padding,
          alignment: Alignment.center,
          child: child,
        ),
      );
      return tooltip == null ? segment : Tooltip(message: tooltip, child: segment);
    }

    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: _navigationEnabled
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  buildSegment(
                    tooltip: '前週',
                    onTap: () => _changeWeek(-1),
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(12),
                    ),
                    child:
                        Icon(Icons.chevron_left, color: scheme.onSurface, size: 20),
                  ),
                  Flexible(
                    child: buildSegment(
                      tooltip: 'レポート期間を選択',
                      onTap: () => const ReportPeriodDialogRequestNotification()
                          .dispatch(context),
                      borderRadius: BorderRadius.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        _periodLabel(),
                        style: labelStyle,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ),
                  buildSegment(
                    tooltip: '次週',
                    onTap: () => _changeWeek(1),
                    borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(12),
                    ),
                    child:
                        Icon(Icons.chevron_right, color: scheme.onSurface, size: 20),
                  ),
                ],
              )
            : buildSegment(
                tooltip: 'レポート期間を選択',
                onTap: () =>
                    const ReportPeriodDialogRequestNotification().dispatch(
                      context,
                    ),
                borderRadius: BorderRadius.circular(12),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  _periodLabel(),
                  style: labelStyle,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
      ),
    );
  }

  void _refreshFromHive() {
    if (!mounted) return;
    _reportRepo.refreshCache();
    final data = _reportRepo.loadWeeklySummary(
      _weekStart,
      days: _rangeDays,
    );
    setState(() {
      _minutesByDayProject = data.actualByDayProject.map(
        (key, value) => MapEntry(key, Map<String, int>.from(value)),
      );
      _plannedMinutesByDayProject = data.plannedByDayProject.map(
        (key, value) => MapEntry(key, Map<String, int>.from(value)),
      );
      _weeklyProjectTotals =
          Map<String, int>.from(data.weeklyActualTotals);
      _weeklyProjectTotalsPlanned =
          Map<String, int>.from(data.weeklyPlannedTotals);
    });
  }

  Future<void> _ensureDataFreshness({required bool forceHeavy}) async {
    try {
      if (forceHeavy) {
        await SyncManager.syncDataFor(_reportTargets, forceHeavy: true);
        // 同期結果の可視化は行わない（UI表示なし）
      } else {
        await SyncManager.syncIfStale(_reportTargets);
        // 同期結果の可視化は行わない（UI表示なし）
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('差分同期に失敗しました: $e')),
      );
    }
  }

  String _projectName(String projectId) {
    if (projectId == _otherProjectId) return 'その他';
    if (projectId.isEmpty) return '未分類';
    final p = ProjectService.getProjectById(projectId);
    return p?.name ?? '未分類';
  }

  int _maxProjectsForWidth(double widthPx) {
    if (widthPx < 420) return 4;
    if (widthPx < 600) return 5;
    if (widthPx < 800) return 7;
    if (widthPx < 1000) return 9;
    return 12;
  }

  int _labelIntervalForRange() {
    if (_rangeDays <= 10) return 1;
    if (_rangeDays <= 21) return 2;
    if (_rangeDays <= 45) return 3;
    if (_rangeDays <= 90) return 7;
    if (_rangeDays <= 180) return 14;
    return 30;
  }

  List<({String projectId, int plannedMinutes, int actualMinutes})>
      _buildProjectChartEntries(double widthPx) {
    final ids = _projectIdsInWeekSorted();
    if (ids.isEmpty) return const [];

    final maxProjects = _maxProjectsForWidth(widthPx);
    if (ids.length <= maxProjects) {
      return ids
          .map((pid) => (
                projectId: pid,
                plannedMinutes: _weeklyProjectTotalsPlanned[pid] ?? 0,
                actualMinutes: _weeklyProjectTotals[pid] ?? 0,
              ))
          .toList();
    }

    final takeN = (maxProjects - 1).clamp(1, ids.length);
    final topIds = ids.take(takeN).toList();
    final otherIds = ids.skip(takeN);
    int otherPlanned = 0;
    int otherActual = 0;
    for (final pid in otherIds) {
      otherPlanned += _weeklyProjectTotalsPlanned[pid] ?? 0;
      otherActual += _weeklyProjectTotals[pid] ?? 0;
    }

    final entries = <({String projectId, int plannedMinutes, int actualMinutes})>[
      ...topIds.map((pid) => (
            projectId: pid,
            plannedMinutes: _weeklyProjectTotalsPlanned[pid] ?? 0,
            actualMinutes: _weeklyProjectTotals[pid] ?? 0,
          )),
    ];
    if (otherPlanned != 0 || otherActual != 0) {
      entries.add((
        projectId: _otherProjectId,
        plannedMinutes: otherPlanned,
        actualMinutes: otherActual,
      ));
    }
    return entries;
  }

  List<String> _projectIdsInWeekSorted() {
    // sort by combined (actual + planned) totals desc for stable stack order
    final Set<String> idSet = {
      ..._weeklyProjectTotals.keys,
      ..._weeklyProjectTotalsPlanned.keys,
    };
    final ids = idSet.toList();
    int totalOf(String pid) =>
        (_weeklyProjectTotals[pid] ?? 0) +
        (_weeklyProjectTotalsPlanned[pid] ?? 0);
    ids.sort((a, b) {
      if (a.isEmpty && b.isEmpty) return 0;
      if (a.isEmpty) return 1;
      if (b.isEmpty) return -1;
      return totalOf(b).compareTo(totalOf(a));
    });
    return ids;
  }

  Color _projectColor(String projectId) {
    // Stable color from projectId hash
    final hash = projectId.hashCode;
    final hue = (hash % 360).toDouble();
    return HSLColor.fromAHSL(1.0, hue, 0.5, 0.55).toColor();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<WeekNavigationNotification>(
      onNotification: (notification) {
        if (notification.targetDate != null) {
          // 特定の日付が指定された場合
          final base = _dateOnly(notification.targetDate!);
          setState(() {
            _weekStart = base.subtract(Duration(days: _rangeDays - 1));
            _highlightDate = notification.highlightDate ?? base;
          });
          unawaited(_load());
        } else if (notification.deltaWeeks == 0) {
          // 今週
          final base = _dateOnly(DateTime.now());
          setState(() {
            _weekStart = base.subtract(Duration(days: _rangeDays - 1));
            _highlightDate = base;
          });
          unawaited(_load());
        } else {
          // 前週・次週
          _changeWeek(notification.deltaWeeks);
        }
        return true;
      },
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(builder: (context, constraints) {
              final double chartHeight = (() {
                final h =
                    constraints.maxHeight.isFinite && constraints.maxHeight > 0
                        ? constraints.maxHeight * 0.45
                        : 320.0;
                return h.clamp(240.0, 520.0);
              })();
              return SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(child: _buildPeriodNavigator()),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                SizedBox(
                                    width: 180,
                                    height: 36,
                                    child: DropdownButtonFormField<String>(
                                      isExpanded: true,
                                      value: _groupingMode,
                                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                        color: Theme.of(context).colorScheme.onSurface,
                                      ),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        filled: true,
                                        fillColor: Theme.of(context).colorScheme.surface,
                                        border: OutlineInputBorder(
                                          borderSide: BorderSide(
                                            color: Theme.of(context).colorScheme.outlineVariant,
                                          ),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderSide: BorderSide(
                                            color: Theme.of(context).colorScheme.outlineVariant,
                                          ),
                                        ),
                                        contentPadding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                        constraints: const BoxConstraints(minHeight: 36, maxHeight: 36),
                                      ),
                                      items: const [
                                        DropdownMenuItem<String>(
                                          value: 'time',
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text('日ごと'),
                                          ),
                                        ),
                                        DropdownMenuItem<String>(
                                          value: 'project',
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text('プロジェクトごと'),
                                          ),
                                        ),
                                      ],
                                      onChanged: (value) async {
                                        if (value == null || value == _groupingMode) {
                                          return;
                                        }
                                        setState(() => _groupingMode = value);
                                        await AppSettingsService.setString(
                                          AppSettingsService.keyReportWeeklyGrouping,
                                          value,
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  if (widget.onExportCsv != null)
                                    IconButton(
                                      icon: widget.isExportingCsv
                                          ? SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(Icons.download),
                                      tooltip: '現在の表示範囲をCSV出力',
                                      onPressed: widget.isExportingCsv ? null : widget.onExportCsv,
                                    ),
                                  if (widget.onSettingsTap != null)
                                    IconButton(
                                      icon: const Icon(Icons.settings),
                                      tooltip: '設定',
                                      onPressed: widget.onSettingsTap,
                                    ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                      child: SizedBox(
                        height: chartHeight,
                        child: _buildWeeklyBarChart(
                          context,
                          chartHeight: chartHeight,
                          widthPx: constraints.maxWidth,
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    // 合計リスト（長い場合にページ全体でスクロール）
                    SizedBox(
                      height: null,
                      child: _buildWeeklyTotalsList(context),
                    ),
                  ],
                ),
              );
            }),
    );
  }

  Widget _buildWeeklyBarChart(
    BuildContext context, {
    required double chartHeight,
    required double widthPx,
  }) {
    final projectIds = _projectIdsInWeekSorted();
    final projectChartEntries = _groupingMode == 'project'
        ? _buildProjectChartEntries(widthPx)
        : const <({String projectId, int plannedMinutes, int actualMinutes})>[];

    List<BarChartGroupData> barGroups = [];
    double dataMaxHours = 0.0;

    if (_groupingMode == 'time') {
      final days =
          List.generate(_rangeDays, (i) => _weekStart.add(Duration(days: i)));
      for (int x = 0; x < days.length; x++) {
        final day = days[x];
        final dataActual = _minutesByDayProject[day] ?? {};
        final dataPlanned = _plannedMinutesByDayProject[day] ?? {};

        double cumulativeA = 0.0;
        final List<BarChartRodStackItem> stacksA = [];
        for (final pid in projectIds) {
          final mins = (dataActual[pid] ?? 0).toDouble();
          if (mins <= 0) continue;
          final hours = mins / 60.0;
          stacksA.add(BarChartRodStackItem(
              cumulativeA, cumulativeA + hours, _projectColor(pid)));
          cumulativeA += hours;
        }

        double cumulativeP = 0.0;
        final List<BarChartRodStackItem> stacksP = [];
        for (final pid in projectIds) {
          final mins = (dataPlanned[pid] ?? 0).toDouble();
          if (mins <= 0) continue;
          final hours = mins / 60.0;
          stacksP.add(BarChartRodStackItem(
              cumulativeP, cumulativeP + hours, _projectColor(pid).withOpacity(0.55)));
          cumulativeP += hours;
        }

        dataMaxHours = [dataMaxHours, cumulativeA, cumulativeP]
            .reduce((a, b) => a > b ? a : b);

        barGroups.add(BarChartGroupData(
          x: x,
          barRods: [
            BarChartRodData(
              toY: cumulativeP,
              width: 12,
              borderRadius: BorderRadius.circular(2),
              rodStackItems: stacksP,
              color: stacksP.isEmpty ? Theme.of(context).dividerColor : null,
            ),
            BarChartRodData(
              toY: cumulativeA,
              width: 12,
              borderRadius: BorderRadius.circular(2),
              rodStackItems: stacksA,
              color: stacksA.isEmpty ? Theme.of(context).dividerColor : null,
            ),
          ],
          barsSpace: 6,
          groupVertically: false,
        ));
      }
    } else {
      // project grouping: one group per project, two rods (planned/actual) using weekly totals
      for (int i = 0; i < projectChartEntries.length; i++) {
        final e = projectChartEntries[i];
        final ph = e.plannedMinutes / 60.0;
        final ah = e.actualMinutes / 60.0;
        dataMaxHours =
            [dataMaxHours, ph, ah].reduce((a, b) => a > b ? a : b);
        final color = _projectColor(e.projectId);
        barGroups.add(BarChartGroupData(x: i, barsSpace: 8, barRods: [
          BarChartRodData(
              toY: ph,
              width: 12,
              borderRadius: BorderRadius.circular(2),
              color: color.withOpacity(0.55)),
          BarChartRodData(
              toY: ah,
              width: 12,
              borderRadius: BorderRadius.circular(2),
              color: color),
        ]));
      }
    }

    // NOTE: chartHeight は親の SizedBox(= LayoutBuilder) により 240..520 に収まる想定
    // このバーグラフは内側に Padding(fromLTRB(12,40,12,12)) を持つため、
    // 縦軸の「描画可能高さ」は概算で 40+12 を差し引く。
    final labelFontSize =
        Theme.of(context).textTheme.bodySmall?.fontSize?.toDouble() ?? 12.0;
    const verticalPadding = 40.0 + 12.0;
    // Bottom title is always 2 lines (日ごと/プロジェクトごと共通) なので高さを確保する
    const bottomReservedSize = 52.0;
    final plotHeight =
        (chartHeight - verticalPadding - bottomReservedSize).clamp(1.0, 99999.0);
    final yScale = computeHoursYAxisScale(
      dataMaxHours: dataMaxHours,
      plotHeightPx: plotHeight,
      labelFontSizePx: labelFontSize,
    );
    final tickInterval = yScale.interval;
    final double maxY = yScale.maxY;
    final int yMaxSteps = (maxY / tickInterval).round();

    Widget bottomTitle(int value) {
      if (_groupingMode == 'time') {
        final days =
            List.generate(_rangeDays, (i) => _weekStart.add(Duration(days: i)));
        if (value < 0 || value >= _rangeDays) {
          return const SizedBox.shrink();
        }
        final interval = _labelIntervalForRange();
        final bool isEdge = value == 0 || value == _rangeDays - 1;
        if (!isEdge && interval > 1 && value % interval != 0) {
          return const SizedBox.shrink();
        }
        final d = days[value];
        final w = DateFormat('E', 'ja_JP').format(d);
        final dateStr = DateFormat('MM/dd').format(d);
        final isHighlight = _highlightDate != null &&
            _dateOnly(d) == _dateOnly(_highlightDate!);
        final style = Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: isHighlight ? FontWeight.bold : null,
              color: isHighlight
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).textTheme.bodySmall?.color,
            );
        return Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(w, style: style),
            Text(dateStr, style: style),
          ]),
        );
      } else {
        if (value < 0 || value >= projectChartEntries.length) {
          return const SizedBox.shrink();
        }
        final pid = projectChartEntries[value].projectId;
        final name = _projectName(pid);
        return Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: SizedBox(
            width: 64,
            child: Text(name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 40, 12, 12),
          child: Stack(children: [
            BarChart(BarChartData(
              alignment: BarChartAlignment.spaceEvenly,
              groupsSpace: 18,
              barGroups: barGroups,
              gridData: const FlGridData(show: true),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 40,
                    interval: tickInterval,
                    getTitlesWidget: (value, meta) {
                      final double k = (value / tickInterval).roundToDouble();
                      final double snapped = (k * tickInterval);
                      if ((value - snapped).abs() > tickInterval * 1e-3) {
                        return const SizedBox.shrink();
                      }
                      if (k > yMaxSteps) return const SizedBox.shrink();
                      final mins = (snapped * 60).round();
                      return Text(
                        _formatMinutes(mins),
                        style: Theme.of(context).textTheme.bodySmall,
                      );
                    },
                  ),
                ),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: 1,
                    reservedSize: bottomReservedSize,
                    getTitlesWidget: (value, meta) =>
                        bottomTitle(value.round()),
                  ),
                ),
              ),
              borderData: FlBorderData(show: false),
              barTouchData: BarTouchData(
                enabled: true,
                touchTooltipData: BarTouchTooltipData(
                    getTooltipItem: (group, groupIndex, rod, rodIndex) => null),
                touchCallback: (event, response) {
                  if (!event.isInterestedForInteractions ||
                      response == null ||
                      response.spot == null) {
                    if (_showOverlayTooltip) {
                      setState(() {
                        _showOverlayTooltip = false;
                        _tooltipOffset = null;
                      });
                    }
                    return;
                  }
                  final spot = response.spot!;
                  final idx = spot.touchedRodDataIndex;
                  final isPlannedRod = idx == 0;
                  final minutes = (spot.touchedRodData.toY * 60).round();
                  setState(() {
                    _overlayTooltipText =
                        '${isPlannedRod ? '予定' : '実績'}: ${_formatMinutes(minutes)}';
                    _showOverlayTooltip = true;
                    _tooltipOffset = spot.offset;
                  });
                },
              ),
              maxY: maxY,
            )),
            Positioned(
              top: 4,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: _showOverlayTooltip ? 1.0 : 0.0,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final w = constraints.maxWidth;
                      final dx = _tooltipOffset?.dx ?? w / 2;
                      final alignX = ((dx / w) * 2 - 1).clamp(-1.0, 1.0);
                      return Align(
                        alignment: Alignment(alignX, -1),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .inverseSurface
                                .withOpacity(0.90),
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: [
                              BoxShadow(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .shadow
                                      .withOpacity(0.18),
                                  blurRadius: 6,
                                  offset: const Offset(0, 2)),
                            ],
                            border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withOpacity(0.6)),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          child: Text(
                            _overlayTooltipText,
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onInverseSurface,
                                fontWeight: FontWeight.w800,
                                fontSize: 13),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildWeeklyTotalsList(BuildContext context) {
    final ids = _projectIdsInWeekSorted();
    if (ids.isEmpty) {
      return const Center(child: Text('データがありません'));
    }
    final isMobile = MediaQuery.of(context).size.width < 800;
    final totalActual =
        _weeklyProjectTotals.values.fold<int>(0, (s, v) => s + v);

    if (isMobile) {
      // スマホ: プロジェクト名 + 実績のみ（見やすさ優先）
      return Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  flex: 7,
                  child: Text(
                    'プロジェクト',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '実績',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: ids.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final pid = ids[index];
              final minutesActual = _weeklyProjectTotals[pid] ?? 0;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      flex: 7,
                      child: Row(
                        children: [
                          Container(width: 10, height: 10, color: _projectColor(pid)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _projectName(pid),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(_formatMinutes(minutesActual)),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const Expanded(
                  flex: 7,
                  child: Text('合計', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                Expanded(
                  flex: 3,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      _formatMinutes(totalActual),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Text('プロジェクト',
                    style: Theme.of(context).textTheme.labelMedium),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text('予定',
                      style: Theme.of(context).textTheme.labelMedium),
                ),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text('実績',
                      style: Theme.of(context).textTheme.labelMedium),
                ),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text('差分',
                      style: Theme.of(context).textTheme.labelMedium),
                ),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text('達成率',
                      style: Theme.of(context).textTheme.labelMedium),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: ids.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final pid = ids[index];
            final minutesActual = _weeklyProjectTotals[pid] ?? 0;
            final minutesPlanned = _weeklyProjectTotalsPlanned[pid] ?? 0;
            final diff = minutesActual - minutesPlanned;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: Row(
                      children: [
                        Container(
                            width: 10, height: 10, color: _projectColor(pid)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _projectName(pid),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(_formatMinutes(minutesPlanned)),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(_formatMinutes(minutesActual)),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(_formatMinutes(diff)),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(() {
                        if (minutesPlanned <= 0) return '-';
                        final rate = (minutesActual / minutesPlanned * 100)
                            .toStringAsFixed(0);
                        return '$rate%';
                      }()),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Expanded(
                flex: 5,
                child:
                    Text('合計', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    _formatMinutes(_weeklyProjectTotalsPlanned.values.fold<int>(0, (s, v) => s + v)),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    _formatMinutes(_weeklyProjectTotals.values.fold<int>(0, (s, v) => s + v)),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    _formatMinutes(_weeklyProjectTotals.values.fold<int>(0, (s, v) => s + v) - _weeklyProjectTotalsPlanned.values.fold<int>(0, (s, v) => s + v)),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(() {
                    final p = _weeklyProjectTotalsPlanned.values
                        .fold<int>(0, (s, v) => s + v);
                    final a = _weeklyProjectTotals.values
                        .fold<int>(0, (s, v) => s + v);
                    if (p <= 0) return '-';
                    return '${(a / p * 100).toStringAsFixed(0)}%';
                  }(), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _repoSubscription?.cancel();
    super.dispose();
  }
}
