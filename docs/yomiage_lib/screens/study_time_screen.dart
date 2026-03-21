// ignore_for_file: library_private_types_in_public_api

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:yomiage/services/study_time_service.dart';
import 'package:intl/intl.dart';

// 週 / 月 切替用
enum TimeViewMode { week, month }

class StudyTimeScreen extends StatefulWidget {
  const StudyTimeScreen({Key? key}) : super(key: key);

  @override
  _StudyTimeScreenState createState() => _StudyTimeScreenState();
}

class _StudyTimeScreenState extends State<StudyTimeScreen> {
  // 表示モード
  TimeViewMode _viewMode = TimeViewMode.week;

  final _studyTimeService = StudyTimeService();
  Map<DateTime, int> _weeklyStudyTime = {};

  // 現在表示している週の開始 (月曜0:00)
  late DateTime _currentWeekStart;

  // 月表示用: 当月1日 0:00
  late DateTime _currentMonthStart;

  DateTime _getStartOfWeek(DateTime date) {
    final tmp = date.subtract(Duration(days: date.weekday - 1));
    return DateTime(tmp.year, tmp.month, tmp.day);
  }

  @override
  void initState() {
    super.initState();
    _currentWeekStart = _getStartOfWeek(DateTime.now());
    _currentMonthStart = DateTime(DateTime.now().year, DateTime.now().month, 1);
    _loadWeeklyStudyTime();
  }

  Future<void> _loadWeeklyStudyTime() async {
    Map<DateTime, int> studyTime;
    if (_viewMode == TimeViewMode.week) {
      studyTime =
          await _studyTimeService.getStudyTimeForWeek(_currentWeekStart);
    } else {
      studyTime =
          await _studyTimeService.getStudyTimeForMonth(_currentMonthStart);
    }
    setState(() {
      _weeklyStudyTime = studyTime;
    });
  }

  void _goPreviousWeek() {
    setState(() {
      _currentWeekStart = _currentWeekStart.subtract(const Duration(days: 7));
    });
    _loadWeeklyStudyTime();
  }

  void _goNextWeek() {
    // 一週間進めても未来週を超えない場合のみ
    final next = _currentWeekStart.add(const Duration(days: 7));
    final thisWeekStart = _getStartOfWeek(DateTime.now());
    if (next.isAfter(thisWeekStart)) return;
    setState(() {
      _currentWeekStart = next;
    });
    _loadWeeklyStudyTime();
  }

  void _goPreviousMonth() {
    setState(() {
      _currentMonthStart =
          DateTime(_currentMonthStart.year, _currentMonthStart.month - 1, 1);
    });
    _loadWeeklyStudyTime();
  }

