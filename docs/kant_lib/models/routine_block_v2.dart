import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'syncable_model.dart';

@HiveType(typeId: 27)
class RoutineBlockV2 extends HiveObject with SyncableModel {
  @HiveField(0)
  String id;

  @HiveField(1)
  String routineTemplateId;

  // 表示名（空ならテンプレートや時間帯で補う）
  @HiveField(2)
  String? blockName;

  // 開始/終了（テンプレ内の想定時間帯）
  @HiveField(3)
  TimeOfDay startTime;
  @HiveField(4)
  TimeOfDay endTime;

  // 稼働時間（分）= ブロック内で実際に稼働すると想定する時間
  @HiveField(30)
  int workingMinutes;

  // 任意の表示色（null可）
  @HiveField(5)
  int? colorValue;

  // 並び順（テンプレート内）
  @HiveField(6)
  int order;

  // 任意の場所
  @HiveField(7)
  String? location;

  // 既定のプロジェクト/サブプロジェクト/モード
  @HiveField(16)
  String? projectId;

  @HiveField(17)
  String? subProjectId;

  @HiveField(18)
  String? subProject;

  @HiveField(19)
  String? modeId;

  /// レポート集計から除外する（= 自由時間以外の枠として扱う想定）
  @HiveField(31)
  bool excludeFromReport = false;

  /// 反映時に予定ブロックを「イベント」扱いにして通知を出すか
  @HiveField(32)
  bool isEvent = false;

  /// 詳細（補足説明）
  @HiveField(33)
  String? details;

  // 同期/監査フィールド
  @HiveField(8)
  DateTime createdAt;
  @override
  @HiveField(9)
  DateTime lastModified;
  @override
  @HiveField(10)
  String userId;

  // Syncable
  @override
  @HiveField(11)
  String? cloudId;
  @override
  @HiveField(12)
  DateTime? lastSynced;
  @override
  @HiveField(13)
  bool isDeleted;
  @override
  @HiveField(14)
  String deviceId;
  @override
  @HiveField(15)
  int version;

  RoutineBlockV2({
    required this.id,
    required this.routineTemplateId,
    this.blockName,
    required this.startTime,
    required this.endTime,
    int? workingMinutes,
    this.colorValue,
    this.order = 0,
    this.location,
    this.projectId,
    this.subProjectId,
    this.subProject,
    this.modeId,
    this.excludeFromReport = false,
    this.isEvent = false,
    this.details,
    required this.createdAt,
    required this.lastModified,
    required this.userId,
    this.cloudId,
    this.lastSynced,
    this.isDeleted = false,
    this.deviceId = '',
    this.version = 1,
  }) : workingMinutes = _normalizeRoutineWorkingMinutes(
          startTime,
          endTime,
          workingMinutes,
        );

  static DateTime _parseDateTime(dynamic raw) {
    if (raw == null) return DateTime.now().toUtc();
    try {
      // Firestore Timestamp 対応（取り込み側が正規化していない場合の保険）
      // ignore: avoid_dynamic_calls
      if (raw.runtimeType.toString() == 'Timestamp') {
        // ignore: avoid_dynamic_calls
        final dt = (raw as dynamic).toDate() as DateTime;
        return dt.toUtc();
      }
    } catch (_) {}
    if (raw is DateTime) return raw.toUtc();
    if (raw is String) {
      final dt = DateTime.tryParse(raw);
      if (dt != null) return dt.toUtc();
    }
    return DateTime.now().toUtc();
  }

  static int _parseInt(dynamic raw, {int fallback = 0}) {
    if (raw == null) return fallback;
    if (raw is int) return raw;
    if (raw is double) return raw.round();
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? fallback;
    return fallback;
  }

