import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../database/local_database.dart';
import '../repositories/study_report_repository.dart';

// ─────────────────────────────────────────────────────────────────────────────
// エントリポイント
// ─────────────────────────────────────────────────────────────────────────────

/// 日・週・月・年の 4 タブで学習時間を確認できるレポート画面。
/// 「予定」の概念はなく、実績のみを表示する。
class StudyReportScreen extends StatelessWidget {
  const StudyReportScreen({super.key, this.localDatabase});

  final LocalDatabase? localDatabase;

  @override
  Widget build(BuildContext context) {
    if (localDatabase == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('学習時間レポート')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'この機能はアプリ版（ローカルDBあり）で利用できます。\nWeb版では記録されません。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('学習時間レポート'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '日'),
              Tab(text: '週'),
              Tab(text: '月'),
              Tab(text: '年'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _DailyTab(db: localDatabase!.db),
            _WeeklyTab(db: localDatabase!.db),
            _MonthlyTab(db: localDatabase!.db),
            _YearlyTab(db: localDatabase!.db),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 共通ユーティリティ
// ─────────────────────────────────────────────────────────────────────────────

/// 秒数を HH:MM 形式にフォーマット（例: 01:30）
String _fmtSec(int sec) {
  if (sec <= 0) return '00:00';
  final h = sec ~/ 3600;
  final m = (sec % 3600) ~/ 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

/// session_type の表示名
String _typeLabel(String t) {
  switch (t) {
    case 'question':
      return '四択・テキスト';
    case 'knowledge':
      return '知識カード';
    case 'english_example':
      return '例文読み上げ';
    case 'english_example_composition':
      return '英作文';
    case 'memorization':
      return '暗記カード';
    default:
      return 'その他';
  }
}

/// session_type のカラー
Color _typeColor(String t) {
  switch (t) {
    case 'question':
      return const Color(0xFF1565C0);
    case 'knowledge':
      return const Color(0xFF2E7D32);
    case 'english_example':
      return const Color(0xFFE65100);
    case 'english_example_composition':
      return const Color(0xFF6A1B9A);
    case 'memorization':
      return const Color(0xFFC62828);
    default:
      return const Color(0xFF546E7A);
  }
}

/// session_type リストをトータル秒数の降順で並べる
List<String> _sortedTypes(Map<String, int> m) {
  final keys = m.keys.toList();
  keys.sort((a, b) => (m[b] ?? 0).compareTo(m[a] ?? 0));
  return keys;
}

/// Y 軸の最大値（1時間単位に切り上げ、最低でも 1 時間）
double _yMax(int totalSec) {
  if (totalSec <= 0) return 3600.0;
  final hours = (totalSec / 3600).ceil();
  return (hours.clamp(1, 999999)) * 3600.0;
}

/// 共通：期間ナビゲーター（前 / ラベル / 次）
Widget _buildPeriodNavigator({
  required BuildContext context,
  required String label,
  required VoidCallback onPrev,
  required VoidCallback onNext,
}) {
  final scheme = Theme.of(context).colorScheme;
  final labelStyle =
      Theme.of(context).textTheme.titleSmall?.copyWith(
        color: scheme.onSurface,
      ) ??
      TextStyle(color: scheme.onSurface, fontSize: 14);

  Widget seg({
    required Widget child,
    required VoidCallback onTap,
    required BorderRadius borderRadius,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 10),
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: borderRadius,
      child: Container(
        height: 36,
        padding: padding,
        alignment: Alignment.center,
        child: child,
      ),
    );
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
          seg(
            onTap: onPrev,
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(12),
            ),
            child: Icon(Icons.chevron_left, color: scheme.onSurface, size: 20),
          ),
          seg(
            onTap: () {},
            borderRadius: BorderRadius.zero,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              label,
              style: labelStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          seg(
            onTap: onNext,
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(12),
            ),
            child: Icon(
              Icons.chevron_right,
              color: scheme.onSurface,
              size: 20,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 共通：合計テーブル（session_type 別実績）
Widget _buildTotalsTable({
  required BuildContext context,
  required Map<String, int> byType,
  required int totalSec,
}) {
  final isMobile = MediaQuery.of(context).size.width < 800;
  final types = _sortedTypes(byType);
  if (types.isEmpty) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        'この期間に記録がありません',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget headerRow() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(
      children: [
        Expanded(
          flex: 7,
          child: Text(
            isMobile ? '種別' : '学習種別',
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
  );

  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      headerRow(),
      const Divider(height: 1),
      ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: types.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final t = types[i];
          final sec = byType[t] ?? 0;
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
                        decoration: BoxDecoration(
                          color: _typeColor(t),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _typeLabel(t),
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
                    child: Text(_fmtSec(sec)),
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
                  _fmtSec(totalSec),
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

// ─────────────────────────────────────────────────────────────────────────────
// 日次タブ
// ─────────────────────────────────────────────────────────────────────────────

class _DailyTab extends StatefulWidget {
  const _DailyTab({required this.db});

  final dynamic db;

  @override
  State<_DailyTab> createState() => _DailyTabState();
}

class _DailyTabState extends State<_DailyTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late DateTime _date;
  bool _loading = true;
  Map<String, int> _byType = {};

  @override
  void initState() {
    super.initState();
    _date = _today();
    unawaited(_load());
  }

  DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await StudyReportRepository.loadDailySummary(widget.db, _date);
    if (mounted) setState(() {
      _byType = data;
      _loading = false;
    });
  }

  void _changeDay(int delta) {
    setState(() => _date = _date.add(Duration(days: delta)));
    unawaited(_load());
  }

  String _label() {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    if (_date == today) return '今日';
    if (_date == today.subtract(const Duration(days: 1))) return '昨日';
    return '${_date.year}/${_date.month.toString().padLeft(2, '0')}/${_date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());

    final totalSec = _byType.values.fold(0, (s, v) => s + v);
    final types = _sortedTypes(_byType);

    return LayoutBuilder(builder: (context, constraints) {
      final chartH = (constraints.maxHeight * 0.45).clamp(200.0, 400.0);
      return SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  _buildPeriodNavigator(
                    context: context,
                    label: _label(),
                    onPrev: () => _changeDay(-1),
                    onNext: () => _changeDay(1),
                  ),
                  const Spacer(),
                  Text(
                    _fmtSec(totalSec),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: chartH,
              child: _buildChart(context, types, chartH),
            ),
            const Divider(height: 1),
            _buildTotalsTable(
              context: context,
              byType: _byType,
              totalSec: totalSec,
            ),
          ],
        ),
      );
    });
  }

  Widget _buildChart(
    BuildContext context,
    List<String> types,
    double chartH,
  ) {
    if (types.isEmpty) {
      return Center(
        child: Text(
          'データなし',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final maxSec = _byType.values.fold(0, (s, v) => s > v ? s : v);
    final yMaxVal = _yMax(maxSec);
    final groups = <BarChartGroupData>[];
    for (int i = 0; i < types.length; i++) {
      final t = types[i];
      final sec = (_byType[t] ?? 0).toDouble();
      groups.add(
        BarChartGroupData(x: i, barRods: [
          BarChartRodData(
            toY: sec,
            width: 20,
            borderRadius: BorderRadius.circular(2),
            color: _typeColor(t),
          ),
        ]),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 24, 12, 8),
      child: BarChart(
        BarChartData(
          maxY: yMaxVal,
          barGroups: groups,
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: true),
          titlesData: FlTitlesData(
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 48,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= types.length) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SizedBox(
                      width: 56,
                      child: Text(
                        _typeLabel(types[i]),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  );
                },
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 44,
                interval: yMaxVal / 4,
                getTitlesWidget: (value, meta) {
                  if (value == 0) {
                    return const Text(
                      '00:00',
                      style: TextStyle(fontSize: 10),
                    );
                  }
                  final snap = (value / (yMaxVal / 4)).roundToDouble() *
                      (yMaxVal / 4);
                  if ((value - snap).abs() > yMaxVal * 1e-3) {
                    return const SizedBox.shrink();
                  }
                  return Text(
                    _fmtSec(snap.round()),
                    style: const TextStyle(fontSize: 10),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final t = types[group.x];
                return BarTooltipItem(
                  '${_typeLabel(t)}\n${_fmtSec(rod.toY.round())}',
                  const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 週次タブ
// ─────────────────────────────────────────────────────────────────────────────

class _WeeklyTab extends StatefulWidget {
  const _WeeklyTab({required this.db});

  final dynamic db;

  @override
  State<_WeeklyTab> createState() => _WeeklyTabState();
}

class _WeeklyTabState extends State<_WeeklyTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static const int _days = 7;
  late DateTime _weekStart;
  bool _loading = true;
  Map<DateTime, Map<String, int>> _byDayType = {};

  @override
  void initState() {
    super.initState();
    _weekStart = _currentWeekStart();
    unawaited(_load());
  }

  DateTime _currentWeekStart() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final delta = (today.weekday - DateTime.monday + 7) % 7;
    return today.subtract(Duration(days: delta));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await StudyReportRepository.loadWeeklySummary(
      widget.db,
      _weekStart,
      _days,
    );
    if (mounted) setState(() {
      _byDayType = data;
      _loading = false;
    });
  }

  void _changeWeek(int delta) {
    setState(() => _weekStart = _weekStart.add(Duration(days: delta * 7)));
    unawaited(_load());
  }

  String _weekLabel() {
    final end = _weekStart.add(const Duration(days: _days - 1));
    return '${_weekStart.month}/${_weekStart.day} - ${end.month}/${end.day}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());

    int totalSec = 0;
    final byType = <String, int>{};
    for (final dayMap in _byDayType.values) {
      for (final e in dayMap.entries) {
        final s = e.value;
        byType[e.key] = (byType[e.key] ?? 0) + s;
        totalSec += s;
      }
    }
    final days = _byDayType.keys.toList()..sort();

    return LayoutBuilder(builder: (context, constraints) {
      final chartH = (constraints.maxHeight * 0.45).clamp(200.0, 400.0);
      return SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  _buildPeriodNavigator(
                    context: context,
                    label: _weekLabel(),
                    onPrev: () => _changeWeek(-1),
                    onNext: () => _changeWeek(1),
                  ),
                  const Spacer(),
                  Text(
                    _fmtSec(totalSec),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: chartH,
              child: _buildChart(context, days, chartH),
            ),
            const Divider(height: 1),
            _buildTotalsTable(
              context: context,
              byType: byType,
              totalSec: totalSec,
            ),
          ],
        ),
      );
    });
  }

  Widget _buildChart(
    BuildContext context,
    List<DateTime> days,
    double chartH,
  ) {
    const weekdayLabels = ['月', '火', '水', '木', '金', '土', '日'];
    final maxDaySec = days.fold(0, (maxVal, d) {
      final s = (_byDayType[d] ?? {}).values.fold(0, (s, v) => s + v);
      return s > maxVal ? s : maxVal;
    });
    final yMaxVal = _yMax(maxDaySec);
    final primary = Theme.of(context).colorScheme.primary;

    final groups = <BarChartGroupData>[];
    for (int i = 0; i < days.length; i++) {
      final d = days[i];
      final daySec = (_byDayType[d] ?? {}).values.fold(0, (s, v) => s + v);
      groups.add(
        BarChartGroupData(x: i, barRods: [
          BarChartRodData(
            toY: daySec.toDouble(),
            width: 20,
            borderRadius: BorderRadius.circular(2),
            color: primary,
          ),
        ]),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 24, 12, 8),
      child: BarChart(
        BarChartData(
          maxY: yMaxVal,
          barGroups: groups,
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: true),
          titlesData: FlTitlesData(
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 36,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= days.length) {
                    return const SizedBox.shrink();
                  }
                  final d = days[i];
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${d.month}/${d.day}\n${weekdayLabels[d.weekday - 1]}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 10),
                    ),
                  );
                },
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 44,
                interval: yMaxVal / 4,
                getTitlesWidget: (value, meta) {
                  if (value == 0) {
                    return const Text(
                      '00:00',
                      style: TextStyle(fontSize: 10),
                    );
                  }
                  final snap = (value / (yMaxVal / 4)).roundToDouble() *
                      (yMaxVal / 4);
                  if ((value - snap).abs() > yMaxVal * 1e-3) {
                    return const SizedBox.shrink();
                  }
                  return Text(
                    _fmtSec(snap.round()),
                    style: const TextStyle(fontSize: 10),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final d = days[group.x];
                final label =
                    '${d.month}/${d.day}\n${_fmtSec(rod.toY.round())}';
                return BarTooltipItem(
                  label,
                  const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 月次タブ
// ─────────────────────────────────────────────────────────────────────────────

class _MonthlyTab extends StatefulWidget {
  const _MonthlyTab({required this.db});

  final dynamic db;

  @override
  State<_MonthlyTab> createState() => _MonthlyTabState();
}

class _MonthlyTabState extends State<_MonthlyTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late DateTime _monthStart;
  bool _loading = true;
  List<({DateTime weekStart, int totalSec})> _weekBuckets = [];
  Map<String, int> _byType = {};

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _monthStart = DateTime(now.year, now.month, 1);
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await StudyReportRepository.loadMonthlySummary(
      widget.db,
      _monthStart,
    );
    if (mounted) setState(() {
      _weekBuckets = data.weekBuckets;
      _byType = data.byType;
      _loading = false;
    });
  }

  void _changeMonth(int delta) {
    setState(() {
      _monthStart = DateTime(_monthStart.year, _monthStart.month + delta, 1);
    });
    unawaited(_load());
  }

  String _monthLabel() =>
      '${_monthStart.year}年${_monthStart.month}月';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());

    final totalSec = _byType.values.fold(0, (s, v) => s + v);

    return LayoutBuilder(builder: (context, constraints) {
      final chartH = (constraints.maxHeight * 0.45).clamp(200.0, 400.0);
      return SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  _buildPeriodNavigator(
                    context: context,
                    label: _monthLabel(),
                    onPrev: () => _changeMonth(-1),
                    onNext: () => _changeMonth(1),
                  ),
                  const Spacer(),
                  Text(
                    _fmtSec(totalSec),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: chartH,
              child: _buildChart(context, chartH),
            ),
            const Divider(height: 1),
            _buildTotalsTable(
              context: context,
              byType: _byType,
              totalSec: totalSec,
            ),
          ],
        ),
      );
    });
  }

  Widget _buildChart(BuildContext context, double chartH) {
    if (_weekBuckets.isEmpty) {
      return Center(
        child: Text(
          'データなし',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final maxSec =
        _weekBuckets.fold(0, (m, b) => b.totalSec > m ? b.totalSec : m);
    final yMaxVal = _yMax(maxSec);
    final primary = Theme.of(context).colorScheme.primary;

    final groups = <BarChartGroupData>[];
    for (int i = 0; i < _weekBuckets.length; i++) {
      groups.add(
        BarChartGroupData(x: i, barRods: [
          BarChartRodData(
            toY: _weekBuckets[i].totalSec.toDouble(),
            width: 20,
            borderRadius: BorderRadius.circular(2),
            color: primary,
          ),
        ]),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 24, 12, 8),
      child: BarChart(
        BarChartData(
          maxY: yMaxVal,
          barGroups: groups,
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: true),
          titlesData: FlTitlesData(
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= _weekBuckets.length) {
                    return const SizedBox.shrink();
                  }
                  final ws = _weekBuckets[i].weekStart;
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${ws.month}/${ws.day}~',
                      style: const TextStyle(fontSize: 10),
                    ),
                  );
                },
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 44,
                interval: yMaxVal / 4,
                getTitlesWidget: (value, meta) {
                  if (value == 0) {
                    return const Text(
                      '00:00',
                      style: TextStyle(fontSize: 10),
                    );
                  }
                  final snap = (value / (yMaxVal / 4)).roundToDouble() *
                      (yMaxVal / 4);
                  if ((value - snap).abs() > yMaxVal * 1e-3) {
                    return const SizedBox.shrink();
                  }
                  return Text(
                    _fmtSec(snap.round()),
                    style: const TextStyle(fontSize: 10),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final ws = _weekBuckets[group.x].weekStart;
                return BarTooltipItem(
                  '${ws.month}/${ws.day}~\n${_fmtSec(rod.toY.round())}',
                  const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 年次タブ
// ─────────────────────────────────────────────────────────────────────────────

class _YearlyTab extends StatefulWidget {
  const _YearlyTab({required this.db});

  final dynamic db;

  @override
  State<_YearlyTab> createState() => _YearlyTabState();
}

class _YearlyTabState extends State<_YearlyTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late DateTime _yearStart;
  bool _loading = true;
  List<int> _monthlyTotals = List.filled(12, 0);
  Map<String, int> _byType = {};

  @override
  void initState() {
    super.initState();
    _yearStart = DateTime(DateTime.now().year, 1, 1);
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await StudyReportRepository.loadYearlySummary(
      widget.db,
      _yearStart,
    );
    if (mounted) setState(() {
      _monthlyTotals = data.monthlyTotals;
      _byType = data.byType;
      _loading = false;
    });
  }

  void _changeYear(int delta) {
    setState(() => _yearStart = DateTime(_yearStart.year + delta, 1, 1));
    unawaited(_load());
  }

  String _yearLabel() => '${_yearStart.year}年';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());

    final totalSec = _monthlyTotals.fold(0, (s, v) => s + v);

    return LayoutBuilder(builder: (context, constraints) {
      final chartH = (constraints.maxHeight * 0.45).clamp(200.0, 400.0);
      return SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  _buildPeriodNavigator(
                    context: context,
                    label: _yearLabel(),
                    onPrev: () => _changeYear(-1),
                    onNext: () => _changeYear(1),
                  ),
                  const Spacer(),
                  Text(
                    _fmtSec(totalSec),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: chartH,
              child: _buildChart(context, chartH),
            ),
            const Divider(height: 1),
            _buildTotalsTable(
              context: context,
              byType: _byType,
              totalSec: totalSec,
            ),
            const Divider(height: 1),
            _buildMonthlyTable(context),
          ],
        ),
      );
    });
  }

  Widget _buildChart(BuildContext context, double chartH) {
    final maxSec =
        _monthlyTotals.fold(0, (m, s) => s > m ? s : m);
    final yMaxVal = _yMax(maxSec);
    final primary = Theme.of(context).colorScheme.primary;
    const monthLabels = [
      '1', '2', '3', '4', '5', '6',
      '7', '8', '9', '10', '11', '12',
    ];

    final groups = <BarChartGroupData>[];
    for (int i = 0; i < 12; i++) {
      groups.add(
        BarChartGroupData(x: i, barRods: [
          BarChartRodData(
            toY: _monthlyTotals[i].toDouble(),
            width: 16,
            borderRadius: BorderRadius.circular(2),
            color: primary,
          ),
        ]),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 24, 12, 8),
      child: BarChart(
        BarChartData(
          maxY: yMaxVal,
          barGroups: groups,
          gridData: const FlGridData(show: true),
          borderData: FlBorderData(show: true),
          titlesData: FlTitlesData(
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= 12) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      monthLabels[i],
                      style: const TextStyle(fontSize: 10),
                    ),
                  );
                },
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 44,
                interval: yMaxVal / 4,
                getTitlesWidget: (value, meta) {
                  if (value == 0) {
                    return const Text(
                      '00:00',
                      style: TextStyle(fontSize: 10),
                    );
                  }
                  final snap = (value / (yMaxVal / 4)).roundToDouble() *
                      (yMaxVal / 4);
                  if ((value - snap).abs() > yMaxVal * 1e-3) {
                    return const SizedBox.shrink();
                  }
                  return Text(
                    _fmtSec(snap.round()),
                    style: const TextStyle(fontSize: 10),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final month = group.x + 1;
                return BarTooltipItem(
                  '${_yearStart.year}年${month}月\n${_fmtSec(rod.toY.round())}',
                  const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 年次のみ月別詳細テーブルを追加表示
  Widget _buildMonthlyTable(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Text(
                  '月',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              Expanded(
                flex: 6,
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
          itemCount: 12,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final sec = _monthlyTotals[i];
            return Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    flex: 4,
                    child: Text('${i + 1}月'),
                  ),
                  Expanded(
                    flex: 6,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        _fmtSec(sec),
                        style: sec == 0
                            ? TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              )
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
