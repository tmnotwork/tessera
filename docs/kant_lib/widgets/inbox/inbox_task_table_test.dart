import 'package:flutter/material.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import '../../models/inbox_task.dart' as inbox;
import '../../models/block.dart' as block;
import '../../providers/task_provider.dart';
import '../../services/block_service.dart';
import '../../services/project_service.dart';
import '../../services/inbox_task_service.dart';
import '../../services/device_info_service.dart';
import '../project_input_field.dart';
import '../sub_project_input_field.dart';
import '../mode_input_field.dart';
import '../../services/actual_task_sync_service.dart';
import '../../services/inbox_task_sync_service.dart';
import '../../services/task_sync_manager.dart';
import '../../services/mode_service.dart';
import 'inbox_memo_dialog.dart';
import 'excel_like_title_cell.dart';

class InboxTaskTableTestWidget extends StatefulWidget {
  const InboxTaskTableTestWidget({super.key});

  @override
  State<InboxTaskTableTestWidget> createState() => _InboxTaskTableTestWidgetState();
}

class _InboxTaskTableTestWidgetState extends State<InboxTaskTableTestWidget> {
  // 可変列の最小幅（PC）
  static const double _minTitleWidth = 220;
  static const double _minProjectWidth = 140;
  static const double _minSubProjectWidth = 140;
  static const double _minBlockWidth = 160;
  static const double _minModeWidth = 120;
  static const double _rowHeight = 36;
  static const String _somedayDropdownValue = '__inbox_someday__';
  // レスポンシブ表示: 退避順（モード → サブプロジェクト）
  static const double _modeColumnHideWidth = 1260;
  static const double _modeColumnShowWidth = 1340;
  static const double _subProjectColumnHideWidth = 1120;
  static const double _subProjectColumnShowWidth = 1200;
  static const Duration _responsiveAnimDuration = Duration(milliseconds: 200);
  static const double _responsiveMinVisibleWidth = 72;
  // 「サブプロジェクト」が2行に折り返す幅では列ごと非表示にする
  static const double _subProjectMinVisibleWidth = 120;
  // 既存行のコントローラ
  final Map<String, TextEditingController> _titleControllers = {};
  final Map<String, TextEditingController> _projectControllers = {};
  final Map<String, TextEditingController> _subProjectControllers = {};
  final Map<String, TextEditingController> _modeControllers = {};
  final Map<String, TextEditingController> _startTimeControllers = {};
  final Map<String, TextEditingController> _durationControllers = {};
  // 追加: 実行日コントローラ
  final Map<String, TextEditingController> _dateControllers = {};
  // 追加: 期限コントローラ
  final Map<String, TextEditingController> _dueDateControllers = {};
  // タイトルの自動保存デバウンス用
  final Map<String, Timer> _titleSaveTimers = {};

  // 新規行 UI は廃止（追加ボタンで即時作成）

  bool _showAssigned = false; // 割り当て済みの表示切替
  // 即時反映: 楽観的に完了として非表示にするID
  final Set<String> _optimisticallyCompleted = <String>{};
  // 画面内の表示順を安定させるため、セッション内で順序を保持
  final List<String> _displayOrderIds = <String>[];

  @override
  void initState() {
    super.initState();
    _refreshAvailableBlocks();
    try {
      ModeService.initialize();
    } catch (_) {}
  }

  @override
  void dispose() {
    for (final t in _titleSaveTimers.values) {
      t.cancel();
    }
    for (final c in _titleControllers.values) {
      c.dispose();
    }
    for (final c in _projectControllers.values) {
      c.dispose();
    }
    for (final c in _subProjectControllers.values) {
      c.dispose();
    }
    for (final c in _modeControllers.values) {
      c.dispose();
    }
    for (final c in _startTimeControllers.values) {
      c.dispose();
    }
    for (final c in _durationControllers.values) {
      c.dispose();
    }
    // 追加: 実行日コントローラ廃棄
    for (final c in _dateControllers.values) {
      c.dispose();
    }
    // 追加: 期限コントローラ廃棄
    for (final c in _dueDateControllers.values) {
      c.dispose();
    }

    super.dispose();
  }

  void _refreshAvailableBlocks() {
    try {
      // このメソッドは現在使用されていないため、空の実装に変更
      setState(() {});
    } catch (e) {
      setState(() {});
    }
  }

  TextStyle _cellTextStyle(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final base = textTheme.bodyMedium ?? const TextStyle();
    final fallbackFamily = base.fontFamily ?? textTheme.bodySmall?.fontFamily ?? 'NotoSansJP';
    return base.copyWith(
      fontSize: 12,
      height: 1.0,
      fontFamily: fallbackFamily,
    );
  }

  Color _resolveTableBackgroundColor(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = theme.scaffoldBackgroundColor;

    if (theme.brightness == Brightness.light) {
      return Color.alphaBlend(scheme.onSurface.withOpacity(0.03), base);
    }

    return scheme.surfaceContainerHighest.withOpacity(0.2);
  }

