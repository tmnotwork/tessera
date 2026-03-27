import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../services/day_key_service.dart';
import '../services/sync_all_history_service.dart';

class SyncAllHistoryScreen extends StatefulWidget {
  const SyncAllHistoryScreen({super.key});

  @override
  State<SyncAllHistoryScreen> createState() => _SyncAllHistoryScreenState();
}

class _SyncAllHistoryScreenState extends State<SyncAllHistoryScreen>
    with SingleTickerProviderStateMixin {
  bool _loading = true;
  List<Map<String, dynamic>> _items = const [];
  String _filterType = 'all';
  String _filterTarget = 'all';
  String _filterHour = 'all'; // 'all' or 'yyyy-MM-dd HH:00' (account TZ)
  String _range = 'all'; // all | 24h | 7d
  late final TabController _tabController;

  static final DateFormat _fmtJstDateTime = DateFormat('yyyy/MM/dd HH:mm:ss');

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _reload();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      await DayKeyService.initialize();
    } catch (_) {}
    final items = await SyncAllHistoryService.load();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  static DateTime? _parseUtcIso(dynamic v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v)?.toUtc();
  }

  static String _formatJstUtcIso(dynamic v) {
    final utc = _parseUtcIso(v);
    if (utc == null) return '';
    final local = DayKeyService.toAccountWallClockFromUtc(utc);
    final tzName = DayKeyService.location.name == 'Asia/Tokyo'
        ? 'JST'
        : DayKeyService.location.name;
    return '${_fmtJstDateTime.format(local)} $tzName';
  }

  static String? _hourBucketKeyFromUtcIso(dynamic v) {
    final utc = _parseUtcIso(v);
    if (utc == null) return null;
    final wc = DayKeyService.toAccountWallClockFromUtc(utc);
    final y = wc.year.toString().padLeft(4, '0');
    final m = wc.month.toString().padLeft(2, '0');
    final d = wc.day.toString().padLeft(2, '0');
    final hh = wc.hour.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:00';
  }

  static List<String> _availableHourBuckets(List<Map<String, dynamic>> items) {
    final loc = DayKeyService.location;
    final sortEpochMs = <String, int>{}; // label -> epoch(ms) for sorting

    for (final e in items) {
      final label = _hourBucketKeyFromUtcIso(e['startedAtUtc']);
      if (label == null || label.isEmpty) continue;
      try {
        final y = int.parse(label.substring(0, 4));
        final m = int.parse(label.substring(5, 7));
        final d = int.parse(label.substring(8, 10));
        final hh = int.parse(label.substring(11, 13));
        final bucket = tz.TZDateTime(loc, y, m, d, hh);
        sortEpochMs[label] = bucket.toUtc().millisecondsSinceEpoch;
      } catch (_) {
        // ignore
      }
    }

    final labels = sortEpochMs.keys.toList()
      ..sort((a, b) => (sortEpochMs[b] ?? -1).compareTo(sortEpochMs[a] ?? -1));
    return labels;
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('履歴を削除'),
        content: const Text('同期/読取 履歴をすべて削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await SyncAllHistoryService.clear();
    await _reload();
  }

  List<Map<String, dynamic>> _applyRange(List<Map<String, dynamic>> items) {
    if (_range == 'all') return items;
    final now = DateTime.now().toUtc();
    final threshold = _range == '24h'
        ? now.subtract(const Duration(hours: 24))
        : now.subtract(const Duration(days: 7));
    return items.where((e) {
      final s = e['startedAtUtc'];
      final dt = _parseUtcIso(s);
      if (dt == null) return false;
      return dt.isAfter(threshold);
    }).toList();
  }

  static int _readEstimateFromKpi(dynamic kpi) {
    if (kpi is! Map) return 0;
    final d = Map<String, dynamic>.from(kpi);
    int v(String k) => (d[k] is int) ? (d[k] as int) : 0;
    return v('queryReads') + v('docGets') + v('watchInitialReads') + v('watchChangeReads');
  }

  static Map<String, int> _kpiInts(dynamic kpi) {
    if (kpi is! Map) {
      return const {
        'queryReads': 0,
        'docGets': 0,
        'writes': 0,
        'batchCommits': 0,
        'watchInitialReads': 0,
        'watchChangeReads': 0,
      };
    }
    final d = Map<String, dynamic>.from(kpi);
    int v(String k) => (d[k] is int) ? (d[k] as int) : 0;
    return {
      'queryReads': v('queryReads'),
      'docGets': v('docGets'),
      'writes': v('writes'),
      'batchCommits': v('batchCommits'),
      'watchInitialReads': v('watchInitialReads'),
      'watchChangeReads': v('watchChangeReads'),
    };
  }

  static String _deriveFeatureKey(Map<String, dynamic> e) {
    final type = (e['type'] as String?) ?? 'syncAll';
    final extra = e['extra'];
    final extraMap = (extra is Map) ? Map<String, dynamic>.from(extra) : null;
    switch (type) {
      case 'fullFetch':
      case 'watchStart':
        final col = extraMap?['collection'];
        if (col is String && col.isNotEmpty) return '$type:$col';
        return type;
      case 'syncIfStale':
      case 'syncDataFor':
        final targets = extraMap?['targets'];
        if (targets is List && targets.isNotEmpty) {
          final list = targets.whereType<String>().toList()..sort();
          if (list.isNotEmpty) return '$type:${list.join(',')}';
        }
        return type;
      case 'onDemandSync':
        final reason = (e['reason'] as String?) ?? '';
        final performedFetch = extraMap?['performedFetch'];
        final fetchTag = (performedFetch is bool)
            ? (performedFetch ? 'fetch' : 'noFetch')
            : null;
        if (reason.isNotEmpty) {
          return fetchTag != null ? '$type:$reason:$fetchTag' : '$type:$reason';
        }
        return type;
      case 'widgetSync':
        return 'widgetSync';
      case 'versionFeed':
        return 'versionFeed';
      case 'syncAll':
      default:
        return type;
    }
  }

  static String _deriveTargetKey(Map<String, dynamic> e) {
    final extra = e['extra'];
    final extraMap = (extra is Map) ? Map<String, dynamic>.from(extra) : null;
    final col = extraMap?['collection'];
    if (col is String && col.isNotEmpty) return col;
    final targets = extraMap?['targets'];
    if (targets is List && targets.isNotEmpty) {
      final list = targets.whereType<String>().toList()..sort();
      if (list.isNotEmpty) return list.join(',');
    }
    return 'unknown';
  }

  static List<String> _availableTypes(List<Map<String, dynamic>> items) {
    final set = <String>{};
    for (final e in items) {
      set.add((e['type'] as String?) ?? 'syncAll');
    }
    final list = set.toList()..sort();
    return list;
  }

  static List<String> _availableTargets(List<Map<String, dynamic>> items) {
    final set = <String>{};
    for (final e in items) {
      final t = _deriveTargetKey(e);
      if (t.isNotEmpty) set.add(t);
    }
    final list = set.toList()..sort();
    return list;
  }

  static String _deriveOriginKey(Map<String, dynamic> e) {
    final origin = (e['origin'] as String?) ?? '';
    if (origin.isEmpty) return 'origin:unknown';
    return 'origin:$origin';
  }

  List<Map<String, dynamic>> _applyTypeTargetFilters(
    List<Map<String, dynamic>> items,
  ) {
    final scoped = _applyRange(items);
    final filteredByType = _filterType == 'all'
        ? scoped
        : scoped
            .where((e) => (e['type'] as String? ?? 'syncAll') == _filterType)
            .toList();
    final filteredByTarget = _filterTarget == 'all'
        ? filteredByType
        : filteredByType.where((e) => _deriveTargetKey(e) == _filterTarget).toList();
    return filteredByTarget;
  }

  List<Map<String, dynamic>> _applyFilters(List<Map<String, dynamic>> items) {
    final filteredByTarget = _applyTypeTargetFilters(items);
    if (_filterHour == 'all') return filteredByTarget;
    return filteredByTarget
        .where((e) => _hourBucketKeyFromUtcIso(e['startedAtUtc']) == _filterHour)
        .toList();
  }

  Map<String, dynamic> _minimizeEntry(Map<String, dynamic> e) {
    return <String, dynamic>{
      'id': e['id'],
      'type': e['type'],
      'reason': e['reason'],
      'origin': e['origin'],
      'startedAtUtc': e['startedAtUtc'],
      'endedAtUtc': e['endedAtUtc'],
      'status': e['status'],
      'success': e['success'],
      if (e.containsKey('userId')) 'userId': e['userId'],
      if (e['extra'] is Map) 'extra': e['extra'],
      if (e['kpiDelta'] is Map) 'kpiDelta': e['kpiDelta'],
    };
  }

  Future<void> _copyFilteredJson() async {
    final filtered = _applyFilters(_items);
    final now = DateTime.now().toUtc().toIso8601String();
    final payload = <String, dynamic>{
      'kind': 'syncReadHistoryFiltered',
      'generatedAtUtc': now,
      'range': _range,
      'filterType': _filterType,
      'filterTarget': _filterTarget,
      'filterHour': _filterHour,
      'count': filtered.length,
      'items': filtered.map(_minimizeEntry).toList(),
    };
    final json = const JsonEncoder.withIndent('  ').convert(payload);
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('抽出結果JSONをコピーしました（${filtered.length}件）')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scoped = _applyRange(_items);
    final filtered = _applyFilters(_items);
    final availableTypes = _availableTypes(scoped);
    final availableTargets = _availableTargets(scoped);
    final availableHours = _availableHourBuckets(_applyTypeTargetFilters(_items));
    return Scaffold(
      appBar: AppBar(
        title: const Text('同期/読取 履歴'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '履歴'),
            Tab(text: '集計'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '更新',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '抽出JSONコピー',
            onPressed: _items.isEmpty ? null : _copyFilteredJson,
            icon: const Icon(Icons.content_copy),
          ),
          IconButton(
            tooltip: '全削除',
            onPressed: _items.isEmpty ? null : _confirmClear,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('履歴はありません'),
                  ),
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _HistoryTab(
                      items: filtered,
                      filterType: _filterType,
                      filterTarget: _filterTarget,
                      filterHour: _filterHour,
                      range: _range,
                      availableTypes: availableTypes,
                      availableTargets: availableTargets,
                      availableHours: availableHours,
                      onFilterTypeChanged: (v) => setState(() {
                        _filterType = v;
                        _filterHour = 'all';
                      }),
                      onFilterTargetChanged: (v) => setState(() {
                        _filterTarget = v;
                        _filterHour = 'all';
                      }),
                      onFilterHourChanged: (v) => setState(() => _filterHour = v),
                      onRangeChanged: (v) => setState(() {
                        _range = v;
                        _filterHour = 'all';
                      }),
                    ),
                    _SummaryTab(
                      items: filtered,
                      range: _range,
                      onRangeChanged: (v) => setState(() => _range = v),
                      filterType: _filterType,
                      filterTarget: _filterTarget,
                      availableTypes: availableTypes,
                      availableTargets: availableTargets,
                      onFilterTypeChanged: (v) => setState(() {
                        _filterType = v;
                        _filterHour = 'all';
                      }),
                      onFilterTargetChanged: (v) => setState(() {
                        _filterTarget = v;
                        _filterHour = 'all';
                      }),
                      deriveFeatureKey: _deriveFeatureKey,
                      deriveOriginKey: _deriveOriginKey,
                      readEstimateFromKpi: _readEstimateFromKpi,
                      kpiInts: _kpiInts,
                    ),
                  ],
                ),
    );
  }
}