  Map<String, dynamic> toJson() {
    String fmt(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return {
      'id': id,
      'routineTemplateId': routineTemplateId,
      'blockName': blockName,
      'startTime': fmt(startTime),
      'endTime': fmt(endTime),
      'colorValue': colorValue,
      'order': order,
      'location': location,
      'projectId': projectId,
      'subProjectId': subProjectId,
      'subProject': subProject,
      'modeId': modeId,
      'workingMinutes': workingMinutes,
      'excludeFromReport': excludeFromReport,
      'isEvent': isEvent,
      'details': details,
      'createdAt': createdAt.toIso8601String(),
      'lastModified': lastModified.toIso8601String(),
      'userId': userId,
      'cloudId': cloudId,
      // NOTE:
      // lastSynced は端末ローカルの同期状態なのでクラウドへ送信しない。
      'isDeleted': isDeleted,
      'deviceId': deviceId,
      'version': version,
    };
  }

  factory RoutineBlockV2.fromJson(Map<String, dynamic> json) {
    TimeOfDay parseTime(dynamic raw) {
      if (raw is String) {
        final p = raw.split(':');
        if (p.length >= 2) {
          return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
        }
      }
      if (raw is Map) {
        try {
          final h = _parseInt(raw['hour'], fallback: 0);
          final m = _parseInt(raw['minute'], fallback: 0);
          return TimeOfDay(hour: h, minute: m);
        } catch (_) {}
      }
      // fallback
      return const TimeOfDay(hour: 0, minute: 0);
    }
    final parsedStart = parseTime(json['startTime']);
    final parsedEnd = parseTime(json['endTime']);
    final normalizedWorking = _normalizeRoutineWorkingMinutes(
      parsedStart,
      parsedEnd,
      _parseInt(json['workingMinutes'], fallback: 0),
    );
    return RoutineBlockV2(
      id: (json['id'] as String?) ?? '',
      routineTemplateId: (json['routineTemplateId'] as String?) ?? '',
      blockName: json['blockName'] as String?,
      startTime: parsedStart,
      endTime: parsedEnd,
      workingMinutes: normalizedWorking,
      colorValue: _parseInt(json['colorValue'], fallback: 0),
      order: _parseInt(json['order'], fallback: 0),
      location: json['location'] as String?,
      projectId: json['projectId'] as String?,
      subProjectId: json['subProjectId'] as String?,
      subProject: json['subProject'] as String?,
      modeId: json['modeId'] as String?,
      excludeFromReport: (json['excludeFromReport'] as bool?) ?? false,
      isEvent: (json['isEvent'] as bool?) ?? false,
      details: json['details'] as String?,
      createdAt: _parseDateTime(json['createdAt']),
      lastModified: _parseDateTime(json['lastModified']),
      userId: (json['userId'] as String?) ?? '',
      cloudId: json['cloudId'] as String?,
      // lastSynced はローカル専用メタデータなので、クラウドJSONからは復元しない。
      lastSynced: null,
      isDeleted: (json['isDeleted'] as bool?) ?? false,
      deviceId: (json['deviceId'] as String?) ?? '',
      version: _parseInt(json['version'], fallback: 1),
    );
  }

  @override
  Map<String, dynamic> toCloudJson() => toJson();

  @override
  void fromCloudJson(Map<String, dynamic> json) {
    if (json.containsKey('blockName')) blockName = json['blockName'] as String?;
    if (json.containsKey('startTime')) {
      final raw = json['startTime'];
      if (raw is String) {
        final p = raw.split(':');
        if (p.length >= 2) {
          startTime = TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
        }
      }
    }
    if (json.containsKey('endTime')) {
      final raw = json['endTime'];
      if (raw is String) {
        final p = raw.split(':');
        if (p.length >= 2) {
          endTime = TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
        }
      }
    }
    colorValue = json['colorValue'] is int ? json['colorValue'] as int : colorValue;
    if (json.containsKey('order')) order = _parseInt(json['order'], fallback: order);
    if (json.containsKey('location')) location = json['location'] as String?;
    if (json.containsKey('projectId')) projectId = json['projectId'] as String?;
    if (json.containsKey('subProjectId')) {
      subProjectId = json['subProjectId'] as String?;
    }
    if (json.containsKey('subProject')) {
      subProject = json['subProject'] as String?;
    }
    if (json.containsKey('modeId')) modeId = json['modeId'] as String?;
    if (json.containsKey('excludeFromReport')) {
      excludeFromReport = json['excludeFromReport'] == true;
    }
    if (json.containsKey('isEvent')) {
      isEvent = json['isEvent'] == true;
    }
    if (json.containsKey('details')) {
      details = json['details'] as String?;
    }
    workingMinutes = _normalizeRoutineWorkingMinutes(
      startTime,
      endTime,
      json.containsKey('workingMinutes')
          ? _parseInt(json['workingMinutes'], fallback: workingMinutes)
          : workingMinutes,
    );
    if (json['createdAt'] != null) {
      createdAt = _parseDateTime(json['createdAt']);
    }
    if (json['lastModified'] != null) {
      lastModified = _parseDateTime(json['lastModified']);
    }
    // lastSynced はローカル専用メタデータなので、クラウド由来では上書きしない。
    userId = (json['userId'] as String?) ?? userId;
    isDeleted = (json['isDeleted'] as bool?) ?? isDeleted;
    deviceId = (json['deviceId'] as String?) ?? deviceId;
    version = _parseInt(json['version'], fallback: version);
  }

  @override
  bool hasConflictWith(SyncableModel other) {
    if (other is! RoutineBlockV2) return false;
    return lastModified != other.lastModified ||
        version != other.version ||
        blockName != other.blockName ||
        startTime != other.startTime ||
        endTime != other.endTime ||
        (colorValue ?? 0) != (other.colorValue ?? 0) ||
        order != other.order ||
        (location ?? '') != (other.location ?? '') ||
        (projectId ?? '') != (other.projectId ?? '') ||
        (subProjectId ?? '') != (other.subProjectId ?? '') ||
        (subProject ?? '') != (other.subProject ?? '') ||
        (modeId ?? '') != (other.modeId ?? '') ||
        workingMinutes != other.workingMinutes ||
        excludeFromReport != other.excludeFromReport ||
        isEvent != other.isEvent ||
        (details ?? '') != (other.details ?? '');
  }

  @override
  SyncableModel resolveConflictWith(SyncableModel other) {
    if (other is! RoutineBlockV2) return this;
    if (other.lastModified.isAfter(lastModified)) {
      blockName = other.blockName;
      startTime = other.startTime;
      endTime = other.endTime;
      colorValue = other.colorValue;
      order = other.order;
      location = other.location;
      projectId = other.projectId;
      subProjectId = other.subProjectId;
      subProject = other.subProject;
      modeId = other.modeId;
      workingMinutes = other.workingMinutes;
      excludeFromReport = other.excludeFromReport;
      isEvent = other.isEvent;
      details = other.details;
      lastModified = other.lastModified;
      version = other.version;
    } else {
      // keep local, bump version minimally
      version = version + 1;
      lastModified = DateTime.now().toUtc();
    }
    return this;
  }

  /// 省略時は現状維持。null を渡すとそのフィールドを null にクリアする。
  static const _omit = Object();

  RoutineBlockV2 copyWith({
    String? id,
    String? routineTemplateId,
    Object? blockName = _omit,
    TimeOfDay? startTime,
    TimeOfDay? endTime,
    int? workingMinutes,
    int? colorValue,
    int? order,
    Object? location = _omit,
    Object? projectId = _omit,
    Object? subProjectId = _omit,
    Object? subProject = _omit,
    Object? modeId = _omit,
    bool? excludeFromReport,
    bool? isEvent,
    Object? details = _omit,
    DateTime? createdAt,
    DateTime? lastModified,
    String? userId,
    String? cloudId,
    DateTime? lastSynced,
    bool? isDeleted,
    String? deviceId,
    int? version,
  }) {
    final nextStart = startTime ?? this.startTime;
    final nextEnd = endTime ?? this.endTime;
    return RoutineBlockV2(
      id: id ?? this.id,
      routineTemplateId: routineTemplateId ?? this.routineTemplateId,
      blockName: blockName == _omit ? this.blockName : blockName as String?,
      startTime: nextStart,
      endTime: nextEnd,
      workingMinutes: _normalizeRoutineWorkingMinutes(
        nextStart,
        nextEnd,
        workingMinutes ?? this.workingMinutes,
      ),
      colorValue: colorValue ?? this.colorValue,
      order: order ?? this.order,
      location: location == _omit ? this.location : location as String?,
      projectId: projectId == _omit ? this.projectId : projectId as String?,
      subProjectId: subProjectId == _omit ? this.subProjectId : subProjectId as String?,
      subProject: subProject == _omit ? this.subProject : subProject as String?,
      modeId: modeId == _omit ? this.modeId : modeId as String?,
      excludeFromReport: excludeFromReport ?? this.excludeFromReport,
      isEvent: isEvent ?? this.isEvent,
      details: details == _omit ? this.details : details as String?,
      createdAt: createdAt ?? this.createdAt,
      lastModified: lastModified ?? this.lastModified,
      userId: userId ?? this.userId,
      cloudId: cloudId ?? this.cloudId,
      lastSynced: lastSynced ?? this.lastSynced,
      isDeleted: isDeleted ?? this.isDeleted,
      deviceId: deviceId ?? this.deviceId,
      version: version ?? this.version,
    );
  }
}

// ===== Manual Hive Adapter (no codegen required) =====
class RoutineBlockV2Adapter extends TypeAdapter<RoutineBlockV2> {
  @override
  final int typeId = 27;

