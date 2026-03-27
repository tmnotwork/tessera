import 'package:hive/hive.dart';
import 'syncable_model.dart';

part 'category.g.dart';

@HiveType(typeId: 1)
class Category extends HiveObject with SyncableModel {
  @HiveField(0)
  String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  DateTime createdAt;

  @HiveField(3)
  @override
  DateTime lastModified;

  @HiveField(4)
  @override
  String userId;

  // 同期用フィールド
  @override
  @HiveField(5)
  String? cloudId;

  @override
  @HiveField(6)
  DateTime? lastSynced;

  @override
  @HiveField(7)
  bool isDeleted;

  @override
  @HiveField(8)
  String deviceId;

  @override
  @HiveField(9)
  int version;

  Category({
    required this.id,
    required this.name,
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

  // SyncableModel の実装
  @override
  Map<String, dynamic> toCloudJson() {
    return {
      'id': id,
      'name': name,
      'nameLower': name.trim().toLowerCase(),
      'createdAt': createdAt.toIso8601String(),
      'lastModified': lastModified.toIso8601String(),
      'userId': userId,
      // NOTE:
      // lastSynced は「端末ローカルの同期状態」(needsSync判定) であり、
      // クラウドへ同期すると他端末/サーバーの値で巻き戻されて
      // 無操作でも upload が繰り返される原因になるため送信しない。
      'isDeleted': isDeleted,
      'deviceId': deviceId,
      'version': version,
    };
  }

  @override
  void fromCloudJson(Map<String, dynamic> json) {
    name = json['name'] ?? name;

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
    if (other is! Category) return false;

    // Category固有の競合チェック
    return lastModified != other.lastModified ||
        version != other.version ||
        name != other.name;
  }

  @override
  SyncableModel resolveConflictWith(SyncableModel other) {
    if (other is! Category) return this;

    // Last-Write-Wins戦略：設定データの最新優先
    if (other.lastModified.isAfter(lastModified)) {
      // リモートが新しい場合
      name = other.name;

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

  // JSON変換メソッド（互換性のため）
  Map<String, dynamic> toJson() {
    return toCloudJson();
  }

  factory Category.fromJson(Map<String, dynamic> json) {
    return Category(
      id: json['id'],
      name: json['name'],
      createdAt: DateTime.parse(json['createdAt']),
      lastModified: DateTime.parse(json['lastModified']),
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

  // copyWithメソッド（同期フィールド対応）
  Category copyWith({
    String? id,
    String? name,
    DateTime? createdAt,
    DateTime? lastModified,
    String? userId,
    // 同期フィールド
    String? cloudId,
    DateTime? lastSynced,
    bool? isDeleted,
    String? deviceId,
    int? version,
  }) {
    return Category(
      id: id ?? this.id,
      name: name ?? this.name,
      createdAt: createdAt ?? this.createdAt,
      lastModified: lastModified ?? this.lastModified,
      userId: userId ?? this.userId,
      // 同期フィールドを保持
      cloudId: cloudId ?? this.cloudId,
      lastSynced: lastSynced ?? this.lastSynced,
      isDeleted: isDeleted ?? this.isDeleted,
      deviceId: deviceId ?? this.deviceId,
      version: version ?? this.version,
    );
  }
}
