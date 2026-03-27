import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';

import '../../providers/task_provider.dart';
import '../../services/app_settings_service.dart';
import '../../utils/unified_screen_dialog.dart';
import '../calendar_block_edit_screen.dart';
import '../inbox_task_add_screen.dart';
import '../mobile_task_edit_screen.dart';
import '../../models/block.dart' as block;
import '../../models/actual_task.dart' as actual;
import '../../widgets/calendar_settings.dart';
import 'scroll_helpers.dart';

class CalendarDayDualLaneView extends StatefulWidget {
  final DateTime selectedDate;
  final CalendarSettings settings;
  final ScrollController dayScrollController;
  final bool Function() isDayInitialScrolled;
  final VoidCallback markDayInitialScrolled;
  final Future<void> Function(DateTime newSelectedDate) onDateChanged;
  /// 予実を左右2列（予定/実績）で表示するか。
  ///
  /// - true: 予定/実績を2列で表示
  /// - false: 1列表示（予定をベースにし、実績は同じ列に重ねて表示）
  ///
  /// NOTE: モバイルの「グリッド表示: 予定/実績/両方」設定は別途適用されます。
  final bool useDualLaneColumns;
  /// 上部に日付ナビ（前後・日付）を表示するか。
  ///
  /// - モバイル: 画面上部ヘッダーが無いので true
  /// - デスクトップ: `CalendarHeader` が日付と前後移動を担うため false（重複回避）
  final bool showInlineDateNavigation;

  const CalendarDayDualLaneView({
    super.key,
    required this.selectedDate,
    required this.settings,
    required this.dayScrollController,
    required this.isDayInitialScrolled,
    required this.markDayInitialScrolled,
    required this.onDateChanged,
    this.useDualLaneColumns = true,
    this.showInlineDateNavigation = true,
  });

  @override
  State<CalendarDayDualLaneView> createState() =>
      _CalendarDayDualLaneViewState();
}

class _CalendarDayDualLaneViewState extends State<CalendarDayDualLaneView> {
  final LayerLink _addMenuLink = LayerLink();
  OverlayEntry? _addMenuOverlay;
  Completer<_CalendarAddAction?>? _addMenuCompleter;

  Future<_CalendarAddAction?> _showAddMenu(BuildContext context) {
    if (_addMenuOverlay != null) {
      _closeAddMenu();
    }
    final completer = Completer<_CalendarAddAction?>();
    _addMenuCompleter = completer;
    final overlay = Overlay.of(context, rootOverlay: true);
    if (overlay == null) {
      completer.complete(null);
      return completer.future;
    }
    _addMenuOverlay = OverlayEntry(
      builder: (context) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final iconColor = scheme.onSurfaceVariant;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _closeAddMenu,
              ),
            ),
            CompositedTransformFollower(
              link: _addMenuLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomRight,
              followerAnchor: Alignment.bottomRight,
              offset: const Offset(0, 0),
              child: Material(
                color: Colors.transparent,
                elevation: 8,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 200,
                  decoration: BoxDecoration(
                    color: theme.cardColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.dividerColor),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        dense: true,
                        leading: Icon(Icons.event_available, color: iconColor),
                        title: const Text('ブロックを追加'),
                        onTap: () =>
                            _closeAddMenu(_CalendarAddAction.block),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        dense: true,
                        leading: Icon(Icons.add_task, color: iconColor),
                        title: const Text('タスクを追加'),
                        onTap: () => _closeAddMenu(_CalendarAddAction.task),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(_addMenuOverlay!);
    return completer.future;
  }

  void _closeAddMenu([_CalendarAddAction? action]) {
    _addMenuOverlay?.remove();
    _addMenuOverlay = null;
    final completer = _addMenuCompleter;
    _addMenuCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(action);
    }
  }

