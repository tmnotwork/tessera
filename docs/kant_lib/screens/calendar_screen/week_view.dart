import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';

import '../../providers/task_provider.dart';
import '../../services/app_settings_service.dart';
import '../../services/day_key_service.dart';
import '../../utils/unified_screen_dialog.dart';
import '../calendar_block_edit_screen.dart';
import '../inbox_task_add_screen.dart';
import '../../models/block.dart' as block;
import '../../widgets/calendar_settings.dart';
import 'scroll_helpers.dart';
import 'week_header_row.dart';

class CalendarWeekView extends StatefulWidget {
  final DateTime focusedDate;
  final CalendarSettings settings;
  final bool showEventsOnly;
  final ScrollController weekScrollController;
  final bool Function() isWeekInitialScrolled;
  final VoidCallback markWeekInitialScrolled;
  final void Function(DateTime day) onTapHeaderGoToDay;

  const CalendarWeekView({
    super.key,
    required this.focusedDate,
    required this.settings,
    required this.showEventsOnly,
    required this.weekScrollController,
    required this.isWeekInitialScrolled,
    required this.markWeekInitialScrolled,
    required this.onTapHeaderGoToDay,
  });

  @override
  State<CalendarWeekView> createState() => _CalendarWeekViewState();
}

class _CalendarWeekViewState extends State<CalendarWeekView> {
  int? _hoveredHeaderIndex;
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

  Color _weekBlockBackground({
    required Color accent,
    required ColorScheme scheme,
    bool isExcluded = false,
  }) {
    if (isExcluded) {
      // 集計外ブロックは強調カラーの薄い色で表示
      return accent.withOpacity(0.4);
    }
    // 週表示では「半透明に見える」問題があったため、
    // ブロック背景はテーマ色（accent）をそのまま不透明で使用する。
    // NOTE: accent は通常 0xFF.. の不透明色。
    return accent;
  }

