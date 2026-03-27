// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:provider/provider.dart';
import '../models/inbox_task.dart' as inbox;
import '../models/actual_task.dart' as actual;
import '../models/block.dart' as block_model;
import '../screens/calendar_block_edit_screen.dart';
import '../utils/unified_screen_dialog.dart';
import 'calendar_settings.dart';
import '../services/calendar_service.dart';
import '../services/app_settings_service.dart';
import '../services/day_key_service.dart';
import '../providers/task_provider.dart';

class CalendarWidget extends StatelessWidget {
  final DateTime focusedDate;
  final DateTime? selectedDate;
  final CalendarSettings settings;
  final Function(DateTime, DateTime) onDaySelected;
  final Function(DateTime) onPageChanged;
  final List<dynamic> Function(DateTime) eventLoader;
  final Function(DateTime)? onYearViewDaySelected; // 年表示での日付選択用
  final Function(DateTime)? onMonthTitleTap; // 年表示で月タイトルタップ用

  const CalendarWidget({
    super.key,
    required this.focusedDate,
    required this.selectedDate,
    required this.settings,
    required this.onDaySelected,
    required this.onPageChanged,
    required this.eventLoader,
    this.onYearViewDaySelected,
    this.onMonthTitleTap,
  });

  double _monthBlockTitleFontSize(BuildContext context) {
    // PC（Web/デスクトップ）では月セル内の予定ブロック文字が小さすぎるため少し拡大。
    final width = MediaQuery.of(context).size.width;
    return width >= 900 ? 10 : 8;
  }

