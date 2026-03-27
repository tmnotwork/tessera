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

// DayNavigationNotification は ../widgets/report_navigation.dart で定義

class DailyReportScreen extends StatefulWidget {
  final DateTime? initialDate;

  const DailyReportScreen({super.key, this.initialDate});

  @override
  State<DailyReportScreen> createState() => _DailyReportScreenState();
}

class _DailyReportScreenState extends State<DailyReportScreen> {
  static const String _otherProjectId = '__other__';
  late DateTime _selectedDate; // date-only (local)
  bool _loading = true;
  // リアルタイム購読は行わず、明示操作時のみ再読込（ちらつき防止）
  Map<String, int> _minutesByProject = {}; // Actual: projectId -> minutes
  Map<String, int> _plannedMinutesByProject =
      {}; // Planned: projectId -> minutes
  // 'time' | 'project' （日次はデフォルトで 'project'）
  String _groupingMode = 'project';
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

  bool _showOverlayTooltip = false;
  String _overlayTooltipText = '';

  @override
  void initState() {
    super.initState();
    _selectedDate = _dateOnly(widget.initialDate ?? DateTime.now());
    _groupingMode = AppSettingsService.getString(AppSettingsService.keyReportDailyGrouping) ?? 'project';
    _repoSubscription = _reportRepo.changes.listen((_) {
      if (!mounted) return;
      _refreshFromHive();
    });
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant DailyReportScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newBase = _dateOnly(widget.initialDate ?? DateTime.now());
    if (newBase != _selectedDate) {
      _selectedDate = newBase;
      unawaited(_load());
    }
  }