  @override
  RoutineBlockV2 read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    TimeOfDay _parseTod(String s) {
      final p = (s).split(':');
      return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
    }
    return RoutineBlockV2(
      id: fields[0] as String,
      routineTemplateId: fields[1] as String,
      blockName: fields[2] as String?,
      startTime: _parseTod(fields[3] as String),
      endTime: _parseTod(fields[4] as String),
      workingMinutes: fields.containsKey(30) ? fields[30] as int? : null,
      colorValue: fields[5] as int?,
      order: fields[6] as int? ?? 0,
      location: fields[7] as String?,
      projectId: fields[16] as String?,
      subProjectId: fields[17] as String?,
      subProject: fields[18] as String?,
      modeId: fields[19] as String?,
      excludeFromReport:
          (fields.containsKey(31) ? (fields[31] as bool?) : null) ?? false,
      isEvent: (fields.containsKey(32) ? (fields[32] as bool?) : null) ?? false,
      details: fields.containsKey(33) ? fields[33] as String? : null,
      createdAt: fields[8] as DateTime,
      lastModified: fields[9] as DateTime,
      userId: fields[10] as String,
      cloudId: fields[11] as String?,
      lastSynced: fields[12] as DateTime?,
      isDeleted: fields[13] as bool? ?? false,
      deviceId: fields[14] as String? ?? '',
      version: fields[15] as int? ?? 1,
    );
  }

