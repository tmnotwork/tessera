import 'package:hive/hive.dart';
import 'syncable_model.dart';

part 'mode.g.dart';

@HiveType(typeId: 4)
class Mode extends HiveObject with SyncableModel {
  @HiveField(0)
  String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  String? description;

  @HiveField(3)
  @override
  String userId;

  @HiveField(4)
  DateTime createdAt;

  @HiveField(5)
  @override
  DateTime lastModified;

  @HiveField(6)
  bool isActive;

  // 同期用フィールド
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

  Mode({
    required this.id,
    required this.name,
    this.description,
    required this.userId,
    required this.createdAt,
    required this.lastModified,
    this.isActive = true,
    // 同期用フィールド
    this.cloudId,
    this.lastSynced,
    this.isDeleted = false,
    this.deviceId = '',
    this.version = 1,
  });

  // SyncableModel の実装
  @override
  Map<String, dynamic> toCloudJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'userId': userId,
      'createdAt': createdAt.toIso8601String(),
      'lastModified': lastModified.toIso8601String(),
      'isActive': isActive,
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
    name = json['name'] ?? name;
    description = json['description'];
    isActive = json['isActive'] ?? isActive;

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
    if (other is! Mode) return false;

    // Mode固有の競合チェック
    return lastModified != other.lastModified ||
        version != other.version ||
        name != other.name ||
        description != other.description ||
        isActive != other.isActive;
  }

  @override
  SyncableModel resolveConflictWith(SyncableModel other) {
    if (other is! Mode) return this;

    // Last-Write-Wins戦略：設定データの最新優先
    if (other.lastModified.isAfter(lastModified)) {
      // リモートが新しい場合
      name = other.name;
      description = other.description;
      isActive = other.isActive;

      // メタデータ更新
      version = other.version + 1;
      lastModified = DateTime.now();
    } else {
      // ローカルが新しい場合
      version++;
      lastModified = DateTime.now();
    }

    return this;
  }

  factory Mode.fromJson(Map<String, dynamic> json) {
    return Mode(
      id: json['id'],
      name: json['name'],
      description: json['description'],
      userId: json['userId'] ?? '',
      createdAt: DateTime.parse(json['createdAt']),
      lastModified: json['lastModified'] != null
          ? DateTime.parse(json['lastModified'])
          : DateTime.now(),
      isActive: json['isActive'] ?? true,
      // 同期フィールド
      cloudId: json['cloudId'],
      // lastSynced はローカル専用メタデータなので、クラウドJSONからは復元しない。
      lastSynced: null,
      isDeleted: json['isDeleted'] ?? false,
      deviceId: json['deviceId'] ?? '',
      version: json['version'] ?? 1,
    );
  }

  // コピーメソッド（同期フィールド対応）
  Mode copyWith({
    String? id,
    String? name,
    String? description,
    String? userId,
    DateTime? createdAt,
    DateTime? lastModified,
    bool? isActive,
    // 同期フィールド
    String? cloudId,
    DateTime? lastSynced,
    bool? isDeleted,
    String? deviceId,
    int? version,
  }) {
    return Mode(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      lastModified: lastModified ?? this.lastModified,
      isActive: isActive ?? this.isActive,
      // 同期フィールドを保持
      cloudId: cloudId ?? this.cloudId,
      lastSynced: lastSynced ?? this.lastSynced,
      isDeleted: isDeleted ?? this.isDeleted,
      deviceId: deviceId ?? this.deviceId,
      version: version ?? this.version,
    );
  }

  @override
  String toString() {
    return 'Mode(id: $id, name: $name, isActive: $isActive)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Mode && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
