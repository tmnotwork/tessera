import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../providers/task_provider.dart';
import '../models/inbox_task.dart' as inbox;
import '../models/block.dart' as block;
import '../models/actual_task.dart' as actual;
import 'dart:math' as math;
// 1行表示のRowTaskCardで統一
import '../widgets/timeline/row_task_card.dart';
import '../widgets/timeline/task_menu.dart';
import '../widgets/timeline/task_details_dialog.dart';
import '../widgets/timeline/block_edit_dialog.dart';
import '../widgets/timeline/running_task_bar.dart';
import '../widgets/timeline/mobile_running_task_bar.dart';
import '../widgets/timeline/mobile_task_card.dart';
import '../services/on_demand_sync_service.dart';
import '../services/block_utilities.dart';
import '../services/sync_all_history_service.dart';
import '../services/project_service.dart';
import '../services/sub_project_service.dart';
import '../services/mode_service.dart';
import 'mobile_task_edit_screen.dart';
import 'inbox_task_edit_screen.dart';
import 'inbox_task_add_screen.dart';
import 'task_timer_screen.dart';
import '../app/main_screen/timeline_actions.dart';
import '../widgets/app_notifications.dart';
import 'dart:async';
import '../utils/ime_safe_dialog.dart';
import '../utils/unified_screen_dialog.dart';

class TimelineScreenV2Controller extends ChangeNotifier {
  VoidCallback? _goPreviousDay;
  VoidCallback? _goNextDay;

  bool get isAttached => _goPreviousDay != null && _goNextDay != null;

  void goToPreviousDay() => _goPreviousDay?.call();

  void goToNextDay() => _goNextDay?.call();

  void _bind({
    required VoidCallback goPreviousDay,
    required VoidCallback goNextDay,
  }) {
    _goPreviousDay = goPreviousDay;
    _goNextDay = goNextDay;
    notifyListeners();
  }

  void _unbind() {
    final hadAttachment = isAttached;
    _goPreviousDay = null;
    _goNextDay = null;
    if (hadAttachment) {
      notifyListeners();
    }
  }
}

const double _modeColumnHideWidth = 1280; // モード列をフェードアウトする開始幅
const double _modeColumnShowWidth = 1340; // モード列を完全表示する幅
const double _locationColumnHideWidth = 1120; // 場所列をフェードアウトする開始幅
const double _locationColumnShowWidth = 1200; // 場所列を完全表示する幅

class TimelineScreenV2 extends StatefulWidget {
  final DateTime? initialDate;
  final ValueChanged<DateTime>? onSelectedDateChanged;
  final ValueChanged<bool>? onRunningBarVisibleChanged;
  final TimelineScreenV2Controller? controller;
  final ValueChanged<double>? onRunningBarHeightChanged;
  /// 画面上部の日付ナビ（前後 + 日付ラベル）を表示するか。
  ///
  /// カレンダー日表示に埋め込まれる場合など、外側で日付ヘッダーを持つケースでは
  /// false にして重複表示を避ける。
  final bool showInlineDateNavigation;
  /// 日付ナビ行で「全て展開/全て閉じる」ボタンの左側に並べるウィジェット（例: 同期・設定アイコン）。
  final List<Widget>? dateRowLeadingActions;

  const TimelineScreenV2({
    super.key,
    this.initialDate,
    this.onSelectedDateChanged,
    this.onRunningBarVisibleChanged,
    this.controller,
    this.onRunningBarHeightChanged,
    this.showInlineDateNavigation = true,
    this.dateRowLeadingActions,
  });

  @override
  State<TimelineScreenV2> createState() => _TimelineScreenV2State();
}

class _TimelineScreenV2State extends State<TimelineScreenV2> {
  late DateTime _selectedDate;
  // “今日”追従（0:00跨ぎで自動更新）を行うかどうか。
  // ユーザーが過去/未来日に移動したら false、今日へ戻したら true。
  late bool _followToday;
  Timer? _midnightFollowTimer;
  bool _lastRunningBarVisible = false;
  final GlobalKey _runningBarKey = GlobalKey(debugLabel: 'timeline_running_bar');
  double _lastReportedRunningBarHeight = 0;
  // 折りたたみ展開状態（ブロックID）
  final Set<String> _expandedBlocks = <String>{};
  // ブロックごとの表示順（taskIdリスト、セッション内のみ保持）
  final Map<String, List<String>> _orderByBlockId = <String, List<String>>{};
  // ギャップ（ブロック未設定枠）の展開状態キー集合
  final Set<String> _expandedGaps = <String>{};
  // 自動的に展開したギャップキー（現在時刻用）
  final Set<String> _autoExpandedGapKeys = <String>{};
  // ユーザーが手動で閉じた自動展開ギャップ
  final Set<String> _suppressedAutoGapKeys = <String>{};
  bool _pendingRunningExpansion = false;
  /// ブロック到着・展開なしの状態でリコンサイルを1回スケジュールしたか（日付変更でリセット）
  bool _didReconcileExpansionForEmpty = false;
  final Set<String> _syncedDateKeys = <String>{};
  final Set<String> _syncingDateKeys = <String>{};
  final Map<String, actual.ActualTask> _pendingBlockActuals = {};
  StreamSubscription<BlockRescheduleNotice>? _blockRescheduleSub;

