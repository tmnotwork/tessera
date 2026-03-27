import 'package:hive/hive.dart';

import 'syncable_model.dart';
import 'work_type.dart';

/// V2のルーティンテンプレート（Single Source of Truth 用）
///
/// - Firestore: users/{uid}/routine_templates_v2/{templateId}
/// - Local Hive: routine_templates_v2
@HiveType(typeId: 29)
class RoutineTemplateV2 extends HiveObject with SyncableModel {
  @HiveField(0)
  String id;

  @HiveField(1)
  String title;

  @HiveField(2)
  String memo;

  @HiveField(3)
  WorkType workType;

  /// HEX文字列（既存のlegacyテンプレと同等の表現）
  @HiveField(4)
  String color;

  /// "weekday" / "holiday" / "both" / "dow:1,2,3..."
  @HiveField(5)
  String applyDayType;

  @HiveField(6)
  bool isActive;

  // --- SyncableModel ---
  @override
  @HiveField(7)
  String? cloudId;

  @override
  @HiveField(8)
  DateTime? lastSynced;

  @override
  @HiveField(9)
  bool isDeleted;

  @override
  @HiveField(10)
  String deviceId;

  @override
  @HiveField(11)
  int version;

  @override
  @HiveField(12)
  String userId;

  @HiveField(13)
  DateTime createdAt;

  @override
  @HiveField(14)
  DateTime lastModified;

  /// 既存のショートカット判定・互換のため保持（V2では予約ID shortcut を推奨）
  @HiveField(15)
  bool isShortcut;

  RoutineTemplateV2({
    required this.id,
    required this.title,
    this.memo = '',
    this.workType = WorkType.free,
    required this.color,
    this.applyDayType = 'weekday',
    this.isActive = true,
    this.cloudId,
    this.lastSynced,
    this.isDeleted = false,
    this.deviceId = '',
    this.version = 1,
    this.userId = '',
    required this.createdAt,
    required this.lastModified,
    this.isShortcut = false,
  });

