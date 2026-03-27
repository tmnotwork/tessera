import 'package:hive/hive.dart';
import 'package:flutter/material.dart';
import 'syncable_model.dart';

part 'calendar_entry.g.dart';

@HiveType(typeId: 6)
class CalendarEntry extends HiveObject with SyncableModel {
  @HiveField(0)
  String id;

  @HiveField(1)
  DateTime date; // 日付

  @HiveField(2)
  String? routineTypeId; // ルーティンタイプID

  @HiveField(3)
  String color; // 色（hex文字列）

  @HiveField(4)
  bool isHoliday; // 休日フラグ

  @HiveField(5)
  bool isOff; // オフフラグ

  @HiveField(6)
  DateTime createdAt;

  @HiveField(7)
  @override
  DateTime lastModified;

  @HiveField(8)
  @override
  String userId;

  // 同期用フィールド
  @override
  @HiveField(9)
  String? cloudId;

  @override
  @HiveField(10)
  DateTime? lastSynced;

  @override
  @HiveField(11)
  bool isDeleted;

  @override
  @HiveField(12)
  String deviceId;

  @override
  @HiveField(13)
  int version;

  CalendarEntry({
    required this.id,
    required this.date,
    this.routineTypeId,
    required this.color,
    required this.isHoliday,
    required this.isOff,
    required this.createdAt,
    required this.lastModified,
    required this.userId,
    // 同期用フィールド
    this.cloudId,
    this.lastSynced,
    this.isDeleted = false,
    this.deviceId = '',
    this.version = 1,
  });

  // 色をColorオブジェクトとして取得
  Color get colorValue {
    return Color(int.parse(color, radix: 16));
  }

  // SyncableModel の実装
  @override
  Map<String, dynamic> toCloudJson() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'routineTypeId': routineTypeId,
      'color': color,
      'isHoliday': isHoliday,
      'isOff': isOff,
      'createdAt': createdAt.toIso8601String(),
      'lastModified': lastModified.toIso8601String(),
      'userId': userId,
      // NOTE:
      // lastSynced は端末ローカルの同期状態なのでクラウドへ送信しない。
      'isDeleted': isDeleted,
      'deviceId': deviceId,
      'version': version,
    };
  }

  // 従来のJSON変換メソッド（互換性のため保持）
  Map<String, dynamic> toJson() {
    return toCloudJson();
  }

  @override
  void fromCloudJson(Map<String, dynamic> json) {
    routineTypeId = json['routineTypeId'];
    color = json['color'] ?? color;
    isHoliday = json['isHoliday'] ?? isHoliday;
    isOff = json['isOff'] ?? isOff;

    if (json['date'] != null) {
      date = DateTime.parse(json['date']);
    }
    if (json['createdAt'] != null) {
      createdAt = DateTime.parse(json['createdAt']);
    }
    if (json['lastModified'] != null) {
      lastModified = DateTime.parse(json['lastModified']);
    }
    // lastSynced はローカル専用メタデータなので、クラウド由来では上書きしない。

    userId = json['userId'] ?? userId;
    isDeleted = json['isDeleted'] ?? isDeleted;
    deviceId = json['deviceId'] ?? deviceId;
    version = json['version'] ?? version;
  }

  @override
  bool hasConflictWith(SyncableModel other) {
    if (other is! CalendarEntry) return false;

    // CalendarEntry固有の競合チェック
    return lastModified != other.lastModified ||
        version != other.version ||
        date != other.date ||
        routineTypeId != other.routineTypeId ||
        color != other.color ||
        isHoliday != other.isHoliday ||
        isOff != other.isOff;
  }

  @override
  SyncableModel resolveConflictWith(SyncableModel other) {
    if (other is! CalendarEntry) return this;

    // Device-Based-Append戦略：異なる端末からの記録は両方保持
    if (deviceId != other.deviceId) {
      // 実際のフォーク（新IDで複製して保存）は同期層で実施済み。
      print(
          '🔄 Different device calendar entries detected: keep both (fork done in sync layer)');
      return this;
    }

    // 同じ端末からの場合は通常の時刻ベース解決
    if (other.lastModified.isAfter(lastModified)) {
      // リモートが新しい場合
      fromCloudJson(other.toCloudJson());
      version = other.version + 1;
      lastModified = DateTime.now();
    } else {
      // ローカルが新しい場合
      version++;
      lastModified = DateTime.now();
    }

    return this;
  }

  factory CalendarEntry.fromJson(Map<String, dynamic> json) {
    return CalendarEntry(
      id: json['id'],
      date: DateTime.parse(json['date']),
      routineTypeId: json['routineTypeId'],
      color: json['color'],
      isHoliday: json['isHoliday'] ?? false,
      isOff: json['isOff'] ?? false,
      createdAt: DateTime.parse(json['createdAt']),
      lastModified: json['lastModified'] != null
          ? DateTime.parse(json['lastModified'])
          : DateTime.now(),
      userId: json['userId'] ?? '',
      // 同期フィールド
      cloudId: json['cloudId'],
      // lastSynced はローカル専用メタデータなので、クラウドJSONからは復元しない。
      lastSynced: null,
      isDeleted: json['isDeleted'] ?? false,
      deviceId: json['deviceId'] ?? '',
      version: json['version'] ?? 1,
    );
  }

  // 日付が同じかチェック
  bool isSameDate(DateTime otherDate) {
    return date.year == otherDate.year &&
        date.month == otherDate.month &&
        date.day == otherDate.day;
  }

  // 日付の文字列表現
  String get dateString {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  // copyWithメソッド（同期フィールド対応）
  CalendarEntry copyWith({
    String? id,
    DateTime? date,
    String? routineTypeId,
    String? color,
    bool? isHoliday,
    bool? isOff,
    DateTime? createdAt,
    DateTime? lastModified,
    String? userId,
    // 同期用フィールド
    String? cloudId,
    DateTime? lastSynced,
    bool? isDeleted,
    String? deviceId,
    int? version,
  }) {
    return CalendarEntry(
      id: id ?? this.id,
      date: date ?? this.date,
      routineTypeId: routineTypeId ?? this.routineTypeId,
      color: color ?? this.color,
      isHoliday: isHoliday ?? this.isHoliday,
      isOff: isOff ?? this.isOff,
      createdAt: createdAt ?? this.createdAt,
      lastModified: lastModified ?? this.lastModified,
      userId: userId ?? this.userId,
      // 同期用フィールド
      cloudId: cloudId ?? this.cloudId,
      lastSynced: lastSynced ?? this.lastSynced,
      isDeleted: isDeleted ?? this.isDeleted,
      deviceId: deviceId ?? this.deviceId,
      version: version ?? this.version,
    );
  }
}