class _HistoryTab extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final String filterType;
  final String filterTarget;
  final String filterHour;
  final String range;
  final List<String> availableTypes;
  final List<String> availableTargets;
  final List<String> availableHours;
  final ValueChanged<String> onFilterTypeChanged;
  final ValueChanged<String> onFilterTargetChanged;
  final ValueChanged<String> onFilterHourChanged;
  final ValueChanged<String> onRangeChanged;

  const _HistoryTab({
    required this.items,
    required this.filterType,
    required this.filterTarget,
    required this.filterHour,
    required this.range,
    required this.availableTypes,
    required this.availableTargets,
    required this.availableHours,
    required this.onFilterTypeChanged,
    required this.onFilterTargetChanged,
    required this.onFilterHourChanged,
    required this.onRangeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _TypeChip(
                label: '全期間',
                selected: range == 'all',
                onTap: () => onRangeChanged('all'),
              ),
              _TypeChip(
                label: '24時間',
                selected: range == '24h',
                onTap: () => onRangeChanged('24h'),
              ),
              _TypeChip(
                label: '7日',
                selected: range == '7d',
                onTap: () => onRangeChanged('7d'),
              ),
              const SizedBox(width: 16),
              _FilterDropdown(
                label: 'type',
                value: filterType,
                values: availableTypes,
                onChanged: onFilterTypeChanged,
              ),
              _FilterDropdown(
                label: '対象',
                value: filterTarget,
                values: availableTargets,
                onChanged: onFilterTargetChanged,
              ),
              _FilterDropdown(
                label: '時間',
                value: filterHour,
                values: availableHours,
                onChanged: onFilterHourChanged,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final e = items[index];
              final startedAtJst = _SyncAllHistoryScreenState._formatJstUtcIso(
                e['startedAtUtc'],
              );
              final endedAtJst = _SyncAllHistoryScreenState._formatJstUtcIso(
                e['endedAtUtc'],
              );
              final reason = (e['reason'] as String?) ?? 'unknown';
              final origin = (e['origin'] as String?) ?? '';
              final status = (e['status'] as String?) ?? '';
              final success = e['success'];
              final type = (e['type'] as String?) ?? 'syncAll';

              final extra = e['extra'];
              final extraSummary = <String>[];
              if (extra is Map) {
                final m = Map<String, dynamic>.from(extra);
                if (m['collection'] is String) extraSummary.add('col=${m['collection']}');
                if (m['docs'] is int) extraSummary.add('docs=${m['docs']}');
                if (m['entries'] is int) extraSummary.add('entries=${m['entries']}');
                // 未送信（outbox/batch）の滞留状況
                Map<String, int>? _pendingInts(dynamic raw) {
                  if (raw is! Map) return null;
                  final mm = Map<String, dynamic>.from(raw);
                  int? pick(String k) {
                    final v = mm[k];
                    return v is int ? v : null;
                  }
                  final taskOutbox = pick('taskOutbox');
                  final blockOutbox = pick('blockOutbox');
                  final taskBatch = pick('taskBatch');
                  if (taskOutbox == null && blockOutbox == null && taskBatch == null) {
                    return null;
                  }
                  return <String, int>{
                    if (taskOutbox != null) 'taskOutbox': taskOutbox,
                    if (blockOutbox != null) 'blockOutbox': blockOutbox,
                    if (taskBatch != null) 'taskBatch': taskBatch,
                  };
                }

                final pendingEnd = _pendingInts(m['pendingEnd']);
                final pendingStart = _pendingInts(m['pendingStart']);
                if (pendingEnd != null && pendingEnd.isNotEmpty) {
                  extraSummary.add(
                    'pendingEnd(t=${pendingEnd['taskOutbox'] ?? '-'},b=${pendingEnd['blockOutbox'] ?? '-'},batch=${pendingEnd['taskBatch'] ?? '-'})',
                  );
                } else if (pendingStart != null && pendingStart.isNotEmpty) {
                  extraSummary.add(
                    'pendingStart(t=${pendingStart['taskOutbox'] ?? '-'},b=${pendingStart['blockOutbox'] ?? '-'},batch=${pendingStart['taskBatch'] ?? '-'})',
                  );
                }
                if (m['caller'] is String && (m['caller'] as String).isNotEmpty) {
                  extraSummary.add('caller=${m['caller']}');
                }
                if (m['fromIndex'] is int) extraSummary.add('from=${m['fromIndex']}');
                if (m['toIndex'] is int) extraSummary.add('to=${m['toIndex']}');
                if (m['selectedIndex'] is int) {
                  extraSummary.add('tab=${m['selectedIndex']}');
                }
                if (m['showSettingsPanel'] is bool) {
                  extraSummary.add('settings=${m['showSettingsPanel']}');
                }
                if (m['originArg'] is String && (m['originArg'] as String).isNotEmpty) {
                  extraSummary.add('originArg=${m['originArg']}');
                }
                if (m['mutexWaitMs'] is int) {
                  extraSummary.add('wait=${m['mutexWaitMs']}ms');
                }
              }

              final kpiDelta = e['kpiDelta'];
              String? readEstimate;
              String? writeEstimate;
              final kpiInMutex = (extra is Map) ? (extra as Map)['kpiDeltaInMutex'] : null;
              final candidate = (kpiInMutex is Map) ? kpiInMutex : kpiDelta;
              if (candidate is Map) {
                final est = _SyncAllHistoryScreenState._readEstimateFromKpi(candidate);
                readEstimate = 'read≈$est';
                try {
                  final m = Map<String, dynamic>.from(candidate);
                  final w = (m['writes'] is int) ? (m['writes'] as int) : 0;
                  final c = (m['batchCommits'] is int) ? (m['batchCommits'] as int) : 0;
                  if (w > 0 || c > 0) {
                    writeEstimate = 'write≈$w${c > 0 ? ' (commit=$c)' : ''}';
                  } else {
                    writeEstimate = 'write≈0';
                  }
                } catch (_) {
                  writeEstimate = 'write≈0';
                }
              }

              final meta = <String>[
                if (origin.isNotEmpty) origin,
                if (status.isNotEmpty) 'status=$status',
                if (success is bool) 'success=$success',
                if (readEstimate != null) readEstimate,
                if (writeEstimate != null) writeEstimate,
                if (extraSummary.isNotEmpty) extraSummary.join(' / '),
              ].join(' / ');

              final timeLine = <String>[
                if (startedAtJst.isNotEmpty) '開始: $startedAtJst',
                if (endedAtJst.isNotEmpty) '終了: $endedAtJst',
              ].join(' / ');

              final subtitle = <String>[
                if (timeLine.isNotEmpty) timeLine,
                if (meta.isNotEmpty) meta,
              ].join('\n');

              return ListTile(
                title: Text('[$type] $reason'),
                subtitle: Text(
                  subtitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                isThreeLine: subtitle.isNotEmpty,
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => _SyncAllHistoryDetailScreen(entry: e),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SummaryRow {
  _SummaryRow({
    required this.key,
    required this.label,
  });

  final String key;
  final String label;
  int? sortEpochMsUtc;
  int count = 0;
  int totalRead = 0;
  int totalWrite = 0;
  int totalBatchCommits = 0;
  int queryReads = 0;
  int docGets = 0;
  int writes = 0;
  int batchCommits = 0;
  int watchInit = 0;
  int watchDelta = 0;
  DateTime? lastAt;
}

class _SummaryTab extends StatefulWidget {
  const _SummaryTab({
    required this.items,
    required this.range,
    required this.onRangeChanged,
    required this.filterType,
    required this.filterTarget,
    required this.availableTypes,
    required this.availableTargets,
    required this.onFilterTypeChanged,
    required this.onFilterTargetChanged,
    required this.deriveFeatureKey,
    required this.deriveOriginKey,
    required this.readEstimateFromKpi,
    required this.kpiInts,
  });

  final List<Map<String, dynamic>> items;
  final String range;
  final ValueChanged<String> onRangeChanged;
  final String filterType;
  final String filterTarget;
  final List<String> availableTypes;
  final List<String> availableTargets;
  final ValueChanged<String> onFilterTypeChanged;
  final ValueChanged<String> onFilterTargetChanged;
  final String Function(Map<String, dynamic>) deriveFeatureKey;
  final String Function(Map<String, dynamic>) deriveOriginKey;
  final int Function(dynamic kpi) readEstimateFromKpi;
  final Map<String, int> Function(dynamic kpi) kpiInts;

  @override
  State<_SummaryTab> createState() => _SummaryTabState();
}

class _SummaryTabState extends State<_SummaryTab> {
  String _groupBy = 'feature'; // feature | type | origin | hour

  String _rangeLabel(String v) {
    switch (v) {
      case '24h':
        return '24時間';
      case '7d':
        return '7日';
      case 'all':
      default:
        return '全期間';
    }
  }

  String _groupByLabel(String v) {
    switch (v) {
      case 'type':
        return 'type別';
      case 'origin':
        return 'origin別';
      case 'hour':
        return '時間別';
      case 'feature':
      default:
        return '機能別';
    }
  }

  List<_SummaryRow> _computeRows() {
    final groups = <String, _SummaryRow>{};

    for (final e in widget.items) {
      final type = (e['type'] as String?) ?? 'syncAll';
      String key;
      if (_groupBy == 'hour') {
        final utc = _SyncAllHistoryScreenState._parseUtcIso(e['startedAtUtc']);
        if (utc == null) {
          key = 'hour:unknown';
        } else {
          final wc = DayKeyService.toAccountWallClockFromUtc(utc);
          final y = wc.year.toString().padLeft(4, '0');
          final m = wc.month.toString().padLeft(2, '0');
          final d = wc.day.toString().padLeft(2, '0');
          final hh = wc.hour.toString().padLeft(2, '0');
          key = '$y-$m-$d $hh:00';
        }
      } else if (_groupBy == 'type') {
        key = type;
      } else if (_groupBy == 'origin') {
        key = widget.deriveOriginKey(e);
      } else {
        key = widget.deriveFeatureKey(e);
      }
      final row = groups.putIfAbsent(
        key,
        () => _SummaryRow(key: key, label: key),
      );
      if (_groupBy == 'hour' && row.sortEpochMsUtc == null) {
        final utc = _SyncAllHistoryScreenState._parseUtcIso(e['startedAtUtc']);
        if (utc != null) {
          final wc = DayKeyService.toAccountWallClockFromUtc(utc);
          final bucket = tz.TZDateTime(
            DayKeyService.location,
            wc.year,
            wc.month,
            wc.day,
            wc.hour,
          );
          row.sortEpochMsUtc = bucket.toUtc().millisecondsSinceEpoch;
        }
      }

      final extra = e['extra'];
      final kpiInMutex = (extra is Map) ? (extra as Map)['kpiDeltaInMutex'] : null;
      final kpi = (kpiInMutex is Map) ? kpiInMutex : e['kpiDelta'];
      final est = widget.readEstimateFromKpi(kpi);
      final ints = widget.kpiInts(kpi);

      row.count += 1;
      row.totalRead += est;
      row.queryReads += ints['queryReads'] ?? 0;
      row.docGets += ints['docGets'] ?? 0;
      final w = ints['writes'] ?? 0;
      final bc = ints['batchCommits'] ?? 0;
      row.totalWrite += w;
      row.totalBatchCommits += bc;
      row.writes += w;
      row.batchCommits += bc;
      row.watchInit += ints['watchInitialReads'] ?? 0;
      row.watchDelta += ints['watchChangeReads'] ?? 0;

      final s = e['startedAtUtc'];
      final dt = _SyncAllHistoryScreenState._parseUtcIso(s);
      if (dt != null) {
        final last = row.lastAt;
        if (last == null || dt.isAfter(last)) row.lastAt = dt;
      }
    }

    final rows = groups.values.toList()
      ..sort((a, b) {
        if (_groupBy == 'hour') {
          final aa = a.sortEpochMsUtc ?? -1;
          final bb = b.sortEpochMsUtc ?? -1;
          return bb.compareTo(aa); // newest first
        }
        return b.totalRead.compareTo(a.totalRead);
      });
    return rows;
  }

  String _buildExportText(List<_SummaryRow> rows) {
    final totalRead = rows.fold<int>(0, (s, r) => s + r.totalRead);
    final totalWrite = rows.fold<int>(0, (s, r) => s + r.totalWrite);
    final totalCommits = rows.fold<int>(0, (s, r) => s + r.totalBatchCommits);
    final totalCount = rows.fold<int>(0, (s, r) => s + r.count);
    final now = DateTime.now().toUtc().toIso8601String();

    final buf = StringBuffer();
    buf.writeln('同期/読取 履歴 - 集計 出力');
    buf.writeln('generatedAtUtc=$now');
    buf.writeln('range=${_rangeLabel(widget.range)} (${widget.range})');
    buf.writeln('groupBy=${_groupByLabel(_groupBy)} ($_groupBy)');
    buf.writeln('totalCount=$totalCount');
    buf.writeln('totalRead≈$totalRead');
    buf.writeln('totalWrite≈$totalWrite');
    buf.writeln('totalBatchCommits=$totalCommits');
    buf.writeln('');
    buf.writeln('---');
    for (final r in rows) {
      final avg = r.count == 0 ? 0.0 : (r.totalRead / r.count);
      final lastAt = r.lastAt?.toIso8601String() ?? '';
      buf.writeln(r.label);
      buf.writeln(
        '  count=${r.count} / read≈${r.totalRead} / avg≈${avg.toStringAsFixed(1)}'
        ' / write≈${r.totalWrite} commit=${r.totalBatchCommits}'
        ' / q=${r.queryReads} doc=${r.docGets} write=${r.writes} commit=${r.batchCommits} watchInit=${r.watchInit} watchΔ=${r.watchDelta}'
        '${lastAt.isNotEmpty ? ' / lastAtUtc=$lastAt' : ''}',
      );
    }
    return buf.toString().trimRight();
  }

  String _buildExportJson(List<_SummaryRow> rows) {
    final totalRead = rows.fold<int>(0, (s, r) => s + r.totalRead);
    final totalWrite = rows.fold<int>(0, (s, r) => s + r.totalWrite);
    final totalCommits = rows.fold<int>(0, (s, r) => s + r.totalBatchCommits);
    final totalCount = rows.fold<int>(0, (s, r) => s + r.count);
    final now = DateTime.now().toUtc().toIso8601String();

    final data = <String, dynamic>{
      'kind': 'syncReadSummary',
      'generatedAtUtc': now,
      'range': widget.range,
      'groupBy': _groupBy,
      'totals': {
        'count': totalCount,
        'readEstimate': totalRead,
        'writeEstimate': totalWrite,
        'batchCommits': totalCommits,
      },
      'rows': rows
          .map((r) {
            final avg = r.count == 0 ? 0.0 : (r.totalRead / r.count);
            return {
              'key': r.key,
              'label': r.label,
              'count': r.count,
              'readEstimate': r.totalRead,
              'writeEstimate': r.totalWrite,
              'batchCommits': r.totalBatchCommits,
              'avgReadEstimate': double.parse(avg.toStringAsFixed(3)),
              'breakdown': {
                'queryReads': r.queryReads,
                'docGets': r.docGets,
                'writes': r.writes,
                'batchCommits': r.batchCommits,
                'watchInitialReads': r.watchInit,
                'watchChangeReads': r.watchDelta,
              },
              if (r.lastAt != null) 'lastAtUtc': r.lastAt!.toIso8601String(),
            };
          })
          .toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  Future<void> _showExportDialog(List<_SummaryRow> rows) async {
    final text = _buildExportText(rows);
    final json = _buildExportJson(rows);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('集計を出力'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: json));
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('JSONをコピーしました')),
                  );
                }
              } catch (_) {}
            },
            child: const Text('JSONコピー'),
          ),
          TextButton(
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: text));
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('テキストをコピーしました')),
                  );
                }
              } catch (_) {}
            },
            child: const Text('テキストコピー'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _computeRows();

    final totalRead = rows.fold<int>(0, (s, r) => s + r.totalRead);
    final totalWrite = rows.fold<int>(0, (s, r) => s + r.totalWrite);
    final totalCommits = rows.fold<int>(0, (s, r) => s + r.totalBatchCommits);
    final totalCount = rows.fold<int>(0, (s, r) => s + r.count);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _FilterDropdown(
                label: 'type',
                value: widget.filterType,
                values: widget.availableTypes,
                onChanged: widget.onFilterTypeChanged,
              ),
              _FilterDropdown(
                label: '対象',
                value: widget.filterTarget,
                values: widget.availableTargets,
                onChanged: widget.onFilterTargetChanged,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _TypeChip(
                label: '全期間',
                selected: widget.range == 'all',
                onTap: () => widget.onRangeChanged('all'),
              ),
              _TypeChip(
                label: '24時間',
                selected: widget.range == '24h',
                onTap: () => widget.onRangeChanged('24h'),
              ),
              _TypeChip(
                label: '7日',
                selected: widget.range == '7d',
                onTap: () => widget.onRangeChanged('7d'),
              ),
              const SizedBox(width: 16),
              _TypeChip(
                label: '機能別',
                selected: _groupBy == 'feature',
                onTap: () => setState(() => _groupBy = 'feature'),
              ),
              _TypeChip(
                label: 'type別',
                selected: _groupBy == 'type',
                onTap: () => setState(() => _groupBy = 'type'),
              ),
              _TypeChip(
                label: 'origin別',
                selected: _groupBy == 'origin',
                onTap: () => setState(() => _groupBy = 'origin'),
              ),
              _TypeChip(
                label: '時間別',
                selected: _groupBy == 'hour',
                onTap: () => setState(() => _groupBy = 'hour'),
              ),
              const SizedBox(width: 16),
              OutlinedButton.icon(
                onPressed: rows.isEmpty ? null : () => _showExportDialog(rows),
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('出力'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '合計: $totalCount件 / read≈$totalRead / write≈$totalWrite (commit=$totalCommits)',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final r = rows[index];
              final avg = r.count == 0 ? 0 : (r.totalRead / r.count);
              final sub = 'count=${r.count} / read≈${r.totalRead} / avg≈${avg.toStringAsFixed(1)}'
                  ' / write≈${r.totalWrite} (commit=${r.totalBatchCommits})'
                  ' / q=${r.queryReads} doc=${r.docGets} write=${r.writes} commit=${r.batchCommits} watchInit=${r.watchInit} watchΔ=${r.watchDelta}';
              return ListTile(
                title: Text(r.label),
                subtitle: Text(
                  sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TypeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
  });

  final String label;
  final String value; // 'all' or actual
  final List<String> values;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: 'all', child: Text('すべて')),
      ...values.map((v) => DropdownMenuItem(value: v, child: Text(v))),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$label: '),
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                items: items,
                onChanged: (v) => onChanged(v ?? 'all'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SyncAllHistoryDetailScreen extends StatelessWidget {
  final Map<String, dynamic> entry;
  const _SyncAllHistoryDetailScreen({required this.entry});

  @override
  Widget build(BuildContext context) {
    final pretty = const JsonEncoder.withIndent('  ').convert(entry);
    final startedAtJst = _SyncAllHistoryScreenState._formatJstUtcIso(entry['startedAtUtc']);
    final endedAtJst = _SyncAllHistoryScreenState._formatJstUtcIso(entry['endedAtUtc']);
    return Scaffold(
      appBar: AppBar(
        title: const Text('詳細'),
        actions: [
          IconButton(
            tooltip: 'コピー',
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: pretty));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('コピーしました')),
                  );
                }
              } catch (_) {}
            },
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (startedAtJst.isNotEmpty) Text('開始: $startedAtJst'),
            if (endedAtJst.isNotEmpty) Text('終了: $endedAtJst'),
            if (startedAtJst.isNotEmpty || endedAtJst.isNotEmpty)
              const SizedBox(height: 8),
            SelectableText(
              pretty,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