  // セッション内で安定した順序を付与（新規は末尾、消えたIDは除去）
  List<inbox.InboxTask> _orderTasksForDisplay(List<inbox.InboxTask> items) {
    final ids = items.map((t) => t.id).toList();
    // なくなったIDを除去
    _displayOrderIds.removeWhere((id) => !ids.contains(id));
    // 新規IDを末尾に追加（元リストの出現順を尊重）
    for (final id in ids) {
      if (!_displayOrderIds.contains(id)) {
        _displayOrderIds.add(id);
      }
    }
    // 並べ替えテーブルを作成
    final indexOf = <String, int>{};
    for (int i = 0; i < _displayOrderIds.length; i++) {
      indexOf[_displayOrderIds[i]] = i;
    }
    final sorted = [...items]..sort((a, b) =>
        (indexOf[a.id] ?? 1 << 30).compareTo(indexOf[b.id] ?? 1 << 30));
    return sorted;
  }

  // HH:MM -> (hour, minute)
  (int?, int?) _parseTime(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return (null, null);

    int? hour;
    int? minute;

    // 1) コロン区切りを優先的に解析（例: 9:00, 09:00, 9:0）
    if (trimmed.contains(':')) {
      final parts = trimmed.split(':');
      if (parts.length >= 2) {
        hour = int.tryParse(parts[0].trim());
        minute = int.tryParse(parts[1].trim());
      }
    }

    // 2) 数字のみで構成される場合のフォールバック（例: 900, 0930, 930）
    if (hour == null || minute == null) {
      final digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.isEmpty) {
        return (null, null);
      } else if (digits.length == 4) {
        hour = int.tryParse(digits.substring(0, 2));
        minute = int.tryParse(digits.substring(2, 4));
      } else if (digits.length == 3) {
        hour = int.tryParse(digits.substring(0, 1));
        minute = int.tryParse(digits.substring(1, 3));
      } else if (digits.length == 2) {
        hour = int.tryParse(digits);
        minute = 0;
      } else if (digits.length == 1) {
        hour = int.tryParse(digits);
        minute = 0;
      }
    }

