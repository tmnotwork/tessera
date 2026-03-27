// LP用スクリーンショット用の架空データレポート画面（表示専用・管理者メニューから表示）

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import '../app/reporting/y_axis_scale.dart';

/// 架空のプロジェクトID（表示名と対応）
const String _pidEnglish = 'english';
const String _pidWork = 'work';
const String _pidSideJob = 'sidejob';

const List<String> _mockProjectOrder = [_pidEnglish, _pidWork, _pidSideJob];

String _mockProjectName(String projectId) {
  switch (projectId) {
    case _pidEnglish:
      return '英語学習';
    case _pidWork:
      return '仕事';
    case _pidSideJob:
      return '副業';
    default:
      return projectId;
  }
}

/// 赤・オレンジ・紫の同系色で統一感（積み上げは下→上で 英語/仕事/副業）
Color _mockProjectColor(String projectId) {
  switch (projectId) {
    case _pidEnglish:
      return const Color(0xFFC62828); // 下段・赤
    case _pidWork:
      return const Color(0xFFE64A19); // 中段・オレンジ（赤系）
    case _pidSideJob:
      return const Color(0xFFAD1457); // 上段・赤紫
    default:
      return HSLColor.fromAHSL(1.0, projectId.hashCode % 360.0, 0.5, 0.55)
          .toColor();
  }
}

/// 左メニューのラベル（レポートを選択した状態で表示）
const List<String> _navLabels = [
  'タイムライン',
  'インボックス',
  'カレンダー',
  'ルーティン',
  'プロジェクト',
  'レポート',
  'DB',
  '設定',
];
const int _reportNavIndex = 5;

/// 架空の週データ（月〜日 7日分）
/// 英語学習・仕事: 少し達成、副業: 少し未達
class _MockWeekData {
  static const int days = 7;

  late final DateTime weekStart;
  late final Map<DateTime, Map<String, int>> plannedByDayProject;
  late final Map<DateTime, Map<String, int>> actualByDayProject;
  late final Map<String, int> weeklyPlanned;
  late final Map<String, int> weeklyActual;

  _MockWeekData() {
    // 固定週: 例 2025/02/24(月) 〜 03/02(日)
    weekStart = DateTime(2025, 2, 24);

    // 日ごとの予定（分）: 英語学習, 仕事, 副業。休日は仕事なし。日曜は勉強・副業多め。
    final plannedPerDay = [
      [50, 180, 90],   // 月
      [50, 160, 90],   // 火
      [50, 180, 90],   // 水
      [50, 160, 90],   // 木
      [50, 180, 90],   // 金
      [60, 0, 90],     // 土（休日）
      [120, 0, 150],   // 日（休日: 勉強・副業多め）
    ];

    // 日ごとの実績（分）。日曜は勉強・副業多め。
    final actualPerDay = [
      [55, 190, 80],   // 月
      [54, 170, 80],   // 火
      [54, 190, 80],   // 水
      [54, 170, 80],   // 木
      [54, 190, 80],   // 金
      [65, 0, 85],     // 土（休日）
      [125, 0, 145],   // 日（休日: 勉強・副業多め）
    ];

    plannedByDayProject = {};
    actualByDayProject = {};
    for (int i = 0; i < days; i++) {
      final day = weekStart.add(Duration(days: i));
      plannedByDayProject[day] = {
        _pidEnglish: plannedPerDay[i][0],
        _pidWork: plannedPerDay[i][1],
        _pidSideJob: plannedPerDay[i][2],
      };
      actualByDayProject[day] = {
        _pidEnglish: actualPerDay[i][0],
        _pidWork: actualPerDay[i][1],
        _pidSideJob: actualPerDay[i][2],
      };
    }

    weeklyPlanned = {
      _pidEnglish: 430,
      _pidWork: 860,
      _pidSideJob: 690,
    };
    weeklyActual = {
      _pidEnglish: 461,
      _pidWork: 910,
      _pidSideJob: 630,
    };
  }
}

