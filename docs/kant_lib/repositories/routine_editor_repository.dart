import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/routine_block_v2.dart';
import '../models/routine_task_v2.dart';
import '../models/routine_template_v2.dart';
import '../services/routine_block_v2_service.dart';
import '../services/routine_database_service.dart';
import '../services/routine_task_v2_service.dart';
import '../services/routine_block_v2_sync_service.dart';
import '../services/routine_task_v2_sync_service.dart';
import '../services/routine_template_v2_sync_service.dart';

class RoutineEditorSnapshot {
  RoutineEditorSnapshot({
    required this.templateId,
    required this.blocks,
    required this.tasksByBlockId,
    required this.generatedAt,
  });

  final String templateId;
  final List<RoutineBlockV2> blocks;
  final Map<String, List<RoutineTaskV2>> tasksByBlockId;
  final DateTime generatedAt;

  List<RoutineTaskV2> tasksForBlock(String blockId) =>
      tasksByBlockId[blockId] ?? const <RoutineTaskV2>[];

  int get totalTaskCount =>
      tasksByBlockId.values.fold<int>(0, (sum, list) => sum + list.length);

  bool get hasBlocks => blocks.isNotEmpty;
}

class RoutineBootstrapResult {
  const RoutineBootstrapResult({
    required this.success,
    required this.attempts,
    this.lastError,
  });

  final bool success;
  final int attempts;
  final Object? lastError;

  factory RoutineBootstrapResult.success({required int attempts}) =>
      RoutineBootstrapResult(success: true, attempts: attempts);
}

class RoutineEditorRepository {
  RoutineEditorRepository._();

  static final RoutineEditorRepository instance =
      RoutineEditorRepository._();

  final Map<String, _TemplateWatcher> _watchers = {};

  Stream<RoutineEditorSnapshot> watchTemplate(String templateId) {
    return _watchers.putIfAbsent(
      templateId,
      () => _TemplateWatcher(
        templateId: templateId,
        buildSnapshot: _buildSnapshot,
        onZeroListeners: () => _disposeWatcher(templateId),
      ),
    ).stream;
  }

  RoutineEditorSnapshot snapshotTemplate(String templateId) {
    return _buildSnapshot(templateId);
  }

  /// V2のみを正として、テンプレ配下の block/task がローカルに存在する状態へ持っていく。
  Future<RoutineBootstrapResult> bootstrapTemplateV2(
    RoutineTemplateV2 template, {
    int maxAttempts = 3,
    Duration retryDelay = const Duration(seconds: 1),
  }) async {
    int attempts = 0;
    Object? lastError;
    while (attempts < maxAttempts) {
      attempts += 1;
      try {
        // 1) V2 Firestore → ローカル取り込み
        try {
          await RoutineTemplateV2SyncService().syncById(template.id);
        } catch (_) {}
        try {
          await RoutineBlockV2SyncService().syncForTemplate(template.id);
        } catch (_) {}
        try {
          await RoutineTaskV2SyncService().syncForTemplate(template.id);
        } catch (_) {}

        final hasBlocks =
            RoutineBlockV2Service.getAllByTemplate(template.id).isNotEmpty;
        if (hasBlocks) {
          return RoutineBootstrapResult.success(attempts: attempts);
        }
      } catch (err) {
        lastError = err;
        if (retryDelay > Duration.zero) {
          await Future.delayed(retryDelay);
        }
      }
      if (retryDelay > Duration.zero) {
        await Future.delayed(retryDelay);
      }
    }

    final hasBlocks =
        RoutineBlockV2Service.getAllByTemplate(template.id).isNotEmpty;
    return RoutineBootstrapResult(
      success: hasBlocks,
      attempts: attempts,
      lastError: lastError,
    );
  }

  RoutineEditorSnapshot _buildSnapshot(String templateId) {
    final blocks = RoutineDatabaseService.getBlocksForTemplate(templateId);
    final tasksByBlockId = <String, List<RoutineTaskV2>>{};
    for (final block in blocks) {
      tasksByBlockId[block.id] = RoutineDatabaseService.getTasksForBlock(
        block.id,
      );
    }
    return RoutineEditorSnapshot(
      templateId: templateId,
      blocks: blocks,
      tasksByBlockId: tasksByBlockId,
      generatedAt: DateTime.now(),
    );
  }

  void _disposeWatcher(String templateId) {
    final watcher = _watchers.remove(templateId);
    watcher?.dispose();
  }
}

class _TemplateWatcher {
  _TemplateWatcher({
    required this.templateId,
    required RoutineEditorSnapshot Function(String templateId) buildSnapshot,
    required this.onZeroListeners,
  }) : _buildSnapshot = buildSnapshot {
    _controller = StreamController<RoutineEditorSnapshot>.broadcast(
      onListen: _emitSnapshot,
      onCancel: () {
        if (!_controller.hasListener) {
          onZeroListeners();
        }
      },
    );
    _blockSub = RoutineBlockV2Service.updateStream.listen((_) {
      _emitSnapshotIfNeeded();
    });
    _taskSub = RoutineTaskV2Service.updateStream.listen((_) {
      _emitSnapshotIfNeeded();
    });
  }

  final String templateId;
  final RoutineEditorSnapshot Function(String templateId) _buildSnapshot;
  final VoidCallback onZeroListeners;

  late final StreamController<RoutineEditorSnapshot> _controller;
  late final StreamSubscription<void> _blockSub;
  late final StreamSubscription<void> _taskSub;

  Stream<RoutineEditorSnapshot> get stream => _controller.stream;

  void dispose() {
    _blockSub.cancel();
    _taskSub.cancel();
    _controller.close();
  }

  void _emitSnapshotIfNeeded() {
    if (!_controller.hasListener) return;
    _emitSnapshot();
  }

  void _emitSnapshot() {
    try {
      final snapshot = _buildSnapshot(templateId);
      if (!_controller.isClosed) {
        _controller.add(snapshot);
      }
    } catch (err, stack) {
      if (!_controller.isClosed) {
        _controller.addError(err, stack);
      }
    }
  }
}
