import 'package:flutter/material.dart';

import '../models/routine_block_v2.dart';
import 'device_info_service.dart';
import 'project_service.dart';
import 'routine_database_service.dart';
import 'routine_lamport_clock_service.dart';
import 'routine_mutation_facade.dart';
import 'routine_template_v2_service.dart';

/// ルーティンテンプレートにデフォルトで備わる「睡眠」ブロックの作成・存在保証。
class RoutineSleepBlockService {
  RoutineSleepBlockService._();

  /// 睡眠ブロックのID接尾辞（テンプレートID + これで一意）
  static const String sleepBlockIdSuffix = '_sleep';

  /// 睡眠ブロックの表示名（DB保存用）
  static const String sleepBlockName = '睡眠';

  /// 睡眠ブロックのUI表示用ラベル（就寝・起床を2行で表示）
  static const String sleepBlockDisplayLabel = '就寝\n起床';

  /// 指定ブロックが睡眠ブロックかどうか（表示を「就寝\n起床」にする判定に使用）
  static bool isSleepBlock(RoutineBlockV2 block) =>
      block.id.endsWith(sleepBlockIdSuffix);

  /// 指定テンプレートに睡眠ブロックが無ければ作成する。
  /// ショートカット用テンプレート（id == 'shortcut' または isShortcut）は対象外。
  static Future<void> ensureSleepBlockForTemplate(String templateId) async {
    final template = RoutineTemplateV2Service.getById(templateId);
    if (template == null) return;
    if (template.id == 'shortcut' || template.isShortcut) return;

    final blocks = RoutineDatabaseService.getBlocksForTemplate(templateId);
    final hasSleep = blocks.any((b) {
      if (b.id == '$templateId$sleepBlockIdSuffix') return true;
      if (b.blockName?.trim() == sleepBlockName) return true;
      // コピー元の睡眠ブロックは id が v2blk_... になることがある。excludeFromReport + 23時〜7時で判定
      if (b.excludeFromReport == true &&
          b.startTime.hour == 23 &&
          b.endTime.hour == 7) return true;
      return false;
    });
    if (hasSleep) return;

    final now = DateTime.now().toUtc();
    final deviceId = await DeviceInfoService.getDeviceId();
    final ver = await RoutineLamportClockService.next();
    final sleepBlockId = '$templateId$sleepBlockIdSuffix';

    final block = RoutineBlockV2(
      id: sleepBlockId,
      routineTemplateId: templateId,
      blockName: sleepBlockName,
      startTime: const TimeOfDay(hour: 23, minute: 0),
      endTime: const TimeOfDay(hour: 7, minute: 0),
      workingMinutes: 8 * 60,
      colorValue: null,
      order: -1,
      location: null,
      projectId: ProjectService.sleepProjectId,
      subProjectId: null,
      subProject: null,
      modeId: null,
      excludeFromReport: true,
      createdAt: now,
      lastModified: now,
      userId: template.userId,
      cloudId: sleepBlockId,
      isDeleted: false,
      deviceId: deviceId,
      version: ver,
    );

    await RoutineMutationFacade.instance.addBlock(block);
  }
}