  @override
  Widget build(BuildContext context) {
    // NOTE:
    // 月表示（TableCalendar）は内部的にeventLoaderを呼ぶだけでは再描画されないケースがあり、
    // 予定編集で日付を変更しても「戻った直後に反映されない」不具合が起きる。
    // ここで TaskProvider を購読して、refreshTasks() による notifyListeners を確実に
    // CalendarWidget の再ビルドへ繋げる。
    return Consumer<TaskProvider>(
      builder: (context, taskProvider, _) {
        // 日表示の場合は時間軸付き1日レイアウト
        if (settings.viewType == CalendarViewType.day) {
          return _buildDayViewWithTimeAxis(context);
        }
        // 年表示の場合は12ヶ月分をグリッドで表示
        if (settings.viewType == CalendarViewType.year ||
            (settings.calendarFormat == CalendarFormat.month &&
                _isYearViewMode())) {
          return _buildYearView(context);
        }

        // 週表示も TableCalendar を使用して月表示と同様のイベント表示に統一

        final isWeekView = settings.calendarFormat == CalendarFormat.week;
        final isMonthGrid = settings.viewType == CalendarViewType.month &&
            settings.calendarFormat == CalendarFormat.month;
        final double rowHeight =
            isWeekView ? 56 : 84; // 週:やや高め, 月:複数行の予定が入る高さ
        final startKey = AppSettingsService.weekStartNotifier.value;
        StartingDayOfWeek starting = StartingDayOfWeek.sunday;
        switch (startKey) {
          case 'monday':
            starting = StartingDayOfWeek.monday;
            break;
          case 'tuesday':
            starting = StartingDayOfWeek.tuesday;
            break;
          case 'wednesday':
            starting = StartingDayOfWeek.wednesday;
            break;
          case 'thursday':
            starting = StartingDayOfWeek.thursday;
            break;
          case 'friday':
            starting = StartingDayOfWeek.friday;
            break;
          case 'saturday':
            starting = StartingDayOfWeek.saturday;
            break;
          case 'sunday':
          default:
            starting = StartingDayOfWeek.sunday;
            break;
        }

        const double daysOfWeekHeight = 16.0; // TableCalendarのデフォルトに合わせる（ズレ防止）

        if (!isMonthGrid) {
          return TableCalendar(
            firstDay: DateTime.utc(2020, 1, 1),
            lastDay: DateTime.utc(2030, 12, 31),
            focusedDay: focusedDate,
            selectedDayPredicate: (day) => isSameDay(selectedDate, day),
            calendarFormat: settings.calendarFormat,
            eventLoader: eventLoader,
            startingDayOfWeek: starting,
            daysOfWeekHeight: daysOfWeekHeight,
            rowHeight: rowHeight,
            onDaySelected: (sel, foc) {
              // TableCalendarは同月外タップ時のfocusedDayが意図と異なる場合があるため、
              // 選択日selを優先して渡す。
              onDaySelected(sel, sel);
            },
            onPageChanged: onPageChanged,
            headerVisible: false,
            calendarStyle: _buildCalendarStyle(context),
            headerStyle: _buildHeaderStyle(),
            calendarBuilders: _buildCalendarBuilders(),
          );
        }

        // --- Phase 2: 月表示（CalendarFormat.month）に終日横断バーを追加 ---
        // TableCalendar は「日付選択/ページング」のために維持し、終日バーはオーバーレイで描画する。
        // 二重表示防止のため、セル内リストから allDay=true は除外する（バー側で表現）。
        const int laneMax = 2;
        const double dayNumberAreaHeight = 25.0; // 既存セル内イベント開始(top=25)に合わせる
        const double eventLaneHeight = 14.0;
        const double barPadX = 4.0; // セル内リストと同じ left/right=4 に合わせる

        String ymdKey(DateTime d) =>
            DayKeyService.formatDayKeyYmd(d.year, d.month, d.day);

    // TableCalendar の実表示（4〜6週）に合わせてグリッド日数を動的に算出する。
    // ここを 6週(42日) 固定にすると、5週の月で「カレンダーがない領域」に
    // 終日横断バーが描画されてしまう。
    final monthFirst = DateTime(focusedDate.year, focusedDate.month, 1);
    final daysInMonth = DateTime(focusedDate.year, focusedDate.month + 1, 0).day;
    final int weekStartDow = _weekdayForStartingDayOfWeek(starting);
    final int delta = (monthFirst.weekday - weekStartDow + 7) % 7; // 月初の前に並ぶセル数
    final totalCells = delta + daysInMonth;
    final weeksNeeded = (totalCells / 7).ceil(); // 4〜6
    final gridCellCount = weeksNeeded * 7;
    final gridStart = DateTime(monthFirst.year, monthFirst.month, monthFirst.day - delta);
    final gridDays = <DateTime>[
      for (int i = 0; i < gridCellCount; i++)
        DateTime(gridStart.year, gridStart.month, gridStart.day + i),
    ];
    final gridDayKeyToIndex = <String, int>{
      for (int i = 0; i < gridDays.length; i++) ymdKey(gridDays[i]): i,
    };

    // 表示範囲の dayKey セット（最大42日）
    final visibleDayKeySet = <String>{
      for (final d in gridDays) ymdKey(d),
    };

        // allDay ブロックを抽出（交差判定は dayKeys 優先）
        final allDayBlocks = taskProvider.blocks
        .where((b) => !b.isDeleted && !b.isCompleted && !b.isPauseDerived)
        .where((b) => b.allDay == true)
        .where((b) {
          final keys = b.dayKeys;
          if (keys != null && keys.any(visibleDayKeySet.contains)) return true;
          final s = b.startAt;
          final e = b.endAtExclusive;
          if (s != null && e != null) {
            // 低頻度fallback（dayKeys欠落時）
            final ks = DayKeyService.computeDayKeysUtc(s, e);
            return ks.any(visibleDayKeySet.contains);
          }
          return false;
        })
        .toList();

    // 週行ごとのセグメントに分割（継続フラグ付き）
    final rowSegments =
        List<List<_MonthAllDaySeg>>.generate(weeksNeeded, (_) => []);
    for (final b in allDayBlocks) {
      // dayKeys から start/end（inclusive）を確定
      final keys = <String>{
        ...(b.dayKeys ?? const <String>[]),
      };
      if (keys.isEmpty && b.startAt != null && b.endAtExclusive != null) {
        keys.addAll(DayKeyService.computeDayKeysUtc(b.startAt!, b.endAtExclusive!));
      }
      if (keys.isEmpty) continue;
      final sorted = keys.toList()..sort();
      final startKey = sorted.first;
      final endKey = sorted.last;

      for (int row = 0; row < weeksNeeded; row++) {
        final rowStartIndex = row * 7;
        final rowEndIndex = rowStartIndex + 6;
        final rowStartKey = ymdKey(gridDays[rowStartIndex]);
        final rowEndKey = ymdKey(gridDays[rowEndIndex]);
        // rowと交差しない
        if (endKey.compareTo(rowStartKey) < 0) continue;
        if (startKey.compareTo(rowEndKey) > 0) continue;

        final segStartKey =
            startKey.compareTo(rowStartKey) < 0 ? rowStartKey : startKey;
        final segEndKey =
            endKey.compareTo(rowEndKey) > 0 ? rowEndKey : endKey;
        final segStartIdx = gridDayKeyToIndex[segStartKey];
        final segEndIdx = gridDayKeyToIndex[segEndKey];
        if (segStartIdx == null || segEndIdx == null) continue;
        final startCol = segStartIdx % 7;
        final endCol = segEndIdx % 7;
        rowSegments[row].add(
          _MonthAllDaySeg(
            block: b,
            row: row,
            startCol: startCol,
            endCol: endCol,
            contPrev: startKey.compareTo(rowStartKey) < 0,
            contNext: endKey.compareTo(rowEndKey) > 0,
          ),
        );
      }
    }

    // 行ごとに lane 割当（最大2段）+ overflow カウント
    final rowLaneCount = List<int>.filled(weeksNeeded, 0);
    final overflowCountByDayKey = <String, int>{};
    final placed = <_MonthAllDayPlaced>[];

    for (int row = 0; row < weeksNeeded; row++) {
      final segs = rowSegments[row]
        ..sort((a, b) {
          if (a.startCol != b.startCol) return a.startCol.compareTo(b.startCol);
          final alen = a.endCol - a.startCol;
          final blen = b.endCol - b.startCol;
          if (alen != blen) return blen.compareTo(alen);
          final at = (a.block.blockName?.isNotEmpty ?? false)
              ? a.block.blockName!
              : a.block.title;
          final bt = (b.block.blockName?.isNotEmpty ?? false)
              ? b.block.blockName!
              : b.block.title;
          return at.compareTo(bt);
        });

      final occ = List<List<bool>>.generate(laneMax, (_) => List<bool>.filled(7, false));
      int maxLaneUsed = 0;
      for (final s in segs) {
        int? lane;
        for (int l = 0; l < laneMax; l++) {
          bool free = true;
          for (int c = s.startCol; c <= s.endCol; c++) {
            if (occ[l][c]) {
              free = false;
              break;
            }
          }
          if (free) {
            lane = l;
            break;
          }
        }
        if (lane == null) {
          // 表示しきれない分は dayKey ごとに +n を出す
          final rowStartIndex = row * 7;
          for (int c = s.startCol; c <= s.endCol; c++) {
            final key = ymdKey(gridDays[rowStartIndex + c]);
            overflowCountByDayKey[key] = (overflowCountByDayKey[key] ?? 0) + 1;
          }
          continue;
        }
        for (int c = s.startCol; c <= s.endCol; c++) {
          occ[lane][c] = true;
        }
        if (lane + 1 > maxLaneUsed) maxLaneUsed = lane + 1;
        placed.add(_MonthAllDayPlaced(seg: s, lane: lane));
      }
      rowLaneCount[row] = maxLaneUsed;
    }

    // reservedHeight は週行単位（全セル同じ）なので dayKey -> reservedHeight に展開して渡す
    final reservedHeightByDayKey = <String, double>{};
    for (int row = 0; row < weeksNeeded; row++) {
      final reserved = rowLaneCount[row] * eventLaneHeight;
      final rowStartIndex = row * 7;
      for (int c = 0; c < 7; c++) {
        reservedHeightByDayKey[ymdKey(gridDays[rowStartIndex + c])] = reserved;
      }
    }

        return LayoutBuilder(
          builder: (context, constraints) {
            final cellWidth = constraints.maxWidth / 7;
            return Stack(
              children: [
                TableCalendar(
                  firstDay: DateTime.utc(2020, 1, 1),
                  lastDay: DateTime.utc(2030, 12, 31),
                  focusedDay: focusedDate,
                  selectedDayPredicate: (day) => isSameDay(selectedDate, day),
                  calendarFormat: settings.calendarFormat,
                  eventLoader: eventLoader,
                  startingDayOfWeek: starting,
                  // 月表示は「存在する週数のみ」表示して、オーバーレイと一致させる
                  sixWeekMonthsEnforced: false,
                  daysOfWeekHeight: daysOfWeekHeight,
                  rowHeight: rowHeight,
                  onDaySelected: (sel, foc) {
                    onDaySelected(sel, sel);
                  },
                  onPageChanged: onPageChanged,
                  headerVisible: false,
                  calendarStyle: _buildCalendarStyle(context),
                  headerStyle: _buildHeaderStyle(),
                  calendarBuilders: _buildCalendarBuilders(
                    monthReservedHeightByDayKey: reservedHeightByDayKey,
                    monthOverflowCountByDayKey: overflowCountByDayKey,
                  ),
                ),
                // 横断バー（週行×lane）
                for (final p in placed)
                  Positioned(
                    left: p.seg.startCol * cellWidth + barPadX,
                    width: (p.seg.endCol - p.seg.startCol + 1) * cellWidth -
                        barPadX * 2,
                    top: daysOfWeekHeight +
                        p.seg.row * rowHeight +
                        dayNumberAreaHeight +
                        p.lane * eventLaneHeight,
                    height: eventLaneHeight,
                    child: GestureDetector(
                      onTap: () async {
                        await showUnifiedScreenDialog<void>(
                          context: context,
                          builder: (_) => CalendarBlockEditScreen(
                            initialBlock: p.seg.block,
                          ),
                        );
                      },
                      child: _buildMonthBlockChip(
                        context,
                        title: (p.seg.block.blockName?.isNotEmpty ?? false)
                            ? p.seg.block.blockName!
                            : p.seg.block.title,
                        // 月セル内の通常ブロック表示に合わせて secondary 固定
                        color: Theme.of(context).colorScheme.secondary,
                        // 継続表現は “角丸の欠け” で統一（矢印は出さない）
                        roundLeft: !p.seg.contPrev,
                        roundRight: !p.seg.contNext,
                        tightHeight: eventLaneHeight,
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildMonthBlockChip(
    BuildContext context, {
    required String title,
    required Color color,
    required bool roundLeft,
    required bool roundRight,
    required double tightHeight,
  }) {
    // 既存の月セル内リスト（Container + 左色帯 + 文字）と同じ見た目を単一ソース化
    final fontSize = _monthBlockTitleFontSize(context);
    final scheme = Theme.of(context).colorScheme;
    final Color bg = () {
      // 透けない色味（Googleカレンダー寄せ）：Container系カラーを使う
      if (color.value == scheme.primary.value) return scheme.primaryContainer;
      if (color.value == scheme.secondary.value) return scheme.secondaryContainer;
      if (color.value == scheme.tertiary.value) return scheme.tertiaryContainer;
      return bgFallback(color, scheme);
    }();
    final Color textColor = () {
      if (color.value == scheme.primary.value) return scheme.onPrimaryContainer;
      if (color.value == scheme.secondary.value) return scheme.onSecondaryContainer;
      if (color.value == scheme.tertiary.value) return scheme.onTertiaryContainer;
      return scheme.onSurface;
    }();
    final radius = Radius.circular(2);
    return SizedBox(
      height: tightHeight,
      child: Container(
        // margin は横断バーでは不要（セル内リストは bottom=2 だが、laneで高さ管理するため）
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.horizontal(
            left: roundLeft ? radius : Radius.zero,
            right: roundRight ? radius : Radius.zero,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: fontSize,
                  color: textColor,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 月表示の「通常（時間あり）予定ブロック」表示
  /// - 背景は塗らない（反転しない）
  /// - ブロック名のみ（先頭の色ドットは付けない）
  Widget _buildMonthTimedBlockDotLine(
    BuildContext context, {
    required String title,
    required Color dotColor,
    required double tightHeight,
  }) {
    final fontSize = _monthBlockTitleFontSize(context);
    final scheme = Theme.of(context).colorScheme;
    final textColor = dotColor == Theme.of(context).disabledColor
        ? Theme.of(context).disabledColor
        : (Theme.of(context).textTheme.bodySmall?.color ?? scheme.onSurface);

    return SizedBox(
      height: tightHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: TextStyle(
            fontSize: fontSize,
            color: textColor,
            fontWeight: FontWeight.w500,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Color bgFallback(Color color, ColorScheme scheme) {
    // 既知のカラー以外は、そのまま背景にしても読めるようsurface上の文字色へ寄せる
    return color;
  }

  static int _weekdayForStartingDayOfWeek(StartingDayOfWeek starting) {
    // DateTime.weekday: Monday=1 ... Sunday=7
    switch (starting) {
      case StartingDayOfWeek.monday:
        return DateTime.monday;
      case StartingDayOfWeek.tuesday:
        return DateTime.tuesday;
      case StartingDayOfWeek.wednesday:
        return DateTime.wednesday;
      case StartingDayOfWeek.thursday:
        return DateTime.thursday;
      case StartingDayOfWeek.friday:
        return DateTime.friday;
      case StartingDayOfWeek.saturday:
        return DateTime.saturday;
      case StartingDayOfWeek.sunday:
      default:
        return DateTime.sunday;
    }
  }

  // 未使用メソッドのため削除
  /*Widget _buildWeekViewWithTimeAxis(BuildContext context, double rowHeight) {
    // 週の開始日を取得（月曜日）
    final weekStart = focusedDate.subtract(
      Duration(days: focusedDate.weekday - 1),
    );

    // 利用可能な高さを計算（ヘッダー分を引く）
    final screenHeight = MediaQuery.of(context).size.height;
    final availableHeight = screenHeight - 300; // ヘッダー、ボタン、余白分を引く
    final calculatedRowHeight = availableHeight / 24; // 24時間分に分割

    return Column(
      children: [
        // 曜日ヘッダー
        Container(
          height: 40,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor, width: 1),
            ),
          ),
          child: Row(
            children: [
              // 時間軸ヘッダー
              Container(
                width: 60,
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(color: Theme.of(context).dividerColor, width: 1),
                  ),
                ),
                child: const Center(
                  child: Text(
                    '時間',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      // use default text color in theme
                    ),
                  ),
                ),
              ),
              // 曜日ヘッダー
              Expanded(
                child: Row(
                  children: [
                    for (int i = 0; i < 7; i++)
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border(
                              right: BorderSide(
                                color: Theme.of(context).dividerColor,
                                width: i < 6 ? 0.5 : 0,
                              ),
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _getWeekdayText(
                                  weekStart.add(Duration(days: i)).weekday,
                                ),
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).textTheme.bodySmall?.color,
                                ),
                              ),
                              Text(
                                '${weekStart.add(Duration(days: i)).day}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: CalendarService.isHolidayCached(
                                          weekStart.add(Duration(days: i)))
                                      ? Theme.of(context).colorScheme.error
                                      : Theme.of(context).textTheme.bodyLarge?.color,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 時間軸とカレンダー本体（スクロール可能）
        Expanded(
          child: SingleChildScrollView(
            child: SizedBox(
              height: calculatedRowHeight * 24, // 24時間分の高さ
              child: Row(
                children: [
                  // 時間軸
                  Container(
                    width: 60,
                    decoration: BoxDecoration(
                      border: Border(
                        right: BorderSide(
                          color: Theme.of(context).dividerColor,
                          width: 1,
                        ),
                      ),
                    ),
                    child: Column(
                      children: [
                        for (int hour = 0; hour < 24; hour++)
                          Container(
                            height: calculatedRowHeight,
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: Theme.of(context).dividerColor,
                                  width: hour < 23 ? 0.5 : 0,
                                ),
                              ),
                            ),
                            child: Center(
                              child: Text(
                                '${hour.toString().padLeft(2, '0')}:00',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Theme.of(context).textTheme.bodySmall?.color,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // カレンダー部分
                  Expanded(
                    child: Column(
                      children: [
                        for (int hour = 0; hour < 24; hour++)
                          Container(
                            height: calculatedRowHeight,
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: Theme.of(context).dividerColor,
                                  width: hour < 23 ? 0.5 : 0,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                for (int day = 0; day < 7; day++)
                                  Expanded(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        border: Border(
                                          right: BorderSide(
                                            color: Theme.of(context).dividerColor,
                                            width: day < 6 ? 0.5 : 0,
                                          ),
                                        ),
                                      ),
                                      child: _buildTimeSlot(
                                        context,
                                        weekStart.add(Duration(days: day)),
                                        hour,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }*/

  CalendarStyle _buildCalendarStyle(BuildContext context) {
    return CalendarStyle(
      // 月が週途中で始まる/終わる場合も前後月の日付を表示する
      outsideDaysVisible: true,
      weekendTextStyle: TextStyle(
        fontSize: 12,
        color: settings.showWeekendColors
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).textTheme.bodyLarge?.color,
      ),
      holidayTextStyle: TextStyle(
        color: settings.showHolidays
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).textTheme.bodyLarge?.color,
      ),
      markerDecoration: BoxDecoration(
        color: settings.showTaskMarkers
            ? Theme.of(context).colorScheme.primary
            : const Color(0x00000000),
        shape: BoxShape.circle,
      ),
      cellMargin: EdgeInsets.zero,
      cellPadding: const EdgeInsets.all(8),
      defaultTextStyle: TextStyle(
          fontSize: 12, color: Theme.of(context).textTheme.bodyLarge?.color),
      selectedTextStyle: TextStyle(
          fontSize: 12, color: Theme.of(context).colorScheme.onPrimary),
      todayTextStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).textTheme.bodyLarge?.color),
      defaultDecoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor, width: 0.5),
      ),
      selectedDecoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        border:
            Border.all(color: Theme.of(context).colorScheme.primary, width: 1),
      ),
      todayDecoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withOpacity( 0.15),
        border:
            Border.all(color: Theme.of(context).colorScheme.primary, width: 1),
      ),
    );
  }

  HeaderStyle _buildHeaderStyle() {
    return HeaderStyle(
      formatButtonVisible: false,
      titleCentered: false,
      leftChevronVisible: false,
      rightChevronVisible: false,
      headerMargin: EdgeInsets.zero,
      headerPadding: EdgeInsets.zero,
    );
  }

  CalendarBuilders _buildCalendarBuilders({
    Map<String, double>? monthReservedHeightByDayKey,
    Map<String, int>? monthOverflowCountByDayKey,
  }) {
    return CalendarBuilders(
      defaultBuilder: (context, day, focusedDay) {
        final isWeekView = settings.calendarFormat == CalendarFormat.week;
        final dayKey = DayKeyService.formatDayKeyYmd(day.year, day.month, day.day);
        final reserved = (!isWeekView)
            ? (monthReservedHeightByDayKey?[dayKey] ?? 0.0)
            : 0.0;
        final overflow = (!isWeekView)
            ? (monthOverflowCountByDayKey?[dayKey] ?? 0)
            : 0;

        var events = eventLoader(day);
        // Phase 2（月表示）: allDay は横断バーで表現するためセル内リストから除外
        if (!isWeekView && events.isNotEmpty) {
          events = events
              .where((e) => !(e is block_model.Block && e.allDay == true))
              .toList();
        }

        return Container(
          margin: EdgeInsets.zero,
          decoration: BoxDecoration(
            border:
                Border.all(color: Theme.of(context).dividerColor, width: 0.5),
          ),
          child: Stack(
            children: [
              // 日付表示
              Positioned(
                top: isWeekView ? 8 : 4,
                left: isWeekView ? 8 : 4,
                child: Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: isWeekView ? 14 : 10,
                    fontWeight: FontWeight.bold,
                    color: CalendarService.isHolidayCached(day)
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
              ),
              // 週表示の場合は曜日も表示
              if (isWeekView)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Text(
                    _getWeekdayText(day.weekday),
                    style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).textTheme.bodySmall?.color),
                  ),
                ),
              // タスク表示（Googleカレンダー風）
              if (events.isNotEmpty)
                Positioned(
                  top: isWeekView ? 30 : (25 + reserved),
                  left: 4,
                  right: 4,
                  bottom: 2,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: events.map((event) {
                        String taskTitle = '';
                        Color taskColor = Theme.of(context).colorScheme.primary;

                        if (event is inbox.InboxTask) {
                          taskTitle = event.title;
                          taskColor = event.isCompleted
                              ? Theme.of(context).disabledColor
                              : Theme.of(context).colorScheme.primary;
                        } else if (event is actual.ActualTask) {
                          taskTitle = event.title;
                          taskColor = event.isCompleted
                              ? Theme.of(context).disabledColor
                              : Theme.of(context).colorScheme.tertiary;
                        } else if (event is block_model.Block) {
                          final b = event;
                          final name =
                              (b.blockName != null && b.blockName!.isNotEmpty)
                                  ? b.blockName!
                                  : '';
                          final title = (b.title.isNotEmpty) ? b.title : '';
                          taskTitle = name.isNotEmpty
                              ? name
                              : (title.isNotEmpty
                                  ? title
                                  : '${b.startHour.toString().padLeft(2, '0')}:${b.startMinute.toString().padLeft(2, '0')}');
                          if (b.excludeFromReport) {
                            // 集計外ブロックは強調カラーの薄い色で表示
                            taskColor = Theme.of(context).colorScheme.secondary.withOpacity(0.5);
                          } else {
                            taskColor = b.isCompleted
                                ? Theme.of(context).disabledColor
                                : Theme.of(context).colorScheme.secondary;
                          }
                        }

                        return GestureDetector(
                          onTap: () async {
                            if (event is block_model.Block) {
                              await showUnifiedScreenDialog<void>(
                                context: context,
                                builder: (_) => CalendarBlockEditScreen(
                                  initialBlock: event,
                                ),
                              );
                            }
                          },
                          child: (event is block_model.Block &&
                                  (event.allDay != true))
                              ? _buildMonthTimedBlockDotLine(
                                  context,
                                  title: taskTitle,
                                  dotColor: taskColor,
                                  tightHeight: 14,
                                )
                              : _buildMonthBlockChip(
                                  context,
                                  title: taskTitle,
                                  color: taskColor,
                                  roundLeft: true,
                                  roundRight: true,
                                  tightHeight: 14,
                                ),
                      );
                      }).toList(),
                    ),
                  ),
                ),
              if (!isWeekView && overflow > 0)
                Positioned(
                  right: 4,
                  bottom: 2,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withOpacity(0.9),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '+$overflow',
                      style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
      // 前月・翌月の日付（月表示の空白部分）を表示
      outsideBuilder: (context, day, focusedDay) {
        final isWeekView = settings.calendarFormat == CalendarFormat.week;

        return Container(
          margin: EdgeInsets.zero,
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor, width: 0.5),
          ),
          child: Stack(
            children: [
              Positioned(
                top: isWeekView ? 8 : 4,
                left: isWeekView ? 8 : 4,
                child: Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: isWeekView ? 14 : 10,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).disabledColor,
                  ),
                ),
              ),
            ],
          ),
        );
      },
      todayBuilder: (context, day, focusedDay) {
        final isWeekView = settings.calendarFormat == CalendarFormat.week;
        final dayKey = DayKeyService.formatDayKeyYmd(day.year, day.month, day.day);
        final reserved = (!isWeekView)
            ? (monthReservedHeightByDayKey?[dayKey] ?? 0.0)
            : 0.0;
        final overflow = (!isWeekView)
            ? (monthOverflowCountByDayKey?[dayKey] ?? 0)
            : 0;

        var events = eventLoader(day);
        if (!isWeekView && events.isNotEmpty) {
          events = events
              .where((e) => !(e is block_model.Block && e.allDay == true))
              .toList();
        }

        return Container(
          margin: EdgeInsets.zero,
          decoration: BoxDecoration(
            border: Border.all(
                color: Theme.of(context).colorScheme.primary, width: 1),
            color: Theme.of(context).colorScheme.primary.withOpacity( 0.06),
          ),
          child: Stack(
            children: [
              // 日付表示
              Positioned(
                top: isWeekView ? 8 : 4,
                left: isWeekView ? 8 : 4,
                child: Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: isWeekView ? 14 : 10,
                    fontWeight: FontWeight.bold,
                    color: CalendarService.isHolidayCached(day)
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
              ),
              // 週表示の場合は曜日も表示
              if (isWeekView)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Text(
                    _getWeekdayText(day.weekday),
                    style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).textTheme.bodySmall?.color),
                  ),
                ),
              // タスク表示（Googleカレンダー風）
              if (events.isNotEmpty)
                Positioned(
                  top: isWeekView ? 30 : (25 + reserved),
                  left: 4,
                  right: 4,
                  bottom: 2,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: events.map((event) {
                        String taskTitle = '';
                        Color taskColor = Theme.of(context).colorScheme.primary;

                        if (event is inbox.InboxTask) {
                          taskTitle = event.title;
                          taskColor = event.isCompleted
                              ? Theme.of(context).disabledColor
                              : Theme.of(context).colorScheme.primary;
                        } else if (event is actual.ActualTask) {
                          taskTitle = event.title;
                          taskColor = event.isCompleted
                              ? Theme.of(context).disabledColor
                              : Theme.of(context).colorScheme.tertiary;
                        } else if (event is block_model.Block) {
                          final b = event;
                          final name =
                              (b.blockName != null && b.blockName!.isNotEmpty)
                                  ? b.blockName!
                                  : '';
                          final title = (b.title.isNotEmpty) ? b.title : '';
                          taskTitle = name.isNotEmpty
                              ? name
                              : (title.isNotEmpty
                                  ? title
                                  : '${b.startHour.toString().padLeft(2, '0')}:${b.startMinute.toString().padLeft(2, '0')}');
                          if (b.excludeFromReport) {
                            // 集計外ブロックは強調カラーの薄い色で表示
                            taskColor = Theme.of(context).colorScheme.secondary.withOpacity(0.5);
                          } else {
                            taskColor = b.isCompleted
                                ? Theme.of(context).disabledColor
                                : Theme.of(context).colorScheme.secondary;
                          }
                        }

                        return GestureDetector(
                          onTap: () async {
                            if (event is block_model.Block) {
                              await showUnifiedScreenDialog<void>(
                                context: context,
                                builder: (_) => CalendarBlockEditScreen(
                                  initialBlock: event,
                                ),
                              );
                            }
                          },
                          child: (event is block_model.Block &&
                                  (event.allDay != true))
                              ? _buildMonthTimedBlockDotLine(
                                  context,
                                  title: taskTitle,
                                  dotColor: taskColor,
                                  tightHeight: 14,
                                )
                              : _buildMonthBlockChip(
                                  context,
                                  title: taskTitle,
                                  color: taskColor,
                                  roundLeft: true,
                                  roundRight: true,
                                  tightHeight: 14,
                                ),
                      );
                      }).toList(),
                    ),
                  ),
                ),
              if (!isWeekView && overflow > 0)
                Positioned(
                  right: 4,
                  bottom: 2,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withOpacity(0.9),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '+$overflow',
                      style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
      selectedBuilder: (context, day, focusedDay) {
        final isWeekView = settings.calendarFormat == CalendarFormat.week;
        final dayKey = DayKeyService.formatDayKeyYmd(day.year, day.month, day.day);
        final reserved = (!isWeekView)
            ? (monthReservedHeightByDayKey?[dayKey] ?? 0.0)
            : 0.0;
        final overflow = (!isWeekView)
            ? (monthOverflowCountByDayKey?[dayKey] ?? 0)
            : 0;

        var events = eventLoader(day);
        if (!isWeekView && events.isNotEmpty) {
          events = events
              .where((e) => !(e is block_model.Block && e.allDay == true))
              .toList();
        }

        return Container(
          margin: EdgeInsets.zero,
          decoration: BoxDecoration(
            border: Border.all(
                color: Theme.of(context).colorScheme.primary, width: 1),
            color: Theme.of(context).colorScheme.primary.withOpacity( 0.06),
          ),
          child: Stack(
            children: [
              // 日付表示
              Positioned(
                top: isWeekView ? 8 : 4,
                left: isWeekView ? 8 : 4,
                child: Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: isWeekView ? 14 : 10,
                    fontWeight: FontWeight.bold,
                    color: CalendarService.isHolidayCached(day)
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
              ),
              // 週表示の場合は曜日も表示
              if (isWeekView)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Text(
                    _getWeekdayText(day.weekday),
                    style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).textTheme.bodySmall?.color),
                  ),
                ),
              // タスク表示（Googleカレンダー風）
              if (events.isNotEmpty)
                Positioned(
                  top: isWeekView ? 30 : (25 + reserved),
                  left: 4,
                  right: 4,
                  bottom: 2,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: events.map((event) {
                        String taskTitle = '';
                        Color taskColor = Theme.of(context).colorScheme.primary;

                        if (event is inbox.InboxTask) {
                          taskTitle = event.title;
                          taskColor = event.isCompleted
                              ? Theme.of(context).disabledColor
                              : Theme.of(context).colorScheme.primary;
                        } else if (event is actual.ActualTask) {
                          taskTitle = event.title;
                          taskColor = event.isCompleted
                              ? Theme.of(context).disabledColor
                              : Theme.of(context).colorScheme.tertiary;
                        } else if (event is block_model.Block) {
                          final b = event;
                          final name =
                              (b.blockName != null && b.blockName!.isNotEmpty)
                                  ? b.blockName!
                                  : '';
                          final title = (b.title.isNotEmpty) ? b.title : '';
                          taskTitle = name.isNotEmpty
                              ? name
                              : (title.isNotEmpty
                                  ? title
                                  : '${b.startHour.toString().padLeft(2, '0')}:${b.startMinute.toString().padLeft(2, '0')}');
                          if (b.excludeFromReport) {
                            // 集計外ブロックは強調カラーの薄い色で表示
                            taskColor = Theme.of(context).colorScheme.secondary.withOpacity(0.5);
                          } else {
                            taskColor = b.isCompleted
                                ? Theme.of(context).disabledColor
                                : Theme.of(context).colorScheme.secondary;
                          }
                        }

                        return (event is block_model.Block &&
                                (event.allDay != true))
                            ? _buildMonthTimedBlockDotLine(
                                context,
                                title: taskTitle,
                                dotColor: taskColor,
                                tightHeight: 14,
                              )
                            : _buildMonthBlockChip(
                                context,
                                title: taskTitle,
                                color: taskColor,
                                roundLeft: true,
                                roundRight: true,
                                tightHeight: 14,
                              );
                      }).toList(),
                    ),
                  ),
                ),
              if (!isWeekView && overflow > 0)
                Positioned(
                  right: 4,
                  bottom: 2,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withOpacity(0.9),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '+$overflow',
                      style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
}

  String _getWeekdayText(int weekday) {
    switch (weekday) {
      case DateTime.monday:
        return '月';
      case DateTime.tuesday:
        return '火';
      case DateTime.wednesday:
        return '水';
      case DateTime.thursday:
        return '木';
      case DateTime.friday:
        return '金';
      case DateTime.saturday:
        return '土';
      case DateTime.sunday:
        return '日';
      default:
        return '';
    }
  }

  // 年表示モードかどうかを判定
  bool _isYearViewMode() {
    // カレンダー設定で年表示が有効になっている場合
    // または、月表示で年全体を表示する場合
    final result = settings.showYearView;
    return result;
  }

  // 年表示のビルダー
  Widget _buildYearView(BuildContext context) {
    final currentYear = focusedDate.year;

    return OrientationBuilder(
      builder: (context, orientation) {
        final screenSize = MediaQuery.of(context).size;
        final isPortrait = orientation == Orientation.portrait;

        // 画面の向きに応じてレイアウトを動的に変更
        int crossAxisCount;
        if (isPortrait) {
          // 縦長の場合：2列表示
          crossAxisCount = 2;
        } else {
          // 横長の場合：6列表示
          crossAxisCount = 6;
        }

        final availableWidth = screenSize.width - 20; // 左右のマージンを最小限に
        final monthWidth = availableWidth / crossAxisCount;
        final monthHeight = monthWidth * 1.2; // 縦横比を1.2に調整（より高く）

        return SingleChildScrollView(
          child: Column(
            children: [
              // 年ヘッダー
              Container(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '$currentYear年',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).textTheme.headlineSmall?.color,
                  ),
                ),
              ),
              // 12ヶ月のグリッド（動的レイアウト）
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    childAspectRatio: monthWidth / monthHeight,
                    crossAxisSpacing: 4,
                    mainAxisSpacing: 4,
                  ),
                  itemCount: 12,
                  itemBuilder: (context, index) {
                    final month = index + 1;
                    final monthDate = DateTime(currentYear, month, 1);
                    return _buildMonthCard(context, monthDate, monthWidth);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // 月カードのビルダー
  Widget _buildMonthCard(
    BuildContext context,
    DateTime monthDate,
    double width,
  ) {
    final monthName = _getMonthName(monthDate.month);
    final daysInMonth = DateTime(monthDate.year, monthDate.month + 1, 0).day;
    final firstDayOfMonth = DateTime(monthDate.year, monthDate.month, 1);
    final firstWeekday = firstDayOfMonth.weekday; // 1=月曜日, 7=日曜日

    // 必要な週数を動的に計算
    // lastDayOfMonthは使用されていないため削除

    // 月初の空白セル数 + 月の日数 = 総セル数
    final cellsBeforeMonth = firstWeekday - 1;
    final totalCells = cellsBeforeMonth + daysInMonth;

    // 必要な週数を計算（7で割って切り上げ）
    final weeksNeeded = (totalCells / 7).ceil();
    final actualCells = weeksNeeded * 7;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor, width: 0.5),
        borderRadius: BorderRadius.circular(4),
        color: Theme.of(context).cardColor,
      ),
      child: Column(
        children: [
          // 月ヘッダー
          GestureDetector(
            onTap: () {
              if (onMonthTitleTap != null) {
                onMonthTitleTap!(monthDate);
              }
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  topRight: Radius.circular(4),
                ),
              ),
              child: Text(
                monthName,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimary,
                    fontSize: 10,
                    fontWeight: FontWeight.bold),
              ),
            ),
          ),
          // 曜日ヘッダー
          SizedBox(
            height: 12,
            child: Row(
              children: ['日', '月', '火', '水', '木', '金', '土'].map((day) {
                return Expanded(
                  child: Container(
                    alignment: Alignment.center,
                    child: Text(
                      day,
                      style: TextStyle(
                          fontSize: 6,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).textTheme.bodySmall?.color),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          // カレンダーグリッド - 動的に計算された週数分のみ表示
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 最小高さを確保して5週分表示できるようにする
                final minHeight = weeksNeeded * 20.0; // 1週あたり最低20px
                final availableHeight = constraints.maxHeight;
                final calculatedHeight =
                    availableHeight > minHeight ? availableHeight : minHeight;

                return SizedBox(
                  height: calculatedHeight,
                  child: GridView.builder(
                    shrinkWrap: false,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 7,
                      childAspectRatio: 1,
                    ),
                    itemCount: actualCells, // 動的に計算されたセル数
                    itemBuilder: (context, index) {
                      // 月初の曜日（1=月曜, 7=日曜）に合わせて日付を計算
                      final dayNumber = index - (firstWeekday - 1) + 1;
                      final currentDate = DateTime(
                        monthDate.year,
                        monthDate.month,
                        dayNumber,
                      );

                      // 現在の月の日付かどうかを判定
                      final isCurrentMonth =
                          dayNumber >= 1 && dayNumber <= daysInMonth;

                      if (!isCurrentMonth) {
                        // 前月・翌月の日付は薄いグレーで表示
                        return Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context).dividerColor,
                              width: 0.25,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              '${currentDate.day}',
                              style: TextStyle(
                                  fontSize: 6,
                                  color: Theme.of(context).disabledColor),
                            ),
                          ),
                        );
                      }

                      final isToday = isSameDay(currentDate, DateTime.now());
                      final isSelected = isSameDay(
                        currentDate,
                        selectedDate ?? focusedDate,
                      );
                      // final dayOfWeek = (index % 7) + 1;

                      return Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                            width: 0.25,
                          ),
                          color: isToday
                              ? Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withOpacity( 0.06)
                              : isSelected
                                  ? Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withOpacity( 0.1)
                                  : const Color(0x00000000),
                        ),
                        child: GestureDetector(
                          onTap: () {
                            // 日付をタップした時にその月に移動
                            if (isCurrentMonth) {
                              final selectedDateTime = DateTime(
                                monthDate.year,
                                monthDate.month,
                                dayNumber,
                              );

                              // 年表示の場合は専用のコールバックを使用
                              if (onYearViewDaySelected != null) {
                                onYearViewDaySelected!(selectedDateTime);
                              } else {
                                // フォールバック: 通常のコールバックを使用
                                onDaySelected(selectedDateTime, selectedDateTime);
                                onPageChanged(selectedDateTime);
                              }
                            }
                          },
                          child: Center(
                            child: Text(
                              '$dayNumber',
                              style: TextStyle(
                                fontSize: 6,
                                fontWeight: isToday
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color:
                                    CalendarService.isHolidayCached(currentDate)
                                        ? Theme.of(context).colorScheme.error
                                        : Theme.of(context)
                                            .textTheme
                                            .bodyLarge
                                            ?.color,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // 月名を取得
  String _getMonthName(int month) {
    switch (month) {
      case 1:
        return '1月';
      case 2:
        return '2月';
      case 3:
        return '3月';
      case 4:
        return '4月';
      case 5:
        return '5月';
      case 6:
        return '6月';
      case 7:
        return '7月';
      case 8:
        return '8月';
      case 9:
        return '9月';
      case 10:
        return '10月';
      case 11:
        return '11月';
      case 12:
        return '12月';
      default:
        return '';
    }
  }

  Widget _buildDayViewWithTimeAxis(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final availableHeight = screenHeight - 200; // ヘッダーとボタン分を引く
    final rowHeight = availableHeight / 24;

    return ListView.builder(
      itemCount: 24,
      itemBuilder: (context, hour) {
        final timeLabel = '${hour.toString().padLeft(2, '0')}:00';
        return Container(
          height: rowHeight,
          decoration: BoxDecoration(
            border: Border(
              bottom:
                  BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 60,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  timeLabel,
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).textTheme.bodySmall?.color),
                ),
              ),
              VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
              Expanded(
                child: Container(
                    // ここに将来的にタスクやイベントを表示可能
                    ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MonthAllDaySeg {
  final block_model.Block block;
  final int row;
  final int startCol;
  final int endCol;
  final bool contPrev;
  final bool contNext;

  const _MonthAllDaySeg({
    required this.block,
    required this.row,
    required this.startCol,
    required this.endCol,
    required this.contPrev,
    required this.contNext,
  });
}

class _MonthAllDayPlaced {
  final _MonthAllDaySeg seg;
  final int lane;

  const _MonthAllDayPlaced({required this.seg, required this.lane});
}
