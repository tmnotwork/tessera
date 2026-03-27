import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/inbox_task.dart';
import '../services/inbox_task_sync_service.dart';
import '../services/sync_manager.dart';
import '../utils/ime_safe_dialog.dart';

class InboxDbScreen extends StatefulWidget {
  const InboxDbScreen({super.key});

  @override
  State<InboxDbScreen> createState() => _InboxDbScreenState();
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

class _NumberRange {
  const _NumberRange({this.min, this.max});

  final double? min;
  final double? max;

  bool get isActive => min != null || max != null;
}

class _TimeFilter {
  const _TimeFilter({this.minMinutes, this.maxMinutes});

  final int? minMinutes;
  final int? maxMinutes;

  bool get isActive => minMinutes != null || maxMinutes != null;
}

class _TimeRangePickerRow extends StatelessWidget {
  const _TimeRangePickerRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final TimeOfDay? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = value == null ? '指定なし' : value!.format(context);
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton(
            onPressed: onTap,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(text),
            ),
          ),
        ),
      ],
    );
  }
}

class _InboxDbScreenState extends State<InboxDbScreen> {
  final DateFormat _date = DateFormat('yyyy/MM/dd');
  final DateFormat _dateTime = DateFormat('yyyy/MM/dd HH:mm');
  final ScrollController _hController = ScrollController();
  final ScrollController _vController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  // フィルタ状態
  // 3ヶ月制限トグルは廃止（初期値として実行日の直近3ヶ月を _execRange に設定）
  String? _titleContains;
  String? _projectIdContains;
  String? _subProjectIdContains;
  String? _memoContains;
  String? _userIdContains;
  String? _blockIdContains;
  String? _cloudIdContains;
  String? _deviceIdContains;
  String? _idContains;
  DateTimeRange? _execRange;
  DateTimeRange? _dueRange;
  DateTimeRange? _startActualRange;
  DateTimeRange? _endActualRange;
  DateTimeRange? _createdRange;
  DateTimeRange? _updatedRange;
  DateTimeRange? _lastSyncedRange;
  bool? _completed; // null: すべて, true/false
  bool? _someday;
  bool? _isRunningFilter;
  bool? _isDeletedFilter;
  _NumberRange? _estimatedDurationRange;
  _NumberRange? _versionRange;
  _TimeFilter? _startClockFilter;

