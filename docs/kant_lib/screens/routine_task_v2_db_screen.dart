import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/routine_task_v2.dart';
import '../services/routine_task_v2_service.dart';
import '../services/routine_task_v2_sync_service.dart';

class RoutineTaskV2DbScreen extends StatefulWidget {
  const RoutineTaskV2DbScreen({super.key});

  @override
  State<RoutineTaskV2DbScreen> createState() => _RoutineTaskV2DbScreenState();
}

class _RoutineTaskV2DbScreenState extends State<RoutineTaskV2DbScreen> {
  final DateFormat _dt = DateFormat('yyyy/MM/dd HH:mm');
  bool _syncing = false;
  String? _error;
  DateTime? _lastSyncedAt;

  List<RoutineTaskV2> _loadLocal() {
    final list = RoutineTaskV2Service.debugGetAllRaw();
    list.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    return list;
  }

  Future<void> _sync({required bool forceFullSync}) async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _error = null;
    });
    try {
      await RoutineTaskV2SyncService().performSync(forceFullSync: forceFullSync);
      _lastSyncedAt = DateTime.now();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  String _statusLabel() {
    if (_syncing) return '同期中...';
    if (_lastSyncedAt == null) return 'ローカル表示';
    return '最終同期: ${_dt.format(_lastSyncedAt!)}';
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _loadLocal();
    return Scaffold(
      appBar: AppBar(
        title: Text('ルーティンタスク（V2） ${tasks.length}件'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                _statusLabel(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          IconButton(
            tooltip: '差分同期',
            onPressed: _syncing ? null : () => _sync(forceFullSync: false),
            icon: const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: 'フル同期',
            onPressed: _syncing ? null : () => _sync(forceFullSync: true),
            icon: const Icon(Icons.sync_problem),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText('同期に失敗しました: $_error'),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: tasks.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final t = tasks[index];
                return ListTile(
                  title: Text(t.name.isEmpty ? '（名称なし）' : t.name),
                  subtitle: Text(
                    'id=${t.id} cloudId=${t.cloudId ?? ""}\n'
                    'templateId=${t.routineTemplateId} blockId=${t.routineBlockId} order=${t.order}\n'
                    'deleted=${t.isDeleted} ver=${t.version} lastModified=${t.lastModified.toIso8601String()}',
                  ),
                  isThreeLine: true,
                );
              },
            ),
    );
  }
}