  String _gapKey(DateTime s, DateTime e) {
    String hhmm(DateTime dt) =>
        '${dt.hour.toString().padLeft(2, '0')}${dt.minute.toString().padLeft(2, '0')}';
    String ymd(DateTime dt) =>
        '${dt.year}${dt.month.toString().padLeft(2, '0')}${dt.day.toString().padLeft(2, '0')}';
    // IMPORTANT:
    // 終端ギャップは「翌日00:00（= dayEndExclusive）」を含み得る。
    // 旧形式（start日付のみ）だと "0000" が同日00:00扱いになり、期限切れと誤判定されて
    // 自動展開が即座に解除される（= 開いても勝手に閉じる）原因になる。
    return 'gap_${ymd(s)}_${hhmm(s)}_${ymd(e)}_${hhmm(e)}';
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  _GapBounds? _decodeGapKey(String key) {
    if (!key.startsWith('gap_')) return null;
    final parts = key.split('_');
    // New format:
    // gap_{startYmd}_{startHHmm}_{endYmd}_{endHHmm}
    //
    // Old format (legacy, keep for safety):
    // gap_{ymd}_{startHHmm}_{endHHmm}
    if (parts.length != 4 && parts.length != 5) return null;

    String startDateStr;
    String startStr;
    String endDateStr;
    String endStr;

    if (parts.length == 5) {
      startDateStr = parts[1];
      startStr = parts[2];
      endDateStr = parts[3];
      endStr = parts[4];
    } else {
      // legacy: endDate is same as startDate (may be corrected below)
      startDateStr = parts[1];
      startStr = parts[2];
      endDateStr = parts[1];
      endStr = parts[3];
    }

    if (startDateStr.length != 8 ||
        endDateStr.length != 8 ||
        startStr.length != 4 ||
        endStr.length != 4) {
      return null;
    }

    int? parseY(String s) => int.tryParse(s.substring(0, 4));
    int? parseM(String s) => int.tryParse(s.substring(4, 6));
    int? parseD(String s) => int.tryParse(s.substring(6, 8));

    final sYear = parseY(startDateStr);
    final sMonth = parseM(startDateStr);
    final sDay = parseD(startDateStr);
    final eYear = parseY(endDateStr);
    final eMonth = parseM(endDateStr);
    final eDay = parseD(endDateStr);

    final startHour = int.tryParse(startStr.substring(0, 2));
    final startMinute = int.tryParse(startStr.substring(2, 4));
    final endHour = int.tryParse(endStr.substring(0, 2));
    final endMinute = int.tryParse(endStr.substring(2, 4));

    if ([
      sYear,
      sMonth,
      sDay,
      eYear,
      eMonth,
      eDay,
      startHour,
      startMinute,
      endHour,
      endMinute,
    ].any((v) => v == null)) {
      return null;
    }

    final start = DateTime(sYear!, sMonth!, sDay!, startHour!, startMinute!);
    var end = DateTime(eYear!, eMonth!, eDay!, endHour!, endMinute!);

    // Legacy補正: 旧形式だと終端ギャップ（翌日00:00）が同日00:00扱いになり得る。
    // end <= start の場合は翌日に繰り上げる。
    if (parts.length == 4 && !end.isAfter(start)) {
      end = end.add(const Duration(days: 1));
    }

    return _GapBounds(start: start, end: end);
  }

  String? _findGapKeyForMoment(
    List<block.Block> blocks,
    DateTime day,
    DateTime target,
  ) {
    final dayStart = DateTime(day.year, day.month, day.day, 0, 0);
    // endExclusive: use next day's 00:00 to avoid 23:59 sentinel
    final dayEndExclusive = DateTime(day.year, day.month, day.day)
        .add(const Duration(days: 1));
    DateTime cursor = dayStart;
    for (final b in blocks) {
      final start = DateTime(
        day.year,
        day.month,
        day.day,
        b.startHour,
        b.startMinute,
      );
      final end = start.add(Duration(minutes: b.estimatedDuration));
      final inGap = !target.isBefore(cursor) && target.isBefore(start);
      if (inGap) {
        return _gapKey(cursor, start);
      }
      if (end.isAfter(cursor)) {
        cursor = end;
      }
    }
    if (!target.isBefore(cursor) && target.isBefore(dayEndExclusive)) {
      return _gapKey(cursor, dayEndExclusive);
    }
    return null;
  }

  bool _setsDiffer(Set<String> a, Set<String> b) {
    if (a.length != b.length) return true;
    for (final value in a) {
      if (!b.contains(value)) return true;
    }
    return false;
  }

  void _maybeUpdateExpandedGaps(
    TaskProvider provider, {
    bool immediate = false,
  }) {
    final now = DateTime.now();
    final selected = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
    );
    final newExpanded = Set<String>.from(_expandedGaps);
    final newAuto = Set<String>.from(_autoExpandedGapKeys);
    final removedAutoKeys = <String>{};
    String? currentKeyForAuto;
    bool addedCurrentKey = false;
    bool keepCurrentSuppressed = false;
    bool clearAllSuppressed = false;

    if (_isSameDay(now, selected)) {
      final blocks = _getBlocksForDate(provider);
      final currentKey = _findGapKeyForMoment(blocks, selected, now);
      currentKeyForAuto = currentKey;

      final toRemove = <String>{};
      for (final key in newAuto) {
        final bounds = _decodeGapKey(key);
        if (bounds == null) {
          toRemove.add(key);
          continue;
        }
        if (!_isSameDay(bounds.start, selected)) {
          toRemove.add(key);
          continue;
        }
        if (!bounds.end.isAfter(now)) {
          toRemove.add(key);
          continue;
        }
        if (currentKey == null || key != currentKey) {
          toRemove.add(key);
        }
      }
      if (toRemove.isNotEmpty) {
        newAuto.removeAll(toRemove);
        newExpanded.removeAll(toRemove);
        removedAutoKeys.addAll(toRemove);
      }
      if (currentKey != null) {
        if (_suppressedAutoGapKeys.contains(currentKey)) {
          newAuto.remove(currentKey);
          newExpanded.remove(currentKey);
          keepCurrentSuppressed = true;
        } else {
          newExpanded.add(currentKey);
          newAuto.add(currentKey);
          addedCurrentKey = true;
        }
      }
    } else {
      if (newAuto.isNotEmpty) {
        newExpanded.removeAll(newAuto);
        newAuto.clear();
      }
      clearAllSuppressed = true;
    }

    final expiredAutoKeys = <String>{};
    final invalidKeys = <String>{};
    for (final key in newExpanded.toList()) {
      final bounds = _decodeGapKey(key);
      if (bounds == null) {
        invalidKeys.add(key);
        continue;
      }
      if (newAuto.contains(key) && !bounds.end.isAfter(now)) {
        expiredAutoKeys.add(key);
      }
    }
    if (invalidKeys.isNotEmpty) {
      newExpanded.removeAll(invalidKeys);
      final removedInvalidAuto = invalidKeys.where(newAuto.contains).toSet();
      if (removedInvalidAuto.isNotEmpty) {
        newAuto.removeAll(removedInvalidAuto);
        removedAutoKeys.addAll(removedInvalidAuto);
      }
    }
    if (expiredAutoKeys.isNotEmpty) {
      newExpanded.removeAll(expiredAutoKeys);
      newAuto.removeAll(expiredAutoKeys);
      removedAutoKeys.addAll(expiredAutoKeys);
    }

    if (_setsDiffer(_expandedGaps, newExpanded) ||
        _setsDiffer(_autoExpandedGapKeys, newAuto)) {
      void apply() {
        _expandedGaps
          ..clear()
          ..addAll(newExpanded);
        _autoExpandedGapKeys
          ..clear()
          ..addAll(newAuto);
        if (clearAllSuppressed) {
          _suppressedAutoGapKeys.clear();
        } else {
          if (expiredAutoKeys.isNotEmpty) {
            _suppressedAutoGapKeys.removeAll(expiredAutoKeys);
          }
          if (removedAutoKeys.isNotEmpty) {
            _suppressedAutoGapKeys.removeAll(removedAutoKeys);
          }
          if (addedCurrentKey && currentKeyForAuto != null) {
            _suppressedAutoGapKeys.remove(currentKeyForAuto);
          }
          if (keepCurrentSuppressed && currentKeyForAuto != null) {
            _suppressedAutoGapKeys.add(currentKeyForAuto);
          }
        }
      }

      if (immediate) {
        setState(apply);
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(apply);
        });
      }
    }
  }

  void _scheduleRunningBarHeightMeasurement() {
    if (widget.onRunningBarHeightChanged == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final element = _runningBarKey.currentContext;
      final height = element?.size?.height ?? 0;
      _updateRunningBarHeight(height);
    });
  }

  void _updateRunningBarHeight(double height) {
    if ((height - _lastReportedRunningBarHeight).abs() < 0.5) return;
    _lastReportedRunningBarHeight = height;
    widget.onRunningBarHeightChanged?.call(height);
  }

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initialDate ?? DateTime.now();
    _followToday = _isSameDay(_selectedDate, DateTime.now());
    _bindController();
    // 同期/読取履歴で「なぜ onDemand が連打されたか」を追えるように、
    // 画面の init/dispose も履歴に残す。
    unawaited(
      SyncAllHistoryService.recordSimpleEvent(
        type: 'screenLifecycle',
        reason: 'TimelineScreenV2:init',
        origin: 'TimelineScreenV2',
        extra: <String, dynamic>{
          'selectedDate': DateTime(
            _selectedDate.year,
            _selectedDate.month,
            _selectedDate.day,
          ).toIso8601String(),
          if (widget.initialDate != null)
            'initialDate': DateTime(
              widget.initialDate!.year,
              widget.initialDate!.month,
              widget.initialDate!.day,
            ).toIso8601String(),
          'followToday': _followToday,
          'showInlineDateNavigation': widget.showInlineDateNavigation,
          'hasController': widget.controller != null,
        },
      ),
    );
    // ブロック時刻変更に伴う「前詰め再配置」のオーバー警告を表示
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
    // 画面表示直後に当日データを同期し、即座に最新状態へ
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 初期表示日を親へ通知（Main側のFABが参照する日付のズレ防止）
      try {
        widget.onSelectedDateChanged?.call(_selectedDate);
      } catch (_) {}

      final provider = Provider.of<TaskProvider>(context, listen: false);
      final stored = provider.getExpandedBlocksForDate(_selectedDate);
      if (stored.isNotEmpty) {
        setState(() {
          _expandedBlocks
            ..clear()
            ..addAll(stored);
        });
      }
      _ensureRunningBlockExpanded(provider);
      if (!mounted) return;
      _preexpandCurrentUnassignedGap(provider);
      setState(() {
        _pendingRunningExpansion = true;
      });
      _preexpandCurrentBlock(provider);
      await _ensureDateSynced(
        provider,
        _selectedDate,
        caller: 'TimelineScreenV2:init',
      );
    });

    // 0:00跨ぎで “今日” 表示を追従（Main側の日付ズレ/前日追加を防ぐ）
    _midnightFollowTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      if (!_followToday) return;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      if (_isSameDay(today, _selectedDate)) return;
      try {
        final provider = context.read<TaskProvider>();
        _changeDate(provider, today);
      } catch (_) {}
    });
  }

  List<block.Block> _getBlocksForDate(TaskProvider provider) {
    final d = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
    );
    final blocks = provider
        .getBlocksForDate(d)
        // 終日はカレンダー（終日レーン）で扱う。タイムラインは time block 前提のため除外する。
        .where((b) => b.allDay != true)
        .where((b) => b.isCompleted != true)
        .toList()
      ..sort((a, b) {
        final t1 = a.startHour * 60 + a.startMinute;
        final t2 = b.startHour * 60 + b.startMinute;
        if (t1 != t2) return t1.compareTo(t2);
        return a.title.compareTo(b.title);
      });
    return blocks;
  }

  List<_BlockBounds> _buildBlockBounds(
    DateTime date,
    List<block.Block> blocks,
  ) {
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEndExclusive = dayStart.add(const Duration(days: 1));

    DateTime blockStart(block.Block b) {
      final s = b.startAt;
      if (s != null) return s.toLocal();
      return DateTime(date.year, date.month, date.day, b.startHour, b.startMinute);
    }

    DateTime blockEndExclusive(block.Block b) {
      final e = b.endAtExclusive;
      if (e != null) return e.toLocal();
      return DateTime(date.year, date.month, date.day, b.startHour, b.startMinute)
          .add(Duration(minutes: b.estimatedDuration));
    }

    final out = <_BlockBounds>[];
    for (final b in blocks) {
      final start = blockStart(b);
      final end = blockEndExclusive(b);
      final segStart = start.isAfter(dayStart) ? start : dayStart;
      final segEnd = end.isBefore(dayEndExclusive) ? end : dayEndExclusive;
      if (!segStart.isBefore(segEnd)) continue;
      out.add(_BlockBounds(blockData: b, start: segStart, end: segEnd));
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  _ActualPlacement _calculateActualPlacement(
    List<_BlockBounds> blockBounds,
    List<_ActualSegment> actuals,
  ) {
    final byBlock = <_BlockBounds, List<_ActualSegment>>{};
    final unassigned = <_ActualSegment>[];
    final spanByBlockId = <String, _BlockBounds>{};
    for (final span in blockBounds) {
      spanByBlockId[span.blockData.id] = span;
      final cloudId = span.blockData.cloudId;
      if (cloudId != null && cloudId.isNotEmpty) {
        spanByBlockId.putIfAbsent(cloudId, () => span);
      }
    }

    for (final seg in actuals) {
      final DateTime start = seg.start;
      final blockKey = seg.task.blockId;
      _BlockBounds? selected =
          (blockKey != null && blockKey.isNotEmpty) ? spanByBlockId[blockKey] : null;
      Duration? bestOffset;
      if (selected == null) {
        for (final span in blockBounds) {
          if (start.isBefore(span.start)) continue;
          if (!start.isBefore(span.end)) continue;
          final offset = start.difference(span.start);
          if (selected == null || offset < bestOffset!) {
            selected = span;
            bestOffset = offset;
          }
        }
      }
      if (selected != null) {
        byBlock.putIfAbsent(selected, () => <_ActualSegment>[]).add(seg);
      } else {
        unassigned.add(seg);
      }
    }
    // byBlockの各リストをstartでソート
    for (final entry in byBlock.entries) {
      entry.value.sort((a, b) => a.start.compareTo(b.start));
    }
    // unassignedもstartでソート
    unassigned.sort((a, b) => a.start.compareTo(b.start));
    return _ActualPlacement(byBlock: byBlock, unassigned: unassigned);
  }

  actual.ActualTask? _findRunningActual(List<actual.ActualTask> tasks) {
    for (final task in tasks) {
      if (task.isRunning) {
        return task;
      }
    }
    return null;
  }

  DateTime _resolveInboxStartTime(DateTime day, inbox.InboxTask task) {
    if (task.startHour != null && task.startMinute != null) {
      return DateTime(
        day.year,
        day.month,
        day.day,
        task.startHour!,
        task.startMinute!,
      );
    }
    // Use end-at-exclusive for ordering (avoid 23:59:59.999 sentinel).
    return DateTime(day.year, day.month, day.day).add(const Duration(days: 1));
  }

  void _toggleGapExpansion(String key, bool currentlyExpanded) {
    setState(() {
      if (currentlyExpanded) {
        _expandedGaps.remove(key);
        if (_autoExpandedGapKeys.remove(key)) {
          _suppressedAutoGapKeys.add(key);
        }
      } else {
        _expandedGaps.add(key);
        _suppressedAutoGapKeys.remove(key);
      }
    });
  }

  // 1行表示に統一しつつ、ブロックの「外枠」を1行ヘッダーとして可視化
  List<_RowItem> _buildRowItems(TaskProvider provider) {
    final date = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
    );
    final List<block.Block> blocks = _getBlocksForDate(provider);
    final Set<String> _blockIdSet = blocks.map((b) => b.id).toSet();
    final Set<String> _blockCloudIdSet = blocks
        .where((b) => b.cloudId != null && b.cloudId!.isNotEmpty)
        .map((b) => b.cloudId!)
        .toSet();
    final blockBounds = _buildBlockBounds(date, blocks);

    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEndExclusive = dayStart.add(const Duration(days: 1));

    DateTime actualStartLocal(actual.ActualTask t) =>
        (t.startAt?.toLocal() ?? t.startTime.toLocal());

    DateTime actualEndLocalExclusive(actual.ActualTask t) {
      final e = t.endAtExclusive?.toLocal() ?? t.endTime?.toLocal();
      if (e != null) return e;
      // running: use now (clamped to day end below)
      return DateTime.now();
    }

    _ActualSegment? segmentForDay(actual.ActualTask t) {
      final s = actualStartLocal(t);
      final e = actualEndLocalExclusive(t);
      final segStart = s.isAfter(dayStart) ? s : dayStart;
      final segEnd = e.isBefore(dayEndExclusive) ? e : dayEndExclusive;
      if (!segStart.isBefore(segEnd)) {
        // 0秒実績（start==end）は「時刻点」として表示対象に含める。
        // ただし、区間のクリップ結果が偶然0になっただけ（=実際には当日と交差しない）
        // のケースを混ぜないため、元の開始/終了が同一のときだけ許可する。
        if (!s.isAtSameMomentAs(e)) return null;
      }
      final needsOverride = segStart != s || segEnd != e;
      return _ActualSegment(
        task: t,
        start: segStart,
        endExclusive: segEnd,
        needsTimeOverride: needsOverride,
      );
    }

    final List<_ActualSegment> actualSegs = provider
        .getActualTasksForDate(date)
        .map(segmentForDay)
        .whereType<_ActualSegment>()
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    final placement = _calculateActualPlacement(blockBounds, actualSegs);
    final actualsByBlock = placement.byBlock;
    final List<_ActualSegment> unassignedActuals = placement.unassigned;

    // その日の時間ありインボックスタスク（ギャップ/ブロック判定用）
    final inboxes = provider.getInboxTasksForDate(date);

    final List<_RowItem> rows = [];

    DateTime cursor = DateTime(date.year, date.month, date.day, 0, 0);
    // NOTE: dayEndExclusive はこの関数の上部で定義済み（duplicate定義を避ける）

    bool _hasKnownBlockLink(inbox.InboxTask t) {
      final linkId = t.blockId;
      if (linkId == null || linkId.isEmpty) return false;
      return _blockIdSet.contains(linkId) || _blockCloudIdSet.contains(linkId);
    }

    bool _isLinkedToBlock(inbox.InboxTask t, block.Block b) {
      final linkId = t.blockId;
      if (linkId == null || linkId.isEmpty) return false;
      if (linkId == b.id) return true;
      final cid = b.cloudId;
      return cid != null && cid.isNotEmpty && linkId == cid;
    }

    // 実績/インボックスを時間帯でまとめて描画（開始時刻昇順マージ）
    void emitMergedInRange(
      DateTime start,
      DateTime end, {
      block.Block? inBlock,
      bool inGap = false,
      bool emit = true,
    }) {
      if (!emit) return;
      // 実績（非running）の該当分
      final aList = unassignedActuals
          .where((seg) => !seg.start.isBefore(start) && seg.start.isBefore(end))
          .toList()
        ..sort((x, y) => x.start.compareTo(y.start));
      // 時間あり未了Inboxの該当分
      final iList =
          inboxes
              .where((t) => t.isCompleted != true)
              .where((t) => !_hasKnownBlockLink(t))
              .where((t) => t.startHour != null && t.startMinute != null)
              .where((t) {
                final ts = DateTime(
                  date.year,
                  date.month,
                  date.day,
                  t.startHour!,
                  t.startMinute!,
                );
                return !ts.isBefore(start) && ts.isBefore(end);
              })
              .toList()
            ..sort((a, b) {
              final as = DateTime(
                date.year,
                date.month,
                date.day,
                a.startHour!,
                a.startMinute!,
              );
              final bs = DateTime(
                date.year,
                date.month,
                date.day,
                b.startHour!,
                b.startMinute!,
              );
              return as.compareTo(bs);
            });

      int ai = 0, ii = 0;
      while (ai < aList.length || ii < iList.length) {
        final nextActual = ai < aList.length ? aList[ai] : null;
        final nextInbox = ii < iList.length ? iList[ii] : null;
        bool pickActual;
        if (nextActual == null) {
          pickActual = false;
        } else if (nextInbox == null) {
          pickActual = true;
        } else {
          final it = DateTime(
            date.year,
            date.month,
            date.day,
            nextInbox.startHour!,
            nextInbox.startMinute!,
          );
          pickActual = nextActual.start.isBefore(it);
        }
        if (pickActual) {
          final seg = nextActual!;
          final actual = seg.task;
          final linkId = actual.blockId;
          if (linkId != null &&
              linkId.isNotEmpty &&
              (_blockIdSet.contains(linkId) ||
                  _blockCloudIdSet.contains(linkId))) {
            ai++;
            continue;
          }
          // ギャップ実績行はデータが揃ってから出す（Project/Mode/SubProject ready 時のみ表示）
          if (inGap &&
              !(ProjectService.isReady &&
                  SubProjectService.isReady &&
                  ModeService.isReady)) {
            ai++;
            continue;
          }
          rows.add(
            _RowItem.actualRow(
              actual,
              displayStart: seg.needsTimeOverride ? seg.start : null,
              displayEnd: seg.needsTimeOverride ? seg.endExclusive : null,
              inBlock: inBlock,
              inGap: inGap,
            ),
          );
          ai++;
        } else {
          rows.add(_RowItem.inboxRow(nextInbox!, inBlock: inBlock, inGap: inGap));
          ii++;
        }
      }
    }

    bool hasInboxInRange(DateTime start, DateTime end) {
      for (final t in inboxes) {
        if (t.isCompleted == true) continue;
        if (_hasKnownBlockLink(t)) continue;
        if (t.startHour == null || t.startMinute == null) continue;
        final tStart = DateTime(
          date.year,
          date.month,
          date.day,
          t.startHour!,
          t.startMinute!,
        );
        if (!tStart.isBefore(end) || tStart.isBefore(start)) continue;
        // start <= tStart < end
        return true;
      }
      return false;
    }

    for (final span in blockBounds) {
      final b = span.blockData;
      final bStart = span.start;
      final bEnd = span.end;
      final linkedActuals = actualsByBlock[span] ?? const <_ActualSegment>[];
      final runningActual =
          _findRunningActual(linkedActuals.map((s) => s.task).toList());
      final List<_ActualSegment> blockLinkedActuals = [];
      final List<_ActualSegment> inlineActuals = [];
      for (final seg in linkedActuals) {
        final act = seg.task;
        final linkId = act.blockId;
        final linkedToBlock = linkId != null &&
            linkId.isNotEmpty &&
            (linkId == b.id ||
                (b.cloudId != null &&
                    b.cloudId!.isNotEmpty &&
                    linkId == b.cloudId));
        if (linkedToBlock) {
          blockLinkedActuals.add(seg);
        } else {
          inlineActuals.add(seg);
        }
      }
      final pendingPlaceholder = _pendingBlockActuals[b.id];
      if (pendingPlaceholder != null) {
        if (blockLinkedActuals.isEmpty) {
          final phStart = pendingPlaceholder.startTime.toLocal();
          final phEnd = (pendingPlaceholder.endTime?.toLocal()) ??
              phStart.add(Duration(
                  minutes: pendingPlaceholder.actualDuration > 0
                      ? pendingPlaceholder.actualDuration
                      : 1));
          blockLinkedActuals.add(_ActualSegment(
            task: pendingPlaceholder,
            start: phStart,
            endExclusive: phEnd,
            needsTimeOverride: true,
          ));
        } else {
          final hasRealActual =
              blockLinkedActuals.any((seg) => !seg.task.id.startsWith('pending-'));
          if (hasRealActual) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() {
                _pendingBlockActuals.remove(b.id);
              });
            });
          }
        }
      }
      // pendingPlaceholderを追加した後、もう一度ソート
      // blockLinkedActualsとinlineActualsをマージしてソート
      // 全体の順序を保証するため
      final allBlockActuals = <_ActualSegment>[
        ...blockLinkedActuals,
        ...inlineActuals,
      ];
      allBlockActuals.sort((a, b) => a.start.compareTo(b.start));
      
      // ソート後、blockLinkedActualsとinlineActualsに再振り分け（表示時の判定用）
      blockLinkedActuals.clear();
      inlineActuals.clear();
      final blockLinkedActualsSet = <String>{};
      for (final seg in allBlockActuals) {
        final act = seg.task;
        final linkId = act.blockId;
        final linkedToBlock = linkId != null &&
            linkId.isNotEmpty &&
            (linkId == b.id ||
                (b.cloudId != null &&
                    b.cloudId!.isNotEmpty &&
                    linkId == b.cloudId));
        if (linkedToBlock) {
          blockLinkedActuals.add(seg);
          blockLinkedActualsSet.add(act.id);
        } else {
          inlineActuals.add(seg);
        }
      }
      
      // ブロックヘッダーの︙メニューが「予定ブロック」ではなく「実績ブロック」を対象にできるように、
      // blockId で紐づいていない（時間帯で表示されている）実績も候補に含める。
      actual.ActualTask? primaryActualForMenu = runningActual;
      if (primaryActualForMenu == null) {
        for (final seg in allBlockActuals) {
          final act = seg.task;
          if (act.id.startsWith('pending-')) continue;
          primaryActualForMenu = act;
          if (act.isRunning) break;
        }
      }

      // ブロック前ギャップ: 1行ヘッダー（ギャップ）→その区間の実績
      if (bStart.isAfter(cursor)) {
        final gKey = _gapKey(cursor, bStart);
        final gExpanded = _expandedGaps.contains(gKey);
        // ギャップ内に実績 or 時間ありインボックスが無ければ表示しない（リンク有無は不問）
        final hasActual = unassignedActuals.any(
          (seg) => !seg.start.isBefore(cursor) && seg.start.isBefore(bStart),
        );
        final hasInbox = hasInboxInRange(cursor, bStart);
        if (!(hasActual || hasInbox)) {
          // 表示対象が無いギャップは従来通り非表示
        } else {
        rows.add(
          _RowItem.gapHeader(
            cursor,
            bStart,
            isExpanded: gExpanded,
            onToggle: () {
              _toggleGapExpansion(gKey, gExpanded);
            },
          ),
        );
        emitMergedInRange(
          cursor,
          bStart,
          inGap: true,
          emit: gExpanded || _autoExpandedGapKeys.contains(gKey),
        );
        }
      }

        final expanded = _expandedBlocks.contains(b.id);

        // ブロック外枠ヘッダー（1行）
        rows.add(
          _RowItem.blockHeader(
            b,
            bStart,
            bEnd,
            isExpanded: expanded,
            onToggle: () {
              _toggleBlockExpansion(provider, b.id, expanded);
            },
            runningActual: runningActual,
            primaryTaskForActions: primaryActualForMenu,
          ),
        );
        // 完了済みの実績は折りたたみ時に非表示
        // allBlockActualsを順序通りに表示（blockLinkedActualsとinlineActualsを統合）
        for (final seg in allBlockActuals) {
          final actualTask = seg.task;
          final isBlockLinked = blockLinkedActualsSet.contains(actualTask.id);
          // 折りたたみ時はblockLinkedActualsのみ表示、展開時は全て表示
          final shouldShowInline = isBlockLinked
              ? (expanded || actualTask.isCompleted != true)
              : expanded;
          if (shouldShowInline) {
            // ギャップ同様: 表示用3サービスが ready のときだけ追加（グレーアウトなく即時表示）
            if (!(ProjectService.isReady &&
                SubProjectService.isReady &&
                ModeService.isReady)) {
              continue;
            }
            rows.add(
              _RowItem.actualRow(
                actualTask,
                displayStart: seg.needsTimeOverride ? seg.start : null,
                displayEnd: seg.needsTimeOverride ? seg.endExclusive : null,
                inBlock: b,
                inGap: false,
              ),
            );
          }
        }
        // ブロック枠内: 紐づく or ブロック時間内開始の実績/インボックスを表示
        if (expanded) {
          // インボックス（未完了のみ）: リンク一致 or （開始時刻あり かつ ブロック時間内）
          final List<inbox.InboxTask> inboxInRange = [];
          for (final t in inboxes) {
            if (t.isCompleted == true) continue;
            final isLinked = _isLinkedToBlock(t, b);
            final hasKnownLink = _hasKnownBlockLink(t);
            bool isInRange = false;
            if (t.startHour != null && t.startMinute != null) {
              final ts = DateTime(
                date.year,
                date.month,
                date.day,
                t.startHour!,
                t.startMinute!,
              );
              isInRange = !ts.isBefore(bStart) && ts.isBefore(bEnd);
            }
            if (hasKnownLink && !isLinked) continue;
            if (isLinked || isInRange) inboxInRange.add(t);
          }
          // 重複除外
          final uniqueInbox = {
            for (final t in inboxInRange) t.id: t,
          }.values.toList();

          final sortedInbox = [...uniqueInbox]
            ..sort(
              (a, bTask) => _resolveInboxStartTime(
                date,
                a,
              ).compareTo(_resolveInboxStartTime(date, bTask)),
            );

          for (final inboxTask in sortedInbox) {
            rows.add(_RowItem.inboxRow(inboxTask, inBlock: b));
          }
        }

      // 疑似タスク表示は廃止（予定ブロックの外枠と中身のみ表示）

      if (bEnd.isAfter(cursor)) cursor = bEnd;
    }

    // 終端ギャップ
    if (cursor.isBefore(dayEndExclusive)) {
      final gKey = _gapKey(cursor, dayEndExclusive);
      final gExpanded = _expandedGaps.contains(gKey);
      final hasActual = unassignedActuals.any(
        (seg) =>
            !seg.start.isBefore(cursor) && seg.start.isBefore(dayEndExclusive),
      );
      final hasInbox = hasInboxInRange(cursor, dayEndExclusive);
      if (hasActual || hasInbox) {
        rows.add(
          _RowItem.gapHeader(
            cursor,
            dayEndExclusive,
            isExpanded: gExpanded,
            onToggle: () {
              _toggleGapExpansion(gKey, gExpanded);
            },
          ),
        );
        emitMergedInRange(
          cursor,
          dayEndExclusive,
          inGap: true,
          emit: gExpanded || _autoExpandedGapKeys.contains(gKey),
        );
      }
    }

    return rows;
  }

  List<inbox.InboxTask> _getOrderedLinked(
    String blockId,
    List<inbox.InboxTask> linked,
  ) {
    // 既知の順序が無ければ初期化
    final ids = linked.map((t) => t.id).toList();
    final current = _orderByBlockId[blockId];
    if (current == null) {
      _orderByBlockId[blockId] = List<String>.from(ids);
      return linked;
    }

    // 既存順序に無いIDを末尾に追加、消えたIDは削除
    final normalized = current.where(ids.contains).toList();
    for (final id in ids) {
      if (!normalized.contains(id)) normalized.add(id);
    }
    _orderByBlockId[blockId] = normalized;

    // 並べ替え
    final indexOf = {
      for (int i = 0; i < normalized.length; i++) normalized[i]: i,
    };
    final sorted = [...linked]
      ..sort(
        (a, b) =>
            (indexOf[a.id] ?? 1 << 30).compareTo(indexOf[b.id] ?? 1 << 30),
      );
    return sorted;
  }

  // 今日を表示中であれば、「現在時刻を含む未指定ギャップ」を初期展開して見せる
  void _preexpandCurrentUnassignedGap(TaskProvider provider) {
    _maybeUpdateExpandedGaps(provider, immediate: true);
  }

  void _reconcileAutoExpansionAfterDataRefresh(TaskProvider provider) {
    _preexpandCurrentUnassignedGap(provider);
    _preexpandCurrentBlock(provider);
    _ensureRunningBlockExpanded(provider);
  }

  // 今日表示時に、現在時刻が属するブロックをデフォルト展開
  void _preexpandCurrentBlock(TaskProvider provider) {
    // 既に手動で展開済みなら尊重
    if (_expandedBlocks.isNotEmpty) return;
    final today = DateTime.now();
    final selected = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
    );
    if (today.year != selected.year ||
        today.month != selected.month ||
        today.day != selected.day) {
      return; // 今日以外は展開しない
    }
    final blocks = _getBlocksForDate(provider);
    final now = today;
    for (final b in blocks) {
      final start = DateTime(
        selected.year,
        selected.month,
        selected.day,
        b.startHour,
        b.startMinute,
      );
      final end = start.add(Duration(minutes: b.estimatedDuration));
      if (!now.isBefore(end) || now.isBefore(start)) {
        continue; // start <= now < end の時だけ展開
      }
      _updateExpandedBlocks(provider, (set) {
        set
          ..clear()
          ..add(b.id);
      });
      break;
    }
  }

  void _ensureRunningBlockExpanded(TaskProvider provider) {
    final selected = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
    );
    final blocks = _getBlocksForDate(provider);
    if (blocks.isEmpty) return;
    final running = provider.runningActualTasks;
    if (running.isEmpty) return;
    final Set<String> targetIds = <String>{};
    for (final actual.ActualTask task in running) {
      if (!_isSameDay(task.startTime, selected)) continue;
      final blockId = task.blockId;
      if (blockId == null || blockId.isEmpty) continue;
      block.Block? match;
      for (final candidate in blocks) {
        if (candidate.id == blockId ||
            (candidate.cloudId != null && candidate.cloudId == blockId)) {
          match = candidate;
          break;
        }
      }
      if (match != null) {
        targetIds.add(match.id);
      }
    }
    if (targetIds.isEmpty) return;
    bool changed = false;
    for (final id in targetIds) {
      if (!_expandedBlocks.contains(id)) {
        changed = true;
        break;
      }
    }
    if (!changed) return;
    _updateExpandedBlocks(provider, (set) {
      set.addAll(targetIds);
    });
  }

  void _scheduleEnsureDateSynced(DateTime date) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = Provider.of<TaskProvider>(context, listen: false);
      _ensureDateSynced(provider, date, caller: 'TimelineScreenV2:changeDate');
    });
  }

  Future<void> _ensureDateSynced(
      TaskProvider provider, DateTime date,
      {String? caller}) async {
    final key = _dateKey(date);
    if (_syncedDateKeys.contains(key) || _syncingDateKeys.contains(key)) {
      return;
    }
    _syncingDateKeys.add(key);
    try {
      // timeline 画面は inbox も参照するため、同一フローでまとめて同期する。
      // VersionFeed は 1 回だけ pull し、Inbox 側ではスキップする。
      await OnDemandSyncService.ensureTimelineDay(
        date,
        pullVersionFeed: true,
        caller: caller,
      );
      await OnDemandSyncService.ensureInboxDay(
        date,
        pullVersionFeed: false,
        caller: caller,
      );
      if (mounted) {
        await provider.refreshTasks(showLoading: false);
        // 同期完了後に “実行中” の自動展開を再試行するためフラグを立てる
        setState(() {
          _pendingRunningExpansion = true;
        });
      }
      _syncedDateKeys.add(key);
    } catch (e) {
      _syncedDateKeys.remove(key);
    } finally {
      _syncingDateKeys.remove(key);
    }
  }

  void _updateExpandedBlocks(
    TaskProvider provider,
    void Function(Set<String>) mutate,
  ) {
    setState(() {
      mutate(_expandedBlocks);
    });
    provider.setExpandedBlocksForDate(_selectedDate, _expandedBlocks);
  }

  void _toggleBlockExpansion(
    TaskProvider provider,
    String blockId,
    bool currentlyExpanded,
  ) {
    _updateExpandedBlocks(provider, (set) {
      if (currentlyExpanded) {
        set.remove(blockId);
      } else {
        set.add(blockId);
      }
    });
  }

  void _changeDate(TaskProvider provider, DateTime newDate) {
    if (_isSameDay(newDate, _selectedDate)) return;
    _followToday = _isSameDay(newDate, DateTime.now());
    provider.setExpandedBlocksForDate(_selectedDate, _expandedBlocks);
    final stored = provider.getExpandedBlocksForDate(newDate);
    setState(() {
      _selectedDate = newDate;
      _expandedBlocks
        ..clear()
        ..addAll(stored);
      _expandedGaps.clear();
      _autoExpandedGapKeys.clear();
      _pendingRunningExpansion = true;
      _didReconcileExpansionForEmpty = false;
    });
    widget.onSelectedDateChanged?.call(newDate);
    _preexpandCurrentUnassignedGap(provider);
    _scheduleEnsureDateSynced(newDate);
  }

  @override
  void didUpdateWidget(covariant TimelineScreenV2 oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._unbind();
      _bindController();
    }
  }

  @override
  void dispose() {
    unawaited(
      SyncAllHistoryService.recordSimpleEvent(
        type: 'screenLifecycle',
        reason: 'TimelineScreenV2:dispose',
        origin: 'TimelineScreenV2',
        extra: <String, dynamic>{
          'selectedDate': DateTime(
            _selectedDate.year,
            _selectedDate.month,
            _selectedDate.day,
          ).toIso8601String(),
          'followToday': _followToday,
          'syncedDateKeys': _syncedDateKeys.length,
          'syncingDateKeys': _syncingDateKeys.length,
        },
      ),
    );
    _blockRescheduleSub?.cancel();
    _midnightFollowTimer?.cancel();
    widget.controller?._unbind();
    super.dispose();
  }

  void _bindController() {
    widget.controller?._bind(
      goPreviousDay: _goToPreviousDay,
      goNextDay: _goToNextDay,
    );
  }

  void _goToPreviousDay() {
    final provider = context.read<TaskProvider>();
    _changeDate(
      provider,
      _selectedDate.subtract(const Duration(days: 1)),
    );
  }

  void _goToNextDay() {
    final provider = context.read<TaskProvider>();
    _changeDate(
      provider,
      _selectedDate.add(const Duration(days: 1)),
    );
  }

  void _expandAllBlocks(TaskProvider provider, List<block.Block> blocks) {
    if (blocks.isEmpty) return;
    _updateExpandedBlocks(provider, (set) {
      for (final b in blocks) {
        set.add(b.id);
      }
    });
  }

  void _expandAllGaps(TaskProvider provider) {
    final date = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
    );
    final dayStart = DateTime(date.year, date.month, date.day);
    // endExclusive: use next day's 00:00 to avoid 23:59 sentinel
    final dayEndExclusive = dayStart.add(const Duration(days: 1));

    final blocks = _getBlocksForDate(provider);
    final blockBounds = _buildBlockBounds(date, blocks);
    final blockIdSet = blocks.map((b) => b.id).toSet();
    final blockCloudIdSet = blocks
        .where((b) => b.cloudId != null && b.cloudId!.isNotEmpty)
        .map((b) => b.cloudId!)
        .toSet();

    bool hasKnownBlockLink(inbox.InboxTask t) {
      final linkId = t.blockId;
      if (linkId == null || linkId.isEmpty) return false;
      return blockIdSet.contains(linkId) || blockCloudIdSet.contains(linkId);
    }

    DateTime actualStartLocal(actual.ActualTask t) =>
        (t.startAt?.toLocal() ?? t.startTime.toLocal());

    DateTime actualEndLocalExclusive(actual.ActualTask t) {
      final e = t.endAtExclusive?.toLocal() ?? t.endTime?.toLocal();
      if (e != null) return e;
      // running: use now (clamped to day end below)
      return DateTime.now();
    }

    _ActualSegment? segmentForDay(actual.ActualTask t) {
      final s = actualStartLocal(t);
      final e = actualEndLocalExclusive(t);
      final segStart = s.isAfter(dayStart) ? s : dayStart;
      final segEnd = e.isBefore(dayEndExclusive) ? e : dayEndExclusive;
      if (!segStart.isBefore(segEnd)) {
        // 0秒実績（start==end）は「時刻点」として表示対象に含める。
        // ただし、区間のクリップ結果が偶然0になっただけ（=実際には当日と交差しない）
        // のケースを混ぜないため、元の開始/終了が同一のときだけ許可する。
        if (!s.isAtSameMomentAs(e)) return null;
      }
      final needsOverride = segStart != s || segEnd != e;
      return _ActualSegment(
        task: t,
        start: segStart,
        endExclusive: segEnd,
        needsTimeOverride: needsOverride,
      );
    }

    final List<_ActualSegment> actualSegs = provider
        .getActualTasksForDate(date)
        .map(segmentForDay)
        .whereType<_ActualSegment>()
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    final placement = _calculateActualPlacement(blockBounds, actualSegs);
    final List<_ActualSegment> unassignedActuals = placement.unassigned;

    // その日の時間ありインボックスタスク（ギャップ判定用）
    final inboxes = provider.getInboxTasksForDate(date);

    bool hasInboxInRange(DateTime start, DateTime end) {
      for (final t in inboxes) {
        if (t.isCompleted == true) continue;
        if (hasKnownBlockLink(t)) continue;
        if (t.startHour == null || t.startMinute == null) continue;
        final tStart = DateTime(
          date.year,
          date.month,
          date.day,
          t.startHour!,
          t.startMinute!,
        );
        if (!tStart.isBefore(end) || tStart.isBefore(start)) continue;
        // start <= tStart < end
        return true;
      }
      return false;
    }

    bool hasActualInRange(DateTime start, DateTime end) {
      return unassignedActuals.any(
        (seg) => !seg.start.isBefore(start) && seg.start.isBefore(end),
      );
    }

    final keysToExpand = <String>{};
    DateTime cursor = DateTime(date.year, date.month, date.day, 0, 0);
    for (final span in blockBounds) {
      final bStart = span.start;
      final bEnd = span.end;

      if (bStart.isAfter(cursor)) {
        final gKey = _gapKey(cursor, bStart);
        final hasActual = hasActualInRange(cursor, bStart);
        final hasInbox = hasInboxInRange(cursor, bStart);
        if (hasActual || hasInbox) {
          keysToExpand.add(gKey);
        }
      }
      if (bEnd.isAfter(cursor)) cursor = bEnd;
    }

    // 終端ギャップ
    if (cursor.isBefore(dayEndExclusive)) {
      final gKey = _gapKey(cursor, dayEndExclusive);
      final hasActual = hasActualInRange(cursor, dayEndExclusive);
      final hasInbox = hasInboxInRange(cursor, dayEndExclusive);
      if (hasActual || hasInbox) {
        keysToExpand.add(gKey);
      }
    }

    if (keysToExpand.isEmpty) return;

    setState(() {
      _expandedGaps.addAll(keysToExpand);
      // 明示的に「全て展開」されたギャップは自動抑制対象から外す
      _suppressedAutoGapKeys.removeAll(keysToExpand);
    });
  }

  void _collapseAllBlocks(TaskProvider provider, List<block.Block> blocks) {
    if (blocks.isEmpty) return;
    _updateExpandedBlocks(provider, (set) {
      for (final b in blocks) {
        set.remove(b.id);
      }
    });
  }

  void _collapseAllGaps(TaskProvider provider) {
    setState(() {
      // 「今日」表示中は、現在時刻が属するギャップが自動展開され得る。
      // まだ自動展開セットに載っていないタイミングで押されても確実に閉じるため、
      // 現在ギャップキーも抑制対象へ追加する。
      final now = DateTime.now();
      final selected = DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
      );
      if (_isSameDay(now, selected)) {
        final blocks = _getBlocksForDate(provider);
        final currentKey = _findGapKeyForMoment(blocks, selected, now);
        if (currentKey != null) {
          _suppressedAutoGapKeys.add(currentKey);
        }
      }

      // 自動展開中のギャップは「全て閉じる」で明示的に閉じた扱いにして、
      // 次のビルドで勝手に開き直らないよう抑制する。
      if (_autoExpandedGapKeys.isNotEmpty) {
        _suppressedAutoGapKeys.addAll(_autoExpandedGapKeys);
      }
      _expandedGaps.clear();
      _autoExpandedGapKeys.clear();
    });
  }

  bool _isMobilePlatform() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return true;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TaskProvider>();
    _maybeUpdateExpandedGaps(provider);
    final blocksForDate = _getBlocksForDate(provider);
    final blocksArrivedButNoneExpanded =
        blocksForDate.isNotEmpty &&
            _expandedBlocks.isEmpty &&
            !_didReconcileExpansionForEmpty;
    final shouldReconcileExpansion =
        _pendingRunningExpansion || blocksArrivedButNoneExpanded;
    if (_pendingRunningExpansion) {
      _pendingRunningExpansion = false;
    }
    if (blocksArrivedButNoneExpanded) {
      _didReconcileExpansionForEmpty = true;
    }
    if (shouldReconcileExpansion) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _reconcileAutoExpansionAfterDataRefresh(provider);
      });
    }
    final rows = _buildRowItems(provider);

    final runningTask = context.select<TaskProvider, actual.ActualTask?>(
      (p) =>
          p.runningActualTasks.isNotEmpty ? p.runningActualTasks.first : null,
    );

    if (widget.onRunningBarHeightChanged != null) {
      if (runningTask != null) {
        _scheduleRunningBarHeightMeasurement();
      } else if (_lastReportedRunningBarHeight != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _updateRunningBarHeight(0);
        });
      }
    }

    // 親へ再生バーの可視状態を通知（必要時のみ）
    final visibleNow = runningTask != null;
    if (visibleNow != _lastRunningBarVisible) {
      _lastRunningBarVisible = visibleNow;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onRunningBarVisibleChanged?.call(visibleNow);
      });
    }

    // Web/desktop resize でも確実に反映されるよう、MediaQueryではなく
    // 実レイアウトの制約幅（LayoutBuilder）でブレークポイント判定する。
    return NotificationListener<TimelineExpandBlockRequestNotification>(
      onNotification: (n) {
        if (!_isSameDay(n.date, _selectedDate)) return true;
        _updateExpandedBlocks(provider, (set) => set.add(n.blockId));
        return true;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
        final double screenWidth = constraints.maxWidth;
        final isMobile = screenWidth < 800;
        final bool isCompactDesktop = !isMobile;

        double resolveVisibility({
          required double width,
          required double hideWidth,
          required double showWidth,
        }) {
          if (!isCompactDesktop) return 0;
          if (width <= hideWidth) return 0;
          if (width >= showWidth) return 1;
          return (width - hideWidth) / (showWidth - hideWidth);
        }

        final double locationVisibility = resolveVisibility(
          width: screenWidth,
          hideWidth: _locationColumnHideWidth,
          showWidth: _locationColumnShowWidth,
        );
        final double modeVisibility = resolveVisibility(
          width: screenWidth,
          hideWidth: _modeColumnHideWidth,
          showWidth: _modeColumnShowWidth,
        );

        final blocksForNav = _getBlocksForDate(provider);
        final bool hasBlocks = blocksForNav.isNotEmpty;
        final bool allExpanded = hasBlocks &&
            blocksForNav.every((b) => _expandedBlocks.contains(b.id));
        final bool anyCollapsed =
            hasBlocks && blocksForNav.any((b) => !_expandedBlocks.contains(b.id));
        final bool canToggleAll = hasBlocks && (anyCollapsed || allExpanded);

        return Column(
          children: [
            if (widget.showInlineDateNavigation) ...[
              _TimelineDateNavigator(
                selectedDate: _selectedDate,
                onPrevious: _goToPreviousDay,
                onNext: _goToNextDay,
                allExpanded: allExpanded,
                onToggleAll: canToggleAll
                    ? () {
                        if (allExpanded) {
                          _collapseAllBlocks(provider, blocksForNav);
                          _collapseAllGaps(provider);
                        } else {
                          _expandAllBlocks(provider, blocksForNav);
                          _expandAllGaps(provider);
                        }
                      }
                    : null,
                leadingActions: widget.dateRowLeadingActions,
              ),
              const Divider(height: 1),
            ],
            Expanded(
              child: isMobile
                  ? _buildMobileList(
                      context,
                      provider,
                      locationVisibility: locationVisibility,
                      modeVisibility: modeVisibility,
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 440),
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final r = rows[i];
                        return r.build(
                          context,
                          provider,
                          _showTaskMenu,
                          _showTaskDetails,
                          _startTask,
                          _deleteTask,
                          _showAssignInboxDialog,
                          _showAssignInboxToGapDialog,
                          locationVisibility: locationVisibility,
                          modeVisibility: modeVisibility,
                        );
                      },
                    ),
            ),
            if (runningTask != null)
              KeyedSubtree(
                key: _runningBarKey,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isMobileBar =
                        _isMobilePlatform() && constraints.maxWidth < 800;
                    if (isMobileBar) {
                      return MobileRunningTaskBar(
                        runningTask: runningTask,
                        onPause: () => _pauseTask(runningTask.id),
                        onComplete: () => _completeTask(runningTask.id),
                      );
                    } else {
                      return RunningTaskBar(
                        runningTask: runningTask,
                        onPause: () => _pauseTask(runningTask.id),
                        onComplete: () => _completeTask(runningTask.id),
                      );
                    }
                  },
                ),
              ),
          ],
        );
      },
    ),
    );
  }

  // スマホ版：PC版と同様に、ブロック間のギャップでも実績を見せる
  Widget _buildMobileList(
    BuildContext context,
    TaskProvider provider, {
    required double locationVisibility,
    required double modeVisibility,
  }) {
    // モバイルは「カードUI」で表示する（スマホ対応の要件）。
    // ただし、行モデル（RowItems）はPCと共有し、データ整形ロジックの二重実装を避ける。
    final rows = _buildRowItems(provider);
    if (rows.isEmpty) {
      return const Center(child: Text('この日のタスクはありません'));
    }
    Key _mobileRowKey(_RowItem r) {
      switch (r.kind) {
        case _RowKind.actual:
          return ValueKey<String>('mobile:actual:${r.actualTask!.id}');
        case _RowKind.inbox:
          return ValueKey<String>(
              'mobile:inbox:${r.inboxTask!.id}:${r.inBlock?.id ?? 'none'}:${r.inGap == true ? 'gap' : 'nogap'}');
        case _RowKind.blockHeader:
          return ValueKey<String>('mobile:blockHeader:${r.frameBlock!.id}');
        case _RowKind.gapHeader:
          // gapKey は start/end から再現できる
          final s = r.start!;
          final e = r.end!;
          return ValueKey<String>('mobile:gapHeader:${_gapKey(s, e)}');
      }
    }

    Widget buildLeaf(_RowItem r) {
      switch (r.kind) {
        case _RowKind.actual:
          final a = r.actualTask!;
          return MobileTaskCard(
            key: _mobileRowKey(r),
            task: a,
            taskProvider: provider,
            onLongPress: () => _showTaskMenu(a, provider),
            onShowDetails: () => _showTaskDetails(a),
            onStart: null,
            onRestart: () => provider.restartActualTaskWithoutPlanned(a.id),
            onDelete: () => _deleteTask(a, provider),
          );
        case _RowKind.inbox:
          final t = r.inboxTask!;
          return MobileTaskCard(
            key: _mobileRowKey(r),
            task: t,
            taskProvider: provider,
            onLongPress: () => _showTaskMenu(t, provider),
            onShowDetails: () => _openMobileEdit(t),
            onStart: () => _startTask(t, provider),
            onRestart: null,
            onDelete: () => _deleteTask(t, provider),
          );
        case _RowKind.blockHeader:
        case _RowKind.gapHeader:
          return const SizedBox.shrink(); // handled by section builder
      }
    }

    List<Widget> buildChildrenForBlock(block.Block b, int startIndex) {
      final out = <Widget>[];
      for (int j = startIndex; j < rows.length; j++) {
        final rr = rows[j];
        if (rr.kind == _RowKind.blockHeader || rr.kind == _RowKind.gapHeader) {
          break;
        }
        // このブロックに所属する行のみ拾う
        final inBlock = rr.inBlock;
        if (inBlock == null || inBlock.id != b.id) {
          break;
        }
        if (rr.kind == _RowKind.actual || rr.kind == _RowKind.inbox) {
          out.add(Padding(
            key: _mobileRowKey(rr),
            // Mobile timeline: reduce horizontal whitespace (requested).
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
            child: buildLeaf(rr),
          ));
        }
      }
      return out;
    }

    List<Widget> buildChildrenForGap(int startIndex) {
      final out = <Widget>[];
      for (int j = startIndex; j < rows.length; j++) {
        final rr = rows[j];
        if (rr.kind == _RowKind.blockHeader || rr.kind == _RowKind.gapHeader) {
          break;
        }
        // ギャップ所属の行のみ拾う
        if (rr.inBlock != null) break;
        if (rr.inGap != true) break;
        if (rr.kind == _RowKind.actual || rr.kind == _RowKind.inbox) {
          out.add(Padding(
            key: _mobileRowKey(rr),
            // Mobile timeline: reduce horizontal whitespace (requested).
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 0),
            child: buildLeaf(rr),
          ));
        }
      }
      return out;
    }

    final List<Widget> items = [];
    for (int i = 0; i < rows.length; i++) {
      final r = rows[i];

      if (r.kind == _RowKind.blockHeader) {
        final b = r.frameBlock!;
        final expanded = r.isExpanded ?? false;
        final s = r.start!;
        final e = r.end!;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final now = DateTime.now();
        final bool isPastBlock = e.isBefore(now);
        final baseTitleStyle = theme.textTheme.titleSmall ??
            theme.textTheme.titleMedium ??
            theme.textTheme.bodyMedium ??
            const TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
        final sTxt =
            '${s.hour.toString().padLeft(2, '0')}:${s.minute.toString().padLeft(2, '0')}';
        final eTxt =
            '${e.hour.toString().padLeft(2, '0')}:${e.minute.toString().padLeft(2, '0')}';
        // ブロック名/タイトルが空白のときはサブプロジェクト→プロジェクト名を表示（表示のみ）
        final namePart = (b.blockName != null && b.blockName!.isNotEmpty)
            ? b.blockName!
            : (b.title.isNotEmpty ? b.title : '');
        final subName = (b.subProject != null && b.subProject!.isNotEmpty)
            ? b.subProject!
            : (b.subProjectId != null && b.subProjectId!.isNotEmpty
                ? (SubProjectService.getSubProjectById(b.subProjectId!)?.name ?? '')
                : '');
        final projName = (b.projectId != null && b.projectId!.isNotEmpty)
            ? (ProjectService.getProjectById(b.projectId!)?.name ?? '')
            : '';
        final title = namePart.isNotEmpty
            ? namePart
            : (subName.isNotEmpty ? subName : (projName.isNotEmpty ? projName : '名称未設定'));

        final children = expanded ? buildChildrenForBlock(b, i + 1) : <Widget>[];
        if (expanded) {
          // 子要素を消費して、二重表示しない
          i += children.length;
        }

        items.add(
          Card(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  leading: IconButton(
                    icon: const Icon(Icons.play_arrow, size: 20),
                    tooltip: '開始',
                    onPressed: () => _startTask(b, provider),
                  ),
                  title: Text(
                    '$sTxt–$eTxt  $title',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: isPastBlock
                        ? baseTitleStyle.copyWith(
                            color: scheme.onSurfaceVariant.withOpacity(0.70),
                          )
                        : baseTitleStyle,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.more_vert, size: 20),
                        tooltip: 'メニュー',
                        color: scheme.onSurfaceVariant,
                        disabledColor: scheme.onSurfaceVariant.withOpacity(0.5),
                        onPressed: () => _showTaskMenu(
                          // スマホ版の「予定ブロック（ヘッダー）」メニューは、
                          // 常に予定ブロック自身を対象にする（実績用メニューが混入して混乱するため）
                          b,
                          provider,
                          blockForHeaderActions: b,
                          blockStartForHeaderActions: s,
                        ),
                      ),
                      if (r.onToggle != null)
                        IconButton(
                          icon: Icon(
                            expanded
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            size: 22,
                          ),
                          tooltip: expanded ? '折りたたむ' : '展開',
                          onPressed: r.onToggle,
                        ),
                    ],
                  ),
                  // スマホ表示のタイムラインでは、予定ブロックのタップで詳細を開かない。
                  // （誤タップで詳細が立ち上がるのを防ぐ。操作はメニューに集約）
                  onTap: null,
                ),
                if (expanded && children.isNotEmpty) const Divider(height: 1),
                if (expanded && children.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(children: children),
                  ),
              ],
            ),
          ),
        );
        continue;
      }

      if (r.kind == _RowKind.gapHeader) {
        final expanded = r.isExpanded ?? false;
        final s = r.start!;
        final e = r.end!;
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final now = DateTime.now();
        final bool isPastGap = e.isBefore(now);
        final baseTitleStyle = theme.textTheme.titleSmall ??
            theme.textTheme.titleMedium ??
            theme.textTheme.bodyMedium ??
            const TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
        final sTxt =
            '${s.hour.toString().padLeft(2, '0')}:${s.minute.toString().padLeft(2, '0')}';
        final eTxt =
            '${e.hour.toString().padLeft(2, '0')}:${e.minute.toString().padLeft(2, '0')}';
        final range = '$sTxt–$eTxt';
        final children = expanded ? buildChildrenForGap(i + 1) : <Widget>[];
        if (expanded) {
          i += children.length;
        }

        items.add(
          Card(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  leading: IconButton(
                    icon: const Icon(Icons.play_arrow, size: 20),
                    tooltip: '開始',
                    onPressed: () => _startTask(null, provider),
                  ),
                  title: Text(
                    '$range  ブロック未指定',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: isPastGap
                        ? baseTitleStyle.copyWith(
                            color: scheme.onSurfaceVariant.withOpacity(0.70),
                          )
                        : baseTitleStyle,
                  ),
                  subtitle: null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.more_vert, size: 20),
                        tooltip: 'メニュー',
                        color: scheme.onSurfaceVariant,
                        disabledColor: scheme.onSurfaceVariant.withOpacity(0.5),
                        onPressed: () => _showGapMenu(
                          provider,
                          gapStart: s,
                          gapEndExclusive: e,
                        ),
                      ),
                      if (r.onToggle != null)
                        IconButton(
                          icon: Icon(
                            expanded
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            size: 22,
                          ),
                          tooltip: expanded ? '折りたたむ' : '展開',
                          onPressed: r.onToggle,
                        ),
                    ],
                  ),
                ),
                if (expanded && children.isNotEmpty) const Divider(height: 1),
                if (expanded && children.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(children: children),
                  ),
              ],
            ),
          ),
        );
        continue;
      }

      // どのセクションにも所属しない行（安全側）
      if (r.kind == _RowKind.actual || r.kind == _RowKind.inbox) {
        items.add(buildLeaf(r));
      }
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 440),
      children: items,
    );
  }
}