  static const List<int> _limitOptions = [200, 500, 1000, 2000];
  int _fetchLimit = 500;
  bool _isLoading = false;
  String? _errorMessage;
  int _requestToken = 0;
  bool _syncing = false;
  DateTime? _lastSyncedAt;
  List<InboxTask> _remoteSource = [];
  List<InboxTask> _displayedTasks = [];
  String? _globalSearchQuery;
  int _sortColumnIndex = 4;
  bool _isSortAscending = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _execRange = DateTimeRange(
      start: today.subtract(const Duration(days: 90)),
      end: today,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshRemote();
    });
  }

  // ヘッダー用: フィルタアイコン付きラベル
  Widget _headerWithFilter(String label, VoidCallback onTap, bool active) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(
              Icons.filter_list,
              size: 16,
              color: active ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  // Chips
  Widget _chip(String text, VoidCallback onDeleted) => Chip(
    label: Text(text, style: const TextStyle(fontSize: 12)),
    deleteIcon: const Icon(Icons.close, size: 16),
    onDeleted: onDeleted,
  );

  void _clearAllFilters() {
    setState(() {
      _titleContains = null;
      _projectIdContains = null;
      _subProjectIdContains = null;
      _memoContains = null;
      _userIdContains = null;
      _blockIdContains = null;
      _cloudIdContains = null;
      _deviceIdContains = null;
      _idContains = null;
      _estimatedDurationRange = null;
      _versionRange = null;
      _startClockFilter = null;
      _searchController.clear();
      _globalSearchQuery = null;
      _startActualRange = null;
      _endActualRange = null;
      _createdRange = null;
      _updatedRange = null;
      _lastSyncedRange = null;
      // クリア時も直近3ヶ月を初期値として設定
      final now = DateTime.now();
      final start = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 90));
      final end = DateTime(now.year, now.month, now.day);
      _execRange = DateTimeRange(start: start, end: end);
      _dueRange = null;
      _completed = null;
      _someday = null;
      _isRunningFilter = null;
      _isDeletedFilter = null;
    });
    _refreshRemote();
  }

  Future<void> _openTextFilterDialog({
    required String label,
    required String? currentValue,
    required ValueChanged<String?> onChanged,
  }) async {
    final controller = TextEditingController(text: currentValue ?? '');
    final res = await showImeSafeDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$label でフィルタ'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '含む文字列'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('適用'),
          ),
        ],
      ),
    );
    if (res == null) return;
    final value = res.isEmpty ? null : res;
    setState(() {
      onChanged(value);
      _displayedTasks = _applyClientFilters(_remoteSource);
    });
  }

  Future<void> _openDateFilterDialog({
    required String label,
    required DateTimeRange? currentValue,
    required ValueChanged<DateTimeRange?> onChanged,
    bool refreshRemote = false,
    DateTimeRange? fallbackRange,
  }) async {
    final now = DateTime.now();
    final defaultRange = fallbackRange ??
        DateTimeRange(
          start: now.subtract(const Duration(days: 7)),
          end: now,
        );
    final initialRange = currentValue ?? defaultRange;
    final res = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: initialRange,
      helpText: '$label フィルタ',
    );
    if (res == null) return;
    if (refreshRemote) {
      setState(() => onChanged(res));
      _refreshRemote();
    } else {
      setState(() {
        onChanged(res);
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    }
  }

  Future<void> _openExecDateFilter() async {
    final now = DateTime.now();
    await _openDateFilterDialog(
      label: '実行日',
      currentValue: _execRange,
      onChanged: (value) => _execRange = value,
      refreshRemote: true,
      fallbackRange: DateTimeRange(
        start: now.subtract(const Duration(days: 7)),
        end: now,
      ),
    );
  }

  Future<void> _openDueDateFilter() async {
    await _openDateFilterDialog(
      label: '期日',
      currentValue: _dueRange,
      onChanged: (value) => _dueRange = value,
    );
  }

  Future<void> _openTriStateFilter({
    required String title,
    required bool? currentValue,
    required ValueChanged<bool?> onChanged,
    bool refreshRemote = false,
  }) async {
    bool? local = currentValue;
    final res = await showDialog<bool?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$title フィルタ'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<bool?>(
              title: const Text('すべて'),
              value: null,
              groupValue: local,
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
            RadioListTile<bool?>(
              title: const Text('はい'),
              value: true,
              groupValue: local,
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
            RadioListTile<bool?>(
              title: const Text('いいえ'),
              value: false,
              groupValue: local,
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, local),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
    if (res == null || res == currentValue) {
      return;
    }
    if (refreshRemote) {
      setState(() => onChanged(res));
      _refreshRemote();
    } else {
      setState(() {
        onChanged(res);
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    }
  }

  @override
  void dispose() {
    try {
      _hController.dispose();
      _vController.dispose();
      _searchController.dispose();
      _searchFocusNode.dispose();
    } catch (_) {}
    super.dispose();
  }

  List<InboxTask> _applyClientFilters(List<InboxTask> source) {
    Iterable<InboxTask> it = source;
    if (_titleContains?.isNotEmpty == true) {
      final q = _titleContains!.toLowerCase();
      it = it.where((t) => t.title.toLowerCase().contains(q));
    }
    if (_projectIdContains?.isNotEmpty == true) {
      final q = _projectIdContains!.toLowerCase();
      it = it.where((t) => (t.projectId ?? '').toLowerCase().contains(q));
    }
    if (_subProjectIdContains?.isNotEmpty == true) {
      final q = _subProjectIdContains!.toLowerCase();
      it = it.where((t) => (t.subProjectId ?? '').toLowerCase().contains(q));
    }
    if (_memoContains?.isNotEmpty == true) {
      final q = _memoContains!.toLowerCase();
      it = it.where((t) => (t.memo ?? '').toLowerCase().contains(q));
    }
    if (_userIdContains?.isNotEmpty == true) {
      final q = _userIdContains!.toLowerCase();
      it = it.where((t) => t.userId.toLowerCase().contains(q));
    }
    if (_blockIdContains?.isNotEmpty == true) {
      final q = _blockIdContains!.toLowerCase();
      it = it.where((t) => (t.blockId ?? '').toLowerCase().contains(q));
    }
    if (_cloudIdContains?.isNotEmpty == true) {
      final q = _cloudIdContains!.toLowerCase();
      it = it.where((t) => (t.cloudId ?? '').toLowerCase().contains(q));
    }
    if (_deviceIdContains?.isNotEmpty == true) {
      final q = _deviceIdContains!.toLowerCase();
      it = it.where((t) => t.deviceId.toLowerCase().contains(q));
    }
    if (_idContains?.isNotEmpty == true) {
      final q = _idContains!.toLowerCase();
      it = it.where((t) => t.id.toLowerCase().contains(q));
    }
    if (_execRange != null) {
      final range = _execRange!;
      it = it.where((t) => _isWithinRange(t.executionDate, range));
    }
    if (_dueRange != null) {
      final range = _dueRange!;
      it = it.where((t) => _isWithinRange(t.dueDate, range));
    }
    if (_startActualRange != null) {
      final range = _startActualRange!;
      it = it.where((t) => _isWithinRange(_plannedStart(t), range));
    }
    if (_endActualRange != null) {
      final range = _endActualRange!;
      it = it.where((t) => _isWithinRange(_plannedEnd(t), range));
    }
    if (_createdRange != null) {
      final range = _createdRange!;
      it = it.where((t) => _isWithinRange(t.createdAt, range));
    }
    if (_updatedRange != null) {
      final range = _updatedRange!;
      it = it.where((t) => _isWithinRange(t.lastModified, range));
    }
    if (_lastSyncedRange != null) {
      final range = _lastSyncedRange!;
      it = it.where((t) => _isWithinRange(t.lastSynced, range));
    }
    if (_startClockFilter?.isActive == true) {
      final filter = _startClockFilter!;
      it = it.where((t) {
        final minutes = _timeOfDayToMinutes(t.startHour, t.startMinute);
        if (minutes == null) return false;
        if (filter.minMinutes != null && minutes < filter.minMinutes!) {
          return false;
        }
        if (filter.maxMinutes != null && minutes > filter.maxMinutes!) {
          return false;
        }
        return true;
      });
    }
    if (_estimatedDurationRange?.isActive == true) {
      final range = _estimatedDurationRange!;
      it = it.where((t) {
        final value = t.estimatedDuration.toDouble();
        if (range.min != null && value < range.min!) return false;
        if (range.max != null && value > range.max!) return false;
        return true;
      });
    }
    if (_versionRange?.isActive == true) {
      final range = _versionRange!;
      it = it.where((t) {
        final value = t.version.toDouble();
        if (range.min != null && value < range.min!) return false;
        if (range.max != null && value > range.max!) return false;
        return true;
      });
    }
    if (_completed != null) {
      it = it.where((t) => t.isCompleted == _completed);
    }
    if (_someday != null) {
      it = it.where((t) => t.isSomeday == _someday);
    }
    if (_isRunningFilter != null) {
      it = it.where((t) => t.isRunning == _isRunningFilter);
    }
    if (_isDeletedFilter != null) {
      it = it.where((t) => t.isDeleted == _isDeletedFilter);
    }
    if (_globalSearchQuery != null && _globalSearchQuery!.isNotEmpty) {
      final q = _globalSearchQuery!.toLowerCase();
      it = it.where((t) => _matchesGlobalSearch(t, q));
    }
    final list = it.toList();
    _sortTasks(list);
    return list;
  }

  bool _matchesGlobalSearch(InboxTask task, String query) {
    final tokens = <String>[
      task.title,
      task.projectId ?? '',
      task.subProjectId ?? '',
      task.memo ?? '',
      task.userId,
      task.blockId ?? '',
      task.cloudId ?? '',
      task.deviceId,
      task.id,
      task.estimatedDuration.toString(),
      if (task.dueDate != null) _date.format(task.dueDate!),
      _date.format(task.executionDate),
      if (_plannedStart(task) != null) _dateTime.format(_plannedStart(task)!),
      if (_plannedEnd(task) != null) _dateTime.format(_plannedEnd(task)!),
      _dateTime.format(task.createdAt),
      _dateTime.format(task.lastModified),
      if (task.lastSynced != null) _dateTime.format(task.lastSynced!),
      task.version.toString(),
      task.isCompleted ? '完了' : '未完了',
      task.isRunning ? '実行中' : '停止',
      task.isSomeday ? 'someday' : '',
      task.isDeleted ? '削除済み' : '有効',
      _formatTimeOfDay(task.startHour, task.startMinute),
    ];
    return tokens
        .where((token) => token.isNotEmpty)
        .any((token) => token.toLowerCase().contains(query));
  }

  void _sortTasks(List<InboxTask> tasks) {
    if (tasks.length <= 1) return;
    tasks.sort((a, b) {
      if (_isSortAscending) {
        return _compareByColumn(a, b);
      }
      return _compareByColumn(b, a);
    });
  }

  int _compareByColumn(InboxTask a, InboxTask b) {
    switch (_sortColumnIndex) {
      case 0:
        return _compareString(a.title, b.title);
      case 1:
        return _compareString(a.projectId, b.projectId);
      case 2:
        return _compareString(a.subProjectId, b.subProjectId);
      case 3:
        return _compareDate(a.dueDate, b.dueDate);
      case 4:
        return _compareDate(a.executionDate, b.executionDate);
      case 5:
        return _compareInt(
          _timeOfDayToMinutes(a.startHour, a.startMinute),
          _timeOfDayToMinutes(b.startHour, b.startMinute),
        );
      case 6:
        return _compareInt(a.estimatedDuration, b.estimatedDuration);
      case 7:
        return _compareString(a.memo, b.memo);
      case 8:
        return _compareDate(_plannedStart(a), _plannedStart(b));
      case 9:
        return _compareDate(_plannedEnd(a), _plannedEnd(b));
      case 10:
        return _compareBool(a.isCompleted, b.isCompleted);
      case 11:
        return _compareBool(a.isRunning, b.isRunning);
      case 12:
        return _compareBool(a.isSomeday, b.isSomeday);
      case 13:
        return _compareDate(a.createdAt, b.createdAt);
      case 14:
        return _compareDate(a.lastModified, b.lastModified);
      case 15:
        return _compareString(a.userId, b.userId);
      case 16:
        return _compareString(a.blockId, b.blockId);
      case 17:
        return _compareString(a.cloudId, b.cloudId);
      case 18:
        return _compareDate(a.lastSynced, b.lastSynced);
      case 19:
        return _compareBool(a.isDeleted, b.isDeleted);
      case 20:
        return _compareString(a.deviceId, b.deviceId);
      case 21:
        return _compareInt(a.version, b.version);
      case 22:
        return _compareString(a.id, b.id);
      default:
        return _compareDate(a.executionDate, b.executionDate);
    }
  }

  int _compareString(String? a, String? b) =>
      _compareComparable(a?.toLowerCase(), b?.toLowerCase());

  int _compareInt(num? a, num? b) => _compareComparable(a, b);

  int _compareDate(DateTime? a, DateTime? b) => _compareComparable(a, b);

  int _compareBool(bool a, bool b) => _compareInt(a ? 1 : 0, b ? 1 : 0);

  int _compareComparable(Comparable? a, Comparable? b) {
    if (identical(a, b)) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  DateTime? _plannedStart(InboxTask task) {
    if (task.startHour == null || task.startMinute == null) return null;
    final d = task.executionDate;
    return DateTime(d.year, d.month, d.day, task.startHour!, task.startMinute!);
  }

  DateTime? _plannedEnd(InboxTask task) {
    final start = _plannedStart(task);
    if (start == null) return null;
    return start.add(Duration(minutes: task.estimatedDuration));
  }

  int? _timeOfDayToMinutes(int? hour, int? minute) {
    if (hour == null) return null;
    return hour * 60 + (minute ?? 0);
  }

  String _formatTimeOfDay(int? hour, int? minute) {
    if (hour == null) return '-';
    final h = hour.toString().padLeft(2, '0');
    final m = (minute ?? 0).toString().padLeft(2, '0');
    return '$h:$m';
  }

  TimeOfDay? _minutesToTimeOfDay(int? minutes) {
    if (minutes == null) return null;
    final hour = minutes ~/ 60;
    final minute = minutes % 60;
    return TimeOfDay(hour: hour, minute: minute);
  }

  DateTime _startOfDay(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  DateTime _endOfDay(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day).add(const Duration(days: 1));

  bool _isWithinRange(DateTime? value, DateTimeRange range) {
    if (value == null) return false;
    final start = _startOfDay(range.start);
    final end = _endOfDay(range.end);
    return !value.isBefore(start) && !value.isAfter(end);
  }

  String _formatDateRangeLabel(DateTimeRange range) =>
      '${_date.format(range.start)}~${_date.format(range.end)}';

  String _formatNumberRangeLabel(_NumberRange range) {
    final min = range.min;
    final max = range.max;
    if (min != null && max != null) {
      return '${min.toInt()}~${max.toInt()}';
    }
    if (min != null) {
      return '>=${min.toInt()}';
    }
    if (max != null) {
      return '<=${max.toInt()}';
    }
    return '';
  }

  String _formatTimeRangeLabel(_TimeFilter filter) {
    final min = filter.minMinutes;
    final max = filter.maxMinutes;
    String format(int minutes) => _formatTimeOfDay(minutes ~/ 60, minutes % 60);
    if (min != null && max != null) {
      return '${format(min)}~${format(max)}';
    }
    if (min != null) {
      return '>=${format(min)}';
    }
    if (max != null) {
      return '<=${format(max)}';
    }
    return '';
  }

  void _handleSearchInput(String value) {
    final normalized = value.trim();
    setState(() {
      _globalSearchQuery = normalized.isEmpty ? null : normalized;
      _displayedTasks = _applyClientFilters(_remoteSource);
    });
  }

  List<Widget> _buildActiveFilterChips() {
    final chips = <Widget>[];

    void addTextChip(String label, String? value, VoidCallback onClear) {
      if (value?.isNotEmpty == true) {
        chips.add(_chip('$label: $value', onClear));
      }
    }

    void addDateChip(String label, DateTimeRange? range, VoidCallback onClear) {
      if (range != null) {
        chips.add(_chip('$label: ${_formatDateRangeLabel(range)}', onClear));
      }
    }

    void addNumberChip(String label, _NumberRange? range, VoidCallback onClear) {
      if (range?.isActive == true) {
        chips.add(_chip('$label: ${_formatNumberRangeLabel(range!)}', onClear));
      }
    }

    void addTimeChip(String label, _TimeFilter? filter, VoidCallback onClear) {
      if (filter?.isActive == true) {
        chips.add(_chip('$label: ${_formatTimeRangeLabel(filter!)}', onClear));
      }
    }

    void addBoolChip(String label, bool? value, VoidCallback onClear) {
      if (value != null) {
        chips.add(_chip('$label: ${value ? 'はい' : 'いいえ'}', onClear));
      }
    }

    addTextChip('タイトル', _titleContains, () {
      setState(() {
        _titleContains = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addTextChip('プロジェクトID', _projectIdContains, () {
      setState(() {
        _projectIdContains = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addTextChip('サブプロジェクトID', _subProjectIdContains, () {
      setState(() {
        _subProjectIdContains = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addTextChip('メモ', _memoContains, () {
      setState(() {
        _memoContains = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addTextChip('ユーザーID', _userIdContains, () {
      setState(() {
        _userIdContains = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addTextChip('ブロックID', _blockIdContains, () {
      setState(() {
        _blockIdContains = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addTextChip('cloudId', _cloudIdContains, () {
      setState(() {
        _cloudIdContains = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addTextChip('deviceId', _deviceIdContains, () {
      setState(() {
        _deviceIdContains = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addTextChip('ID', _idContains, () {
      setState(() {
        _idContains = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addDateChip('実行日', _execRange, () {
      setState(() => _execRange = null);
      _refreshRemote();
    });
    addDateChip('期日', _dueRange, () {
      setState(() {
        _dueRange = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addDateChip('開始実績', _startActualRange, () {
      setState(() {
        _startActualRange = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addDateChip('終了実績', _endActualRange, () {
      setState(() {
        _endActualRange = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addDateChip('作成', _createdRange, () {
      setState(() {
        _createdRange = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addDateChip('更新', _updatedRange, () {
      setState(() {
        _updatedRange = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addDateChip('lastSynced', _lastSyncedRange, () {
      setState(() {
        _lastSyncedRange = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addNumberChip('見積(分)', _estimatedDurationRange, () {
      setState(() {
        _estimatedDurationRange = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addNumberChip('version', _versionRange, () {
      setState(() {
        _versionRange = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addTimeChip('開始時刻', _startClockFilter, () {
      setState(() {
        _startClockFilter = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addBoolChip('完了', _completed, () {
      setState(() => _completed = null);
      _refreshRemote();
    });
    addBoolChip('Someday', _someday, () {
      setState(() => _someday = null);
      _refreshRemote();
    });
    addBoolChip('実行中', _isRunningFilter, () {
      setState(() {
        _isRunningFilter = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    addBoolChip('削除', _isDeletedFilter, () {
      setState(() {
        _isDeletedFilter = null;
        _displayedTasks = _applyClientFilters(_remoteSource);
      });
    });
    if (_globalSearchQuery?.isNotEmpty == true) {
      chips.add(_chip('検索: ${_globalSearchQuery!}', _clearGlobalSearch));
    }
    return chips;
  }

  Future<void> _openNumberFilterDialog({
    required String label,
    required _NumberRange? currentValue,
    required ValueChanged<_NumberRange?> onChanged,
  }) async {
    final minController = TextEditingController(
      text: currentValue?.min?.toString() ?? '',
    );
    final maxController = TextEditingController(
      text: currentValue?.max?.toString() ?? '',
    );
    final res = await showImeSafeDialog<_NumberRange?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$label でフィルタ'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: minController,
              decoration: const InputDecoration(
                labelText: '最小値',
                hintText: '例: 30',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: maxController,
              decoration: const InputDecoration(
                labelText: '最大値',
                hintText: '例: 120',
              ),
              keyboardType: TextInputType.number,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, const _NumberRange()),
            child: const Text('クリア'),
          ),
          ElevatedButton(
            onPressed: () {
              final min = double.tryParse(minController.text.trim());
              final max = double.tryParse(maxController.text.trim());
              Navigator.pop(ctx, _NumberRange(min: min, max: max));
            },
            child: const Text('適用'),
          ),
        ],
      ),
    );
    if (res == null) {
      return;
    }
    setState(() {
      onChanged(res.isActive ? res : null);
      _displayedTasks = _applyClientFilters(_remoteSource);
    });
  }

  Future<void> _openTimeFilterDialog({
    required String label,
    required _TimeFilter? currentValue,
    required ValueChanged<_TimeFilter?> onChanged,
  }) async {
    TimeOfDay? start = currentValue?.minMinutes != null
        ? _minutesToTimeOfDay(currentValue!.minMinutes!)
        : null;
    TimeOfDay? end = currentValue?.maxMinutes != null
        ? _minutesToTimeOfDay(currentValue!.maxMinutes!)
        : null;

    final res = await showDialog<_TimeFilter?>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) => AlertDialog(
            title: Text('$label でフィルタ'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TimeRangePickerRow(
                  label: '開始',
                  value: start,
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: ctx,
                      initialTime: start ?? const TimeOfDay(hour: 9, minute: 0),
                    );
                    if (picked != null) {
                      setStateDialog(() => start = picked);
                    }
                  },
                ),
                const SizedBox(height: 12),
                _TimeRangePickerRow(
                  label: '終了',
                  value: end,
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: ctx,
                      initialTime: end ?? const TimeOfDay(hour: 18, minute: 0),
                    );
                    if (picked != null) {
                      setStateDialog(() => end = picked);
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('キャンセル'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, const _TimeFilter()),
                child: const Text('クリア'),
              ),
              ElevatedButton(
                onPressed: () {
                  final min = start == null ? null : start!.hour * 60 + start!.minute;
                  final max = end == null ? null : end!.hour * 60 + end!.minute;
                  Navigator.pop(ctx, _TimeFilter(minMinutes: min, maxMinutes: max));
                },
                child: const Text('適用'),
              ),
            ],
          ),
        );
      },
    );
    if (res == null) return;
    setState(() {
      onChanged(res.isActive ? res : null);
      _displayedTasks = _applyClientFilters(_remoteSource);
    });
  }


  void _clearGlobalSearch() {
    if (_searchController.text.isEmpty) {
      _handleSearchInput('');
      return;
    }
    _searchController.clear();
    _handleSearchInput('');
  }

  void _focusSearchField() {
    if (!_searchFocusNode.hasFocus) {
      _searchFocusNode.requestFocus();
    }
    _searchController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchController.text.length,
    );
  }

  void _handleSort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _isSortAscending = ascending;
      _sortTasks(_displayedTasks);
    });
  }

  Future<void> _refreshRemote({bool forceHeavySync = false}) async {
    final token = ++_requestToken;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (forceHeavySync) {
        await _ensureInboxFreshness(forceHeavy: true);
      } else {
        await _ensureInboxFreshness(forceHeavy: false);
      }
      final svc = InboxTaskSyncService();
      DateTime? execStart;
      DateTime? execEnd;
      if (_execRange != null) {
        execStart = DateTime(
          _execRange!.start.year,
          _execRange!.start.month,
          _execRange!.start.day,
        );
        execEnd = DateTime(
          _execRange!.end.year,
          _execRange!.end.month,
          _execRange!.end.day,
          23,
          59,
          59,
          999,
        );
      }
      final tasks = await svc.fetchTasksForDb(
        executionStart: execStart,
        executionEnd: execEnd,
        isCompleted: _completed,
        isSomeday: _someday,
        limit: _fetchLimit,
      );

      if (!mounted || token != _requestToken) {
        return;
      }

      setState(() {
        _remoteSource = tasks;
        _displayedTasks = _applyClientFilters(tasks);
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (e) {
      if (!mounted || token != _requestToken) {
        return;
      }
      setState(() {
        _remoteSource = [];
        _displayedTasks = [];
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _ensureInboxFreshness({required bool forceHeavy}) async {
    try {
      setState(() => _syncing = true);
      if (forceHeavy) {
        await SyncManager.syncDataFor(
          {DataSyncTarget.inboxTasks},
          forceHeavy: true,
        );
        _lastSyncedAt = DateTime.now();
      } else {
        final results = await SyncManager.syncIfStale(
          {DataSyncTarget.inboxTasks},
        );
        final success = results.values
            .where((result) => result != null)
            .any((result) => result!.success);
        if (success) {
          _lastSyncedAt = DateTime.now();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('差分同期に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
      }
    }
  }

  String _syncStatusLabel() {
    if (_syncing) return '同期中...';
    if (_lastSyncedAt == null) {
      return 'ローカルキャッシュを表示中';
    }
    final diff = DateTime.now().difference(_lastSyncedAt!);
    if (diff.inMinutes < 1) return '直前に同期済み';
    return '最終同期: ${_dateTime.format(_lastSyncedAt!)}';
  }

  @override
  Widget build(BuildContext context) {
    final isPc = MediaQuery.of(context).size.width >= 800;

    if (!isPc) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.desktop_windows, size: 48),
              SizedBox(height: 12),
              Text('この画面はPC版のみ対応しています'),
            ],
          ),
        ),
      );
    }
    final table = _buildTable(context, _displayedTasks);
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyF):
            const _FocusSearchIntent(),
        LogicalKeySet(LogicalKeyboardKey.controlRight, LogicalKeyboardKey.keyF):
            const _FocusSearchIntent(),
        LogicalKeySet(LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyF):
            const _FocusSearchIntent(),
        LogicalKeySet(LogicalKeyboardKey.metaRight, LogicalKeyboardKey.keyF):
            const _FocusSearchIntent(),
      },
      child: Actions(
        actions: {
          _FocusSearchIntent: CallbackAction<_FocusSearchIntent>(
            onInvoke: (intent) {
              _focusSearchField();
              return null;
            },
          ),
        },
        child: table,
      ),
    );
  }

  Widget _buildTable(BuildContext context, List<InboxTask> tasks) {
    final columns = <DataColumn>[];
    void addColumn(Widget label, {bool numeric = false}) {
      columns.add(
        DataColumn(
          label: label,
          numeric: numeric,
          onSort: (columnIndex, ascending) =>
              _handleSort(columnIndex, ascending),
        ),
      );
    }

    addColumn(
      _headerWithFilter(
        'タイトル',
        () => _openTextFilterDialog(
          label: 'タイトル',
          currentValue: _titleContains,
          onChanged: (v) => _titleContains = v,
        ),
        _titleContains?.isNotEmpty == true,
      ),
    );
    addColumn(
      _headerWithFilter(
        'プロジェクトID',
        () => _openTextFilterDialog(
          label: 'プロジェクトID',
          currentValue: _projectIdContains,
          onChanged: (v) => _projectIdContains = v,
        ),
        _projectIdContains?.isNotEmpty == true,
      ),
    );
    addColumn(
      _headerWithFilter(
        'サブプロジェクトID',
        () => _openTextFilterDialog(
          label: 'サブプロジェクトID',
          currentValue: _subProjectIdContains,
          onChanged: (v) => _subProjectIdContains = v,
        ),
        _subProjectIdContains?.isNotEmpty == true,
      ),
    );
    addColumn(
      _headerWithFilter('期日', _openDueDateFilter, _dueRange != null),
    );
    addColumn(
      _headerWithFilter('実行日', _openExecDateFilter, _execRange != null),
    );
    addColumn(
      _headerWithFilter(
        '開始時刻',
        () => _openTimeFilterDialog(
          label: '開始時刻',
          currentValue: _startClockFilter,
          onChanged: (v) => _startClockFilter = v,
        ),
        _startClockFilter?.isActive == true,
      ),
    );
    addColumn(
      _headerWithFilter(
        '見積(分)',
        () => _openNumberFilterDialog(
          label: '見積(分)',
          currentValue: _estimatedDurationRange,
          onChanged: (v) => _estimatedDurationRange = v,
        ),
        _estimatedDurationRange?.isActive == true,
      ),
      numeric: true,
    );
    addColumn(
      _headerWithFilter(
        'メモ',
        () => _openTextFilterDialog(
          label: 'メモ',
          currentValue: _memoContains,
          onChanged: (v) => _memoContains = v,
        ),
        _memoContains?.isNotEmpty == true,
      ),
    );
    addColumn(
      _headerWithFilter(
        '開始実績',
        () => _openDateFilterDialog(
          label: '開始実績',
          currentValue: _startActualRange,
          onChanged: (v) => _startActualRange = v,
        ),
        _startActualRange != null,
      ),
    );
    addColumn(
      _headerWithFilter(
        '終了実績',
        () => _openDateFilterDialog(
          label: '終了実績',
          currentValue: _endActualRange,
          onChanged: (v) => _endActualRange = v,
        ),
        _endActualRange != null,
      ),
    );
    addColumn(
      _headerWithFilter(
        '完了',
        () => _openTriStateFilter(
          title: '完了',
          currentValue: _completed,
          onChanged: (v) => _completed = v,
          refreshRemote: true,
        ),
        _completed != null,
      ),
    );
    addColumn(
      _headerWithFilter(
        '実行中',
        () => _openTriStateFilter(
          title: '実行中',
          currentValue: _isRunningFilter,
          onChanged: (v) => _isRunningFilter = v,
        ),
        _isRunningFilter != null,
      ),
    );
    addColumn(
      _headerWithFilter(
        'Someday',
        () => _openTriStateFilter(
          title: 'Someday',
          currentValue: _someday,
          onChanged: (v) => _someday = v,
          refreshRemote: true,
        ),
        _someday != null,
      ),
    );
    addColumn(
      _headerWithFilter(
        '作成',
        () => _openDateFilterDialog(
          label: '作成',
          currentValue: _createdRange,
          onChanged: (v) => _createdRange = v,
        ),
        _createdRange != null,
      ),
    );
    addColumn(
      _headerWithFilter(
        '更新',
        () => _openDateFilterDialog(
          label: '更新',
          currentValue: _updatedRange,
          onChanged: (v) => _updatedRange = v,
        ),
        _updatedRange != null,
      ),
    );
    addColumn(
      _headerWithFilter(
        'ユーザーID',
        () => _openTextFilterDialog(
          label: 'ユーザーID',
          currentValue: _userIdContains,
          onChanged: (v) => _userIdContains = v,
        ),
        _userIdContains?.isNotEmpty == true,
      ),
    );
    addColumn(
      _headerWithFilter(
        'ブロックID',
        () => _openTextFilterDialog(
          label: 'ブロックID',
          currentValue: _blockIdContains,
          onChanged: (v) => _blockIdContains = v,
        ),
        _blockIdContains?.isNotEmpty == true,
      ),
    );
    addColumn(
      _headerWithFilter(
        'cloudId',
        () => _openTextFilterDialog(
          label: 'cloudId',
          currentValue: _cloudIdContains,
          onChanged: (v) => _cloudIdContains = v,
        ),
        _cloudIdContains?.isNotEmpty == true,
      ),
    );
    addColumn(
      _headerWithFilter(
        'lastSynced',
        () => _openDateFilterDialog(
          label: 'lastSynced',
          currentValue: _lastSyncedRange,
          onChanged: (v) => _lastSyncedRange = v,
        ),
        _lastSyncedRange != null,
      ),
    );
    addColumn(
      _headerWithFilter(
        '削除',
        () => _openTriStateFilter(
          title: '削除',
          currentValue: _isDeletedFilter,
          onChanged: (v) => _isDeletedFilter = v,
        ),
        _isDeletedFilter != null,
      ),
    );
    addColumn(
      _headerWithFilter(
        'deviceId',
        () => _openTextFilterDialog(
          label: 'deviceId',
          currentValue: _deviceIdContains,
          onChanged: (v) => _deviceIdContains = v,
        ),
        _deviceIdContains?.isNotEmpty == true,
      ),
    );
    addColumn(
      _headerWithFilter(
        'version',
        () => _openNumberFilterDialog(
          label: 'version',
          currentValue: _versionRange,
          onChanged: (v) => _versionRange = v,
        ),
        _versionRange?.isActive == true,
      ),
      numeric: true,
    );
    addColumn(
      _headerWithFilter(
        'ID',
        () => _openTextFilterDialog(
          label: 'ID',
          currentValue: _idContains,
          onChanged: (v) => _idContains = v,
        ),
        _idContains?.isNotEmpty == true,
      ),
    );

    final rows = tasks.map((t) {
      return DataRow(
        cells: [
          DataCell(SelectableText(t.title)),
          DataCell(Text(t.projectId ?? '-')),
          DataCell(Text(t.subProjectId ?? '-')),
          DataCell(Text(t.dueDate != null ? _date.format(t.dueDate!) : '-')),
          DataCell(Text(_date.format(t.executionDate))),
          DataCell(Text(_formatTimeOfDay(t.startHour, t.startMinute))),
          DataCell(Text('${t.estimatedDuration}')),
          DataCell(Text(t.memo ?? '-')),
          DataCell(
            Text(_plannedStart(t) != null ? _dateTime.format(_plannedStart(t)!) : '-'),
          ),
          DataCell(
            Text(_plannedEnd(t) != null ? _dateTime.format(_plannedEnd(t)!) : '-'),
          ),
          DataCell(
            Icon(
              t.isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
              color: t.isCompleted
                  ? Theme.of(context).colorScheme.secondary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          DataCell(
            Icon(
              t.isRunning ? Icons.play_circle : Icons.pause_circle_filled,
              color: t.isRunning
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          DataCell(
            Icon(
              t.isSomeday ? Icons.flag : Icons.outlined_flag,
              color: t.isSomeday
                  ? Theme.of(context).colorScheme.tertiary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          DataCell(Text(_dateTime.format(t.createdAt))),
          DataCell(Text(_dateTime.format(t.lastModified))),
          DataCell(Text(t.userId)),
          DataCell(Text(t.blockId ?? '-')),
          DataCell(Text(t.cloudId ?? '-')),
          DataCell(
            Text(t.lastSynced != null ? _dateTime.format(t.lastSynced!) : '-'),
          ),
          DataCell(
            Icon(
              t.isDeleted ? Icons.delete_forever : Icons.remove_circle_outline,
              color: t.isDeleted
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          DataCell(Text(t.deviceId)),
          DataCell(Text('${t.version}')),
          DataCell(SelectableText(t.id)),
        ],
      );
    }).toList();

    final headingStyle = Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.bold);

    final dataTable = DataTable(
      showCheckboxColumn: false,
      headingTextStyle: headingStyle,
      sortColumnIndex: _sortColumnIndex,
      sortAscending: _isSortAscending,
      columns: columns,
      rows: rows,
      columnSpacing: 16,
      headingRowHeight: 44,
      dataRowMinHeight: 40,
      dataRowMaxHeight: 52,
    );

    final sharedScrollBehavior = ScrollConfiguration.of(context).copyWith(
      dragDevices: const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              const Icon(Icons.cloud_queue, size: 18),
              const SizedBox(width: 8),
            Text('ローカル取得: ${tasks.length}件 / 上限 $_fetchLimit'),
            const SizedBox(width: 12),
            Text(
              _syncStatusLabel(),
              style: Theme.of(context).textTheme.bodySmall,
            ),
              if (_isLoading) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
              const Spacer(),
              SizedBox(
                width: 260,
                child: Tooltip(
                  message: 'Ctrl/Cmd + F でフォーカス',
                  waitDuration: const Duration(milliseconds: 400),
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    onChanged: _handleSearchInput,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: '全文検索',
                      hintText: 'Ctrl/Cmd + F',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: (_globalSearchQuery?.isNotEmpty ?? false)
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              tooltip: '検索をクリア',
                              onPressed: _clearGlobalSearch,
                            )
                          : null,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: _fetchLimit,
                  items: _limitOptions
                      .map(
                        (value) => DropdownMenuItem<int>(
                          value: value,
                          child: Text('$value件'),
                        ),
                      )
                      .toList(),
                  onChanged: _isLoading
                      ? null
                      : (value) {
                          if (value != null && value != _fetchLimit) {
                            setState(() => _fetchLimit = value);
                            _refreshRemote();
                          }
                        },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: '差分同期を実行',
                onPressed: _isLoading
                    ? null
                    : () => _refreshRemote(forceHeavySync: true),
              ),
            ],
          ),
        ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _errorMessage!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              const Icon(Icons.filter_alt, size: 18),
              const SizedBox(width: 8),
              const Text('デフォルト: 過去3ヶ月以内のデータを表示'),
              const Spacer(),
              TextButton.icon(
                onPressed: _clearAllFilters,
                icon: const Icon(Icons.clear),
                label: const Text('フィルタをクリア'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: _buildActiveFilterChips(),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final table = Scrollbar(
                controller: _hController,
                thumbVisibility: true,
                notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
                child: ScrollConfiguration(
                  behavior: sharedScrollBehavior,
                  child: SingleChildScrollView(
                    controller: _hController,
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 2200),
                      child: Scrollbar(
                        controller: _vController,
                        thumbVisibility: true,
                        child: ScrollConfiguration(
                          behavior: sharedScrollBehavior,
                          child: SingleChildScrollView(
                            controller: _vController,
                            child: dataTable,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );

              return Stack(
                children: [
                  Positioned.fill(child: table),
                  if (_isLoading)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          color: Theme.of(
                            context,
                          ).colorScheme.surface.withOpacity(0.04),
                          child: const Center(
                            child: CircularProgressIndicator(),
                          ),
                        ),
                      ),
                    ),
                  if (!_isLoading && tasks.isEmpty)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Center(
                          child: Text(
                            '一致するデータがありません',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: Theme.of(context).hintColor),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