class ReportScreenshotMockScreen extends StatefulWidget {
  const ReportScreenshotMockScreen({super.key});

  @override
  State<ReportScreenshotMockScreen> createState() =>
      _ReportScreenshotMockScreenState();
}

class _ReportScreenshotMockScreenState extends State<ReportScreenshotMockScreen> {
  final _mock = _MockWeekData();
  bool _showOverlayTooltip = false;
  String _overlayTooltipText = '';
  Offset? _tooltipOffset;
  String _groupingMode = 'time'; // 'time' | 'project'

  String _formatMinutes(int minutes) {
    final sign = minutes < 0 ? '-' : '';
    final v = minutes.abs();
    final h = v ~/ 60;
    final m = v % 60;
    return '$sign${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  DateTime _dateOnly(DateTime dt) {
    final d = dt.toLocal();
    return DateTime(d.year, d.month, d.day);
  }

  @override
  Widget build(BuildContext context) {
    const double navWidth = 140; // 固定幅（本番の左メニューと同一）
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildLeftNav(context, navWidth),
          const VerticalDivider(width: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final chartHeight = (() {
                  final h = constraints.maxHeight.isFinite &&
                          constraints.maxHeight > 0
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
                            _buildPeriodNavigator(),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
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
                                        fillColor:
                                            Theme.of(context).colorScheme.surface,
                                        border: OutlineInputBorder(
                                          borderSide: BorderSide(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .outlineVariant,
                                          ),
                                        ),
                                        enabledBorder: OutlineInputBorder(
                                          borderSide: BorderSide(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .outlineVariant,
                                          ),
                                        ),
                                        contentPadding:
                                            const EdgeInsets.symmetric(
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
                                      onChanged: (value) {
                                        if (value != null) setState(() => _groupingMode = value);
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
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                        child: SizedBox(
                          height: chartHeight,
                          child: _buildBarChart(context,
                              chartHeight: chartHeight),
                        ),
                      ),
                      const Divider(height: 1),
                      _buildTotalsTable(context),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftNav(BuildContext context, double width) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 0,
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: List.generate(_navLabels.length, (i) {
                  final selected = i == _reportNavIndex;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: selected ? scheme.primary : null,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: scheme.primary
                                .withOpacity(selected ? 0.8 : 0.0),
                            width: selected ? 1.5 : 0.0,
                          ),
                        ),
                        child: Text(
                          _navLabels[i],
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.normal,
                            color: selected
                                ? scheme.onPrimary
                                : scheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
            // Kant: 本番（new_ui_screen デフォルトUI）と同じ: 縦バー幅でフォントサイズ切替
            LayoutBuilder(
              builder: (context, constraints) {
                final barWidth = constraints.maxWidth;
                final fontSize = barWidth <= 80 ? 21.0 : 29.0;
                final horizontalPadding = barWidth <= 80 ? 8.0 : 16.0;
                final scheme = Theme.of(context).colorScheme;
                return Padding(
                  padding: EdgeInsets.fromLTRB(horizontalPadding, 10, horizontalPadding, 12),
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
    );
  }

  /// 本番 weekly_report_screen と同じ: 角丸ボックス内の中央に日付（モックは 3/1 - 3/7 固定）
  /// DefaultTextStyle.override で祖先の透明色を上書き（テーマ由来の alpha=0 対策）
  Widget _buildPeriodNavigator() {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final labelColor = isDark ? Colors.white : Colors.black;

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
            _navSegment(
              scheme: scheme,
              child: Icon(Icons.chevron_left,
                  color: scheme.onSurface, size: 20),
            ),
            _navSegment(
              scheme: scheme,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: DefaultTextStyle(
                style: TextStyle(
                  color: labelColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
                child: const Text('3/1 - 3/7'),
              ),
            ),
            _navSegment(
              scheme: scheme,
              child: Icon(Icons.chevron_right,
                  color: scheme.onSurface, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navSegment({
    required ColorScheme scheme,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 10),
    required Widget child,
  }) {
    return Container(
      height: 36,
      padding: padding,
      alignment: Alignment.center,
      child: child,
    );
  }

  Widget _buildBarChart(BuildContext context, {required double chartHeight}) {
    const verticalPadding = 40.0 + 12.0;
    const bottomReservedSize = 52.0;
    final plotHeight =
        (chartHeight - verticalPadding - bottomReservedSize).clamp(1.0, 99999.0);
    final labelFontSize =
        Theme.of(context).textTheme.bodySmall?.fontSize?.toDouble() ?? 12.0;
    final emptyBarColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.white24
        : Colors.black12;

    double dataMaxHours = 0.0;
    final barGroups = <BarChartGroupData>[];
    Widget Function(double, dynamic) bottomTitlesBuilder;

    if (_groupingMode == 'project') {
      for (int i = 0; i < _mockProjectOrder.length; i++) {
        final pid = _mockProjectOrder[i];
        final planned = (_mock.weeklyPlanned[pid] ?? 0) / 60.0;
        final actual = (_mock.weeklyActual[pid] ?? 0) / 60.0;
        dataMaxHours = [dataMaxHours, planned, actual].reduce((a, b) => a > b ? a : b);
        final color = _mockProjectColor(pid);
        barGroups.add(BarChartGroupData(
          x: i,
          barsSpace: 8,
          barRods: [
            BarChartRodData(
              toY: planned,
              width: 12,
              borderRadius: BorderRadius.circular(2),
              color: color.withOpacity(0.55),
            ),
            BarChartRodData(
              toY: actual,
              width: 12,
              borderRadius: BorderRadius.circular(2),
              color: color,
            ),
          ],
        ));
      }
      bottomTitlesBuilder = (value, meta) {
        final idx = value.round();
        if (idx < 0 || idx >= _mockProjectOrder.length) return const SizedBox.shrink();
        final name = _mockProjectName(_mockProjectOrder[idx]);
        return Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: SizedBox(
            width: 64,
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        );
      };
    } else {
      final days = List.generate(
          _MockWeekData.days, (i) => _mock.weekStart.add(Duration(days: i)));

      for (int x = 0; x < days.length; x++) {
        final day = days[x];
        final dataActual = _mock.actualByDayProject[day] ?? {};
        final dataPlanned = _mock.plannedByDayProject[day] ?? {};

        double cumulativeA = 0.0;
        final stacksA = <BarChartRodStackItem>[];
        for (final pid in _mockProjectOrder) {
          final mins = (dataActual[pid] ?? 0).toDouble();
          if (mins <= 0) continue;
          final hours = mins / 60.0;
          stacksA.add(BarChartRodStackItem(
              cumulativeA, cumulativeA + hours, _mockProjectColor(pid)));
          cumulativeA += hours;
        }

        double cumulativeP = 0.0;
        final stacksP = <BarChartRodStackItem>[];
        for (final pid in _mockProjectOrder) {
          final mins = (dataPlanned[pid] ?? 0).toDouble();
          if (mins <= 0) continue;
          final hours = mins / 60.0;
          stacksP.add(BarChartRodStackItem(
              cumulativeP, cumulativeP + hours, _mockProjectColor(pid)));
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
              color: stacksP.isEmpty ? emptyBarColor : null,
            ),
            BarChartRodData(
              toY: cumulativeA,
              width: 12,
              borderRadius: BorderRadius.circular(2),
              rodStackItems: stacksA,
              color: stacksA.isEmpty ? emptyBarColor : null,
            ),
          ],
          barsSpace: 6,
          groupVertically: false,
        ));
      }
      bottomTitlesBuilder = (value, meta) {
        final days = List.generate(
            _MockWeekData.days, (i) => _mock.weekStart.add(Duration(days: i)));
        if (value < 0 || value >= days.length) {
          return const SizedBox.shrink();
        }
        final d = days[value.round()];
        final w = DateFormat('E', 'ja_JP').format(d);
        final dateStr = DateFormat('MM/dd').format(d);
        return Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(w, style: Theme.of(context).textTheme.bodySmall),
              Text(dateStr, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        );
      };
    }

    final yScale = computeHoursYAxisScale(
      dataMaxHours: dataMaxHours,
      plotHeightPx: plotHeight,
      labelFontSizePx: labelFontSize,
    );
    final tickInterval = yScale.interval;
    final maxY = yScale.maxY;
    final yMaxSteps = (maxY / tickInterval).round();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 40, 12, 12),
          child: Stack(
            children: [
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
                        final double k =
                            (value / tickInterval).roundToDouble();
                        final double snapped = k * tickInterval;
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
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 1,
                      reservedSize: bottomReservedSize,
                      getTitlesWidget: bottomTitlesBuilder,
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                barTouchData: BarTouchData(
                  enabled: true,
                  touchTooltipData: BarTouchTooltipData(
                      getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                          null),
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
                        final alignX =
                            ((dx / w) * 2 - 1).clamp(-1.0, 1.0);
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTotalsTable(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 800;
    final totalPlanned = _mock.weeklyPlanned.values.fold<int>(0, (s, v) => s + v);
    final totalActual = _mock.weeklyActual.values.fold<int>(0, (s, v) => s + v);

    if (isMobile) {
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
          ..._mockProjectOrder.map((pid) {
            final actual = _mock.weeklyActual[pid] ?? 0;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    flex: 7,
                    child: Row(
                      children: [
                        Container(
                            width: 10,
                            height: 10,
                            color: _mockProjectColor(pid)),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(_mockProjectName(pid),
                                overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(_formatMinutes(actual))),
                  ),
                ],
              ),
            );
          }),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const Expanded(
                    flex: 7,
                    child: Text('合計',
                        style: TextStyle(fontWeight: FontWeight.bold))),
                Expanded(
                  flex: 3,
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(_formatMinutes(totalActual),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold))),
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
                      style: Theme.of(context).textTheme.labelMedium)),
              Expanded(
                  flex: 3,
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: Text('予定',
                          style: Theme.of(context).textTheme.labelMedium))),
              Expanded(
                  flex: 3,
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: Text('実績',
                          style: Theme.of(context).textTheme.labelMedium))),
              Expanded(
                  flex: 3,
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: Text('差分',
                          style: Theme.of(context).textTheme.labelMedium))),
              Expanded(
                  flex: 3,
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: Text('達成率',
                          style: Theme.of(context).textTheme.labelMedium))),
            ],
          ),
        ),
        const Divider(height: 1),
        ..._mockProjectOrder.map((pid) {
          final planned = _mock.weeklyPlanned[pid] ?? 0;
          final actual = _mock.weeklyActual[pid] ?? 0;
          final diff = actual - planned;
          final rateStr = planned <= 0
              ? '-'
              : '${(actual / planned * 100).toStringAsFixed(0)}%';
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Row(
                    children: [
                      Container(
                          width: 10,
                          height: 10,
                          color: _mockProjectColor(pid)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(_mockProjectName(pid),
                              overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
                Expanded(
                    flex: 3,
                    child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(_formatMinutes(planned)))),
                Expanded(
                    flex: 3,
                    child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(_formatMinutes(actual)))),
                Expanded(
                    flex: 3,
                    child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(_formatMinutes(diff)))),
                Expanded(
                    flex: 3,
                    child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(rateStr))),
              ],
            ),
          );
        }),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              const Expanded(
                  flex: 5,
                  child: Text('合計',
                      style: TextStyle(fontWeight: FontWeight.bold))),
              Expanded(
                  flex: 3,
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(_formatMinutes(totalPlanned),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold)))),
              Expanded(
                  flex: 3,
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(_formatMinutes(totalActual),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold)))),
              Expanded(
                  flex: 3,
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                          _formatMinutes(totalActual - totalPlanned),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold)))),
              Expanded(
                  flex: 3,
                  child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                          totalPlanned <= 0
                              ? '-'
                              : '${(totalActual / totalPlanned * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold)))),
            ],
          ),
        ),
      ],
    );
  }
}