// 表示フレーム定義
// 旧フレーム構造は廃止（統一1行表示のため）

class _InboxRow extends StatelessWidget {
  final inbox.InboxTask task;
  final VoidCallback onUnlink;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  const _InboxRow({
    required this.task,
    required this.onUnlink,
    required this.onMoveUp,
    required this.onMoveDown,
  });

  @override
  Widget build(BuildContext context) {
    final start = (task.startHour != null && task.startMinute != null)
        ? '${task.startHour!.toString().padLeft(2, '0')}:${task.startMinute!.toString().padLeft(2, '0')}'
        : '--:--';
    final end = (task.startHour != null && task.startMinute != null)
        ? DateTime(
            task.executionDate.year,
            task.executionDate.month,
            task.executionDate.day,
            task.startHour!,
            task.startMinute!,
          ).add(Duration(minutes: task.estimatedDuration))
        : null;
    final endStr = end != null
        ? '${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}'
        : '--:--';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            Icons.task_alt,
            size: 16,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          _Badge(text: '${task.estimatedDuration}分'),
          const SizedBox(width: 8),
          Text('$start→$endStr', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.link_off, size: 16),
            tooltip: 'リンク解除',
            onPressed: onUnlink,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 16),
            tooltip: '上へ',
            onPressed: onMoveUp,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 16),
            tooltip: '下へ',
            onPressed: onMoveDown,
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  const _Badge({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11)),
    );
  }
}

