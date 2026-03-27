import 'package:flutter/material.dart';

import '../app/theme/domain_colors.dart';
import '../models/routine_block_v2.dart';
import '../models/work_type.dart';
import '../models/routine_template_v2.dart';
import 'device_info_service.dart';
import 'routine_block_v2_service.dart';
import 'routine_block_v2_sync_service.dart';
import 'routine_lamport_clock_service.dart';
import 'routine_task_v2_service.dart';
import 'routine_task_v2_sync_service.dart';
import 'routine_template_v2_service.dart';
import 'routine_template_v2_sync_service.dart';
import 'routine_sleep_block_service.dart';

/// V2-only の初期ルーティン（平日/休日/ショートカット）を作成する。
///
/// 目的:
/// - 新規ユーザーで旧テンプレート互換パスを経由せず、V2 のみで初期表示を成立させる
/// - 端末間で重複生成しない（予約IDを使用）
class RoutineV2DefaultsService {
  RoutineV2DefaultsService._();

  static const String weekdayTemplateId = 'weekday_template_v2';
  static const String holidayTemplateId = 'holiday_template_v2';
  /// 非定型ショートカットの予約ID（タスク・ブロック・編集UIのSSOT。変更しない）
  static const String shortcutTemplateId = 'shortcut';

  static const String shortcutBlockId = 'v2blk_shortcut_0';

  static int _durationMinutes(TimeOfDay s, TimeOfDay e) {
    final sm = s.hour * 60 + s.minute;
    var em = e.hour * 60 + e.minute;
    if (em <= sm) em += 24 * 60;
    final diff = em - sm;
    return diff > 0 ? diff : 30;
  }

