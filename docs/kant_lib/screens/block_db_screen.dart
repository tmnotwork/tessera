import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:intl/intl.dart';

import '../models/block.dart';
import '../services/block_service.dart';
import '../utils/ime_safe_dialog.dart';

class BlockDbScreen extends StatefulWidget {
  const BlockDbScreen({super.key});

  @override
  State<BlockDbScreen> createState() => _BlockDbScreenState();
}

class _BlockDbScreenState extends State<BlockDbScreen> {
  final DateFormat _date = DateFormat('yyyy/MM/dd');
  final DateFormat _dateTime = DateFormat('yyyy/MM/dd HH:mm');
  late Future<void> _initFuture;
  final ScrollController _hController = ScrollController();
  final ScrollController _vController = ScrollController();

  String? _titleContains;
  String? _projectIdContains;
  DateTimeRange? _executionRange;
  bool? _isCompletedFilter;

  @override
  void initState() {
    super.initState();
    _setDefaultRange();
    _initFuture = BlockService.initialize();
  }

  void _setDefaultRange() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month - 2, 1); // 約3ヶ月前
    final end = DateTime(now.year, now.month + 1, 0); // 翌月末
    _executionRange = DateTimeRange(start: start, end: end);
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
      _isCompletedFilter = null;
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

  Future<void> _openExecutionRangeFilter() async {
    final initial = _executionRange ??
        DateTimeRange(
          start: DateTime.now().subtract(const Duration(days: 90)),
          end: DateTime.now().add(const Duration(days: 30)),
        );
    final res = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: initial,
    );
    if (res != null) {
      setState(() => _executionRange = res);
    }
  }

  Future<void> _openCompletedFilter() async {
    final res = await showDialog<bool?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('完了でフィルタ'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<bool?>(
              title: const Text('すべて'),
              value: null,
              groupValue: _isCompletedFilter,
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
            RadioListTile<bool?>(
              title: const Text('未完了のみ'),
              value: false,
              groupValue: _isCompletedFilter,
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
            RadioListTile<bool?>(
              title: const Text('完了のみ'),
              value: true,
              groupValue: _isCompletedFilter,
              onChanged: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _isCompletedFilter),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
    if (res != null) {
      setState(() => _isCompletedFilter = res);
    }
  }

  List<Block> _loadBlocks() {
    List<Block> all = BlockService.getAllBlocks();
    all = all.where((b) => !b.isDeleted).toList();

    if (_titleContains != null && _titleContains!.isNotEmpty) {
      final query = _titleContains!.toLowerCase();
      all = all.where((b) => b.title.toLowerCase().contains(query)).toList();
    }
    if (_projectIdContains != null && _projectIdContains!.isNotEmpty) {
      final query = _projectIdContains!.toLowerCase();
      all = all
          .where((b) => (b.projectId ?? '').toLowerCase().contains(query))
          .toList();
    }
    if (_isCompletedFilter != null) {
      all = all.where((b) => b.isCompleted == _isCompletedFilter).toList();
    }
    if (_executionRange != null) {
      final start = DateTime(
        _executionRange!.start.year,
        _executionRange!.start.month,
        _executionRange!.start.day,
      );
      final end = DateTime(
        _executionRange!.end.year,
        _executionRange!.end.month,
        _executionRange!.end.day,
        23,
        59,
        59,
      );
      all = all.where((b) {
        final d = b.executionDate;
        final day = DateTime(d.year, d.month, d.day);
        return !day.isBefore(start) && !day.isAfter(end);
      }).toList();
    }

    all.sort((a, b) {
      final c = a.executionDate.compareTo(b.executionDate);
      if (c != 0) return c;
      final ah = a.startHour * 60 + a.startMinute;
      final bh = b.startHour * 60 + b.startMinute;
      return ah.compareTo(bh);
    });
    return all;
  }

  Widget _buildTable(BuildContext context, List<Block> blocks) {
    final columns = <DataColumn>[
      DataColumn(
        label: _headerWithFilter(
          'タイトル',
          _openTitleFilter,
          _titleContains?.isNotEmpty == true,
        ),
      ),
      DataColumn(
        label: _headerWithFilter(
          '実行日',
          _openExecutionRangeFilter,
          _executionRange != null,
        ),
      ),
      const DataColumn(label: Text('開始')),
      const DataColumn(label: Text('予定(分)')),
      DataColumn(
        label: _headerWithFilter(
          'プロジェクトID',
          _openProjectFilter,
          _projectIdContains?.isNotEmpty == true,
        ),
      ),
      const DataColumn(label: Text('サブプロジェクト')),
      DataColumn(
        label: _headerWithFilter('完了', _openCompletedFilter, _isCompletedFilter != null),
      ),
      const DataColumn(label: Text('イベント')),
      const DataColumn(label: Text('作成')),
      const DataColumn(label: Text('更新')),
      const DataColumn(label: Text('cloudId')),
      const DataColumn(label: Text('ID')),
    ];

    final rows = blocks.map((b) {
      return DataRow(
        cells: [
          DataCell(SelectableText(b.title)),
          DataCell(Text(_date.format(b.executionDate))),
          DataCell(Text('${b.startHour.toString().padLeft(2, '0')}:${b.startMinute.toString().padLeft(2, '0')}')),
          DataCell(Text('${b.estimatedDuration}')),
          DataCell(Text(b.projectId ?? '-')),
          DataCell(Text(b.subProject ?? b.subProjectId ?? '-')),
          DataCell(Text(b.isCompleted ? '完了' : '未了')),
          DataCell(Text(b.isEvent ? '○' : '-')),
          DataCell(Text(_dateTime.format(b.createdAt.toLocal()))),
          DataCell(Text(_dateTime.format(b.lastModified.toLocal()))),
          DataCell(Text(b.cloudId ?? '-')),
          DataCell(SelectableText(b.id)),
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
              const Text('デフォルト: 約3ヶ月前〜翌月末の予定ブロックを表示'),
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
              if (_executionRange != null)
                _chip(
                  '実行日: ${_date.format(_executionRange!.start)}~${_date.format(_executionRange!.end)}',
                  () => setState(() => _executionRange = null),
                ),
              if (_isCompletedFilter != null)
                _chip(
                  '完了: ${_isCompletedFilter! ? '完了のみ' : '未完了のみ'}',
                  () => setState(() => _isCompletedFilter = null),
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
                  constraints: const BoxConstraints(minWidth: 1400),
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
              child: Text(
                  'ローカルDBの読み込みに失敗しました\n${snapshot.error}'),
            ),
          );
        }
        return StreamBuilder<BoxEvent>(
          stream: BlockService.watchChanges(),
          builder: (context, _) {
            final blocks = _loadBlocks();
            return _buildTable(context, blocks);
          },
        );
      },
    );
  }
}