class _GapBounds {
  final DateTime start;
  final DateTime end;
  const _GapBounds({required this.start, required this.end});
}

class _BlockBounds {
  final block.Block blockData;
  final DateTime start;
  final DateTime end;
  const _BlockBounds({
    required this.blockData,
    required this.start,
    required this.end,
  });
}

class _ActualPlacement {
  final Map<_BlockBounds, List<_ActualSegment>> byBlock;
  final List<_ActualSegment> unassigned;
  const _ActualPlacement({required this.byBlock, required this.unassigned});
}

class _ActualSegment {
  final actual.ActualTask task;
  final DateTime start;
  final DateTime endExclusive;
  final bool needsTimeOverride;
  const _ActualSegment({
    required this.task,
    required this.start,
    required this.endExclusive,
    required this.needsTimeOverride,
  });
}

// 1行レコード（ブロック外枠ヘッダー、ギャップヘッダー、実績行）
enum _RowKind { blockHeader, gapHeader, actual, inbox }

typedef _TaskMenuCallback =
    void Function(
      dynamic task,
      TaskProvider provider, {
      BuildContext? anchorContext,
    });

typedef _AssignInboxToBlockRowFn = Future<void> Function(
  BuildContext context,
  TaskProvider provider,
  block.Block b,
);

typedef _AssignInboxToGapRowFn = Future<void> Function(
  BuildContext context,
  TaskProvider provider, {
  required DateTime gapStart,
  required DateTime gapEndExclusive,
});