  void _goNextMonth() {
    final next =
        DateTime(_currentMonthStart.year, _currentMonthStart.month + 1, 1);
    final thisMonthStart =
        DateTime(DateTime.now().year, DateTime.now().month, 1);
    if (next.isAfter(thisMonthStart)) return;
    setState(() {
      _currentMonthStart = next;
    });
    _loadWeeklyStudyTime();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('学習時間'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 表示モード切替トグル
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: _viewMode == TimeViewMode.week ? '前の週' : '前の月',
                  onPressed: _viewMode == TimeViewMode.week
                      ? _goPreviousWeek
                      : _goPreviousMonth,
                ),
                Text(
                  _viewMode == TimeViewMode.week
                      ? _formatWeekRange(_currentWeekStart)
                      : _formatMonthRange(_currentMonthStart),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  tooltip: _viewMode == TimeViewMode.week ? '次の週' : '次の月',
                  onPressed: _viewMode == TimeViewMode.week
                      ? (_currentWeekStart
                              .add(const Duration(days: 7))
                              .isAfter(_getStartOfWeek(DateTime.now()))
                          ? null
                          : _goNextWeek)
                      : (_currentMonthStart.year == DateTime.now().year &&
                              _currentMonthStart.month == DateTime.now().month
                          ? null
                          : _goNextMonth),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 切り替えボタン
            Center(
              child: ToggleButtons(
                isSelected: [
                  _viewMode == TimeViewMode.week,
                  _viewMode == TimeViewMode.month
                ],
                onPressed: (index) {
                  setState(() {
                    _viewMode =
                        index == 0 ? TimeViewMode.week : TimeViewMode.month;
                  });
                  _loadWeeklyStudyTime();
                },
                children: const [Text('週'), Text('月')],
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: _buildBarChart(),
            ),
          ],
        ),
      ),
    );
  }

  double _getMaxStudyTime() {
    if (_weeklyStudyTime.isEmpty) return 3600; // デフォルト1時間
    return _weeklyStudyTime.values.reduce((a, b) => a > b ? a : b).toDouble();
  }

  List<BarChartGroupData> _getBarGroups() {
    if (_viewMode == TimeViewMode.week) {
      final startOfWeek = _currentWeekStart;
      return List.generate(7, (index) {
        final date = startOfWeek.add(Duration(days: index));
        final key = DateTime(date.year, date.month, date.day);
        final duration = _weeklyStudyTime[key] ?? 0;
        return BarChartGroupData(
          x: index,
          barRods: [
            BarChartRodData(
              toY: duration.toDouble(),
              color: Colors.blue,
              width: 20,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(4)),
            ),
          ],
        );
      });
    } else {
      final daysInMonth = DateUtils.getDaysInMonth(
          _currentMonthStart.year, _currentMonthStart.month);
      return List.generate(daysInMonth, (index) {
        final date = DateTime(
            _currentMonthStart.year, _currentMonthStart.month, index + 1);
        final key = date;
        final duration = _weeklyStudyTime[key] ?? 0;
        return BarChartGroupData(
          x: index,
          barRods: [
            BarChartRodData(
              toY: duration.toDouble(),
              color: Colors.green,
              width: 10,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(4)),
            ),
          ],
        );
      });
    }
  }

  DateTime _getDateForIndex(int index) {
    if (_viewMode == TimeViewMode.week) {
      return _currentWeekStart.add(Duration(days: index));
    } else {
      return DateTime(
          _currentMonthStart.year, _currentMonthStart.month, index + 1);
    }
  }

  Widget _buildBarChart() {
    final barChart = BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: _getMaxStudyTime(),
        barTouchData: BarTouchData(
          enabled: true,
          touchTooltipData: BarTouchTooltipData(
            tooltipBgColor: Colors.blueGrey,
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final date = _getDateForIndex(groupIndex);
              final duration =
                  _weeklyStudyTime[DateTime(date.year, date.month, date.day)] ??
                      0;
              return BarTooltipItem(
                '${(_viewMode == TimeViewMode.week ? DateFormat('MM/dd') : DateFormat('d')).format(date)}\n${_formatDuration(duration)}',
                const TextStyle(color: Colors.white),
              );
            },
          ),
        ),
        titlesData: FlTitlesData(
          show: true,
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final date = _getDateForIndex(value.toInt());
                return Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    _viewMode == TimeViewMode.week
                        ? DateFormat('E').format(date)
                        : DateFormat('d').format(date),
                    style: const TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (value, meta) {
                return Text(
                  _formatDuration(value.toInt()),
                  style: const TextStyle(
                    color: Colors.grey,
                    fontWeight: FontWeight.bold,
                    fontSize: 10,
                  ),
                );
              },
            ),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
        ),
        borderData: FlBorderData(show: false),
        barGroups: _getBarGroups(),
      ),
    );

    if (_viewMode == TimeViewMode.month) {
      final daysInMonth = DateUtils.getDaysInMonth(
          _currentMonthStart.year, _currentMonthStart.month);
      // スクロール可能な横幅を確保
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: daysInMonth * 18.0,
          child: barChart,
        ),
      );
    }
    return barChart;
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0) {
      return '${hours}h${minutes}m';
    }
    return '${minutes}m';
  }

  String _formatWeekRange(DateTime weekStart) {
    final formatter = DateFormat('MM/dd');
    final startStr = formatter.format(weekStart);
    final endStr = formatter.format(weekStart.add(const Duration(days: 6)));
    return '$startStr - $endStr';
  }

  String _formatMonthRange(DateTime monthStart) {
    final formatter = DateFormat('yyyy/MM');
    return formatter.format(monthStart);
  }
}
