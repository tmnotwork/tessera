import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'syncable_model.dart';

@HiveType(typeId: 28)
class RoutineTaskV2 extends HiveObject with SyncableModel {
  @HiveField(0)
  String id;

  // 所属
  @HiveField(1)
  String routineTemplateId;
  @HiveField(2)
  String routineBlockId;

  @HiveField(3)
  String name;

  // 推定作業時間（分）
  @HiveField(4)
  int estimatedDuration;

  @HiveField(5)
  String? projectId;
  @HiveField(6)
  String? subProjectId;
  @HiveField(7)
  String? subProject; // 表示用

  @HiveField(8)
  String? modeId;

  @HiveField(9)
  String? details;
  @HiveField(10)
  String? memo;
  @HiveField(11)
  String? location;

  /// legacy互換（特にショートカット）: タスク単位のブロック名
  /// - RoutineBlockV2.blockName とは別の「行ごとのラベル」として扱う
  @HiveField(21)
  String? blockName;

  /// 反映時に予定ブロックを「イベント」扱いにして通知を出すか
  @HiveField(22)
  bool isEvent;

  @HiveField(12)
  int order; // ブロック内の並び順

  // 監査/同期
  @HiveField(13)
  DateTime createdAt;
  @override
  @HiveField(14)
  DateTime lastModified;
  @override
  @HiveField(15)
  String userId;

  @override
  @HiveField(16)
  String? cloudId;
  @override
  @HiveField(17)
  DateTime? lastSynced;
  @override
  @HiveField(18)
  bool isDeleted;
  @override
  @HiveField(19)
  String deviceId;
  @override
  @HiveField(20)
  int version;

  RoutineTaskV2({
    required this.id,
    required this.routineTemplateId,
    required this.routineBlockId,
    required this.name,
    required this.estimatedDuration,
    this.projectId,
    this.subProjectId,
    this.subProject,
    this.modeId,
    this.details,
    this.memo,
    this.location,
    this.blockName,
    this.isEvent = false,
    this.order = 0,
    required this.createdAt,
    required this.lastModified,
    required this.userId,
    this.cloudId,
    this.lastSynced,
    this.isDeleted = false,
    this.deviceId = '',
    this.version = 1,
  });

  static int _parseInt(dynamic raw, {int fallback = 0}) {
    if (raw == null) return fallback;
    if (raw is int) return raw;
    if (raw is double) return raw.round();
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? fallback;
    return fallback;
  }

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

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'routineTemplateId': routineTemplateId,
      'routineBlockId': routineBlockId,
      'name': name,
      'estimatedDuration': estimatedDuration,
      'projectId': projectId,
      'subProjectId': subProjectId,
      'subProject': subProject,
      'modeId': modeId,
      'details': details,
      'memo': memo,
      'location': location,
      'blockName': blockName,
      'isEvent': isEvent,
      'order': order,
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