class _RowItem {
  final _RowKind kind;
  final block.Block? frameBlock;
  final actual.ActualTask? actualTask;
  final inbox.InboxTask? inboxTask;
  final DateTime? start;
  final DateTime? end;
  final block.Block? inBlock;
  final bool? isExpanded;
  final VoidCallback? onToggle;
  final bool inGap;
  final block.Block? plannedBlock; // legacy field (unused)
  final actual.ActualTask? runningActual;
  final dynamic primaryTaskForActions;

  _RowItem._(
    this.kind, {
    this.frameBlock,
    this.actualTask,
    this.inboxTask,
    this.start,
    this.end,
    this.inBlock,
    this.isExpanded,
    this.onToggle,
    this.inGap = false,
    // ignore: unused_element_parameter
    this.plannedBlock,
    this.runningActual,
    this.primaryTaskForActions,
  });

  factory _RowItem.blockHeader(
    block.Block b,
    DateTime start,
    DateTime end, {
    required bool isExpanded,
    required VoidCallback onToggle,
    actual.ActualTask? runningActual,
    dynamic primaryTaskForActions,
  }) => _RowItem._(
    _RowKind.blockHeader,
    frameBlock: b,
    start: start,
    end: end,
    isExpanded: isExpanded,
    onToggle: onToggle,
    runningActual: runningActual,
    primaryTaskForActions: primaryTaskForActions,
  );
  factory _RowItem.gapHeader(
    DateTime start,
    DateTime end, {
    required bool isExpanded,
    required VoidCallback onToggle,
  }) => _RowItem._(
    _RowKind.gapHeader,
    start: start,
    end: end,
    isExpanded: isExpanded,
    onToggle: onToggle,
  );
  factory _RowItem.actualRow(
    actual.ActualTask a, {
    DateTime? displayStart,
    DateTime? displayEnd,
    block.Block? inBlock,
    bool inGap = false,
  }) => _RowItem._(
    _RowKind.actual,
    actualTask: a,
    start: displayStart,
    end: displayEnd,
    inBlock: inBlock,
    inGap: inGap,
  );
  factory _RowItem.inboxRow(
    inbox.InboxTask t, {
    block.Block? inBlock,
    bool inGap = false,
  }) =>
      _RowItem._(_RowKind.inbox, inboxTask: t, inBlock: inBlock, inGap: inGap);
  // planned row is removed

