import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/actual_task.dart';
import '../services/actual_task_service.dart';
import '../utils/ime_safe_dialog.dart';

class ActualDbScreen extends StatefulWidget {
  const ActualDbScreen({super.key});

  @override
  State<ActualDbScreen> createState() => _ActualDbScreenState();
}

class _ActualDbScreenState extends State<ActualDbScreen> {
  final DateFormat _date = DateFormat('yyyy/MM/dd');
  final DateFormat _dateTime = DateFormat('yyyy/MM/dd HH:mm');
  late Future<void> _initFuture;
  final ScrollController _hController = ScrollController();
  final ScrollController _vController = ScrollController();

  String? _titleContains;
  String? _projectIdContains;
  String? _blockIdContains;
  DateTimeRange? _startRange;
  ActualTaskStatus? _status;

  @override
  void initState() {
    super.initState();
    _setDefaultRange();
    _initFuture = ActualTaskService.initialize();
  }

  void _setDefaultRange() {
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day);
    final start = end.subtract(const Duration(days: 29));
    _startRange = DateTimeRange(start: start, end: end);
  }

  @override
  void dispose() {
    try {
      _hController.dispose();
      _vController.dispose();
    } catch (_) {}
    super.dispose();
  }

  Widget _headerWithFilter(String label, VoidCallback onTap, bool active) {
    return InkWell(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 4),
          Icon(
            Icons.filter_list,
            size: 16,
            color: active
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, VoidCallback onDeleted) {
    return Chip(
      label: Text(text, style: const TextStyle(fontSize: 12)),
      deleteIcon: const Icon(Icons.close, size: 16),
      onDeleted: onDeleted,
    );
  }

  void _clearAllFilters() {
    setState(() {
      _titleContains = null;
      _projectIdContains = null;
      _blockIdContains = null;
      _status = null;
      _setDefaultRange();
    });
  }

  Future<void> _openTitleFilter() async {
    final controller = TextEditingController(text: _titleContains ?? '');
    final res = await showImeSafeDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('タイトルでフィルタ'),
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
    if (res != null) {
      setState(() => _titleContains = res.isEmpty ? null : res);
    }
  }

  Future<void> _openProjectFilter() async {
    final controller = TextEditingController(text: _projectIdContains ?? '');
    final res = await showImeSafeDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('プロジェクトIDでフィルタ'),
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
    if (res != null) {
      setState(() => _projectIdContains = res.isEmpty ? null : res);
    }
  }

  Future<void> _openBlockFilter() async {
    final controller = TextEditingController(text: _blockIdContains ?? '');
    final res = await showImeSafeDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ブロックIDでフィルタ'),
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
    if (res != null) {
      setState(() => _blockIdContains = res.isEmpty ? null : res);
    }
  }

  Future<void> _openStartRangeFilter() async {
    final initial = _startRange ??
        DateTimeRange(
          start: DateTime.now().subtract(const Duration(days: 6)),
          end: DateTime.now(),
        );
    final res = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: initial,
    );
    if (res != null) {
      setState(() => _startRange = res);
    }
  }

  Future<void> _openStatusFilter() async {
    final res = await showDialog<ActualTaskStatus?>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('ステータスでフィルタ'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<ActualTaskStatus?>(
                title: const Text('すべて'),
                value: null,
                groupValue: _status,
                onChanged: (v) => Navigator.pop(ctx, v),
              ),
              ...ActualTaskStatus.values.map((status) {
                return RadioListTile<ActualTaskStatus?>(
                  title: Text(_statusLabel(status)),
                  value: status,
                  groupValue: _status,
                  onChanged: (v) => Navigator.pop(ctx, v),
                );
              }),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, _status),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
    if (res != null) {
      setState(() => _status = res);
    }
  }

  List<ActualTask> _loadTasks() {
    final all = ActualTaskService.getAllActualTasks();
    Iterable<ActualTask> it = all;

    if (_titleContains != null && _titleContains!.isNotEmpty) {
      final query = _titleContains!.toLowerCase();
      it = it.where((task) => task.title.toLowerCase().contains(query));
    }
    if (_projectIdContains != null && _projectIdContains!.isNotEmpty) {
      final query = _projectIdContains!.toLowerCase();
      it = it.where(
        (task) => (task.projectId ?? '').toLowerCase().contains(query),
      );
    }
    if (_blockIdContains != null && _blockIdContains!.isNotEmpty) {
      final query = _blockIdContains!.toLowerCase();
      it = it.where(
        (task) => (task.blockId ?? '').toLowerCase().contains(query),
      );
    }
    if (_status != null) {
      it = it.where((task) => task.status == _status);
    }
    if (_startRange != null) {
      final start = DateTime(
        _startRange!.start.year,
        _startRange!.start.month,
        _startRange!.start.day,
      );
      final end = DateTime(
        _startRange!.end.year,
        _startRange!.end.month,
        _startRange!.end.day,
        23,
        59,
        59,
        999,
      );
      it = it.where((task) {
        final st = task.startTime.toLocal();
        return !st.isBefore(start) && !st.isAfter(end);
      });
    }

    final list = it.toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    return list;
  }

  String _statusLabel(ActualTaskStatus status) {
    switch (status) {
      case ActualTaskStatus.running:
        return '実行中';
      case ActualTaskStatus.completed:
        return '完了';
      case ActualTaskStatus.paused:
        return '一時停止';
    }
  }

  IconData _statusIcon(ActualTaskStatus status) {
    switch (status) {
      case ActualTaskStatus.running:
        return Icons.play_circle_fill;
      case ActualTaskStatus.completed:
        return Icons.check_circle;
      case ActualTaskStatus.paused:
        return Icons.pause_circle_filled;
    }
  }

  Color _statusColor(ActualTaskStatus status, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case ActualTaskStatus.running:
        return scheme.primary;
      case ActualTaskStatus.completed:
        return scheme.secondary;
      case ActualTaskStatus.paused:
        return scheme.tertiary;
    }
  }

  Widget _buildTable(BuildContext context, List<ActualTask> tasks) {
    final columns = <DataColumn>[
      DataColumn(
        label: _headerWithFilter(
          'タイトル',
          _openTitleFilter,
          _titleContains?.isNotEmpty == true,
        ),
      ),
      DataColumn(
        label: _headerWithFilter('ステータス', _openStatusFilter, _status != null),
      ),
      DataColumn(
        label: _headerWithFilter(
          'プロジェクトID',
          _openProjectFilter,
          _projectIdContains?.isNotEmpty == true,
        ),
      ),
      const DataColumn(label: Text('サブプロジェクトID')),
      DataColumn(
        label: _headerWithFilter(
          '開始',
          _openStartRangeFilter,
          _startRange != null,
        ),
      ),
      const DataColumn(label: Text('終了')),
      const DataColumn(label: Text('実績時間(分)')),
      DataColumn(
        label: _headerWithFilter(
          'ブロックID',
          _openBlockFilter,
          _blockIdContains?.isNotEmpty == true,
        ),
      ),
      const DataColumn(label: Text('ブロック名')),
      const DataColumn(label: Text('モードID')),
      const DataColumn(label: Text('場所')),
      const DataColumn(label: Text('メモ')),
      const DataColumn(label: Text('作成')),
      const DataColumn(label: Text('更新')),
      const DataColumn(label: Text('cloudId')),
      const DataColumn(label: Text('lastSynced')),
      const DataColumn(label: Text('deviceId')),
      const DataColumn(label: Text('version')),
      const DataColumn(label: Text('ID')),
    ];

    final rows = tasks.map((task) {
      final duration = task.durationInMinutes;
      return DataRow(
        cells: [
          DataCell(SelectableText(task.title)),
          DataCell(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _statusIcon(task.status),
                  size: 16,
                  color: _statusColor(task.status, context),
                ),
                const SizedBox(width: 4),
                Text(_statusLabel(task.status)),
              ],
            ),
          ),
          DataCell(Text(task.projectId ?? '-')),
          DataCell(Text(task.subProjectId ?? '-')),
          DataCell(Text(_dateTime.format(task.startTime.toLocal()))),
          DataCell(
            Text(
              task.endTime != null
                  ? _dateTime.format(task.endTime!.toLocal())
                  : '-',
            ),
          ),
          DataCell(Text('$duration')),
          DataCell(SelectableText(task.blockId ?? '-')),
          DataCell(Text(task.blockName ?? '-')),
          DataCell(Text(task.modeId ?? '-')),
          DataCell(Text(task.location ?? '-')),
          DataCell(Text(task.memo ?? '-')),
          DataCell(Text(_dateTime.format(task.createdAt.toLocal()))),
          DataCell(Text(_dateTime.format(task.lastModified.toLocal()))),
          DataCell(Text(task.cloudId ?? '-')),
          DataCell(
            Text(
              task.lastSynced != null
                  ? _dateTime.format(task.lastSynced!.toLocal())
                  : '-',
            ),
          ),
          DataCell(Text(task.deviceId)),
          DataCell(Text('${task.version}')),
          DataCell(SelectableText(task.id)),
        ],
      );
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Icon(Icons.filter_alt, size: 18),
              const SizedBox(width: 8),
              const Text('デフォルト: 過去30日以内のデータを表示'),
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
            children: [
              if (_titleContains?.isNotEmpty == true)
                _chip(
                  'タイトル: ${_titleContains!}',
                  () => setState(() => _titleContains = null),
                ),
              if (_projectIdContains?.isNotEmpty == true)
                _chip(
                  'PJ: ${_projectIdContains!}',
                  () => setState(() => _projectIdContains = null),
                ),
              if (_blockIdContains?.isNotEmpty == true)
                _chip(
                  'ブロック: ${_blockIdContains!}',
                  () => setState(() => _blockIdContains = null),
                ),
              if (_startRange != null)
                _chip(
                  '開始: ${_date.format(_startRange!.start)}~${_date.format(_startRange!.end)}',
                  () => setState(() => _startRange = null),
                ),
              if (_status != null)
                _chip(
                  'ステータス: ${_statusLabel(_status!)}',
                  () => setState(() => _status = null),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Scrollbar(
            controller: _hController,
            thumbVisibility: true,
            notificationPredicate: (notification) =>
                notification.metrics.axis == Axis.horizontal,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: const {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.trackpad,
                },
              ),
              child: SingleChildScrollView(
                controller: _hController,
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 2200),
                  child: Scrollbar(
                    controller: _vController,
                    thumbVisibility: true,
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(
                        dragDevices: const {
                          PointerDeviceKind.touch,
                          PointerDeviceKind.mouse,
                          PointerDeviceKind.trackpad,
                        },
                      ),
                      child: SingleChildScrollView(
                        controller: _vController,
                        child: DataTable(
                          headingTextStyle: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                          columns: columns,
                          rows: rows,
                          dataRowMinHeight: 40,
                          dataRowMaxHeight: 56,
                          columnSpacing: 16,
                          headingRowHeight: 44,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 800;

    if (!isWide) {
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

    return FutureBuilder<void>(
      future: _initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('ローカルDBの読み込みに失敗しました\n${snapshot.error}'),
            ),
          );
        }
        return StreamBuilder(
          stream: ActualTaskService.actualTaskBox.watch(),
          builder: (context, _) {
            final tasks = _loadTasks();
            return _buildTable(context, tasks);
          },
        );
      },
    );
  }
}