  static Future<void> ensureDefaultsIfEmpty({required String uid}) async {
    // 既にV2テンプレがある場合は何もしない
    final existing = RoutineTemplateV2Service.getAll(includeDeleted: true)
        .where((t) => t.userId == uid || t.userId.isEmpty)
        .toList();
    if (existing.isNotEmpty) return;

    final now = DateTime.now().toUtc();
    final deviceId = await DeviceInfoService.getDeviceId();

    Future<void> upsertTemplateAndSync(RoutineTemplateV2 tpl) async {
      final local = RoutineTemplateV2Service.getById(tpl.id);
      if (local == null) {
        await RoutineTemplateV2Service.add(tpl);
      } else {
        await RoutineTemplateV2Service.update(tpl);
      }
      try {
        await RoutineTemplateV2SyncService().uploadToFirebase(tpl);
        await RoutineTemplateV2Service.update(tpl);
      } catch (_) {}
    }

    Future<void> upsertBlockAndSync(RoutineBlockV2 block) async {
      final local = RoutineBlockV2Service.getById(block.id);
      if (local == null) {
        await RoutineBlockV2Service.add(block);
      } else {
        await RoutineBlockV2Service.update(block);
      }
      try {
        await RoutineBlockV2SyncService().uploadToFirebase(block);
        await RoutineBlockV2Service.update(block);
      } catch (_) {}
    }

    // --- Shortcut (予約ID) ---
    {
      final ver = await RoutineLamportClockService.next();
      final tpl = RoutineTemplateV2(
        id: shortcutTemplateId,
        title: '非定型ショートカット',
        memo: '',
        workType: WorkType.free,
        color: DomainColors.defaultHex,
        applyDayType: 'both',
        isActive: true,
        isDeleted: false,
        version: ver,
        deviceId: deviceId,
        userId: uid,
        createdAt: now,
        lastModified: now,
        isShortcut: true,
      )..cloudId = shortcutTemplateId;
      await upsertTemplateAndSync(tpl);

      final bVer = await RoutineLamportClockService.next();
      final block = RoutineBlockV2(
        id: shortcutBlockId,
        routineTemplateId: shortcutTemplateId,
        blockName: 'ショートカット',
        startTime: const TimeOfDay(hour: 0, minute: 0),
        endTime: const TimeOfDay(hour: 23, minute: 59),
        workingMinutes:
            _durationMinutes(const TimeOfDay(hour: 0, minute: 0), const TimeOfDay(hour: 23, minute: 59)),
        colorValue: null,
        order: 0,
        location: null,
        createdAt: now,
        lastModified: now,
        userId: uid,
        cloudId: shortcutBlockId,
        isDeleted: false,
        deviceId: deviceId,
        version: bVer,
      );
      await upsertBlockAndSync(block);
      // タスクは空でもOK（ユーザーが編集して追加する）
      try {
        await RoutineTaskV2SyncService().performSync(forceFullSync: false);
      } catch (_) {}
    }

    // --- Weekday ---
    {
      final ver = await RoutineLamportClockService.next();
      final tpl = RoutineTemplateV2(
        id: weekdayTemplateId,
        title: '平日ルーティン',
        memo: '',
        workType: WorkType.work,
        color: DomainColors.weekdayTemplateHex,
        applyDayType: 'weekday',
        isActive: true,
        isDeleted: false,
        version: ver,
        deviceId: deviceId,
        userId: uid,
        createdAt: now,
        lastModified: now,
        isShortcut: false,
      )..cloudId = weekdayTemplateId;
      await upsertTemplateAndSync(tpl);

      final defs = <({String id, String? name, TimeOfDay start, TimeOfDay end})>[
        (
          id: 'v2blk_${weekdayTemplateId}_morning',
          name: '朝',
          start: const TimeOfDay(hour: 6, minute: 0),
          end: const TimeOfDay(hour: 8, minute: 0),
        ),
        (
          id: 'v2blk_${weekdayTemplateId}_work',
          name: '仕事',
          start: const TimeOfDay(hour: 8, minute: 0),
          end: const TimeOfDay(hour: 17, minute: 0),
        ),
        (
          id: 'v2blk_${weekdayTemplateId}_evening',
          name: '夕方',
          start: const TimeOfDay(hour: 17, minute: 0),
          end: const TimeOfDay(hour: 22, minute: 0),
        ),
      ];
      for (int i = 0; i < defs.length; i++) {
        final d = defs[i];
        final bVer = await RoutineLamportClockService.next();
        final block = RoutineBlockV2(
          id: d.id,
          routineTemplateId: weekdayTemplateId,
          blockName: d.name,
          startTime: d.start,
          endTime: d.end,
          workingMinutes: _durationMinutes(d.start, d.end),
          colorValue: null,
          order: i,
          location: null,
          createdAt: now,
          lastModified: now,
          userId: uid,
          cloudId: d.id,
          isDeleted: false,
          deviceId: deviceId,
          version: bVer,
        );
        await upsertBlockAndSync(block);
      }
    }

    // --- Holiday ---
    {
      final ver = await RoutineLamportClockService.next();
      final tpl = RoutineTemplateV2(
        id: holidayTemplateId,
        title: '休日ルーティン',
        memo: '',
        workType: WorkType.free,
        color: DomainColors.holidayTemplateHex,
        applyDayType: 'holiday',
        isActive: true,
        isDeleted: false,
        version: ver,
        deviceId: deviceId,
        userId: uid,
        createdAt: now,
        lastModified: now,
        isShortcut: false,
      )..cloudId = holidayTemplateId;
      await upsertTemplateAndSync(tpl);

      final defs = <({String id, String? name, TimeOfDay start, TimeOfDay end})>[
        (
          id: 'v2blk_${holidayTemplateId}_morning',
          name: '朝',
          start: const TimeOfDay(hour: 7, minute: 0),
          end: const TimeOfDay(hour: 10, minute: 0),
        ),
        (
          id: 'v2blk_${holidayTemplateId}_afternoon',
          name: '午後',
          start: const TimeOfDay(hour: 13, minute: 0),
          end: const TimeOfDay(hour: 18, minute: 0),
        ),
      ];
      for (int i = 0; i < defs.length; i++) {
        final d = defs[i];
        final bVer = await RoutineLamportClockService.next();
        final block = RoutineBlockV2(
          id: d.id,
          routineTemplateId: holidayTemplateId,
          blockName: d.name,
          startTime: d.start,
          endTime: d.end,
          workingMinutes: _durationMinutes(d.start, d.end),
          colorValue: null,
          order: i,
          location: null,
          createdAt: now,
          lastModified: now,
          userId: uid,
          cloudId: d.id,
          isDeleted: false,
          deviceId: deviceId,
          version: bVer,
        );
        await upsertBlockAndSync(block);
      }
      await RoutineSleepBlockService.ensureSleepBlockForTemplate(holidayTemplateId);
    }

    // 仕上げ: V2ローカルの整合性が崩れていた場合に備え、タスク箱の整合も一度だけ行う
    // （タスク未作成なら何も起きない）
    try {
      await RoutineTaskV2Service.initialize();
    } catch (_) {}
  }
}