  Widget build(
    BuildContext context,
    TaskProvider provider,
    _TaskMenuCallback onMenu,
    void Function(dynamic) onDetails,
    void Function(dynamic, TaskProvider) onStart,
    void Function(dynamic, TaskProvider) onDelete,
    _AssignInboxToBlockRowFn assignInboxToBlockForRow,
    _AssignInboxToGapRowFn assignInboxToGapForRow, {
    double locationVisibility = 1,
    double modeVisibility = 1,
  }) {
    Key _rowKey() {
      switch (kind) {
        case _RowKind.blockHeader:
          return ValueKey<String>('row:blockHeader:${frameBlock!.id}');
        case _RowKind.gapHeader:
          final s = start!;
          final e = end!;
          // gapKey は start/end から再現できる
          final key =
              '${s.millisecondsSinceEpoch}-${e.millisecondsSinceEpoch}'; // fallback
          return ValueKey<String>('row:gapHeader:$key');
        case _RowKind.actual:
          return ValueKey<String>('row:actual:${actualTask!.id}');
        case _RowKind.inbox:
          return ValueKey<String>(
              'row:inbox:${inboxTask!.id}:${inBlock?.id ?? 'none'}:${inGap ? 'gap' : 'nogap'}');
      }
    }

    switch (kind) {
      case _RowKind.blockHeader:
        final b = frameBlock!;
        final runningActual = this.runningActual;
        final sTxt =
            '${start!.hour.toString().padLeft(2, '0')}:${start!.minute.toString().padLeft(2, '0')}';
        final eTxt =
            '${end!.hour.toString().padLeft(2, '0')}:${end!.minute.toString().padLeft(2, '0')}';
        final title = (b.blockName != null && b.blockName!.isNotEmpty)
            ? b.blockName!
            : (b.title.isNotEmpty ? b.title : '名称未設定');
        final isRunningHere = runningActual != null
            ? runningActual.isRunning
            : provider.runningActualTasks.any((t) => t.blockId == b.id);

        Future<void> openAddInboxTaskForBlock() async {
          final s = start!;
          final pushed = await showUnifiedScreenDialog<bool>(
            context: context,
            builder: (_) => InboxTaskAddScreen(
              initialDate: b.executionDate,
              initialStartTime: TimeOfDay(hour: s.hour, minute: s.minute),
              initialBlockId: b.id,
            ),
          );
          if (pushed == true) {
            // Ensure the header updates immediately (linked tasks appear under the block).
            provider.refreshTasks();
          }
        }

        Color borderColor() {
          final scheme = Theme.of(context).colorScheme;
          final now = DateTime.now();
          final blockStart = start!;
          final blockEnd = end!;
          if (!now.isBefore(blockEnd)) return scheme.outlineVariant;
          final bool inProgress =
              !now.isBefore(blockStart) && now.isBefore(blockEnd);
          final bool emphasize = inProgress || isRunningHere;
          if (b.isEvent == true) {
            return emphasize
                ? scheme.tertiary
                : scheme.tertiary.withOpacity(0.55);
          }
          return emphasize
              ? scheme.primary
              : scheme.primary.withOpacity(0.55);
        }

        // 「過去の予定ブロック」は文字色も落として分かるようにする（PC版）
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final now = DateTime.now();
        final blockEnd = end!;
        final bool isPastBlock = !now.isBefore(blockEnd);
        final baseTitleStyle = theme.textTheme.titleSmall ??
            theme.textTheme.titleMedium ??
            theme.textTheme.bodyMedium ??
            const TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
        final mutedTitleStyle =
            baseTitleStyle.copyWith(color: scheme.onSurfaceVariant.withOpacity(0.70));

        return Container(
          key: _rowKey(),
          decoration: BoxDecoration(
            // PC版の見た目は変更前の配色へ戻す
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withOpacity(0.35),
            border: Border(
              left: BorderSide(color: borderColor(), width: 3),
              right: BorderSide(color: Theme.of(context).dividerColor),
              bottom: BorderSide(color: Theme.of(context).dividerColor),
              top: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: IconButton(
              icon: const Icon(Icons.play_arrow, size: 18),
              tooltip: '開始',
              onPressed: () => onStart(b, provider),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24),
            ),
            title: Row(
              children: [
                Text(
                  '$sTxt-$eTxt',
                  style: (isPastBlock ? mutedTitleStyle : baseTitleStyle)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: isPastBlock ? mutedTitleStyle : baseTitleStyle,
                  ),
                ),
              ],
            ),
            onTap: null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isRunningHere) ...[
                  const _Badge(text: '実行中'),
                  const SizedBox(width: 6),
                ],
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 18),
                  tooltip: 'インボックスから割当',
                  onPressed: () =>
                      assignInboxToBlockForRow(context, provider, b),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24),
                ),
                IconButton(
                  icon: const Icon(Icons.playlist_add, size: 18),
                  tooltip: '新規タスクを追加',
                  onPressed: () => openAddInboxTaskForBlock(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: '編集',
                  onPressed: () async {
                    await showUnifiedScreenDialog<bool>(
                      context: context,
                      builder: (_) =>
                          BlockEditDialog(target: b, taskProvider: provider),
                    );
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24),
                ),
                Builder(
                  builder: (menuContext) => IconButton(
                    icon: const Icon(Icons.more_vert, size: 18),
                    tooltip: 'メニュー',
                    onPressed: () =>
                        onMenu(b, provider, anchorContext: menuContext),
                    color: scheme.onSurfaceVariant,
                    disabledColor: scheme.onSurfaceVariant.withOpacity(0.5),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    (isExpanded ?? false)
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                  ),
                  onPressed: onToggle,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24),
                  tooltip: (isExpanded ?? false) ? '折りたたむ' : '展開',
                ),
              ],
            ),
          ),
        );

      case _RowKind.actual:
        final a = actualTask!;
        final b = inBlock;
        final child = RowTaskCard(
          key: null, // 行の key は下の Container に統一（ブロック未指定でも同じツリーにする）
          task: a,
          taskProvider: provider,
          displayStartTime: start,
          displayEndTime: end,
          onLongPress: (menuContext) =>
              onMenu(a, provider, anchorContext: menuContext),
          onShowDetails: () => onDetails(a),
          onStart: null,
          onRestart: () => provider.restartActualTaskWithoutPlanned(a.id),
          onDelete: () => onDelete(a, provider),
          locationVisibility: locationVisibility,
          modeVisibility: modeVisibility,
        );
        // ブロック未指定（b==null && !inGap）も同じ Container で包む（広い画面で右側グレーアウト対策）
        return Container(
          key: _rowKey(),
          margin: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(
              // イベントは赤の左ライン（inBlock がある場合のみ）、それ以外は下罫線のみ
              left: (b != null && b.isEvent == true)
                  ? BorderSide(
                      color: Theme.of(context).colorScheme.tertiary,
                      width: 3,
                    )
                  : BorderSide.none,
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: child,
        );
      case _RowKind.inbox:
        final t = inboxTask!;
        final child = RowTaskCard(
          key: null, // 行の key は下の Container に統一（ブロック未指定でも同じツリーにする）
          task: t,
          taskProvider: provider,
          onLongPress: (menuContext) =>
              onMenu(t, provider, anchorContext: menuContext),
          onShowDetails: null, // インライン編集を優先（ダイアログは開かない）
          onStart: () => onStart(t, provider),
          onRestart: null,
          onDelete: () => onDelete(t, provider),
          locationVisibility: locationVisibility,
          modeVisibility: modeVisibility,
        );
        // ブロック未指定（b==null）も同じ Container で包む（右側グレーアウト対策）
        return Container(
          key: _rowKey(),
          margin: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: child,
        );
      case _RowKind.gapHeader:
        final s = start!;
        final e = end!;
        final sTxt =
            '${s.hour.toString().padLeft(2, '0')}:${s.minute.toString().padLeft(2, '0')}';
        final eTxt =
            '${e.hour.toString().padLeft(2, '0')}:${e.minute.toString().padLeft(2, '0')}';
        final timeRange = '$sTxt-$eTxt';
        final dayOnly = DateTime(s.year, s.month, s.day);
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final now = DateTime.now();
        final bool isPastGap = !now.isBefore(e);
        final baseTitleStyle = theme.textTheme.titleSmall ??
            theme.textTheme.titleMedium ??
            theme.textTheme.bodyMedium ??
            const TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
        Color gapBorderColor() {
          // 予定ブロック同様、「区間が終了したら」ライン色を落とす。
          if (!now.isBefore(e)) return scheme.outlineVariant;
          final bool inProgress = !now.isBefore(s) && now.isBefore(e);
          return inProgress
              ? scheme.primary
              : scheme.primary.withOpacity(0.55);
        }

        Future<void> openAddInboxTaskForGap() async {
          final pushed = await showUnifiedScreenDialog<bool>(
            context: context,
            builder: (_) => InboxTaskAddScreen(
              initialDate: dayOnly,
              initialStartTime: TimeOfDay(hour: s.hour, minute: s.minute),
              initialBlockId: null,
            ),
          );
          if (pushed == true) {
            provider.refreshTasks();
          }
        }
        return Container(
          key: _rowKey(),
          decoration: BoxDecoration(
            // PC版の見た目は変更前の配色へ戻す
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withOpacity(0.35),
            border: Border(
              left: BorderSide(
                color: gapBorderColor(),
                width: 3,
              ),
              right: BorderSide(color: Theme.of(context).dividerColor),
              bottom: BorderSide(color: Theme.of(context).dividerColor),
              top: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: IconButton(
              icon: const Icon(Icons.play_arrow, size: 18),
              tooltip: '開始',
              onPressed: () => onStart(null, provider),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24),
            ),
            title: Row(
              children: [
                Text(
                  timeRange,
                  style: (isPastGap
                          ? baseTitleStyle.copyWith(
                              color: scheme.onSurfaceVariant.withOpacity(0.70),
                            )
                          : baseTitleStyle)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'ブロック未指定',
                    style: isPastGap
                        ? baseTitleStyle.copyWith(
                            color: scheme.onSurfaceVariant.withOpacity(0.70),
                          )
                        : baseTitleStyle,
                  ),
                ),
              ],
            ),
            onTap: null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 18),
                  tooltip: 'インボックスから割当',
                  onPressed: () => assignInboxToGapForRow(
                        context,
                        provider,
                        gapStart: s,
                        gapEndExclusive: e,
                      ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24),
                ),
                IconButton(
                  icon: const Icon(Icons.playlist_add, size: 18),
                  tooltip: '新規タスクを追加',
                  onPressed: () => openAddInboxTaskForGap(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: '予定ブロックを追加',
                  onPressed: () async {
                    final created =
                        await TimelineActions.addBlockToTimelineReturningBlock(
                      context,
                      day: DateTime(s.year, s.month, s.day),
                      snackbarLabel:
                          '${s.year}/${s.month.toString().padLeft(2, '0')}/${s.day.toString().padLeft(2, '0')}',
                      initialStart: TimeOfDay(hour: s.hour, minute: s.minute),
                      fullscreen: true,
                    );
                    if (!context.mounted || created == null) return;

                    // ギャップ区間に開始する「未リンクの時間ありインボックス」を紐づける（確認→実行）
                    final ids = provider
                        .collectUnassignedTimedInboxTaskIdsStartingInRange(
                      rangeStartLocal: s,
                      rangeEndExclusiveLocal: e,
                    );
                    if (!context.mounted) return;
                    if (ids.isEmpty) return;

                    final ok = await showImeSafeDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('確認'),
                        content: Text(
                          'この時間帯のタスク ${ids.length} 件を、このブロックに紐づけますか？\n（開始時刻は維持します）',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: const Text('しない'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: const Text('紐づける'),
                          ),
                        ],
                      ),
                    );
                    if (ok != true) return;

                    final linked =
                        await provider.linkInboxTaskIdsToBlockPreservingTime(
                      blockId: created.id,
                      inboxTaskIds: ids,
                    );
                    if (!context.mounted) return;
                    if (linked > 0) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$linked 件を紐づけました')),
                      );
                    }
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24),
                ),
                // ギャップには「メニュー」ボタンが無いが、列揃えのため同幅の空きを確保する
                const SizedBox(width: 24),
                IconButton(
                  icon: Icon(
                    (isExpanded ?? false)
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                  ),
                  onPressed: onToggle,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24),
                ),
              ],
            ),
          ),
        );
      // no planned row
    }
  }
}

