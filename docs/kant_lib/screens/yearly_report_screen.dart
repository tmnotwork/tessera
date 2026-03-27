import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../services/app_settings_service.dart';
import '../services/project_service.dart';
import '../app/reporting/report_data_repository.dart';
import '../app/reporting/y_axis_scale.dart';
import '../services/sync_manager.dart';
import '../services/report_sync_service.dart';
import '../widgets/report_navigation.dart';

class _ProjectChartEntry {
  final String projectId; // 通常は projectId、集約は _otherProjectId
  final int plannedMinutes;
  final int actualMinutes;
  const _ProjectChartEntry({
    required this.projectId,
    required this.plannedMinutes,
    required this.actualMinutes,
  });

  int get totalMinutes => plannedMinutes + actualMinutes;
}

class YearlyReportScreen extends StatefulWidget {
  final DateTime? initialDate;
  const YearlyReportScreen({super.key, this.initialDate});

  @override
  State<YearlyReportScreen> createState() => _YearlyReportScreenState();
}

class _YearlyReportScreenState extends State<YearlyReportScreen> {
  static const String _otherProjectId = '__other__';
  late DateTime _yearStart; // YYYY-01-01
  bool _loading = true;
  final List<int> _plannedByMonth = List.filled(12, 0);
  final List<int> _actualByMonth = List.filled(12, 0);
  final Map<String, int> _plannedByProject = {}; // projectId -> minutes
  final Map<String, int> _actualByProject = {}; // projectId -> minutes
  String _groupingMode = 'time'; // 'time' | 'project'
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
    // 棒グラフの横軸が読める範囲に収めるため、画面幅に応じて上位のみ表示する。
    if (widthPx < 420) return 4;
    if (widthPx < 600) return 5;
    if (widthPx < 800) return 7;
    if (widthPx < 1000) return 9;
    return 12;
  }

  List<_ProjectChartEntry> _buildProjectChartEntries(double widthPx) {
    final ids = _projectIdsSorted();
    if (ids.isEmpty) return const [];

    final maxProjects = _maxProjectsForWidth(widthPx);
    if (ids.length <= maxProjects) {
      return ids
          .map((pid) => _ProjectChartEntry(
                projectId: pid,
                plannedMinutes: _plannedByProject[pid] ?? 0,
                actualMinutes: _actualByProject[pid] ?? 0,
              ))
          .toList();
    }

    // 上位(max-1)件 + 残りを「その他」に集約
    final takeN = (maxProjects - 1).clamp(1, ids.length);
    final topIds = ids.take(takeN).toList();
    final otherIds = ids.skip(takeN);

    int otherPlanned = 0;
    int otherActual = 0;
    for (final pid in otherIds) {
      otherPlanned += _plannedByProject[pid] ?? 0;
      otherActual += _actualByProject[pid] ?? 0;
    }

    final entries = <_ProjectChartEntry>[
      ...topIds.map((pid) => _ProjectChartEntry(
            projectId: pid,
            plannedMinutes: _plannedByProject[pid] ?? 0,
            actualMinutes: _actualByProject[pid] ?? 0,
          )),
    ];
    if (otherPlanned != 0 || otherActual != 0) {
      entries.add(_ProjectChartEntry(
        projectId: _otherProjectId,
        plannedMinutes: otherPlanned,
        actualMinutes: otherActual,
      ));
    }
    return entries;
  }

  @override
  void initState() {
    super.initState();
    final base = widget.initialDate ?? DateTime.now();
    _yearStart = DateTime(base.year, 1, 1);
    _groupingMode = AppSettingsService.getString(AppSettingsService.keyReportYearlyGrouping) ?? 'time';
    _repoSubscription = _reportRepo.changes.listen((_) {
      if (!mounted) return;
      _refreshFromHive();
    });
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant YearlyReportScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newBase = widget.initialDate ?? DateTime.now();
    if (newBase.year != _yearStart.year) {
      _yearStart = DateTime(newBase.year, 1, 1);
      unawaited(_load());
    }
  }

  Future<void> _load({bool runSync = true}) async {
    // 期間を計算
    final start = _yearStart;
    final end = DateTime(start.year + 1, 1, 1);

    // 表示直前にキャッシュを再構築（タイムラインでブロック変更後も「開いただけ」で最新を表示）
    _reportRepo.refreshCache();
    // 先にローカル集計を表示し、同期はバックグラウンドで反映する。
    final initial = _reportRepo.loadYearlySummary(_yearStart);
    if (mounted) {
      setState(() {
        for (int i = 0; i < initial.monthlyAggregates.length && i < 12; i++) {
          _plannedByMonth[i] = initial.monthlyAggregates[i].plannedMinutes;
          _actualByMonth[i] = initial.monthlyAggregates[i].actualMinutes;
        }
        _plannedByProject
          ..clear()
          ..addAll(initial.plannedByProject);
        _actualByProject
          ..clear()
          ..addAll(initial.actualByProject);
        _loading = false;
      });
    }

    // 同期を実行（完了後にローカル集計を再反映）
    if (runSync) {
      try {
        await ReportSyncService.ensureRange(start: start, end: end);
      } catch (_) {
        // エラー時もローカル表示は維持する
      }
      if (mounted) {
        _refreshFromHive();
      }
    }
  }

  void _refreshFromHive() {
    if (!mounted) return;
    _reportRepo.refreshCache();
    final data = _reportRepo.loadYearlySummary(_yearStart);
    setState(() {
      for (int i = 0; i < data.monthlyAggregates.length && i < 12; i++) {
        _plannedByMonth[i] = data.monthlyAggregates[i].plannedMinutes;
        _actualByMonth[i] = data.monthlyAggregates[i].actualMinutes;
      }
      _plannedByProject
        ..clear()
        ..addAll(data.plannedByProject);
      _actualByProject
        ..clear()
        ..addAll(data.actualByProject);
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

  void _changeYear(int deltaYears) {
    setState(() {
      _yearStart = DateTime(_yearStart.year + deltaYears, 1, 1);
    });
    unawaited(_load());
  }

  String _periodLabel() {
    return DateFormat('yyyy年').format(_yearStart);
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
              tooltip: '前年',
              onTap: () => _changeYear(-1),
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
              tooltip: '翌年',
              onTap: () => _changeYear(1),
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    return LayoutBuilder(builder: (context, constraints) {
      // グラフの横軸は画面幅に依存するため、ここで bars を組み立てる
      double dataMaxHours = 1.0;
      late final List<BarChartGroupData> bars;
      final List<_ProjectChartEntry> projectChartEntries =
          _groupingMode == 'project'
              ? _buildProjectChartEntries(constraints.maxWidth)
              : const [];

      if (_groupingMode == 'time') {
        final maxVal = [
          ..._plannedByMonth.map((e) => e.toDouble()),
          ..._actualByMonth.map((e) => e.toDouble())
        ].fold<double>(1.0, (p, v) => v > p ? v : p);
        dataMaxHours = (maxVal / 60.0);
        bars = List<BarChartGroupData>.generate(12, (i) {
          final planned = _plannedByMonth[i] / 60.0;
          final actual = _actualByMonth[i] / 60.0;
          final scheme = Theme.of(context).colorScheme;
          return BarChartGroupData(x: i + 1, barsSpace: 6, barRods: [
            BarChartRodData(
                toY: planned,
                width: 12,
                borderRadius: BorderRadius.circular(2),
                color: scheme.primary.withOpacity(0.55)),
            BarChartRodData(
                toY: actual,
                width: 12,
                borderRadius: BorderRadius.circular(2),
                color: scheme.primary),
          ]);
        });
      } else {
        bars = [];
        for (int i = 0; i < projectChartEntries.length; i++) {
          final e = projectChartEntries[i];
          final ph = e.plannedMinutes / 60.0;
          final ah = e.actualMinutes / 60.0;
          dataMaxHours = [dataMaxHours, ph, ah].reduce((a, b) => a > b ? a : b);
          final color = _projectColor(e.projectId);
          bars.add(BarChartGroupData(x: i + 1, barsSpace: 6, barRods: [
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

      final double chartHeight = (() {
        final h = constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight * 0.45
            : 320.0;
        return h.clamp(240.0, 520.0);
      })();

      // 縦軸のラベルが重ならないよう、描画高さから interval を自動計算
      final labelFontSize =
          Theme.of(context).textTheme.bodySmall?.fontSize?.toDouble() ?? 12.0;
      const verticalPadding = 40.0 + 12.0; // chart内Padding(top+bottom)
      final bottomReservedSize = _groupingMode == 'project' ? 52.0 : 28.0;
      final plotHeight =
          (chartHeight - verticalPadding - bottomReservedSize).clamp(1.0, 99999.0);
      final yScale = computeHoursYAxisScale(
        dataMaxHours: dataMaxHours,
        plotHeightPx: plotHeight,
        labelFontSizePx: labelFontSize,
      );
      final tickInterval = yScale.interval;
      final maxYAligned = yScale.maxY;
      final int yMaxSteps = (maxYAligned / tickInterval).round();

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
                                  value: 'time',
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text('月ごと'),
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
                                if (value == null || value == _groupingMode) return;
                                setState(() => _groupingMode = value);
                                await AppSettingsService.setString(
                                  AppSettingsService.keyReportYearlyGrouping,
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
              child: Padding(
                  // 上部に余白確保
                  padding: const EdgeInsets.fromLTRB(12, 40, 12, 12),
                  child: BarChart(BarChartData(
                    groupsSpace: 18,
                    barGroups: bars,
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
                      )),
                      bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: bottomReservedSize,
                              getTitlesWidget: (v, m) {
                                if (_groupingMode == 'time') {
                                  final month = v.toInt();
                                  if (month < 1 || month > 12) {
                                    return const SizedBox.shrink();
                                  }
                                  return Text('$month月',
                                      style:
                                          Theme.of(context).textTheme.bodySmall);
                                } else {
                                  final idx = v.toInt() - 1;
                                  if (idx < 0 ||
                                      idx >= projectChartEntries.length) {
                                    return const SizedBox.shrink();
                                  }
                                  final pid = projectChartEntries[idx].projectId;
                                  final name = _projectDisplayName(pid);
                                  return SizedBox(
                                    width: 64,
                                    child: Text(name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall),
                                  );
                                }
                              })),
                      rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                      topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false)),
                    ),
                    barTouchData: BarTouchData(
                      enabled: true,
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipItem: (group, groupIndex, rod, rodIndex) {
                          final isPlanned = rodIndex == 0;
                          final minutes = (rod.toY * 60).round();
                          final title = isPlanned ? '予定' : '実績';
                          final scheme = Theme.of(context).colorScheme;
                          final textColor = scheme.onInverseSurface;
                          return BarTooltipItem(
                            '$title: ${_formatMinutes(minutes)}',
                            TextStyle(
                              color: textColor,
                              fontWeight: FontWeight.w800,
                              fontSize: 13,
                              shadows: [
                                Shadow(
                                  color: scheme.shadow.withOpacity(0.38),
                                  blurRadius: 2,
                                  offset: const Offset(0, 1),
                                ),
                                Shadow(
                                  color: scheme.shadow.withOpacity(0.12),
                                  blurRadius: 1,
                                  offset: const Offset(0, 0),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    maxY: maxYAligned,
                    borderData: FlBorderData(show: false),
                  ))),
            ),
            const Divider(height: 1),
            _buildYearlyTotalsList(context),
          ],
        ),
      );
    });
  }

  List<String> _projectIdsSorted() {
    final ids = <String>{..._plannedByProject.keys, ..._actualByProject.keys}.toList();
    int totalOf(String pid) => (_plannedByProject[pid] ?? 0) + (_actualByProject[pid] ?? 0);
    ids.sort((a, b) {
      if (a.isEmpty && b.isEmpty) return 0;
      if (a.isEmpty) return 1;
      if (b.isEmpty) return -1;
      return totalOf(b).compareTo(totalOf(a));
    });
    return ids;
  }

  Widget _buildYearlyTotalsList(BuildContext context) {
    if (_groupingMode == 'time') {
      final totalPlanned = _plannedByMonth.fold<int>(0, (s, v) => s + v);
      final totalActual = _actualByMonth.fold<int>(0, (s, v) => s + v);
      final totalDiff = totalActual - totalPlanned;
      return Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Text('月', style: Theme.of(context).textTheme.labelMedium),
                ),
                Expanded(
                  flex: 3,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text('予定', style: Theme.of(context).textTheme.labelMedium),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text('実績', style: Theme.of(context).textTheme.labelMedium),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text('差分', style: Theme.of(context).textTheme.labelMedium),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text('達成率', style: Theme.of(context).textTheme.labelMedium),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 12,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final p = _plannedByMonth[i];
              final a = _actualByMonth[i];
              final diff = a - p;
              final rate = p > 0 ? '${(a / p * 100).toStringAsFixed(0)}%' : '-';
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Expanded(flex: 5, child: Text('${i + 1}月')),
                    Expanded(
                      flex: 3,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(_formatMinutes(p)),
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(_formatMinutes(a)),
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
                        child: Text(rate),
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
                    child: Text(
                      totalPlanned <= 0
                          ? '-'
                          : '${(totalActual / totalPlanned * 100).toStringAsFixed(0)}%',
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

    // プロジェクトごとのサマリ（週・月と同じ右寄せレイアウト + 合計行）
    final ids = _projectIdsSorted();
    if (ids.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('データがありません')));
    }
    final isMobile = MediaQuery.of(context).size.width < 800;
    final totalPlanned = _plannedByProject.values.fold<int>(0, (s, v) => s + v);
    final totalActual = _actualByProject.values.fold<int>(0, (s, v) => s + v);
    final totalDiff = totalActual - totalPlanned;

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
              final name =
                  ProjectService.getProjectById(pid)?.name ?? (pid.isEmpty ? '未分類' : pid);
              final minutesActual = _actualByProject[pid] ?? 0;
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
                            child: Text(name, overflow: TextOverflow.ellipsis),
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
              Expanded(flex: 5, child: Text('プロジェクト', style: Theme.of(context).textTheme.labelMedium)),
              Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text('予定', style: Theme.of(context).textTheme.labelMedium))),
              Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text('実績', style: Theme.of(context).textTheme.labelMedium))),
              Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text('差分', style: Theme.of(context).textTheme.labelMedium))),
              Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text('達成率', style: Theme.of(context).textTheme.labelMedium))),
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
            final name = ProjectService.getProjectById(pid)?.name ?? (pid.isEmpty ? '未分類' : pid);
            final minutesPlanned = _plannedByProject[pid] ?? 0;
            final minutesActual = _actualByProject[pid] ?? 0;
            final diff = minutesActual - minutesPlanned;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(flex: 5, child: Text(name, overflow: TextOverflow.ellipsis)),
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
                        return '${(minutesActual / minutesPlanned * 100).toStringAsFixed(0)}%';
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
              const Expanded(flex: 5, child: Text('合計', style: TextStyle(fontWeight: FontWeight.bold))),
              Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text(_formatMinutes(totalPlanned), style: const TextStyle(fontWeight: FontWeight.bold)))),
              Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text(_formatMinutes(totalActual), style: const TextStyle(fontWeight: FontWeight.bold)))),
              Expanded(flex: 3, child: Align(alignment: Alignment.centerRight, child: Text(_formatMinutes(totalDiff), style: const TextStyle(fontWeight: FontWeight.bold)))),
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
