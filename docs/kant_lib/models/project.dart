import 'package:hive/hive.dart';
import 'syncable_model.dart';
import '../utils/text_normalizer.dart';

part 'project.g.dart';

@HiveType(typeId: 2)
class Project extends HiveObject with SyncableModel {
  @HiveField(0)
  String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  String? description;

  @HiveField(3)
  DateTime createdAt;

  @HiveField(4)
  @override
  DateTime lastModified;

  @HiveField(5)
  bool isArchived;

  @HiveField(6)
  @override
  String userId;

  @HiveField(7)
  String? category;

  // 同期用フィールド
  @override
  @HiveField(8)
  String? cloudId;

  @override
  @HiveField(9)
  DateTime? lastSynced;

  @override
  @HiveField(10)
  bool isDeleted;

  @override
  @HiveField(11)
  String deviceId;

  @override
  @HiveField(12)
  int version;

  // 並び順（小さいほど先頭）
  @HiveField(13)
  int? sortOrder;

  Project({
    required this.id,
    required this.name,
    this.description,
    required this.createdAt,
    required this.lastModified,
    this.isArchived = false,
    required this.userId,
    this.category,
    // 同期用フィールド
    this.cloudId,
    this.lastSynced,
    this.isDeleted = false,
    this.deviceId = '',
    this.version = 1,
    this.sortOrder,
  });

  // SyncableModel の実装
  @override
  Map<String, dynamic> toCloudJson() {
    return {
      'id': id,
      'name': name,
      'normalizedName': normalizeProjectName(name),
      'description': description,
      'createdAt': createdAt.toIso8601String(),
      'lastModified': lastModified.toIso8601String(),
      'isArchived': isArchived,
      'userId': userId,
      'category': category,
      'sortOrder': sortOrder,
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
    category = json['category'];
    if (json.containsKey('sortOrder')) {
      final v = json['sortOrder'];
      sortOrder = (v is int) ? v : (v is num ? v.toInt() : sortOrder);
    }
    isArchived = json['isArchived'] ?? isArchived;

    if (json['createdAt'] != null) {
      createdAt = DateTime.parse(json['createdAt']);
    }
    if (json['lastModified'] != null) {
      lastModified = DateTime.parse(json['lastModified']);
    }
    // lastSynced はローカル専用メタデータなので、クラウド由来では上書きしない。

    isDeleted = json['isDeleted'] ?? isDeleted;
    deviceId = json['deviceId'] ?? deviceId;
    version = json['version'] ?? version;
    userId = json['userId'] ?? userId;

    // No local field to store normalizedName; ensure our name is normalized on writes.
  }

  // 従来のfactory（互換性のため保持）
  factory Project.fromJson(Map<String, dynamic> json) {
    return Project(
      id: json['id'],
      name: json['name'],
      description: json['description'],
      createdAt: DateTime.parse(json['createdAt']),
      lastModified: DateTime.parse(json['lastModified']),
      isArchived: json['isArchived'] ?? false,
      userId: json['userId'],
      category: json['category'],
      // 同期フィールド
      cloudId: json['cloudId'],
      // lastSynced はローカル専用メタデータなので、クラウドJSONからは復元しない。
      lastSynced: null,
      isDeleted: json['isDeleted'] ?? false,
      deviceId: json['deviceId'] ?? '',
      version: json['version'] ?? 1,
      sortOrder: json['sortOrder'] is int
          ? json['sortOrder'] as int
          : (json['sortOrder'] is num
              ? (json['sortOrder'] as num).toInt()
              : null),
    );
  }

  @override
  bool hasConflictWith(SyncableModel other) {
    if (other is! Project) return false;

    // プロジェクト固有の競合チェック
    return lastModified != other.lastModified ||
        version != other.version ||
        name != other.name ||
        description != other.description ||
        sortOrder != other.sortOrder ||
        isArchived != other.isArchived;
  }

  @override
  SyncableModel resolveConflictWith(SyncableModel other) {
    if (other is! Project) return this;

    // Field-Level-Merge戦略：フィールド別に新しい方を採用
    if (other.lastModified.isAfter(lastModified)) {
      // リモートのほうが新しい場合、フィールド別にマージ
      name = other.name;
      description = other.description;
      category = other.category;
      sortOrder = other.sortOrder;
      isArchived = other.isArchived;

      // メタデータ更新
      version = other.version + 1;
      lastModified = DateTime.now();
    } else {
      // ローカルが新しい場合はローカルを保持してバージョンアップ
      version++;
      lastModified = DateTime.now();
    }

    return this;
  }

  // プロジェクトをアーカイブ
  void archive() {
    isArchived = true;
    markAsModified();
    lastModified = DateTime.now();
  }

  // プロジェクトを復元
  void unarchive() {
    isArchived = false;
    lastModified = DateTime.now();
  }

  // copyWithメソッド（同期フィールド対応）
  Project copyWith({
    String? id,
    String? name,
    String? description,
    DateTime? createdAt,
    DateTime? lastModified,
    bool? isArchived,
    String? userId,
    String? category,
    // 同期フィールド
    String? cloudId,
    DateTime? lastSynced,
    bool? isDeleted,
    String? deviceId,
    int? version,
    int? sortOrder,
  }) {
    return Project(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      lastModified: lastModified ?? this.lastModified,
      isArchived: isArchived ?? this.isArchived,
      userId: userId ?? this.userId,
      category: category ?? this.category,
      // 同期フィールドを保持
      cloudId: cloudId ?? this.cloudId,
      lastSynced: lastSynced ?? this.lastSynced,
      isDeleted: isDeleted ?? this.isDeleted,
      deviceId: deviceId ?? this.deviceId,
      version: version ?? this.version,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}