class _GapItem {
  final DateTime time;
  final String title;
  final String durationText;
  final String rangeText;
  final Widget icon;
  _GapItem({
    required this.time,
    required this.title,
    required this.durationText,
    required this.rangeText,
    required this.icon,
  });
}

class _DragData {
  final String taskId;
  _DragData({required this.taskId});
}

class _DragAvatar extends StatelessWidget {
  final String title;
  const _DragAvatar({required this.title});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: const Color(0x00000000),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.inverseSurface.withOpacity(0.85),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          title,
          style: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _TimelineDateNavigator extends StatelessWidget {
  final DateTime selectedDate;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool allExpanded;
  final VoidCallback? onToggleAll;
  final List<Widget>? leadingActions;

  const _TimelineDateNavigator({
    required this.selectedDate,
    required this.onPrevious,
    required this.onNext,
    required this.allExpanded,
    required this.onToggleAll,
    this.leadingActions,
  });

  @override
  Widget build(BuildContext context) {
    final label = DateFormat('yyyy/MM/dd (E)', 'ja_JP').format(selectedDate);
    final Color textColor =
        Theme.of(context).textTheme.titleMedium?.color ??
            Theme.of(context).colorScheme.onSurface;
    final titleStyle = (Theme.of(context).textTheme.titleMedium ??
            const TextStyle())
        .copyWith(
      color: textColor,
      fontWeight: FontWeight.w600,
    );

    // 左メニュー「Kant」行と高さを揃える（48px）
    const double dateBarHeight = 48;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: dateBarHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              // 左: 日付ナビ（左揃え）
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.max,
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      tooltip: '前日',
                      onPressed: onPrevious,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        label,
                        style: titleStyle,
                        textAlign: TextAlign.left,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      tooltip: '翌日',
                      onPressed: onNext,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                  ],
                ),
              ),
            // 展開ボタンの左: 外から渡されたアクション（同期・設定など）
            if (leadingActions != null && leadingActions!.isNotEmpty) ...leadingActions!,
            // 右端: 予定ブロックと同じ開閉ボタン（全て展開/全て閉じる）
            IconButton(
              icon: Icon(
                allExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 18,
              ),
              tooltip: allExpanded ? '全て閉じる' : '全て展開',
              onPressed: onToggleAll,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

class _ActualProgressRow extends StatelessWidget {
  final actual.ActualTask task;
  final int plannedMinutes;
  const _ActualProgressRow({required this.task, required this.plannedMinutes});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final elapsed = now.difference(task.startTime).inMinutes.clamp(0, 100000);
    final planned = math.max(plannedMinutes, 1);
    final ratio = (elapsed / planned).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.timelapse, size: 14),
            const SizedBox(width: 6),
            Text(
              '実行中 ${elapsed}分 / 予定${planned}分',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: ratio, minHeight: 6),
        ),
      ],
    );
  }
}