  @override
  Widget build(BuildContext context) {
    final taskProvider = Provider.of<TaskProvider>(context);
    final scheme = Theme.of(context).colorScheme;
    // テーマの primary 色を使用（テーマ切替に追従）
    final accent = scheme.primary;
    // デフォルトのブロック背景色（集計外でない場合）
    final defaultBlockBg = _weekBlockBackground(accent: accent, scheme: scheme);
    final onBlockBg =
        ThemeData.estimateBrightnessForColor(defaultBlockBg) == Brightness.dark
            ? Colors.white
            : Colors.black;
    // 週開始曜日を設定（AppSettingsService.weekStartNotifier）に統一する
    final startKey = AppSettingsService.weekStartNotifier.value;
    final int weekStartDow = switch (startKey) {
      'monday' => DateTime.monday,
      'tuesday' => DateTime.tuesday,
      'wednesday' => DateTime.wednesday,
      'thursday' => DateTime.thursday,
      'friday' => DateTime.friday,
      'saturday' => DateTime.saturday,
      'sunday' => DateTime.sunday,
      _ => DateTime.sunday,
    };
    final delta = (widget.focusedDate.weekday - weekStartDow + 7) % 7;
    final startOfWeek = widget.focusedDate.subtract(Duration(days: delta));
    final days = List.generate(
        7,
        (i) =>
            DateTime(startOfWeek.year, startOfWeek.month, startOfWeek.day + i));

    // Week view should be resilient even if there are no blocks, or if some
    // blocks have legacy/invalid hour fields. Always segment by day boundary.
    _PlannedSegment? plannedSegmentForDay(DateTime day, block.Block b) {
      if (b.allDay == true) return null; // 終日は上部レーンで描画する
      final dayStart = DateTime(day.year, day.month, day.day);
      final dayEndExclusive = dayStart.add(const Duration(days: 1));

      DateTime startLocal() {
        final s = b.startAt?.toLocal();
        if (s != null) return s;
        // DateTime constructor safely normalizes out-of-range hour/minute.
        return DateTime(
          b.executionDate.year,
          b.executionDate.month,
          b.executionDate.day,
          b.startHour,
          b.startMinute,
        );
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
      return _PlannedSegment(
        item: b,
        dayStart: dayStart,
        start: segStart,
        endExclusive: segEnd,
      );
    }

    final dailySegs = <DateTime, List<_PlannedSegment>>{
      for (final d in days)
        d: taskProvider
            .getBlocksForDate(d)
            .where((b) => !b.isDeleted && !b.isCompleted && !b.isPauseDerived)
            .where((b) => widget.showEventsOnly ? b.isEvent == true : true)
            .where((b) => b.allDay != true)
            .map((b) => plannedSegmentForDay(d, b))
            .whereType<_PlannedSegment>()
            .toList(),
    };

    // 終日ブロック（週内に交差するもの）を一意化して収集
    final Map<String, block.Block> allDayByKey = <String, block.Block>{};
    for (final d in days) {
      for (final b in taskProvider.getBlocksForDate(d)) {
        if (b.isDeleted || b.isCompleted || b.isPauseDerived) continue;
        if (b.allDay != true) continue;
        if (widget.showEventsOnly && b.isEvent != true) {
          continue;
        }
        final key = (b.cloudId != null && b.cloudId!.isNotEmpty) ? b.cloudId! : b.id;
        allDayByKey[key] = b;
      }
    }
    final allDayBlocks = allDayByKey.values.toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        const double baseHourHeight = 44.0;
        const double minBlockPixelHeight = 22.0;
        const double timeColWidth = 60.0;
        final dayColWidth = (constraints.maxWidth - timeColWidth) / 7;

        final dayIntervals = [
          for (final d in days)
            [
              for (final seg in dailySegs[d] ?? const <_PlannedSegment>[])
                (
                  // Use minutes from dayStart so that dayEndExclusive (next day 00:00)
                  // becomes 1440, not 0.
                  start: seg.startMinutesOfDay,
                  end: seg.endMinutesOfDay,
                  short: seg.durationMinutes <= 15,
                ),
            ]
        ];
        final layout = CalendarScrollHelpers.computeWeekHourLayout(
          dayIntervals: dayIntervals,
          baseHourHeight: baseHourHeight,
          minBlockPixelHeight: minBlockPixelHeight,
        );
        // 防御: 何らかの理由で0/不正値になってもグリッドが消えないようにする
        final hourHeights = layout.hourHeights.map((h) {
          if (!h.isFinite || h <= 0) return baseHourHeight;
          return h < baseHourHeight ? baseHourHeight : h;
        }).toList(growable: false);
        final List<double> prefix = List<double>.generate(25, (i) => 0);
        for (int i = 1; i < 25; i++) {
          prefix[i] = prefix[i - 1] + hourHeights[i - 1];
        }
        final totalHeight = prefix[24] > 0 ? prefix[24] : baseHourHeight * 24;

        // --- All-day lane layout (Google-like) ---
        final weekDayKeys = <String>[
          for (final d in days)
            DayKeyService.formatDayKeyYmd(d.year, d.month, d.day),
        ];

        ({int startCol, int endCol, bool contPrev, bool contNext, block.Block b})?
            spanFor(block.Block b) {
          final keys = <String>{
            ...(b.dayKeys ?? const <String>[]),
          };
          if (keys.isEmpty) {
            final s = b.startAt;
            final e = b.endAtExclusive;
            if (s != null && e != null) {
              keys.addAll(DayKeyService.computeDayKeysUtc(s, e));
            }
          }
          if (keys.isEmpty) return null;

          int? startCol;
          int? endCol;
          for (int i = 0; i < weekDayKeys.length; i++) {
            if (keys.contains(weekDayKeys[i])) {
              startCol ??= i;
              endCol = i;
            }
          }
          if (startCol == null || endCol == null) return null;

          final sorted = keys.toList()..sort();
          final contPrev = sorted.first.compareTo(weekDayKeys.first) < 0;
          final contNext = sorted.last.compareTo(weekDayKeys.last) > 0;
          return (
            startCol: startCol,
            endCol: endCol,
            contPrev: contPrev,
            contNext: contNext,
            b: b,
          );
        }

        final spans = allDayBlocks
            .map(spanFor)
            .whereType<
                ({int startCol, int endCol, bool contPrev, bool contNext, block.Block b})>()
            .toList()
          ..sort((a, b) {
            if (a.startCol != b.startCol) return a.startCol.compareTo(b.startCol);
            final alen = a.endCol - a.startCol;
            final blen = b.endCol - b.startCol;
            if (alen != blen) return blen.compareTo(alen);
            final at = a.b.blockName?.isNotEmpty == true ? a.b.blockName! : a.b.title;
            final bt = b.b.blockName?.isNotEmpty == true ? b.b.blockName! : b.b.title;
            return at.compareTo(bt);
          });

        const double allDayRowHeight = 18.0;
        const double allDayPad = 2.0;
        final List<List<bool>> occ = <List<bool>>[]; // lane -> 7 cols
        final List<(int lane, ({int startCol, int endCol, bool contPrev, bool contNext, block.Block b}) span)>
            placed = [];
        for (final s in spans) {
          int lane = 0;
          for (;; lane++) {
            if (lane >= occ.length) {
              occ.add(List<bool>.filled(7, false));
            }
            bool free = true;
            for (int c = s.startCol; c <= s.endCol; c++) {
              if (occ[lane][c]) {
                free = false;
                break;
              }
            }
            if (free) break;
          }
          for (int c = s.startCol; c <= s.endCol; c++) {
            occ[lane][c] = true;
          }
          placed.add((lane, s));
        }
        final allDayLaneHeight = occ.isEmpty ? 0.0 : (occ.length * allDayRowHeight + 2);

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!widget.isWeekInitialScrolled() &&
              widget.settings.viewType == CalendarViewType.week &&
              widget.weekScrollController.hasClients) {
            final now = DateTime.now();
            final int h = now.hour;
            final double currentY =
                prefix[h] + hourHeights[h] * (now.minute / 60.0);
            final double viewport =
                widget.weekScrollController.position.viewportDimension;
            final double maxScroll =
                (totalHeight - viewport).clamp(0.0, double.infinity);
            final double target =
                (currentY - viewport / 2).clamp(0.0, maxScroll);
            widget.weekScrollController.jumpTo(target);
            widget.markWeekInitialScrolled();
          }
        });

        return Stack(
          children: [
            Column(
              children: [
                SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      const SizedBox(width: timeColWidth),
                      WeekHeaderRow(
                        days: days,
                        dayColWidth: dayColWidth,
                        hoveredIndex: _hoveredHeaderIndex,
                        onHoverChanged: (i) => setState(
                            () => _hoveredHeaderIndex = i >= 0 ? i : null),
                        onTapDay: (i) => widget.onTapHeaderGoToDay(days[i]),
                      ),
                    ],
                  ),
                ),
                if (allDayLaneHeight > 0)
                  SizedBox(
                    height: allDayLaneHeight,
                    child: Stack(
                      children: [
                        for (final p in placed)
                          Positioned(
                            left: timeColWidth +
                                p.$2.startCol * dayColWidth +
                                allDayPad,
                            width: (p.$2.endCol - p.$2.startCol + 1) *
                                    dayColWidth -
                                allDayPad * 2,
                            top: p.$1 * allDayRowHeight,
                            height: allDayRowHeight - 1,
                            child: GestureDetector(
                              onTap: () async {
                                final changed =
                                    await showUnifiedScreenDialog<bool>(
                                  context: context,
                                  builder: (_) => CalendarBlockEditScreen(
                                    initialBlock: p.$2.b,
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
                                  color: _weekBlockBackground(
                                    accent: accent,
                                    scheme: scheme,
                                    isExcluded: p.$2.b.excludeFromReport,
                                  ),
                                  border: Border.all(
                                    color: p.$2.b.excludeFromReport
                                        ? accent.withOpacity(0.5)
                                        : accent,
                                  ),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                child: Row(
                                  children: [
                                    if (p.$2.contPrev)
                                      const Text('◀',
                                          style: TextStyle(fontSize: 10)),
                                    Expanded(
                                      child: Text(
                                        (p.$2.b.blockName?.isNotEmpty ?? false)
                                            ? p.$2.b.blockName!
                                            : p.$2.b.title,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: p.$2.b.excludeFromReport
                                              ? scheme.onSurface
                                                  .withOpacity(0.75)
                                              : onBlockBg,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (p.$2.contNext)
                                      const Text('▶',
                                          style: TextStyle(fontSize: 10)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: widget.weekScrollController,
                    child: SizedBox(
                      height: totalHeight,
                      // 予定0件の週でも、Stackの幅が0に潰れてグリッドが消えないように
                      // ここで幅を明示して親制約をtightにする。
                      width: constraints.maxWidth,
                      child: Stack(
                        fit: StackFit.expand,
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
                                                        ?.color,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                for (int d = 0; d < 7; d++)
                                  SizedBox(
                                    width: dayColWidth,
                                    child: Column(
                                      children: [
                                        for (int h = 0; h < 24; h++)
                                          GestureDetector(
                                            onTap: () async {
                                              final changed =
                                                  await showUnifiedScreenDialog<
                                                      bool>(
                                                context: context,
                                                builder: (_) =>
                                                    CalendarBlockEditScreen(
                                                  initialDate: days[d],
                                                  initialStart: TimeOfDay(
                                                      hour: h, minute: 0),
                                                  isEvent: true,
                                                ),
                                              );
                                              if (changed == true && mounted) {
                                                await Provider.of<TaskProvider>(
                                                        context,
                                                        listen: false)
                                                    .refreshTasks();
                                                if (mounted) setState(() {});
                                              }
                                            },
                                            child: Container(
                                              height: hourHeights[h],
                                              decoration: BoxDecoration(
                                                border: Border(
                                                  top: BorderSide(
                                                      color: Theme.of(context)
                                                          .dividerColor),
                                                  right: BorderSide(
                                                      color: Theme.of(context)
                                                          .dividerColor),
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          for (int d = 0; d < 7; d++) ...[
                            () {
                              final segs = dailySegs[days[d]]!;
                              final int n = segs.length;
                              if (n == 0) return const SizedBox.shrink();

                          // Prepare layout arrays
                          final List<int> startMins = List<int>.filled(n, 0);
                          final List<int> endMins = List<int>.filled(n, 0);
                          final List<double> tops = List<double>.filled(n, 0);
                          final List<double> heights =
                              List<double>.filled(n, 0);

                          for (int i = 0; i < n; i++) {
                            final seg = segs[i];
                            final int start =
                                seg.start.hour * 60 + seg.start.minute;
                            final int end = seg.endMinutesOfDay;
                            startMins[i] = start;
                            endMins[i] = end;

                            // top
                            tops[i] = prefix[seg.start.hour] +
                                hourHeights[seg.start.hour] *
                                    (seg.start.minute / 60.0);

                            // height across hours
                            int remain = seg.durationMinutes;
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
                            heights[i] = hgt < minBlockPixelHeight
                                ? minBlockPixelHeight
                                : hgt;
                          }

                          // Overlap detection -> half width flags
                          final List<bool> halfWidth =
                              List<bool>.filled(n, false);
                          for (int i = 0; i < n; i++) {
                            for (int j = i + 1; j < n; j++) {
                              if (startMins[i] < endMins[j] &&
                                  endMins[i] > startMins[j]) {
                                halfWidth[i] = true;
                                halfWidth[j] = true;
                              }
                            }
                          }

                          // Column assignment (0 or 1) using sweep line
                          final List<int> columns = List<int>.filled(n, 0);
                          final List<int> order = List<int>.generate(
                              n, (i) => i)
                            ..sort(
                                (a, b) => startMins[a].compareTo(startMins[b]));
                          final List<int> active = <int>[];
                          final Map<int, int> activeCol = <int, int>{};
                          for (final idx in order) {
                            active.removeWhere(
                                (k) => endMins[k] <= startMins[idx]);
                            activeCol.removeWhere(
                                (k, v) => endMins[k] <= startMins[idx]);
                            final used = <int>{
                              for (final k in active) (activeCol[k] ?? 0)
                            };
                            int col;
                            if (used.contains(0) && used.contains(1)) {
                              int col0End = 1 << 30;
                              int col1End = 1 << 30;
                              for (final k in active) {
                                final c = activeCol[k] ?? 0;
                                if (c == 0 && endMins[k] < col0End)
                                  col0End = endMins[k];
                                if (c == 1 && endMins[k] < col1End)
                                  col1End = endMins[k];
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

                          // Render positioned blocks for this day
                          return Stack(
                            children: [
                              for (int i = 0; i < n; i++)
                                Positioned(
                                  left: (() {
                                    final double baseLeft =
                                        timeColWidth + d * dayColWidth + 2;
                                    if (halfWidth[i] && columns[i] == 1) {
                                      return baseLeft + dayColWidth / 2.0;
                                    }
                                    return baseLeft;
                                  })(),
                                  width: halfWidth[i]
                                      ? (dayColWidth / 2.0 - 4)
                                      : (dayColWidth - 4),
                                  top: tops[i],
                                  height: heights[i],
                                  child: GestureDetector(
                                    onTap: () async {
                                      final changed =
                                          await Navigator.of(context)
                                              .push<bool>(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              CalendarBlockEditScreen(
                                            initialBlock: segs[i].item,
                                          ),
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
                                        color: _weekBlockBackground(
                                          accent: accent,
                                          scheme: scheme,
                                          isExcluded: segs[i].item.excludeFromReport,
                                        ),
                                        border: Border.all(
                                          color: segs[i].item.excludeFromReport
                                              ? accent.withOpacity(0.5)
                                              : accent,
                                        ),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 4, vertical: 1),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              (segs[i].item
                                                          .blockName
                                                          ?.isNotEmpty ??
                                                      false)
                                                  ? segs[i].item.blockName!
                                                  : segs[i].item.title,
                                              style: TextStyle(
                                                fontSize: 10,
                                                color: segs[i].item.excludeFromReport
                                                    ? scheme.onSurface.withOpacity(0.75)
                                                    : onBlockBg,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        }(),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
            Positioned(
              right: 16,
              bottom: 16,
              child: CompositedTransformTarget(
                link: _addMenuLink,
                child: FloatingActionButton(
                  heroTag: 'week_view_add_item_fab',
                  onPressed: () async {
                    final action = await _showAddMenu(context);
                    if (action == null || !mounted) return;
                    final date = DateTime(
                      widget.focusedDate.year,
                      widget.focusedDate.month,
                      widget.focusedDate.day,
                    );
                    if (action == _CalendarAddAction.block) {
                      final changed = await showUnifiedScreenDialog<bool>(
                        context: context,
                        builder: (_) => CalendarBlockEditScreen(
                          initialDate: date,
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
                          initialDate: date,
                        ),
                      );
                      if (changed == true && mounted) {
                        await Provider.of<TaskProvider>(context, listen: false)
                            .refreshTasks();
                        if (mounted) setState(() {});
                      }
                    }
                  },
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
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

class _PlannedSegment {
  final block.Block item;
  final DateTime dayStart;
  final DateTime start;
  final DateTime endExclusive;

  const _PlannedSegment({
    required this.item,
    required this.dayStart,
    required this.start,
    required this.endExclusive,
  });

  int get durationMinutes =>
      endExclusive.difference(start).inMinutes.clamp(1, 24 * 60);

  int get startMinutesOfDay =>
      start.difference(dayStart).inMinutes.clamp(0, 24 * 60);

  int get endMinutesOfDay =>
      endExclusive.difference(dayStart).inMinutes.clamp(0, 24 * 60);
}

enum _CalendarAddAction { block, task }