  @override
  void write(BinaryWriter writer, RoutineBlockV2 obj) {
    String fmt(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    writer
      ..writeByte(23)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.routineTemplateId)
      ..writeByte(2)
      ..write(obj.blockName)
      ..writeByte(3)
      ..write(fmt(obj.startTime))
      ..writeByte(4)
      ..write(fmt(obj.endTime))
      ..writeByte(30)
      ..write(obj.workingMinutes)
      ..writeByte(5)
      ..write(obj.colorValue)
      ..writeByte(6)
      ..write(obj.order)
      ..writeByte(7)
      ..write(obj.location)
      ..writeByte(16)
      ..write(obj.projectId)
      ..writeByte(17)
      ..write(obj.subProjectId)
      ..writeByte(18)
      ..write(obj.subProject)
      ..writeByte(19)
      ..write(obj.modeId)
      ..writeByte(31)
      ..write(obj.excludeFromReport)
      ..writeByte(32)
      ..write(obj.isEvent)
      ..writeByte(33)
      ..write(obj.details)
      ..writeByte(8)
      ..write(obj.createdAt)
      ..writeByte(9)
      ..write(obj.lastModified)
      ..writeByte(10)
      ..write(obj.userId)
      ..writeByte(11)
      ..write(obj.cloudId)
      ..writeByte(12)
      ..write(obj.lastSynced)
      ..writeByte(13)
      ..write(obj.isDeleted)
      ..writeByte(14)
      ..write(obj.deviceId)
      ..writeByte(15)
      ..write(obj.version);
  }
}

int _routineMinutesBetween(TimeOfDay start, TimeOfDay end) {
  final startMinutes = start.hour * 60 + start.minute;
  final endMinutes = end.hour * 60 + end.minute;
  int diff = endMinutes - startMinutes;
  if (diff <= 0) {
    diff += 24 * 60;
  }
  return diff;
}

int _normalizeRoutineWorkingMinutes(
    TimeOfDay start, TimeOfDay end, int? workingMinutes) {
  final total = _routineMinutesBetween(start, end);
  if (workingMinutes == null) return total;
  if (workingMinutes < 0) return 0;
  if (workingMinutes > total) return total;
  return workingMinutes;
}