// ===== helpers =====
extension _Actions on _TimelineScreenV2State {
  // 旧タイムラインのメニュー/詳細/開始/削除操作をV2でも使う
  void _showTaskMenu(
    dynamic task,
    TaskProvider taskProvider, {
    BuildContext? anchorContext,
    block.Block? blockForHeaderActions,
    DateTime? blockStartForHeaderActions,
  }) {
    // NOTE:
    // スマホ版の予定ブロックヘッダーでは、ヘッダー上のボタンを減らし
    // 「新規タスクを追加」等をメニューへ集約したい。
    // ただし、メニューは実績（primaryTaskForActions）を開くケースがあるため、
    // “ヘッダーの文脈としてのブロック”を別途受け取れるようにする。
    //
    final block.Block? effectiveBlock =
        blockForHeaderActions ?? (task is block.Block ? task : null);

    final VoidCallback? onAssignInboxFromMenu = effectiveBlock != null
        ? () => _showAssignInboxDialog(
              context,
              taskProvider,
              effectiveBlock,
            )
        : null;

    final VoidCallback? onAddTaskToBlockFromMenu = effectiveBlock != null
        ? () async {
            final b = effectiveBlock;
            final baseStart = blockStartForHeaderActions ??
                DateTime(
                  b.executionDate.year,
                  b.executionDate.month,
                  b.executionDate.day,
                  b.startHour,
                  b.startMinute,
                );
            final pushed = await showUnifiedScreenDialog<bool>(
              context: context,
              builder: (_) => InboxTaskAddScreen(
                initialDate: b.executionDate,
                initialStartTime:
                    TimeOfDay(hour: baseStart.hour, minute: baseStart.minute),
                initialBlockId: b.id,
              ),
            );
            if (pushed == true) {
              taskProvider.refreshTasks();
            }
          }
        : null;
    Offset? anchorOffset;
    Size anchorSize = Size.zero;
    Size overlaySize = MediaQuery.of(context).size;
    final overlayState = Overlay.of(context);
    final overlayBox = overlayState.context.findRenderObject() as RenderBox?;
    if (overlayBox != null) {
      overlaySize = overlayBox.size;
    }
    if (anchorContext != null) {
      final buttonBox = anchorContext.findRenderObject() as RenderBox?;
      if (buttonBox != null && overlayBox != null) {
        anchorOffset = buttonBox.localToGlobal(
          Offset.zero,
          ancestor: overlayBox,
        );
        anchorSize = buttonBox.size;
      }
    }

    // PC タイムライン（行右端の more_vert）では anchorContext を渡す。タイトルは行上に出ているので省略。
    final bool omitMenuTitle = anchorContext != null;

    if (anchorOffset == null) {
      showDialog(
        context: context,
        builder: (context) {
          return TaskMenu(
            task: task,
            plannedBlock: effectiveBlock,
            taskProvider: taskProvider,
            onShowDetails: () => _showTaskDetails(task),
            onAssignInbox: onAssignInboxFromMenu,
            onAddTaskToBlock: onAddTaskToBlockFromMenu,
            omitTitle: omitMenuTitle,
          );
        },
      );
      return;
    }

    const double kDialogWidth = 360.0;
    const double kEstimatedHeight = 420.0;
    const double kMargin = 16.0;
    final double belowTop = anchorOffset.dy + anchorSize.height + 8.0;
    final double aboveTop = anchorOffset.dy - kEstimatedHeight - 8.0;

    double left = anchorOffset.dx;
    if (left + kDialogWidth + kMargin > overlaySize.width) {
      left = overlaySize.width - kDialogWidth - kMargin;
    }
    if (left < kMargin) left = kMargin;

    double top = belowTop;
    if (top + kEstimatedHeight + kMargin > overlaySize.height) {
      top = aboveTop;
      if (top < kMargin) {
        top = (overlaySize.height - kEstimatedHeight) / 2;
      }
    }

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'task-menu',
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return Stack(
          children: [
            Positioned(
              left: left,
              top: top,
              child: Material(
                color: const Color(0x00000000),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: kDialogWidth),
                  child: SizedBox(
                    width: kDialogWidth,
                    child: TaskMenu(
                      task: task,
                      plannedBlock: effectiveBlock,
                      taskProvider: taskProvider,
                      onShowDetails: () =>
                          _showTaskDetails(task, anchorContext: anchorContext),
                      onAssignInbox: onAssignInboxFromMenu,
                      onAddTaskToBlock: onAddTaskToBlockFromMenu,
                      omitTitle: omitMenuTitle,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
    );
  }

  // スマホ版: ギャップ（ブロック未指定）ヘッダー用メニュー
  void _showGapMenu(
    TaskProvider provider, {
    required DateTime gapStart,
    required DateTime gapEndExclusive,
  }) {
    final dayOnly = DateTime(gapStart.year, gapStart.month, gapStart.day);
    final label =
        '${dayOnly.year}/${dayOnly.month.toString().padLeft(2, '0')}/${dayOnly.day.toString().padLeft(2, '0')}';

    Future<void> openAddPlannedBlock() async {
      await TimelineActions.addBlockToTimeline(
        context,
        day: dayOnly,
        snackbarLabel: label,
        initialStart: TimeOfDay(hour: gapStart.hour, minute: gapStart.minute),
        fullscreen: true,
      );
    }

    Future<void> openAddInboxTaskForGap() async {
      final pushed = await showUnifiedScreenDialog<bool>(
        context: context,
        builder: (_) => InboxTaskAddScreen(
          initialDate: dayOnly,
          initialStartTime: TimeOfDay(hour: gapStart.hour, minute: gapStart.minute),
          initialBlockId: null,
        ),
      );
      if (pushed == true) {
        provider.refreshTasks();
      }
    }

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('ブロック未指定'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('予定ブロックを追加'),
              onTap: () async {
                final nav = Navigator.of(dialogContext, rootNavigator: true);
                nav.pop();
                await Future<void>.delayed(Duration.zero);
                await openAddPlannedBlock();
              },
            ),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: const Text('インボックスから割当'),
              onTap: () async {
                final nav = Navigator.of(dialogContext, rootNavigator: true);
                nav.pop();
                await Future<void>.delayed(Duration.zero);
                await _showAssignInboxToGapDialog(
                  context,
                  provider,
                  gapStart: gapStart,
                  gapEndExclusive: gapEndExclusive,
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('新規タスクを追加'),
              onTap: () async {
                final nav = Navigator.of(dialogContext, rootNavigator: true);
                nav.pop();
                await Future<void>.delayed(Duration.zero);
                await openAddInboxTaskForGap();
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('キャンセル'),
          ),
        ],
      ),
    );
  }

  void _showTaskDetails(dynamic task, {BuildContext? anchorContext}) {
    // 実績タスクはモバイル編集画面へ。その他は詳細ダイアログを維持
    if (MediaQuery.of(context).size.width < 800 && task is actual.ActualTask) {
      _openMobileEdit(task);
      return;
    }
    Future.microtask(() {
      // NOTE:
      // メニューバーのアンカー位置に追従して表示すると、縦方向の制約が効かず
      // 画面外にはみ出して「スクロール不能」になるケースがあるため、
      // 詳細は常に画面中央（SafeArea内）に表示する。
      showImeSafeDialog(
        context: context,
        useRootNavigator: true,
        builder: (_) => TaskDetailsDialog(task: task),
      );
    });
  }

  void _openMobileEdit(dynamic task) {
    // インボックスタスクは専用の編集画面へ
    if (task is inbox.InboxTask) {
      _openInboxEdit(task);
      return;
    }
    showUnifiedScreenDialog<void>(
      context: context,
      builder: (_) => MobileTaskEditScreen(task: task),
    );
  }

  void _openInboxEdit(inbox.InboxTask task) {
    showUnifiedScreenDialog<void>(
      context: context,
      builder: (_) => InboxTaskEditScreen(task: task),
    );
  }

  Future<void> _startTask(dynamic task, TaskProvider taskProvider) async {
    if (task is block.Block) {
      final durationMinutes = task.estimatedDuration;
      final showTimer = _isMobilePlatform() && durationMinutes > 0;

      if (showTimer) {
        await taskProvider.createActualTask(task);
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => TaskTimerScreen(
              durationMinutes: durationMinutes,
              title: task.title,
            ),
          ),
        );
        return;
      }

      taskProvider.createActualTask(task);
      final now = DateTime.now();
      final pendingActual = actual.ActualTask(
        id: 'pending-${task.id}-$now',
        title: task.title,
        projectId: task.projectId,
        dueDate: task.dueDate,
        startTime: now,
        status: actual.ActualTaskStatus.running,
        memo: task.memo,
        createdAt: now,
        lastModified: now,
        userId: task.userId,
        blockId: (task.cloudId != null && task.cloudId!.isNotEmpty)
            ? task.cloudId!
            : task.id,
        subProjectId: task.subProjectId,
        subProject: task.subProject,
        modeId: task.modeId,
        blockName: task.blockName,
        location: task.location,
      );
      setState(() {
        _pendingBlockActuals[task.id] = pendingActual;
      });
      Future.delayed(const Duration(seconds: 5), () {
        if (!mounted) return;
        if (_pendingBlockActuals[task.id]?.id == pendingActual.id) {
          setState(() {
            _pendingBlockActuals.remove(task.id);
          });
        }
      });
      return;
    }
    if (task is inbox.InboxTask) {
      final durationMinutes = task.estimatedDuration;
      final showTimer = _isMobilePlatform() && durationMinutes > 0;

      if (showTimer) {
        await taskProvider.createActualTaskFromInbox(task.id);
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => TaskTimerScreen(
              durationMinutes: durationMinutes,
              title: task.title,
            ),
          ),
        );
        return;
      }

      taskProvider.createActualTaskFromInbox(task.id);
      return;
    }
  }

  void _deleteTask(dynamic task, TaskProvider taskProvider) {
    if (task is actual.ActualTask) {
      taskProvider.deleteActualTask(task.id);
    } else if (task is block.Block) {
      taskProvider.deleteBlock(task.id);
    }
  }

  void _pauseTask(String taskId) async {
    try {
      await Provider.of<TaskProvider>(
        context,
        listen: false,
      ).pauseActualTask(taskId);
    } catch (_) {}
  }

  void _completeTask(String taskId) async {
    try {
      await Provider.of<TaskProvider>(
        context,
        listen: false,
      ).completeActualTask(taskId);
    } catch (_) {}
  }

  void _reorderInline(String blockId, String taskId, {required bool up}) {
    final current = _orderByBlockId[blockId];
    if (current == null) return;
    final idx = current.indexOf(taskId);
    if (idx < 0) return;
    final nextIdx = up ? (idx - 1) : (idx + 1);
    if (nextIdx < 0 || nextIdx >= current.length) return;
    setState(() {
      final tmp = current[idx];
      current[idx] = current[nextIdx];
      current[nextIdx] = tmp;
      _orderByBlockId[blockId] = List<String>.from(current);
    });
  }

  Future<void> _showLinkDialog(
    BuildContext context,
    TaskProvider provider,
    block.Block b,
  ) async {
    final candidates =
        provider.allInboxTasks.where((t) => t.isDeleted != true).where((t) {
          final sameDay =
              t.executionDate.year == b.executionDate.year &&
              t.executionDate.month == b.executionDate.month &&
              t.executionDate.day == b.executionDate.day;
          // 既に同一ブロックへリンク済み or 未リンクを候補に含める
          final eligible =
              (t.blockId == null || t.blockId!.isEmpty || t.blockId == b.id);
          // Someday は候補から除外
          final notSomeday = (t.isSomeday != true);
          return sameDay && eligible && notSomeday;
        }).toList()..sort((a, b0) => a.title.compareTo(b0.title));

    if (candidates.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('リンク可能なインボックスがありません')));
      }
      return;
    }

    final selectedId = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('インボックスをリンク'),
        content: SizedBox(
          width: 420,
          height: 360,
          child: ListView.builder(
            itemCount: candidates.length,
            itemBuilder: (c, i) {
              final t = candidates[i];
              final hasTime = (t.startHour != null && t.startMinute != null);
              return ListTile(
                leading: const Icon(Icons.inbox),
                title: Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${t.estimatedDuration}分  ${hasTime ? '${t.startHour!.toString().padLeft(2, '0')}:${t.startMinute!.toString().padLeft(2, '0')}' : '--:--'}',
                ),
                trailing: (t.blockId == b.id)
                    ? const _Badge(text: '既にリンク')
                    : null,
                onTap: () => Navigator.of(ctx).pop(t.id),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('キャンセル'),
          ),
        ],
      ),
    );

    if (!mounted || selectedId == null) return;
    final matches = provider.allInboxTasks
        .where((t) => t.id == selectedId)
        .toList();
    if (matches.isEmpty) return;
    await _linkInboxToBlock(context, provider, matches.first, b);
  }

  Future<void> _linkInboxToBlock(
    BuildContext context,
    TaskProvider provider,
    inbox.InboxTask t,
    block.Block b,
  ) async {
    try {
      final updated = t.copyWith(
        blockId: (b.cloudId != null && b.cloudId!.isNotEmpty)
            ? b.cloudId!
            : b.id,
        executionDate: b.executionDate,
        startHour: b.startHour,
        startMinute: b.startMinute,
      );
      await provider.updateInboxTask(updated);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('リンクしました: ${t.title}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('リンクに失敗しました: $e')));
      }
    }
  }

  Future<void> _unlinkInboxTask(
    BuildContext context,
    TaskProvider provider,
    inbox.InboxTask t,
  ) async {
    try {
      final updated = t.copyWith(blockId: null);
      await provider.updateInboxTask(updated);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('リンクを解除しました: ${t.title}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('解除に失敗しました: $e')));
      }
    }
  }

  // インボックスから選択して、このブロックに割当（1:Nルールで自動配置）
  Future<void> _showAssignInboxDialog(
    BuildContext context,
    TaskProvider provider,
    block.Block b,
  ) async {
    final day = b.executionDate;
    final candidates =
        provider.allInboxTasks
            .where((t) => t.isDeleted != true && (t.isCompleted != true))
            .where((t) => t.isSomeday != true)
            .where((t) => t.blockId == null || t.blockId!.isEmpty)
            .where(
              (t) =>
                  t.executionDate.year == day.year &&
                  t.executionDate.month == day.month &&
                  t.executionDate.day == day.day,
            )
            .toList()
          ..sort((a, b0) => a.title.compareTo(b0.title));
    await showImeSafeDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('インボックスから割当'),
        content: SizedBox(
          width: 420,
          height: 360,
          child: candidates.isEmpty
              ? const Center(child: Text('割り当て可能なタスクがありません'))
              : ListView.builder(
                  itemCount: candidates.length,
                  itemBuilder: (c, i) {
                    final t = candidates[i];
                    final hasTime =
                        (t.startHour != null && t.startMinute != null);
                    return ListTile(
                      leading: const Icon(Icons.inbox),
                      title: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${t.estimatedDuration}分  ${hasTime ? '${t.startHour!.toString().padLeft(2, '0')}:${t.startMinute!.toString().padLeft(2, '0')}' : '--:--'}',
                      ),
                      onTap: () async {
                        Navigator.of(ctx).pop();
                        await provider.assignInboxToBlockWithScheduling(
                          t.id,
                          b.id,
                        );
                      },
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  /// ギャップ（ブロック未指定）へ、同日の未割り当てインボックスを割り当て
  Future<void> _showAssignInboxToGapDialog(
    BuildContext context,
    TaskProvider provider, {
    required DateTime gapStart,
    required DateTime gapEndExclusive,
  }) async {
    final day = DateTime(gapStart.year, gapStart.month, gapStart.day);
    final candidates =
        provider.allInboxTasks
            .where((t) => t.isDeleted != true && (t.isCompleted != true))
            .where((t) => t.isSomeday != true)
            .where((t) => t.blockId == null || t.blockId!.isEmpty)
            .where(
              (t) =>
                  t.executionDate.year == day.year &&
                  t.executionDate.month == day.month &&
                  t.executionDate.day == day.day,
            )
            .toList()
          ..sort((a, b0) => a.title.compareTo(b0.title));
    await showImeSafeDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('インボックスから割当'),
        content: SizedBox(
          width: 420,
          height: 360,
          child: candidates.isEmpty
              ? const Center(child: Text('割り当て可能なタスクがありません'))
              : ListView.builder(
                  itemCount: candidates.length,
                  itemBuilder: (c, i) {
                    final t = candidates[i];
                    final hasTime =
                        (t.startHour != null && t.startMinute != null);
                    return ListTile(
                      leading: const Icon(Icons.inbox),
                      title: Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${t.estimatedDuration}分  ${hasTime ? '${t.startHour!.toString().padLeft(2, '0')}:${t.startMinute!.toString().padLeft(2, '0')}' : '--:--'}',
                      ),
                      onTap: () async {
                        Navigator.of(ctx).pop();
                        await provider.assignInboxToUnassignedGapWithScheduling(
                          t.id,
                          gapStart: gapStart,
                          gapEndExclusive: gapEndExclusive,
                        );
                      },
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }
}