  @override
  void dispose() {
    _closeAddMenu();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final taskProvider = Provider.of<TaskProvider>(context);
    final scheme = Theme.of(context).colorScheme;
    final date = widget.selectedDate;
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEndExclusive = dayStart.add(const Duration(days: 1));
    const double baseHourHeight = 44.0; // デフォルトを半分に
    const double rowUnitHeight = 22.0; // 1行相当の高さ
    const double minBlockVisualHeight = 22.0; // ブロック最小表示高さ
    const timeColWidth = 60.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool isMobile = MediaQuery.of(context).size.width < 800;
        final bool useGrid = AppSettingsService.mobileDayUseGridNotifier.value;
        final int which = AppSettingsService.mobileDayGridWhichNotifier.value;
        final bool mobileGridSinglePlanned = isMobile && useGrid && which == 0;
        final bool mobileGridSingleActual = isMobile && useGrid && which == 1;
        final bool hidePlanned = mobileGridSingleActual;
        final bool hideActual = mobileGridSinglePlanned;
        final bool mobileSingleLane = hidePlanned || hideActual;

        final int colCount = widget.useDualLaneColumns
            ? (mobileSingleLane ? 1 : 2)
            : 1;
        final colWidth = (constraints.maxWidth - timeColWidth) / colCount;

        _PlannedSegment? plannedSegmentForDay(block.Block b) {
          if (b.allDay == true) return null; // 終日は上部レーンで描画する
          DateTime startLocal() {
            final s = b.startAt?.toLocal();
            if (s != null) return s;
            return DateTime(b.executionDate.year, b.executionDate.month,
                b.executionDate.day, b.startHour, b.startMinute);
          }

          DateTime endLocalExclusive() {
            final e = b.endAtExclusive?.toLocal();
            if (e != null) return e;
            return startLocal().add(Duration(minutes: b.estimatedDuration));
          }

          final s = startLocal();
          final e = endLocalExclusive();
          final segStart = s.isAfter(dayStart) ? s : dayStart;
          final segEnd = e.isBefore(dayEndExclusive) ? e : dayEndExclusive;
          if (!segStart.isBefore(segEnd)) return null;
          return _PlannedSegment(item: b, start: segStart, endExclusive: segEnd);
        }

        _ActualSegment? actualSegmentForDay(actual.ActualTask t) {
          final s = (t.startAt?.toLocal() ?? t.startTime.toLocal());
          final rawEnd = t.endAtExclusive?.toLocal() ??
              t.endTime?.toLocal() ??
              DateTime.now();
          final segStart = s.isAfter(dayStart) ? s : dayStart;
          final segEnd =
              rawEnd.isBefore(dayEndExclusive) ? rawEnd : dayEndExclusive;
          if (!segStart.isBefore(segEnd)) return null;
          return _ActualSegment(task: t, start: segStart, endExclusive: segEnd);
        }

        final plannedSegs = taskProvider
            .getBlocksForDate(date)
            .where((b) => !b.isDeleted && !b.isPauseDerived)
            .where((b) => b.allDay != true)
            .map(plannedSegmentForDay)
            .whereType<_PlannedSegment>()
            .toList();

        // 終日ブロック（この日に交差するもの）
        final allDayBlocks = taskProvider
            .getBlocksForDate(date)
            .where((b) => !b.isDeleted && !b.isPauseDerived)
            .where((b) => b.allDay == true)
            .toList();

        // NOTE:
        // この画面（予実対比/2レーン日表示）は「予定/実績の可視化」が主目的のため、
        // 「イベントのみ表示」設定に関わらず予定ブロック/実績ブロックを表示する。
        final actualSegs = taskProvider
            .getActualTasksForDate(date)
            .map(actualSegmentForDay)
            .whereType<_ActualSegment>()
            .toList();

        // 動的な時間高さ（スマホ・グリッド・予定のみ）
        // keep computed layout flags only; remove unused local
        // (no behavior change)
        late final List<double> hourHeights;
        late final List<double> prefix;
        late final double totalHeight;

        if (isMobile && useGrid) {
          final List<List<({int start, int end})>> hourSegments =
              List.generate(24, (_) => <({int start, int end})>[]);
          // 予定
          if (which != 1) {
            for (final seg in plannedSegs) {
              int remain = seg.durationMinutes;
              int h = seg.start.hour;
              int m = seg.start.minute;
              while (remain > 0 && h < 24) {
                final int slot = 60 - m;
                final int used = remain < slot ? remain : slot;
                hourSegments[h].add((start: m, end: m + used));
                remain -= used;
                h += 1;
                m = 0;
              }
            }
          }
          // 実績
          if (which != 0) {
            for (final seg in actualSegs) {
              final st = seg.start;
              final et = seg.endExclusive;
              DateTime cur = st;
              while (cur.isBefore(et)) {
                final hour = cur.hour;
                final min = cur.minute;
                final endOfHour =
                    DateTime(cur.year, cur.month, cur.day, cur.hour)
                        .add(const Duration(hours: 1));
                final segmentEnd = et.isBefore(endOfHour) ? et : endOfHour;
                final used = segmentEnd.difference(cur).inMinutes.clamp(0, 60);
                if (used > 0 && hour >= 0 && hour < 24) {
                  hourSegments[hour].add((start: min, end: min + used));
                }
                cur = segmentEnd;
              }
            }
          }
          final layout = CalendarScrollHelpers.computeDayHourLayout(
            hourSegments: hourSegments,
            baseHourHeight: baseHourHeight,
            rowUnitHeight: rowUnitHeight,
          );
          hourHeights = layout.hourHeights;
          prefix = layout.prefix;
          totalHeight = layout.totalHeight;
        } else {
          hourHeights = List<double>.filled(24, baseHourHeight);
          prefix = List<double>.generate(25, (i) => 0);
          for (int i = 1; i < 25; i++) {
            prefix[i] = prefix[i - 1] + hourHeights[i - 1];
          }
          totalHeight = prefix[24];
        }

        // Compute planned block layout (top/height) and assign up to 2 columns when overlapping
        final int nPlanned = plannedSegs.length;
        final List<int> startMins = List<int>.filled(nPlanned, 0);
        final List<int> endMins = List<int>.filled(nPlanned, 0);
        final List<double> tops = List<double>.filled(nPlanned, 0);
        final List<double> heights = List<double>.filled(nPlanned, 0);
        for (int i = 0; i < nPlanned; i++) {
          final seg = plannedSegs[i];
          final int start = seg.start.hour * 60 + seg.start.minute;
          final int dur = seg.durationMinutes;
          final int end = start + dur;
          startMins[i] = start;
          endMins[i] = end;
          // top
          tops[i] =
              prefix[seg.start.hour] + hourHeights[seg.start.hour] * (seg.start.minute / 60.0);
          // height across hours
          int remain = dur;
          int h = seg.start.hour;
          int m = seg.start.minute;
          double hgt = 0;
          while (remain > 0 && h < 24) {
            final int slot = 60 - m;
            final int used = remain < slot ? remain : slot;
            hgt += hourHeights[h] * (used / 60.0);
            remain -= used;
            h += 1;
            m = 0;
          }
          heights[i] = hgt < minBlockVisualHeight ? minBlockVisualHeight : hgt;
        }

        // Determine which items overlap with any other
        final List<bool> halfWidth = List<bool>.filled(nPlanned, false);
        for (int i = 0; i < nPlanned; i++) {
          for (int j = i + 1; j < nPlanned; j++) {
            if (startMins[i] < endMins[j] && endMins[i] > startMins[j]) {
              // strict overlap
              halfWidth[i] = true;
              halfWidth[j] = true;
            }
          }
        }

        // Assign columns (0 or 1) with a sweep; at boundary (end == start) no overlap
        final List<int> columns = List<int>.filled(nPlanned, 0);
        final List<int> order = List<int>.generate(nPlanned, (i) => i)
          ..sort((a, b) => startMins[a].compareTo(startMins[b]));
        final List<int> active = <int>[]; // indices currently overlapping
        final Map<int, int> activeCol = <int, int>{};
        for (final idx in order) {
          // remove inactive
          active.removeWhere((k) => endMins[k] <= startMins[idx]);
          activeCol.removeWhere((k, v) => endMins[k] <= startMins[idx]);
          // used columns among active
          final used = <int>{};
          for (final k in active) {
            used.add(activeCol[k] ?? 0);
          }
          int col;
          if (used.contains(0) && used.contains(1)) {
            // both used, still pick the one that will free earlier
            // choose column of the active item that ends sooner to share width
            int col0End = 1 << 30;
            int col1End = 1 << 30;
            for (final k in active) {
              final c = activeCol[k] ?? 0;
              if (c == 0 && endMins[k] < col0End) col0End = endMins[k];
              if (c == 1 && endMins[k] < col1End) col1End = endMins[k];
            }
            col = col0End <= col1End ? 0 : 1;
          } else if (!used.contains(0)) {
            col = 0;
          } else {
            col = 1;
          }
          columns[idx] = col;
          active.add(idx);
          activeCol[idx] = col;
        }

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!widget.isDayInitialScrolled() &&
              widget.settings.viewType == CalendarViewType.day &&
              widget.dayScrollController.hasClients) {
            final now = DateTime.now();
            final int h = now.hour;
            final double currentY =
                prefix[h] + hourHeights[h] * (now.minute / 60.0);
            final double viewport =
                widget.dayScrollController.position.viewportDimension;
            final double maxScroll =
                (totalHeight - viewport).clamp(0.0, double.infinity);
            final double target =
                (currentY - viewport / 2).clamp(0.0, maxScroll);
            widget.dayScrollController.jumpTo(target);
            widget.markDayInitialScrolled();
          }
        });

        Widget buildPlannedLane() {
          return SizedBox(
            width: colWidth,
            child: Column(
              children: [
                for (int h = 0; h < 24; h++)
                  GestureDetector(
                    onTap: () async {
                      final changed = await showUnifiedScreenDialog<bool>(
                        context: context,
                        builder: (_) => CalendarBlockEditScreen(
                          initialDate: DateTime(date.year, date.month, date.day),
                          initialStart: TimeOfDay(hour: h, minute: 0),
                          isEvent: true,
                        ),
                      );
                      if (changed == true && mounted) {
                        await Provider.of<TaskProvider>(context, listen: false)
                            .refreshTasks();
                        if (mounted) setState(() {});
                      }
                    },
                    child: Container(
                      height: hourHeights[h],
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(color: Theme.of(context).dividerColor),
                          right:
                              BorderSide(color: Theme.of(context).dividerColor),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        }

        Widget buildActualLane() {
          return SizedBox(
            width: colWidth,
            child: Column(
              children: [
                for (int h = 0; h < 24; h++)
                  Container(
                    height: hourHeights[h],
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: Theme.of(context).dividerColor),
                        right: BorderSide(color: Theme.of(context).dividerColor),
                      ),
                    ),
                  ),
              ],
            ),
          );
        }

        double plannedLaneLeft() => timeColWidth + 2;

        double actualLaneLeft() {
          const base = timeColWidth + 2;
          // 1列表示の場合は、予実2列表示がオフのときは右半分に配置
          // モバイル実績のみ（= 1列）では先頭列に描画
          if (colCount == 1) {
            // useDualLaneColumnsがfalseのときは右半分に配置
            if (!widget.useDualLaneColumns && !hidePlanned) {
              return base + colWidth / 2.0;
            }
            return base;
          }
          return base + colWidth + 2;
        }

        return Stack(
          children: [
            Column(
              children: [
                if (widget.showInlineDateNavigation)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      border: Border(
                        bottom: BorderSide(color: Theme.of(context).dividerColor),
                      ),
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chevron_left),
                          onPressed: () async {
                            final d = date.subtract(const Duration(days: 1));
                            await widget
                                .onDateChanged(DateTime(d.year, d.month, d.day));
                          },
                          tooltip: '前の日',
                        ),
                        Expanded(
                          child: Center(
                            child: Text(
                              '${date.month}月${date.day}日 (${[
                                '月',
                                '火',
                                '水',
                                '木',
                                '金',
                                '土',
                                '日'
                              ][date.weekday - 1]})',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right),
                          onPressed: () async {
                            final d = date.add(const Duration(days: 1));
                            await widget
                                .onDateChanged(DateTime(d.year, d.month, d.day));
                          },
                          tooltip: '次の日',
                        ),
                        IconButton(
                          icon: const Icon(Icons.calendar_today),
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: date,
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2030),
                            );
                            if (picked != null) {
                              await widget.onDateChanged(
                                DateTime(picked.year, picked.month, picked.day),
                              );
                            }
                          },
                          tooltip: '日付選択',
                        ),
                      ],
                    ),
                  ),
            if (allDayBlocks.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border(
                    bottom: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                ),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final b in allDayBlocks.take(3))
                      InkWell(
                        onTap: () async {
                          final changed = await showUnifiedScreenDialog<bool>(
                            context: context,
                            builder: (_) =>
                                CalendarBlockEditScreen(initialBlock: b),
                          );
                          if (changed == true && mounted) {
                            await Provider.of<TaskProvider>(context, listen: false)
                                .refreshTasks();
                            if (mounted) setState(() {});
                          }
                        },
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 260),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: b.excludeFromReport
                                ? (b.isEvent == true
                                    ? scheme.tertiaryContainer.withOpacity(0.4)
                                    : scheme.secondaryContainer.withOpacity(0.4))
                                : (b.isEvent == true
                                    ? scheme.tertiaryContainer
                                    : scheme.secondaryContainer),
                            border: Border.all(
                              color: b.excludeFromReport
                                  ? (b.isEvent == true
                                      ? scheme.tertiary.withOpacity(0.5)
                                      : scheme.secondary.withOpacity(0.5))
                                  : (b.isEvent == true
                                      ? scheme.tertiary
                                      : scheme.secondary),
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            (b.blockName?.isNotEmpty ?? false)
                                ? b.blockName!
                                : b.title,
                            style: TextStyle(
                              fontSize: 12,
                              color: b.excludeFromReport
                                  ? scheme.onSurface.withOpacity(0.75)
                                  : null,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    if (allDayBlocks.length > 3)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '他${allDayBlocks.length - 3}件',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            SizedBox(
              height: 24,
              child: Row(
                children: [
                  const SizedBox(width: timeColWidth),
                  if (isMobile && useGrid && which == 2)
                    Container(
                      width: colWidth,
                      alignment: Alignment.center,
                      child: const Text('予定',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                  if (isMobile && useGrid && which == 2)
                    Container(
                      width: colWidth,
                      alignment: Alignment.center,
                      child: const Text('実績',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold)),
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: widget.dayScrollController,
                child: SizedBox(
                  height: totalHeight,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Row(
                          children: [
                            SizedBox(
                              width: timeColWidth,
                              child: Column(
                                children: [
                                  for (int h = 0; h < 24; h++)
                                    SizedBox(
                                      height: hourHeights[h],
                                      child: Align(
                                        alignment: Alignment.topRight,
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                              right: 4.0, top: 0),
                                          child: Transform.translate(
                                            offset: const Offset(0, -8),
                                            child: Text(
                                              '${h.toString().padLeft(2, '0')}:00',
                                              style: TextStyle(
                                                  fontSize: 10,
                                                  color: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.color),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (colCount == 1) ...[
                              // 1列表示（モバイルの予定のみ/実績のみ、またはPCの単列モード）
                              if (hidePlanned) buildActualLane() else buildPlannedLane(),
                            ] else ...[
                              // 2列表示（予定/実績）
                              if (!hidePlanned) buildPlannedLane(),
                              if (!hideActual) buildActualLane(),
                            ],
                          ],
                        ),
                      ),
                      if (!hidePlanned)
                        for (int i = 0; i < plannedSegs.length; i++)
                          Positioned(
                            left: (() {
                              final double baseLeft = plannedLaneLeft();
                              if (halfWidth[i] && columns[i] == 1) {
                                return baseLeft + colWidth / 2.0;
                              }
                              return baseLeft;
                            })(),
                            width: halfWidth[i]
                                ? (colWidth / 2.0 - 4)
                                : (colWidth - 4),
                            top: tops[i],
                            height: heights[i],
                            child: GestureDetector(
                              onTap: () async {
                                final e = plannedSegs[i].item;
                                final changed = await showUnifiedScreenDialog<bool>(
                                  context: context,
                                  builder: (_) => CalendarBlockEditScreen(
                                    initialBlock: e,
                                  ),
                                );
                                if (changed == true && mounted) {
                                  await Provider.of<TaskProvider>(context,
                                          listen: false)
                                      .refreshTasks();
                                  if (mounted) setState(() {});
                                }
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  color: plannedSegs[i].item.excludeFromReport
                                      ? (plannedSegs[i].item.isEvent
                                          ? scheme.tertiaryContainer.withOpacity(0.4)
                                          : (plannedSegs[i].item.creationMethod ==
                                                  block.TaskCreationMethod.manual
                                              ? scheme.secondaryContainer.withOpacity(0.4)
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .primaryContainer
                                                  .withOpacity(0.4)))
                                      : (plannedSegs[i].item.isEvent
                                          ? scheme.tertiaryContainer
                                          : (plannedSegs[i].item.creationMethod ==
                                                  block.TaskCreationMethod.manual
                                              ? scheme.secondaryContainer
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .primaryContainer)),
                                  border: Border.all(
                                    color: plannedSegs[i].item.excludeFromReport
                                        ? (plannedSegs[i].item.isEvent
                                            ? scheme.tertiary.withOpacity(0.5)
                                            : (plannedSegs[i].item.creationMethod ==
                                                        block.TaskCreationMethod
                                                            .manual
                                                    ? scheme.secondary.withOpacity(0.5)
                                                    : Theme.of(context)
                                                        .colorScheme
                                                        .primary
                                                        .withOpacity(0.5)))
                                        : (plannedSegs[i].item.isEvent
                                            ? scheme.tertiary
                                            : (plannedSegs[i].item.creationMethod ==
                                                        block.TaskCreationMethod
                                                            .manual
                                                    ? scheme.secondary
                                                    : Theme.of(context)
                                                        .colorScheme
                                                        .primary)),
                                    width: plannedSegs[i].item.excludeFromReport ? 1.0 : 1.0,
                                  ),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        (plannedSegs[i].item.blockName
                                                    ?.isNotEmpty ??
                                                false)
                                            ? plannedSegs[i].item.blockName!
                                            : plannedSegs[i].item.title,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: plannedSegs[i].item.excludeFromReport
                                              ? scheme.onSurface.withOpacity(0.75)
                                              : null,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      if (!hideActual)
                        for (final seg in actualSegs)
                          Positioned(
                            left: actualLaneLeft(),
                            width: (colCount == 1 && !widget.useDualLaneColumns && !hidePlanned)
                                ? (colWidth / 2.0 - 4)
                                : (colWidth - 4),
                            top: (() {
                              final st = seg.start;
                              return prefix[st.hour] +
                                  hourHeights[st.hour] * (st.minute / 60.0);
                            })(),
                            height: (() {
                              final minutes = seg.durationMinutes;
                              int remain = minutes;
                              int h = seg.start.hour;
                              int m = seg.start.minute;
                              double hgt = 0;
                              while (remain > 0 && h < 24) {
                                final int slot = 60 - m;
                                final int used = remain < slot ? remain : slot;
                                hgt += hourHeights[h] * (used / 60.0);
                                remain -= used;
                                h += 1;
                                m = 0;
                              }
                              return hgt < minBlockVisualHeight
                                  ? minBlockVisualHeight
                                  : hgt;
                            })(),
                            child: GestureDetector(
                              onTap: () async {
                                final changed = await showUnifiedScreenDialog<bool>(
                                  context: context,
                                  builder: (_) =>
                                      MobileTaskEditScreen(task: seg.task),
                                );
                                if (changed == true && mounted) {
                                  Provider.of<TaskProvider>(context,
                                          listen: false)
                                      .refreshTasks();
                                }
                              },
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .secondary
                                      .withOpacity( 0.12),
                                  border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .secondary
                                          .withOpacity( 0.3)),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                child: Text(
                                  seg.task.title,
                                  style: const TextStyle(fontSize: 10),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                    ],
                  ),
                ),
              ),
            ),
            ],
          ),
          // FAB for adding items
          Positioned(
              right: 16,
              bottom: 16,
              child: CompositedTransformTarget(
                link: _addMenuLink,
                child: FloatingActionButton(
                  heroTag: 'day_view_add_item_fab',
                  onPressed: () async {
                    final action = await _showAddMenu(context);
                    if (action == null || !mounted) return;
                    if (action == _CalendarAddAction.block) {
                      final changed = await showUnifiedScreenDialog<bool>(
                        context: context,
                        builder: (_) => CalendarBlockEditScreen(
                          initialDate: DateTime(date.year, date.month, date.day),
                          initialStart: TimeOfDay.fromDateTime(DateTime.now()),
                          isEvent: false,
                        ),
                      );
                      if (changed == true && mounted) {
                        await Provider.of<TaskProvider>(context, listen: false)
                            .refreshTasks();
                        if (mounted) setState(() {});
                      }
                    } else if (action == _CalendarAddAction.task) {
                      final changed = await showUnifiedScreenDialog<bool>(
                        context: context,
                        builder: (_) => InboxTaskAddScreen(
                          initialDate: DateTime(date.year, date.month, date.day),
                        ),
                      );
                      if (changed == true && mounted) {
                        await Provider.of<TaskProvider>(context, listen: false)
                            .refreshTasks();
                        if (mounted) setState(() {});
                      }
                    }
                  },
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  child: const Icon(Icons.add),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

enum _CalendarAddAction { block, task }

class _PlannedSegment {
  final block.Block item;
  final DateTime start;
  final DateTime endExclusive;

  const _PlannedSegment({
    required this.item,
    required this.start,
    required this.endExclusive,
  });

  int get durationMinutes => endExclusive.difference(start).inMinutes.clamp(1, 24 * 60);
}

class _ActualSegment {
  final actual.ActualTask task;
  final DateTime start;
  final DateTime endExclusive;

  const _ActualSegment({
    required this.task,
    required this.start,
    required this.endExclusive,
  });

  int get durationMinutes => endExclusive.difference(start).inMinutes.clamp(1, 24 * 60);
}