  DateTime _dateOnly(DateTime dt) {
    final d = dt.toLocal();
    return DateTime(d.year, d.month, d.day);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      locale: const Locale('ja', 'JP'),
    );
    if (picked != null) {
      setState(() => _selectedDate = _dateOnly(picked));
      await _load();
    }
  }

  void _changeDay(int delta) {
    setState(() => _selectedDate = _selectedDate.add(Duration(days: delta)));
    unawaited(_load());
  }

  String _periodLabel() {
    return DateFormat('yyyy/MM/dd').format(_selectedDate);
  }

  Widget _buildPeriodNavigator() {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle =
        Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onSurface) ??
            TextStyle(color: scheme.onSurface, fontSize: 14);
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            buildSegment(
              tooltip: '前日',
              onTap: () => _changeDay(-1),
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(12),
              ),
              child: Icon(Icons.chevron_left, color: scheme.onSurface, size: 20),
            ),
            buildSegment(
              tooltip: 'レポート期間を選択',
              onTap: () =>
                  const ReportPeriodDialogRequestNotification().dispatch(context),
              borderRadius: BorderRadius.zero,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                _periodLabel(),
                style: labelStyle,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            buildSegment(
              tooltip: '翌日',
              onTap: () => _changeDay(1),
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(12),
              ),
              child: Icon(Icons.chevron_right, color: scheme.onSurface, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _load({bool runSync = true}) async {
    setState(() => _loading = true);

    // 期間を計算
    final start = _selectedDate;
    final end = start.add(const Duration(days: 1));

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
    final data = _reportRepo.loadDailySummary(_selectedDate);
    if (mounted) {
      setState(() {
        _minutesByProject = Map<String, int>.from(data.actualMinutesByProject);
        _plannedMinutesByProject =
            Map<String, int>.from(data.plannedMinutesByProject);
        _loading = false;
      });
    }
  }

  void _refreshFromHive() {
    if (!mounted) return;
    _reportRepo.refreshCache();
    final data = _reportRepo.loadDailySummary(_selectedDate);
    setState(() {
      _minutesByProject = Map<String, int>.from(data.actualMinutesByProject);
      _plannedMinutesByProject =
          Map<String, int>.from(data.plannedMinutesByProject);
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

  List<String> _projectIdsSorted() {
    final Set<String> idSet = {
      ..._minutesByProject.keys,
      ..._plannedMinutesByProject.keys,
    };
    final ids = idSet.toList();
    int totalOf(String pid) =>
        (_minutesByProject[pid] ?? 0) + (_plannedMinutesByProject[pid] ?? 0);
    ids.sort((a, b) {
      if (a.isEmpty && b.isEmpty) return 0;
      if (a.isEmpty) return 1;
      if (b.isEmpty) return -1;
      return totalOf(b).compareTo(totalOf(a));
    });
    return ids;
  }

  Color _projectColor(String projectId) {
    final hash = projectId.hashCode;
    final hue = (hash % 360).toDouble();
    return HSLColor.fromAHSL(1.0, hue, 0.5, 0.55).toColor();
  }

  String _projectDisplayName(String projectId) {
    if (projectId == _otherProjectId) return 'その他';
    return ProjectService.getProjectById(projectId)?.name ??
        (projectId.isEmpty ? '未分類' : projectId);
  }

  int _maxProjectsForWidth(double widthPx) {
    if (widthPx < 420) return 4;
    if (widthPx < 600) return 5;
    if (widthPx < 800) return 7;
    if (widthPx < 1000) return 9;
    return 12;
  }

  List<({String projectId, int plannedMinutes, int actualMinutes})>
      _buildProjectChartEntries(double widthPx) {
    final ids = _projectIdsSorted();
    if (ids.isEmpty) return const [];

    final maxProjects = _maxProjectsForWidth(widthPx);
    if (ids.length <= maxProjects) {
      return ids
          .map((pid) => (
                projectId: pid,
                plannedMinutes: _plannedMinutesByProject[pid] ?? 0,
                actualMinutes: _minutesByProject[pid] ?? 0,
              ))
          .toList();
    }

    final takeN = (maxProjects - 1).clamp(1, ids.length);
    final topIds = ids.take(takeN).toList();
    final otherIds = ids.skip(takeN);
    int otherPlanned = 0;
    int otherActual = 0;
    for (final pid in otherIds) {
      otherPlanned += _plannedMinutesByProject[pid] ?? 0;
      otherActual += _minutesByProject[pid] ?? 0;
    }

    final entries = <({String projectId, int plannedMinutes, int actualMinutes})>[
      ...topIds.map((pid) => (
            projectId: pid,
            plannedMinutes: _plannedMinutesByProject[pid] ?? 0,
            actualMinutes: _minutesByProject[pid] ?? 0,
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

  @override
  Widget build(BuildContext context) {
    return NotificationListener<DayNavigationNotification>(
      onNotification: (notification) {
        if (notification.targetDate != null) {
          // 特定の日付が指定された場合
          setState(() => _selectedDate = _dateOnly(notification.targetDate!));
          unawaited(_load());
        } else if (notification.pickDate) {
          // 日付選択ダイアログを表示
          _pickDate();
        } else if (notification.deltaDays == 0) {
          // 今日
          setState(() => _selectedDate = _dateOnly(DateTime.now()));
          unawaited(_load());
        } else {
          // 前日・翌日
          _changeDay(notification.deltaDays);
        }
        return true;
      },
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(builder: (context, constraints) {
              final double chartHeight = (() {
                final h = constraints.maxHeight.isFinite && constraints.maxHeight > 0
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
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _buildPeriodNavigator(),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
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
                                          value: 'project',
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text('プロジェクトごと'),
                                          ),
                                        ),
                                        DropdownMenuItem<String>(
                                          value: 'time',
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text('日合計'),
                                          ),
                                        ),
                                      ],
                                      onChanged: (value) async {
                                        if (value == null || value == _groupingMode) {
                                          return;
                                        }
                                        setState(() => _groupingMode = value);
                                        await AppSettingsService.setString(
                                          AppSettingsService.keyReportDailyGrouping,
                                          value,
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                        height: chartHeight,
                        child:
                            _buildDailyBarChart(context, chartHeight: chartHeight, widthPx: constraints.maxWidth)),
                    const Divider(height: 1),
                    // 合計テーブル（横スクロール対応）
                    _buildDailyTotalsTable(context),
                  ],
                ),
              );
            }),
    );
  }

  Widget _buildDailyBarChart(BuildContext context,
      {required double chartHeight, required double widthPx}) {
    List<BarChartGroupData> barGroups = [];
    double baseHours = 1.0;
    Widget Function(double, TitleMeta) bottomTitleBuilder;

    if (_groupingMode == 'project') {
      final entries = _buildProjectChartEntries(widthPx);
      for (int i = 0; i < entries.length; i++) {
        final e = entries[i];
        final ph = e.plannedMinutes / 60.0;
        final ah = e.actualMinutes / 60.0;
        baseHours = [baseHours, ph, ah].reduce((a, b) => a > b ? a : b);
        final color = _projectColor(e.projectId);
        barGroups.add(BarChartGroupData(x: i, barsSpace: 8, barRods: [
          BarChartRodData(
            toY: ph,
            width: 10,
            borderRadius: BorderRadius.circular(2),
            color: color.withOpacity(0.55),
          ),
          BarChartRodData(
            toY: ah,
            width: 10,
            borderRadius: BorderRadius.circular(2),
            color: color,
          ),
        ]));
      }
      bottomTitleBuilder = (value, meta) {
        final idx = value.toInt();
        if (idx < 0 || idx >= entries.length) return const SizedBox.shrink();
        final pid = entries[idx].projectId;
        final name = _projectDisplayName(pid);
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SizedBox(
            width: 56,
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10),
            ),
          ),
        );
      };
    } else {
      final totalPlannedMinutes =
          _plannedMinutesByProject.values.fold<int>(0, (s, v) => s + v);
      final totalActualMinutes =
          _minutesByProject.values.fold<int>(0, (s, v) => s + v);
      final double plannedHours = totalPlannedMinutes / 60.0;
      final double actualHours = totalActualMinutes / 60.0;
      baseHours = [plannedHours, actualHours, 1.0].reduce((a, b) => a > b ? a : b);
      barGroups = [
        BarChartGroupData(x: 0, barsSpace: 10, barRods: [
          BarChartRodData(
            toY: plannedHours,
            width: 20,
            borderRadius: BorderRadius.circular(2),
            color: Theme.of(context).colorScheme.primary.withOpacity( 0.4),
          ),
          BarChartRodData(
            toY: actualHours,
            width: 20,
            borderRadius: BorderRadius.circular(2),
            color: Theme.of(context).colorScheme.primary,
          ),
        ])
      ];
      bottomTitleBuilder = (value, meta) {
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            DateFormat('MM/dd').format(_selectedDate),
            style: const TextStyle(fontSize: 12),
          ),
        );
      };
    }

    const verticalPadding = 40.0 + 12.0;
    final bottomReservedSize = _groupingMode == 'project' ? 52.0 : 28.0;
    final plotHeight =
        (chartHeight - verticalPadding - bottomReservedSize).clamp(1.0, 99999.0);
    const labelFontSize = 10.0; // leftTitles の TextStyle(fontSize: 10) と揃える
    final yScale = computeHoursYAxisScale(
      dataMaxHours: baseHours,
      plotHeightPx: plotHeight,
      labelFontSizePx: labelFontSize,
    );
    final tickInterval = yScale.interval;
    final double maxYAligned = yScale.maxY;
    final int yMaxSteps = (maxYAligned / tickInterval).round();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 40, 12, 12),
      child: Stack(children: [
        BarChart(BarChartData(
          maxY: maxYAligned,
          barGroups: barGroups,
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: bottomReservedSize,
                getTitlesWidget: bottomTitleBuilder,
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                interval: tickInterval,
                getTitlesWidget: (value, meta) {
                  final double k = (value / tickInterval).roundToDouble();
                  final double snapped = k * tickInterval;
                  if ((value - snapped).abs() > tickInterval * 1e-3) {
                    return const SizedBox.shrink();
                  }
                  if (k > yMaxSteps) return const SizedBox.shrink();
                  final mins = (snapped * 60).round();
                  return Text(
                    _formatMinutes(mins),
                    style: const TextStyle(fontSize: 10),
                  );
                },
              ),
            ),
          ),
          gridData: const FlGridData(show: true),
          barTouchData: BarTouchData(
            enabled: true,
            touchTooltipData: BarTouchTooltipData(getTooltipItem: (a, b, c, d) => null),
            touchCallback: (event, response) {
              if (!event.isInterestedForInteractions || response == null || response.spot == null) {
                if (_showOverlayTooltip) {
                  setState(() => _showOverlayTooltip = false);
                }
                return;
              }
              final spot = response.spot!;
              final idx = spot.touchedRodDataIndex;
              final isPlanned = idx == 0;
              final minutes = (spot.touchedRodData.toY * 60).round();
              setState(() {
                _overlayTooltipText = '${isPlanned ? '予定' : '実績'}: ${_formatMinutes(minutes)}';
                _showOverlayTooltip = true;
              });
            },
          ),
          borderData: FlBorderData(show: true),
        )),
        Positioned(
          top: 4,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: _showOverlayTooltip ? 1.0 : 0.0,
              child: Center(
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
                            .withOpacity( 0.18),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      )
                    ],
                    border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .outlineVariant
                            .withOpacity(0.6)),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(
                    _overlayTooltipText,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onInverseSurface,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildDailyTotalsTable(BuildContext context) {
    final ids = _projectIdsSorted();

    final totalPlanned =
        _plannedMinutesByProject.values.fold<int>(0, (sum, mins) => sum + mins);
    final totalActual =
        _minutesByProject.values.fold<int>(0, (sum, mins) => sum + mins);
    final totalDiff = totalActual - totalPlanned;

    final isMobile = MediaQuery.of(context).size.width < 800;
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
              final projectName = ProjectService.getProjectById(pid)?.name ??
                  (pid.isEmpty ? '未分類' : pid);
              final minutesActual = _minutesByProject[pid] ?? 0;
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      flex: 7,
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            color: _projectColor(pid),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              projectName,
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
                  child:
                      Text('合計', style: TextStyle(fontWeight: FontWeight.bold)),
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
            final projectName = ProjectService.getProjectById(pid)?.name ?? (pid.isEmpty ? '未分類' : pid);
            final minutesActual = _minutesByProject[pid] ?? 0;
            final minutesPlanned = _plannedMinutesByProject[pid] ?? 0;
            final diff = minutesActual - minutesPlanned;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: Row(
                      children: [
                        Container(width: 10, height: 10, color: _projectColor(pid)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            projectName,
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
                        final rate =
                            (minutesActual / minutesPlanned * 100).toStringAsFixed(0);
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
                child: Text('合計', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    _formatMinutes(totalPlanned),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
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
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    _formatMinutes(totalDiff),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(() {
                    if (totalPlanned <= 0) return '-';
                    return '${(totalActual / totalPlanned * 100).toStringAsFixed(0)}%';
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