  // ---- JSON / Cloud ----
  static String _isoUtc(DateTime dt) => dt.toUtc().toIso8601String();

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
      'title': title,
      'memo': memo,
      'workType': workType.index,
      'color': color,
      'applyDayType': applyDayType,
      'isActive': isActive,
      'isDeleted': isDeleted,
      'version': version,
      'deviceId': deviceId,
      'userId': userId,
      'createdAt': _isoUtc(createdAt),
      'lastModified': _isoUtc(lastModified),
      // NOTE:
      // lastSynced は端末ローカルの同期状態なのでクラウドへ送信しない。
      'isShortcut': isShortcut,
    };
  }

  factory RoutineTemplateV2.fromJson(Map<String, dynamic> json) {
    int workTypeIdx = 1;
    try {
      final raw = json['workType'];
      if (raw is int) workTypeIdx = raw;
      if (raw is String) workTypeIdx = int.tryParse(raw) ?? workTypeIdx;
    } catch (_) {}
    WorkType wt = WorkType.free;
    if (workTypeIdx == 0) wt = WorkType.work;
    if (workTypeIdx == 1) wt = WorkType.free;

    return RoutineTemplateV2(
      id: (json['id'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      memo: (json['memo'] as String?) ?? '',
      workType: wt,
      color: (json['color'] as String?) ?? '',
      applyDayType: (json['applyDayType'] as String?) ?? 'weekday',
      isActive: (json['isActive'] as bool?) ?? true,
      isDeleted: (json['isDeleted'] as bool?) ?? false,
      version: _parseInt(json['version'], fallback: 1),
      deviceId: (json['deviceId'] as String?) ?? '',
      userId: (json['userId'] as String?) ?? '',
      createdAt: _parseDateTime(json['createdAt']),
      lastModified: _parseDateTime(json['lastModified']),
      // lastSynced はローカル専用メタデータなので、クラウドJSONからは復元しない。
      lastSynced: null,
      isShortcut: (json['isShortcut'] as bool?) ?? false,
      cloudId: json['cloudId'] as String?,
    );
  }

  @override
  Map<String, dynamic> toCloudJson() => toJson();

  @override
  void fromCloudJson(Map<String, dynamic> json) {
    if (json.containsKey('title')) title = (json['title'] as String?) ?? title;
    if (json.containsKey('memo')) memo = (json['memo'] as String?) ?? memo;
    if (json.containsKey('workType')) {
      try {
        final raw = json['workType'];
        int idx = workType.index;
        if (raw is int) idx = raw;
        if (raw is String) idx = int.tryParse(raw) ?? idx;
        workType = idx == 0 ? WorkType.work : WorkType.free;
      } catch (_) {}
    }
    if (json.containsKey('color')) color = (json['color'] as String?) ?? color;
    if (json.containsKey('applyDayType')) {
      applyDayType = (json['applyDayType'] as String?) ?? applyDayType;
    }
    if (json.containsKey('isActive')) {
      isActive = (json['isActive'] as bool?) ?? isActive;
    }

    if (json.containsKey('createdAt')) createdAt = _parseDateTime(json['createdAt']);
    if (json.containsKey('lastModified')) {
      lastModified = _parseDateTime(json['lastModified']);
    }
    // lastSynced はローカル専用メタデータなので、クラウド由来では上書きしない。
    if (json.containsKey('userId')) userId = (json['userId'] as String?) ?? userId;
    if (json.containsKey('isDeleted')) {
      isDeleted = (json['isDeleted'] as bool?) ?? isDeleted;
    }
    if (json.containsKey('deviceId')) deviceId = (json['deviceId'] as String?) ?? deviceId;
    if (json.containsKey('version')) {
      version = _parseInt(json['version'], fallback: version);
    }
    if (json.containsKey('isShortcut')) {
      isShortcut = (json['isShortcut'] as bool?) ?? isShortcut;
    }
    // 正規ショートカットはドキュメントID固定。クラウドJSONに isShortcut が無い旧データでも編集画面とFABが一致するよう補正。
    if (id == 'shortcut' || cloudId == 'shortcut') {
      isShortcut = true;
    }
  }

  @override
  bool hasConflictWith(SyncableModel other) {
    if (other is! RoutineTemplateV2) return false;
    return lastModified != other.lastModified ||
        version != other.version ||
        isDeleted != other.isDeleted ||
        title != other.title ||
        memo != other.memo ||
        workType != other.workType ||
        color != other.color ||
        applyDayType != other.applyDayType ||
        isActive != other.isActive ||
        isShortcut != other.isShortcut;
  }

  @override
  SyncableModel resolveConflictWith(SyncableModel other) {
    // 競合解決の主因は version+deviceId を前提に ConflictDetector が行う。
    // ここでは “より新しいものを採用” の保険として lastModified を用いる。
    if (other is! RoutineTemplateV2) return this;
    if (other.lastModified.isAfter(lastModified)) {
      fromCloudJson(other.toCloudJson());
    }
    return this;
  }
}

// ===== Manual Hive Adapter (no codegen required) =====
class RoutineTemplateV2Adapter extends TypeAdapter<RoutineTemplateV2> {
  @override
  final int typeId = 29;

  @override
  RoutineTemplateV2 read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    final workTypeIdx = fields[3] as int? ?? 1;
    final wt = workTypeIdx == 0 ? WorkType.work : WorkType.free;
    return RoutineTemplateV2(
      id: fields[0] as String,
      title: fields[1] as String,
      memo: fields[2] as String? ?? '',
      workType: wt,
      color: fields[4] as String? ?? '',
      applyDayType: fields[5] as String? ?? 'weekday',
      isActive: fields[6] as bool? ?? true,
      cloudId: fields[7] as String?,
      lastSynced: fields[8] as DateTime?,
      isDeleted: fields[9] as bool? ?? false,
      deviceId: fields[10] as String? ?? '',
      version: fields[11] as int? ?? 1,
      userId: fields[12] as String? ?? '',
      createdAt: fields[13] as DateTime,
      lastModified: fields[14] as DateTime,
      isShortcut: fields[15] as bool? ?? false,
    );
  }

  @override
  void write(BinaryWriter writer, RoutineTemplateV2 obj) {
    writer
      ..writeByte(16)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.memo)
      ..writeByte(3)
      ..write(obj.workType.index)
      ..writeByte(4)
      ..write(obj.color)
      ..writeByte(5)
      ..write(obj.applyDayType)
      ..writeByte(6)
      ..write(obj.isActive)
      ..writeByte(7)
      ..write(obj.cloudId)
      ..writeByte(8)
      ..write(obj.lastSynced)
      ..writeByte(9)
      ..write(obj.isDeleted)
      ..writeByte(10)
      ..write(obj.deviceId)
      ..writeByte(11)
      ..write(obj.version)
      ..writeByte(12)
      ..write(obj.userId)
      ..writeByte(13)
      ..write(obj.createdAt)
      ..writeByte(14)
      ..write(obj.lastModified)
      ..writeByte(15)
      ..write(obj.isShortcut);
  }
}

