import 'package:flutter/material.dart';

import 'routine_task_v2.dart';

/// CSV 入出力・ショートカット表など用の **表示行**（Hive ではない）。
///
/// CSV 列意味は従来のルーティンタスク行と同一で、UI から永続モデル（V2）を直接露出しない。
/// 時刻・モード等は既存ウィジェット互換のため **ミュータブル**。
class RoutineShortcutTaskRow {
  String id;
  String name;
  String? projectId;
  TimeOfDay startTime;
  TimeOfDay endTime;
  String? details;
  String? memo;
  String? subProjectId;
  String? subProject;
  String? modeId;
  String? blockName;
  String routineTemplateId;
  String timeZoneId;
  DateTime createdAt;
  DateTime lastModified;
  String userId;
  String? cloudId;
  DateTime? lastSynced;
  bool isDeleted;
  String deviceId;
  int version;
  String? location;

  RoutineShortcutTaskRow({
    required this.id,
    required this.name,
    this.projectId,
    required this.startTime,
    required this.endTime,
    this.details,
    this.memo,
    this.subProjectId,
    this.subProject,
    this.modeId,
    this.blockName,
    required this.routineTemplateId,
    required this.timeZoneId,
    required this.createdAt,
    required this.lastModified,
    required this.userId,
    this.cloudId,
    this.lastSynced,
    this.isDeleted = false,
    this.deviceId = '',
    this.version = 1,
    this.location,
  });

  /// ショートカット等: V2 から表示行へ（時刻はダミー可）。
  factory RoutineShortcutTaskRow.fromV2(
    RoutineTaskV2 t, {
    TimeOfDay startTime = const TimeOfDay(hour: 0, minute: 0),
    TimeOfDay endTime = const TimeOfDay(hour: 0, minute: 0),
    String? routineTemplateId,
    String? timeZoneId,
    String? blockName,
  }) {
    return RoutineShortcutTaskRow(
      id: t.id,
      name: t.name,
      projectId: t.projectId,
      startTime: startTime,
      endTime: endTime,
      details: t.details,
      memo: t.memo,
      subProjectId: t.subProjectId,
      subProject: t.subProject,
      modeId: t.modeId,
      blockName: blockName ?? t.blockName,
      routineTemplateId: routineTemplateId ?? t.routineTemplateId,
      timeZoneId: timeZoneId ?? t.routineBlockId,
      createdAt: t.createdAt,
      lastModified: t.lastModified,
      userId: t.userId,
      cloudId: t.cloudId,
      lastSynced: t.lastSynced,
      isDeleted: t.isDeleted,
      deviceId: t.deviceId,
      version: t.version,
      location: t.location,
    );
  }
}
