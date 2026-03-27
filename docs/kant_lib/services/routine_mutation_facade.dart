import '../models/routine_block_v2.dart';
import '../models/routine_task_v2.dart';
import '../models/routine_template_v2.dart';

import 'device_info_service.dart';
import 'routine_lamport_clock_service.dart';
import 'routine_block_v2_service.dart';
import 'routine_task_v2_service.dart';
import 'routine_block_v2_sync_service.dart';
import 'routine_task_v2_sync_service.dart';
import 'routine_template_v2_service.dart';
import 'routine_template_v2_sync_service.dart';

/// Centralizes mutations to V2 blocks/tasks so that dual-write logic lives in a
/// single place.
class RoutineMutationFacade {
  RoutineMutationFacade._();

  static final RoutineMutationFacade instance = RoutineMutationFacade._();

  Future<void> addTemplate(RoutineTemplateV2 template) async {
    await _applyV2Modified(template);
    await RoutineTemplateV2Service.add(template);
    await _syncV2Template(template);
  }

  /// ローカルのみ追加（同期なし）。一括コピーで即時反映してからバックグラウンドで同期する用途。
  Future<void> addTemplateLocal(RoutineTemplateV2 template) async {
    await _applyV2Modified(template);
    await RoutineTemplateV2Service.add(template);
  }

  /// 指定テンプレートとそのブロック・タスクを Firebase に同期（バックグラウンド用）。
  Future<void> syncTemplateWithBlocksAndTasksToFirebase(String templateId) async {
    final t = RoutineTemplateV2Service.getById(templateId);
    if (t != null) await _syncV2Template(t);
    final blocks = RoutineBlockV2Service.getAllByTemplate(templateId);
    for (final b in blocks) await _syncV2Block(b);
    final tasks = RoutineTaskV2Service.getByTemplate(templateId);
    for (final t in tasks) await _syncV2Task(t);
  }

  Future<void> updateTemplate(RoutineTemplateV2 template) async {
    await _applyV2Modified(template);
    await RoutineTemplateV2Service.update(template);
    await _syncV2Template(template);
  }

  Future<void> deleteTemplate(String templateId) async {
    final existing = RoutineTemplateV2Service.getById(templateId);
    if (existing != null && !existing.isDeleted) {
      existing.isDeleted = true;
      existing.isActive = false;
      await _applyV2Modified(existing);
      await RoutineTemplateV2Service.update(existing);
      await _syncV2Template(existing);
    }
  }

  Future<void> addBlock(RoutineBlockV2 block) async {
    await _applyV2Modified(block);
    await RoutineBlockV2Service.add(block);
    await _syncV2Block(block);
  }

  /// ローカルのみ追加（同期なし）。一括コピーで即時反映してからバックグラウンドで同期する用途。
  Future<void> addBlockLocal(RoutineBlockV2 block) async {
    await _applyV2Modified(block);
    await RoutineBlockV2Service.add(block);
  }

  Future<void> updateBlock(RoutineBlockV2 block) async {
    await _applyV2Modified(block);
    await RoutineBlockV2Service.update(block);
    await _syncV2Block(block);
  }

  Future<void> addTask(RoutineTaskV2 task) async {
    await _applyV2Modified(task);
    await RoutineTaskV2Service.add(task);
    await _syncV2Task(task);
  }

  /// ローカルのみ追加（同期なし）。一括コピーで即時反映してからバックグラウンドで同期する用途。
  Future<void> addTaskLocal(RoutineTaskV2 task) async {
    await _applyV2Modified(task);
    await RoutineTaskV2Service.add(task);
  }

  Future<void> updateTask(RoutineTaskV2 task) async {
    await _applyV2Modified(task);
    await RoutineTaskV2Service.update(task);
    await _syncV2Task(task);
  }

  Future<void> deleteTask(String taskId, String templateId) async {
    // 明示削除は tombstone(isDeleted=true) として保持し、同期で伝播する
    final existing = RoutineTaskV2Service.getById(taskId);
    if (existing != null && !existing.isDeleted) {
      final tombstone = existing.copyWith(isDeleted: true);
      await _applyV2Modified(tombstone);
      await RoutineTaskV2Service.update(tombstone);
      await _syncV2Task(tombstone);
    }
  }

  Future<void> deleteBlock(String blockId, String templateId) async {
    // ブロックに紐づくタスクも tombstone として削除
    final tasks = RoutineTaskV2Service.getByBlock(blockId);
    for (final task in tasks) {
      if (!task.isDeleted) {
        final tombstone = task.copyWith(isDeleted: true);
        await _applyV2Modified(tombstone);
        await RoutineTaskV2Service.update(tombstone);
        await _syncV2Task(tombstone);
      }
    }
    // ブロック本体も tombstone として削除
    final block = RoutineBlockV2Service.getById(blockId);
    if (block != null && !block.isDeleted) {
      final tombstone = block.copyWith(isDeleted: true);
      await _applyV2Modified(tombstone);
      await RoutineBlockV2Service.update(tombstone);
      await _syncV2Block(tombstone);
    }
  }

  Future<void> _applyV2Modified(dynamic v2) async {
    // v2 is RoutineTaskV2 or RoutineBlockV2 (both implement SyncableModel fields)
    final deviceId = await DeviceInfoService.getDeviceId();
    final ver = await RoutineLamportClockService.next();
    try {
      // ignore: avoid_dynamic_calls
      v2.deviceId = deviceId;
      // ignore: avoid_dynamic_calls
      v2.version = ver;
      // ignore: avoid_dynamic_calls
      v2.lastModified = DateTime.now().toUtc();
      // docId == id を成立させる
      // ignore: avoid_dynamic_calls
      v2.cloudId ??= v2.id as String;
    } catch (_) {}
  }

  Future<void> _syncV2Block(RoutineBlockV2 block) async {
    try {
      final sync = RoutineBlockV2SyncService();
      await sync.uploadToFirebase(block);
      await RoutineBlockV2Service.update(block);
    } catch (_) {}
  }

  Future<void> _syncV2Task(RoutineTaskV2 task) async {
    try {
      final sync = RoutineTaskV2SyncService();
      await sync.uploadToFirebase(task);
      await RoutineTaskV2Service.update(task);
    } catch (_) {}
  }

  Future<void> _syncV2Template(RoutineTemplateV2 template) async {
    try {
      final sync = RoutineTemplateV2SyncService();
      await sync.uploadToFirebase(template);
      await RoutineTemplateV2Service.update(template);
    } catch (_) {}
  }
}