  factory RoutineTaskV2.fromJson(Map<String, dynamic> json) {
    return RoutineTaskV2(
      id: (json['id'] as String?) ?? '',
      routineTemplateId: (json['routineTemplateId'] as String?) ?? '',
      routineBlockId: (json['routineBlockId'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      estimatedDuration: _parseInt(json['estimatedDuration'], fallback: 0),
      projectId: json['projectId'] as String?,
      subProjectId: json['subProjectId'] as String?,
      subProject: json['subProject'] as String?,
      modeId: json['modeId'] as String?,
      details: json['details'] as String?,
      memo: json['memo'] as String?,
      location: json['location'] as String?,
      blockName: json['blockName'] as String?,
      isEvent: (json['isEvent'] as bool?) ?? false,
      order: _parseInt(json['order'], fallback: 0),
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
    if (json.containsKey('name')) name = (json['name'] as String?) ?? name;
    if (json.containsKey('estimatedDuration')) {
      estimatedDuration =
          _parseInt(json['estimatedDuration'], fallback: estimatedDuration);
    }
    projectId = json['projectId'] as String? ?? projectId;
    subProjectId = json['subProjectId'] as String? ?? subProjectId;
    subProject = json['subProject'] as String? ?? subProject;
    modeId = json['modeId'] as String? ?? modeId;
    details = json['details'] as String? ?? details;
    memo = json['memo'] as String? ?? memo;
    if (json.containsKey('location')) location = json['location'] as String?;
    if (json.containsKey('blockName')) blockName = json['blockName'] as String?;
    if (json.containsKey('isEvent')) isEvent = (json['isEvent'] as bool?) ?? false;
    if (json.containsKey('order')) {
      order = _parseInt(json['order'], fallback: order);
    }
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
    if (other is! RoutineTaskV2) return false;
    return lastModified != other.lastModified ||
        version != other.version ||
        name != other.name ||
        estimatedDuration != other.estimatedDuration ||
        (projectId ?? '') != (other.projectId ?? '') ||
        (subProjectId ?? '') != (other.subProjectId ?? '') ||
        (subProject ?? '') != (other.subProject ?? '') ||
        (modeId ?? '') != (other.modeId ?? '') ||
        (details ?? '') != (other.details ?? '') ||
        (memo ?? '') != (other.memo ?? '') ||
        (location ?? '') != (other.location ?? '') ||
        (blockName ?? '') != (other.blockName ?? '') ||
        isEvent != other.isEvent ||
        order != other.order;
  }

  @override
  SyncableModel resolveConflictWith(SyncableModel other) {
    if (other is! RoutineTaskV2) return this;
    if (other.lastModified.isAfter(lastModified)) {
      name = other.name;
      estimatedDuration = other.estimatedDuration;
      projectId = other.projectId;
      subProjectId = other.subProjectId;
      subProject = other.subProject;
      modeId = other.modeId;
      details = other.details;
      memo = other.memo;
      location = other.location;
      blockName = other.blockName;
      isEvent = other.isEvent;
      order = other.order;
      lastModified = other.lastModified;
      version = other.version;
    } else {
      version = version + 1;
      lastModified = DateTime.now().toUtc();
    }
    return this;
  }

  RoutineTaskV2 copyWith({
    String? id,
    String? routineTemplateId,
    String? routineBlockId,
    String? name,
    int? estimatedDuration,
    String? projectId,
    String? subProjectId,
    String? subProject,
    String? modeId,
    String? details,
    String? memo,
    String? location,
    String? blockName,
    bool? isEvent,
    int? order,
    DateTime? createdAt,
    DateTime? lastModified,
    String? userId,
    String? cloudId,
    DateTime? lastSynced,
    bool? isDeleted,
    String? deviceId,
    int? version,
  }) {
    return RoutineTaskV2(
      id: id ?? this.id,
      routineTemplateId: routineTemplateId ?? this.routineTemplateId,
      routineBlockId: routineBlockId ?? this.routineBlockId,
      name: name ?? this.name,
      estimatedDuration: estimatedDuration ?? this.estimatedDuration,
      projectId: projectId ?? this.projectId,
      subProjectId: subProjectId ?? this.subProjectId,
      subProject: subProject ?? this.subProject,
      modeId: modeId ?? this.modeId,
      details: details ?? this.details,
      memo: memo ?? this.memo,
      location: location ?? this.location,
      blockName: blockName ?? this.blockName,
      isEvent: isEvent ?? this.isEvent,
      order: order ?? this.order,
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
class RoutineTaskV2Adapter extends TypeAdapter<RoutineTaskV2> {
  @override
  final int typeId = 28;

  @override
  RoutineTaskV2 read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    return RoutineTaskV2(
      id: fields[0] as String,
      routineTemplateId: fields[1] as String,
      routineBlockId: fields[2] as String,
      name: fields[3] as String,
      estimatedDuration: fields[4] as int,
      projectId: fields[5] as String?,
      subProjectId: fields[6] as String?,
      subProject: fields[7] as String?,
      modeId: fields[8] as String?,
      details: fields[9] as String?,
      memo: fields[10] as String?,
      location: fields[11] as String?,
      blockName: fields[21] as String?,
      isEvent: fields[22] as bool? ?? false,
      order: fields[12] as int? ?? 0,
      createdAt: fields[13] as DateTime,
      lastModified: fields[14] as DateTime,
      userId: fields[15] as String,
      cloudId: fields[16] as String?,
      lastSynced: fields[17] as DateTime?,
      isDeleted: fields[18] as bool? ?? false,
      deviceId: fields[19] as String? ?? '',
      version: fields[20] as int? ?? 1,
    );
  }

  @override
  void write(BinaryWriter writer, RoutineTaskV2 obj) {
    writer
      ..writeByte(23)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.routineTemplateId)
      ..writeByte(2)
      ..write(obj.routineBlockId)
      ..writeByte(3)
      ..write(obj.name)
      ..writeByte(4)
      ..write(obj.estimatedDuration)
      ..writeByte(5)
      ..write(obj.projectId)
      ..writeByte(6)
      ..write(obj.subProjectId)
      ..writeByte(7)
      ..write(obj.subProject)
      ..writeByte(8)
      ..write(obj.modeId)
      ..writeByte(9)
      ..write(obj.details)
      ..writeByte(10)
      ..write(obj.memo)
      ..writeByte(11)
      ..write(obj.location)
      ..writeByte(12)
      ..write(obj.order)
      ..writeByte(13)
      ..write(obj.createdAt)
      ..writeByte(14)
      ..write(obj.lastModified)
      ..writeByte(15)
      ..write(obj.userId)
      ..writeByte(16)
      ..write(obj.cloudId)
      ..writeByte(17)
      ..write(obj.lastSynced)
      ..writeByte(18)
      ..write(obj.isDeleted)
      ..writeByte(19)
      ..write(obj.deviceId)
      ..writeByte(20)
      ..write(obj.version)
      ..writeByte(21)
      ..write(obj.blockName)
      ..writeByte(22)
      ..write(obj.isEvent);
  }
}