    if (hour == null || minute == null) return (null, null);
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return (null, null);
    return (hour, minute);
  }

  String _formatTimeDisplay(int? hour, int? minute) {
    if (hour == null || minute == null) return '';
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  // 追加: 日付表示フォーマット（yy/mm/dd）
  String _formatDate(DateTime d) {
    final yy = (d.year % 100).toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$yy/$mm/$dd';
  }

  // PC用: 期限の短縮表示フォーマット（yy/mm/dd）
  String _formatDateShort(DateTime d) {
    final yy = (d.year % 100).toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$yy/$mm/$dd';
  }

  // 実行日ごとの候補ブロック取得（未完了・同日）
  List<block.Block> _getAvailableBlocksForDate(DateTime date) {
    // インボックス画面のポリシー: 実行日が当日以前は当日扱い
    final now = DateTime.now();
    final todayYmd = DateTime(now.year, now.month, now.day);
    final DateTime effective = () {
      final dl = date.toLocal();
      final ymd = DateTime(dl.year, dl.month, dl.day);
      if (ymd.isBefore(todayYmd)) return todayYmd;
      return ymd;
    }();

    bool sameYmd(DateTime a, DateTime b) {
      final al = a.toLocal();
      final bl = b.toLocal();
      return al.year == bl.year && al.month == bl.month && al.day == bl.day;
    }

    final allBlocks = BlockService.getAllBlocks();
    final filtered = allBlocks.where((b) {
      final isSameDay = sameYmd(b.executionDate, effective);
      final isNotDeleted = !b.isDeleted;

      // 実行中のブロック（時間内）は isCompleted でも候補に含める
      bool isWithinBlockWindow() {
        try {
          final start = DateTime(
            b.executionDate.year,
            b.executionDate.month,
            b.executionDate.day,
            b.startHour,
            b.startMinute,
          );
          final end = start.add(Duration(minutes: b.estimatedDuration));
          return !now.isBefore(start) && now.isBefore(end);
        } catch (_) {
          return false;
        }
      }

      final includeByCompletion = !b.isCompleted || isWithinBlockWindow();

      bool isPastBlock() {
        try {
          final start = DateTime(
            b.executionDate.year,
            b.executionDate.month,
            b.executionDate.day,
            b.startHour,
            b.startMinute,
          );
          final end = start.add(Duration(minutes: b.estimatedDuration));
          // 「過ぎ去った予定ブロック」は end <= now と解釈
          return !now.isBefore(end);
        } catch (_) {
          return false;
        }
      }

      // 仕様変更: 多対1許可のため、既リンク有無は候補から除外しない
      return isSameDay &&
          isNotDeleted &&
          includeByCompletion &&
          !isPastBlock();
    }).toList();

    filtered.sort((a, b) {
      final at = a.startHour * 60 + a.startMinute;
      final bt = b.startHour * 60 + b.startMinute;
      return at.compareTo(bt);
    });

    return filtered;
  }

  // この行のタスク用の候補（自分に既に割り当て済みのブロックは例外的に含める）
  List<block.Block> _getAvailableBlocksForTask(inbox.InboxTask task) {
    final base = _getAvailableBlocksForDate(task.executionDate);
    if (task.blockId == null || task.blockId!.isEmpty) return base;
    final current = BlockService.getBlockById(task.blockId!);
    if (current == null) return base;
    // 同日で未完了なら候補に足す（他タスクに紐づいていても自分の現在選択は表示する）
    bool sameYmd(DateTime a, DateTime b) {
      final al = a.toLocal();
      final bl = b.toLocal();
      return al.year == bl.year && al.month == bl.month && al.day == bl.day;
    }

    if (sameYmd(current.executionDate, task.executionDate) &&
        !current.isCompleted &&
        !current.isDeleted) {
      if (!base.any((b) => b.id == current.id)) {
        return [...base, current]..sort((a, b) =>
            (a.startHour * 60 + a.startMinute)
                .compareTo(b.startHour * 60 + b.startMinute));
      }
    }
    return base;
  }

  void _ensureControllers(inbox.InboxTask task) {
    _titleControllers.putIfAbsent(
        task.id, () => TextEditingController(text: task.title));

    // プロジェクト名初期化
    final projectName = task.projectId != null
        ? (ProjectService.getProjectById(task.projectId!)?.name ?? '')
        : '';
    _projectControllers.putIfAbsent(
        task.id, () => TextEditingController(text: projectName));

    // サブプロジェクト名初期化
    final subProjectName = task.subProjectId != null ? '' : '';
    _subProjectControllers.putIfAbsent(
        task.id, () => TextEditingController(text: subProjectName));
    // モード名初期化
    final modeName = () {
      if (task.modeId != null && task.modeId!.isNotEmpty) {
        try {
          return ModeService.getModeById(task.modeId!)?.name ?? '';
        } catch (_) {
          return '';
        }
      }
      return '';
    }();
    _modeControllers.putIfAbsent(
        task.id, () => TextEditingController(text: modeName));
    if (_modeControllers[task.id]?.text != modeName) {
      _modeControllers[task.id]?.text = modeName;
    }

    // 開始時刻
    _startTimeControllers.putIfAbsent(
        task.id,
        () => TextEditingController(
            text: _formatTimeDisplay(task.startHour, task.startMinute)));

    // 作業時間
    _durationControllers.putIfAbsent(task.id,
        () => TextEditingController(text: (task.estimatedDuration).toString()));

    // 追加: 実行日
    _dateControllers.putIfAbsent(task.id,
        () => TextEditingController(text: _formatDate(task.executionDate)));

    // 追加: 期限
    _dueDateControllers.putIfAbsent(
        task.id,
        () => TextEditingController(
            text: task.dueDate != null ? _formatDateShort(task.dueDate!) : ''));
  }

  Future<void> _saveEditedTask(
      BuildContext context, inbox.InboxTask original) async {
    final title = _titleControllers[original.id]?.text.trim() ?? original.title;

    // 時刻
    final (h, m) = _parseTime(_startTimeControllers[original.id]?.text ?? '');
    final durationText = _durationControllers[original.id]?.text ?? '';
    int? duration;
    if (durationText.isNotEmpty) {
      duration = int.tryParse(durationText);
    }

    // プロジェクト/サブプロジェクトは ProjectInputField/SubProjectInputField の onChange で即時反映させる方針

    final updated = original.copyWith(
      title: title.isEmpty ? original.title : title,
      startHour: h ?? original.startHour,
      startMinute: m ?? original.startMinute,
      estimatedDuration: duration ?? original.estimatedDuration,
    );

    await context.read<TaskProvider>().updateInboxTask(updated);
    _refreshAvailableBlocks();
  }

  // Enterキーで確定後にフォーカスを外して非アクティブ表示にする
  Future<void> _saveAndUnfocus(
      BuildContext context, inbox.InboxTask task) async {
    await _saveEditedTask(context, task);
    try {
      FocusScope.of(context).unfocus();
    } catch (_) {}
  }

  Future<void> _deleteTask(BuildContext context, inbox.InboxTask task) async {
    await context.read<TaskProvider>().deleteInboxTask(task.id);
    _refreshAvailableBlocks();
  }

  // 追加: 実行日更新
  Future<void> _updateExecutionDate(
      BuildContext context, inbox.InboxTask task) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: task.executionDate,
      firstDate: DateTime.now().subtract(const Duration(days: 0)),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      // 実行日を更新し、ブロック選択は一旦クリア（同日の候補から再選択）
      final newExec = DateTime(picked.year, picked.month, picked.day);
      final updated = task.copyWith(executionDate: newExec, blockId: null);
      await context.read<TaskProvider>().updateInboxTask(updated);
      setState(() {
        _dateControllers[task.id]?.text = _formatDate(newExec);
      });
    }
  }

  // 追加: 期限更新
  Future<void> _updateDueDate(
      BuildContext context, inbox.InboxTask task) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: task.dueDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      final newDue = DateTime(picked.year, picked.month, picked.day);
      final updated = task.copyWith(dueDate: newDue);
      await context.read<TaskProvider>().updateInboxTask(updated);
      setState(() {
        _dueDateControllers[task.id]?.text = _formatDateShort(newDue);
      });
    }
  }

  // 新規追加はボタン押下で即時作成する方針に変更（旧 _saveNewRow は削除）

  @override
  Widget build(BuildContext context) {
    return Consumer<TaskProvider>(
      builder: (context, taskProvider, child) {
        final all = taskProvider.allInboxTasks
            .where((t) => !t.isCompleted)
            .where((t) => !_optimisticallyCompleted.contains(t.id))
            .toList();
        final baseTasks = all
            .where((t) => taskProvider.shouldShowInboxTask(t,
                includeAssigned: _showAssigned))
            .toList();
        final tasks = _orderTasksForDisplay(baseTasks);

        double resolveVisibility({
          required double width,
          required double hideWidth,
          required double showWidth,
        }) {
          if (width <= hideWidth) return 0;
          if (width >= showWidth) return 1;
          return (width - hideWidth) / (showWidth - hideWidth);
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.of(context).size.width;
            final modeVisibility = resolveVisibility(
              width: width,
              hideWidth: _modeColumnHideWidth,
              showWidth: _modeColumnShowWidth,
            );
            final subProjectVisibility = resolveVisibility(
              width: width,
              hideWidth: _subProjectColumnHideWidth,
              showWidth: _subProjectColumnShowWidth,
            );
            final tableBackgroundColor = _resolveTableBackgroundColor(context);

            return Column(
              children: [
            // フィルタトグル
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(Icons.filter_list,
                      size: 18, color: Theme.of(context).hintColor),
                  const SizedBox(width: 6),
                  Text('割り当て済みも表示',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).textTheme.bodySmall?.color)),
                  const SizedBox(width: 6),
                  Switch(
                    value: _showAssigned,
                    onChanged: (v) => setState(() => _showAssigned = v),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    thumbColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return Theme.of(context).colorScheme.onPrimary;
                      }
                      return Theme.of(context).colorScheme.onSurfaceVariant;
                    }),
                    trackColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return Theme.of(context).colorScheme.primary;
                      }
                      return Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest;
                    }),
                    overlayColor: WidgetStateProperty.all(
                      Theme.of(context)
                          .colorScheme
                          .primary
                          .withOpacity( 0.08),
                    ),
                  ),
                ],
              ),
            ),
            // ヘッダー
            Container(
              height: 36,
              decoration: BoxDecoration(
                color: tableBackgroundColor,
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
              child: Row(
                children: [
                  // 追加: 期限
                  SizedBox(
                    width: 88,
                    child: Container(
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                          border: Border(
                              right: BorderSide(
                                  color: Theme.of(context).dividerColor))),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Text('期限',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                  // 追加: 情報（メモ）
                  SizedBox(
                    width: 44,
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          border: Border(
                              right: BorderSide(
                                  color: Theme.of(context).dividerColor))),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Text('メモ',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                  // 追加: 実行日
                  SizedBox(
                    width: 88,
                    child: Container(
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                          border: Border(
                              right: BorderSide(
                                  color: Theme.of(context).dividerColor))),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Text('実行日',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 88,
                    child: Container(
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                          border: Border(
                              right: BorderSide(
                                  color: Theme.of(context).dividerColor))),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Text('実行時刻',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Container(
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                          border: Border(
                              right: BorderSide(
                                  color: Theme.of(context).dividerColor))),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Text('所要',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                  Flexible(
                    flex: 4,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: _minTitleWidth,
                      ),
                      child: Container(
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                            border: Border(
                                right: BorderSide(
                                    color: Theme.of(context).dividerColor))),
                        child: const Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                          child: Text('タスク名',
                              style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ),
                  // 実行ボタン列
                  SizedBox(
                    width: 44,
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          border: Border(
                              right: BorderSide(
                                  color: Theme.of(context).dividerColor))),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Text('実行',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          border: Border(
                              right: BorderSide(
                                  color: Theme.of(context).dividerColor))),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Text('完了',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                  Flexible(
                    flex: 2,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: _minProjectWidth,
                      ),
                      child: Container(
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                            border: Border(
                                right: BorderSide(
                                    color: Theme.of(context).dividerColor))),
                        child: const Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                          child: Text('プロジェクト',
                              style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ),
                  _ResponsiveColumn(
                    visibility: subProjectVisibility,
                    fullWidth: _minSubProjectWidth,
                    minVisibleWidth: _subProjectMinVisibleWidth,
                    duration: _responsiveAnimDuration,
                    child: Container(
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        border: Border(
                          right: BorderSide(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                      ),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Text(
                          'サブプロジェクト',
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                  _ResponsiveColumn(
                    visibility: modeVisibility,
                    fullWidth: _minModeWidth,
                    minVisibleWidth: _responsiveMinVisibleWidth,
                    duration: _responsiveAnimDuration,
                    child: Container(
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        border: Border(
                          right: BorderSide(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                      ),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Text(
                          'モード',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Flexible(
                    flex: 2,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: _minBlockWidth,
                      ),
                      child: Container(
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                            border: Border(
                                right: BorderSide(
                                    color: Theme.of(context).dividerColor))),
                        child: const Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                          child: Text('ブロック',
                              style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          border: Border(
                              right: BorderSide(
                                  color: Theme.of(context).dividerColor))),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        child: Text('操作',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // データ行
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                  color: tableBackgroundColor,
                  border: Border.all(color: Theme.of(context).dividerColor)),
              child: Column(
                children: [
                  ...List.generate(tasks.length, (index) {
                    final t = tasks[index];
                    _ensureControllers(t);
                    return Container(
                      height: 36,
                      decoration: BoxDecoration(
                        color: tableBackgroundColor,
                        border: Border(
                          bottom: BorderSide(
                            color: Theme.of(context).dividerColor,
                            width: index == tasks.length - 1 ? 0 : 1,
                          ),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 追加: 期限
                          SizedBox(
                            width: 88,
                            child: Container(
                              decoration: BoxDecoration(
                                  border: Border(
                                      right: BorderSide(
                                          color:
                                              Theme.of(context).dividerColor))),
                              alignment: Alignment.center,
                              child: SizedBox(
                                height: _rowHeight,
                                child: TextField(
                                  controller: _dueDateControllers[t.id],
                                  readOnly: true,
                                  textAlign: TextAlign.center,
                                  textAlignVertical: TextAlignVertical.center,
                                  style: _cellTextStyle(context),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    isCollapsed: true,
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 4.0, vertical: 16.0),
                                    constraints: BoxConstraints(
                                      minHeight: _rowHeight,
                                      maxHeight: _rowHeight,
                                    ),
                                    hintText: 'yy/mm/dd',
                                    hintStyle: TextStyle(fontSize: 12),
                                  ),
                                  onTap: () => _updateDueDate(context, t),
                                ),
                              ),
                            ),
                          ),
                          // 追加: 情報（メモ）
                          SizedBox(
                            width: 44,
                            child: Container(
                              decoration: BoxDecoration(
                                  border: Border(
                                      right: BorderSide(
                                          color:
                                              Theme.of(context).dividerColor))),
                              alignment: Alignment.center,
                              child: IconButton(
                                icon: Icon(
                                  Icons.comment_outlined,
                                  size: 18,
                                  // 他のセル文字と同じ色で十分（強調しない）
                                  color: Theme.of(context).textTheme.bodyMedium?.color,
                                ),
                                tooltip: 'コメントを編集',
                                  onPressed: () =>
                                      showInboxMemoEditorDialog(context, t),
                              ),
                            ),
                          ),
                          // 追加: 実行日
                          SizedBox(
                            width: 88,
                            child: Container(
                              decoration: BoxDecoration(
                                  border: Border(
                                      right: BorderSide(
                                          color:
                                              Theme.of(context).dividerColor))),
                              alignment: Alignment.center,
                              child: SizedBox(
                                height: _rowHeight,
                                child: TextField(
                                  controller: _dateControllers[t.id],
                                  readOnly: true,
                                  textAlign: TextAlign.center,
                                  textAlignVertical: TextAlignVertical.center,
                                  style: _cellTextStyle(context),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    isCollapsed: true,
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 4.0, vertical: 16.0),
                                    constraints: BoxConstraints(
                                      minHeight: _rowHeight,
                                      maxHeight: _rowHeight,
                                    ),
                                    hintText: 'yy/mm/dd',
                                    hintStyle: TextStyle(fontSize: 12),
                                  ),
                                  onTap: () =>
                                      _updateExecutionDate(context, t),
                                ),
                              ),
                            ),
                          ),
                          // 時間（開始）
                          SizedBox(
                            width: 88,
                            child: Container(
                              decoration: BoxDecoration(
                                  border: Border(
                                      right: BorderSide(
                                          color:
                                              Theme.of(context).dividerColor))),
                              alignment: Alignment.center,
                              child: SizedBox(
                                height: _rowHeight,
                                child: TextField(
                                  controller: _startTimeControllers[t.id],
                                  textAlign: TextAlign.center,
                                  textAlignVertical: TextAlignVertical.center,
                                  style: _cellTextStyle(context),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    isCollapsed: true,
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 4.0, vertical: 16.0),
                                    constraints: BoxConstraints(
                                      minHeight: _rowHeight,
                                      maxHeight: _rowHeight,
                                    ),
                                    hintText: 'HH:MM',
                                    hintStyle: TextStyle(fontSize: 12),
                                  ),
                                  keyboardType: TextInputType.number,
                                  onSubmitted: (_) =>
                                      _saveAndUnfocus(context, t),
                                ),
                              ),
                            ),
                          ),
                          // 所要
                          SizedBox(
                            width: 56,
                            child: Container(
                              decoration: BoxDecoration(
                                  border: Border(
                                      right: BorderSide(
                                          color:
                                              Theme.of(context).dividerColor))),
                              alignment: Alignment.center,
                              child: SizedBox(
                                height: _rowHeight,
                                child: TextField(
                                  controller: _durationControllers[t.id],
                                  textAlign: TextAlign.center,
                                  textAlignVertical: TextAlignVertical.center,
                                  style: _cellTextStyle(context),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    isCollapsed: true,
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 4.0, vertical: 16.0),
                                    constraints: BoxConstraints(
                                      minHeight: _rowHeight,
                                      maxHeight: _rowHeight,
                                    ),
                                    hintText: '分',
                                    hintStyle: TextStyle(fontSize: 12),
                                  ),
                                  keyboardType: TextInputType.number,
                                  onSubmitted: (_) =>
                                      _saveAndUnfocus(context, t),
                                ),
                              ),
                            ),
                          ),
                          // タスク名（タイトル）: Excelライクなセル
                          Flexible(
                            flex: 4,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minWidth: _minTitleWidth,
                              ),
                              child: ExcelLikeTitleCell(
                                controller: _titleControllers[t.id]!,
                                rowHeight: _rowHeight,
                                borderColor: Theme.of(context).dividerColor,
                                placeholder: '(無題)',
                                onChanged: (_) {
                                  _titleSaveTimers[t.id]?.cancel();
                                  _titleSaveTimers[t.id] = Timer(
                                    const Duration(milliseconds: 700),
                                    () => _saveEditedTask(context, t),
                                  );
                                },
                                onCommit: () => _saveEditedTask(context, t),
                              ),
                            ),
                          ),
                          // 実行ボタン
                          SizedBox(
                            width: 44,
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                  border: Border(
                                      right: BorderSide(
                                          color:
                                              Theme.of(context).dividerColor))),
                              child: IconButton(
                                icon: Icon(Icons.play_arrow,
                                    // 他のセル文字と同じ色で十分（強調しない）
                                    color: Theme.of(context).textTheme.bodyMedium?.color,
                                    size: 20),
                                tooltip: 'このタスクを実行',
                                onPressed: () async {
                                  // 現在のタイトルの未保存分を先に反映
                                  final currentTitle =
                                      (_titleControllers[t.id]?.text.trim() ??
                                                  '')
                                              .isNotEmpty
                                          ? _titleControllers[t.id]!.text.trim()
                                          : t.title;
                                  if (currentTitle != t.title) {
                                    await context
                                        .read<TaskProvider>()
                                        .updateInboxTask(
                                            t.copyWith(title: currentTitle));
                                  }
                                  await context
                                      .read<TaskProvider>()
                                      .createActualTaskFromInbox(t.id);
                                },
                              ),
                            ),
                          ),
                          // 完了（0分実績作成）
                          SizedBox(
                            width: 44,
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                  border: Border(
                                      right: BorderSide(
                                          color:
                                              Theme.of(context).dividerColor))),
                              child: IconButton(
                                icon: Icon(Icons.check,
                                    // 他のセル文字と同じ色で十分（強調しない）
                                    color: Theme.of(context).textTheme.bodyMedium?.color,
                                    size: 20),
                                tooltip: '0分実績を作成して完了',
                                onPressed: () async {
                                  await _completeWithZeroActual(t);
                                },
                              ),
                            ),
                          ),
                          // プロジェクト
                          Flexible(
                            flex: 2,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minWidth: _minProjectWidth,
                              ),
                              child: Container(
                                decoration: BoxDecoration(
                                    border: Border(
                                        right: BorderSide(
                                            color: Theme.of(context)
                                                .dividerColor))),
                                child: ProjectInputField(
                                  controller: _projectControllers[t.id]!,
                                  useOutlineBorder: false,
                                  includeArchived: false,
                                  showAllOnTap: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 6.0,
                                    vertical: 10.0,
                                  ),
                                  onProjectChanged: (projectId) async {
                                    final updated =
                                        t.copyWith(projectId: projectId);
                                    await context
                                        .read<TaskProvider>()
                                        .updateInboxTask(updated);
                                    setState(() {});
                                  },
                                ),
                              ),
                            ),
                          ),
                          // サブプロジェクト
                          _ResponsiveColumn(
                            visibility: subProjectVisibility,
                            fullWidth: _minSubProjectWidth,
                            minVisibleWidth: _subProjectMinVisibleWidth,
                            duration: _responsiveAnimDuration,
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border(
                                  right: BorderSide(
                                    color: Theme.of(context).dividerColor,
                                  ),
                                ),
                              ),
                              child: SubProjectInputField(
                                controller: _subProjectControllers[t.id]!,
                                projectId: t.projectId,
                                useOutlineBorder: false,
                                onSubProjectChanged:
                                    (subProjectId, subProjectName) async {
                                  final updated =
                                      t.copyWith(subProjectId: subProjectId);
                                  await context
                                      .read<TaskProvider>()
                                      .updateInboxTask(updated);
                                  setState(() {});
                                },
                              ),
                            ),
                          ),
                          _ResponsiveColumn(
                            visibility: modeVisibility,
                            fullWidth: _minModeWidth,
                            minVisibleWidth: _responsiveMinVisibleWidth,
                            duration: _responsiveAnimDuration,
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border(
                                  right: BorderSide(
                                    color: Theme.of(context).dividerColor,
                                  ),
                                ),
                              ),
                              child: ModeInputField(
                                controller: _modeControllers[t.id]!,
                                useOutlineBorder: false,
                                withBackground: false,
                                height: 32,
                                onModeChanged: (modeId) async {
                                  final updated = t.copyWith(
                                    modeId: modeId,
                                    lastModified: DateTime.now(),
                                    version: t.version + 1,
                                  );
                                  await context
                                      .read<TaskProvider>()
                                      .updateInboxTask(updated);
                                  setState(() {});
                                },
                                onAutoSave: () async {
                                  if (_modeControllers[t.id]
                                              ?.text
                                              .trim()
                                              .isEmpty ==
                                          true &&
                                      t.modeId != null) {
                                    final updated = t.copyWith(
                                      modeId: null,
                                      lastModified: DateTime.now(),
                                      version: t.version + 1,
                                    );
                                    await context
                                        .read<TaskProvider>()
                                        .updateInboxTask(updated);
                                    setState(() {});
                                  }
                                },
                              ),
                            ),
                          ),
                          // ブロック（候補）
                          Flexible(
                            flex: 2,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minWidth: _minBlockWidth,
                              ),
                              child: Container(
                                decoration: BoxDecoration(
                                    border: Border(
                                        right: BorderSide(
                                            color: Theme.of(context)
                                                .dividerColor))),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 6),
                                alignment: Alignment.centerLeft,
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String?>(
                                    isExpanded: true,
                                    // 現在の選択をそのまま表示（候補には自分の選択も含める）
                                    value: t.isSomeday == true
                                        ? _somedayDropdownValue
                                        : (t.blockId != null &&
                                                t.blockId!.isNotEmpty
                                            ? t.blockId
                                            : null),
                                    hint: const Text('なし',
                                        style: TextStyle(fontSize: 12)),
                                    items: [
                                      const DropdownMenuItem<String?>(
                                        value: null,
                                        child: Text('なし',
                                            style: TextStyle(fontSize: 12)),
                                      ),
                                      ..._getAvailableBlocksForTask(t).map(
                                        (b) => DropdownMenuItem<String?>(
                                          value: b.id,
                                          child: Text(
                                            '${((b.blockName != null && b.blockName!.isNotEmpty) ? b.blockName! : (b.title.isEmpty ? '(無題)' : b.title))} (${b.startHour.toString().padLeft(2, '0')}:${b.startMinute.toString().padLeft(2, '0')})',
                                            overflow: TextOverflow.ellipsis,
                                            style:
                                                const TextStyle(fontSize: 12),
                                          ),
                                        ),
                                      ),
                                      const DropdownMenuItem<String?>(
                                        value: _somedayDropdownValue,
                                        child: Text('いつか',
                                            style: TextStyle(fontSize: 12)),
                                      ),
                                    ],
                                    onChanged: (val) async {
                                      // タイトルの未保存分を取り込む
                                      final currentTitle =
                                          (_titleControllers[t.id]
                                                          ?.text
                                                          .trim() ??
                                                      '')
                                                  .isNotEmpty
                                              ? _titleControllers[t.id]!
                                                  .text
                                                  .trim()
                                              : t.title;
                                      // 仕様変更: ブロックへリンクせず、ブロックの日時をタスクへ反映する
                                      if (val == _somedayDropdownValue) {
                                        final updated = t.copyWith(
                                          title: currentTitle,
                                          blockId: null,
                                          startHour: null,
                                          startMinute: null,
                                          isSomeday: true,
                                        );
                                        await context
                                            .read<TaskProvider>()
                                            .updateInboxTask(updated);
                                        _startTimeControllers[t.id]?.text = '';
                                      } else if (val != null &&
                                          val.isNotEmpty) {
                                        final blk =
                                            BlockService.getBlockById(val);
                                        if (blk != null) {
                                          // 仕様: 過去に置かないため、Providerのスケジューリングを使用
                                          await context
                                              .read<TaskProvider>()
                                              .assignInboxToBlockWithScheduling(
                                                  t.id, blk.id);
                                        }
                                      } else {
                                        // 選択をクリア: 実行時刻を未設定に戻す（未割当）
                                        final updated = t.copyWith(
                                          title: currentTitle,
                                          startHour: null,
                                          startMinute: null,
                                          blockId: null,
                                          isSomeday: false,
                                        );
                                        await context
                                            .read<TaskProvider>()
                                            .updateInboxTask(updated);
                                        // UIの時刻表示も即時反映
                                        _startTimeControllers[t.id]?.text = '';
                                      }
                                      setState(() {});
                                    },
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // 操作（メニュー）
                          SizedBox(
                            width: 44,
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                  border: Border(
                                      right: BorderSide(
                                          color:
                                              Theme.of(context).dividerColor))),
                              child: PopupMenuButton<String>(
                                tooltip: '操作',
                                icon: Icon(
                                  Icons.more_vert,
                                  size: 18,
                                  color: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.color,
                                ),
                                onSelected: (value) async {
                                  switch (value) {
                                    case 'complete':
                                      await _completeWithZeroActual(t);
                                      break;
                                    case 'someday':
                                      final updated =
                                          t.copyWith(isSomeday: true);
                                      await context
                                          .read<TaskProvider>()
                                          .updateInboxTask(updated);
                                      setState(() {});
                                      break;
                                    case 'delete':
                                      await _deleteTask(context, t);
                                      break;
                                  }
                                },
                                itemBuilder: (ctx) => [
                                  const PopupMenuItem(
                                    value: 'complete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.check, size: 16),
                                        SizedBox(width: 8),
                                        Text('完了'),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'someday',
                                    child: Row(
                                      children: const [
                                        Icon(Icons.nightlight_round, size: 16),
                                        SizedBox(width: 8),
                                        Text('いつか'),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete_forever,
                                            size: 16,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .error),
                                        const SizedBox(width: 8),
                                        const Text('削除'),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),

            // 追加ボタン
            Container(
              margin: const EdgeInsets.only(top: 16.0),
              child: ElevatedButton.icon(
                onPressed: () async {
                  // 押下時点で即追加（タイトルは仮値、プロジェクト等は後から編集可能）
                  await context.read<TaskProvider>().createTaskForInbox(
                        title: '',
                      );
                },
                icon: const Icon(Icons.add),
                label: const Text('タスクを追加'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
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

  // 0分実績作成 + インボックス完了（Runningバーを出さない実装）
  Future<void> _completeWithZeroActual(inbox.InboxTask task) async {
    try {
      // 楽観的更新: 先にUIから消す
      _optimisticallyCompleted.add(task.id);
      if (mounted) setState(() {});

      // バックグラウンドで処理（0分実績→完了→軽量リフレッシュ）
      unawaited(() async {
        try {
          final svc = ActualTaskSyncService();
          await svc.createCompletedZeroTaskWithSync(
            title: task.title,
            projectId: task.projectId,
            memo: task.memo,
            subProjectId: task.subProjectId,
            subProject: null,
            modeId: null,
            blockName: null,
            sourceInboxTaskId: task.id,
          );
        } catch (_) {}
        try {
          final now = DateTime.now();
          final completedInbox = task.copyWith(
            isCompleted: true,
            endTime: now,
          );
          try {
            completedInbox.markAsModified(await DeviceInfoService.getDeviceId());
          } catch (_) {}
          await InboxTaskService.updateInboxTask(completedInbox);
          unawaited(
              TaskSyncManager.syncInboxTaskImmediately(completedInbox, 'update'));
        } catch (_) {}
        try {
          if (mounted) {
            // 非ブロッキングの軽量更新
            // ignore: unawaited_futures
            context.read<TaskProvider>().refreshTasks(showLoading: false);
          }
        } catch (_) {}
      }());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('完了処理に失敗しました: $e')),
        );
      }
    }
  }
}

class _ResponsiveColumn extends StatelessWidget {
  final double visibility;
  final double fullWidth;
  final double minVisibleWidth;
  final Duration duration;
  final Widget child;

  const _ResponsiveColumn({
    required this.visibility,
    required this.fullWidth,
    required this.minVisibleWidth,
    required this.duration,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final target = visibility.clamp(0.0, 1.0);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: target),
      duration: duration,
      curve: Curves.easeInOut,
      builder: (context, v, _) {
        final width = fullWidth * v;
        final isVisible = v > 0 && width >= minVisibleWidth;
        if (!isVisible) return const SizedBox.shrink();
        return SizedBox(
          width: width,
          child: Opacity(
            opacity: v,
            child: IgnorePointer(
              ignoring: v <= 0,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
