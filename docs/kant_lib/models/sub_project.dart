import 'package:hive/hive.dart';
import 'syncable_model.dart';

part 'sub_project.g.dart';

@HiveType(typeId: 3)
class SubProject extends HiveObject with SyncableModel {
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
  String projectId; // 親プロジェクトのID

  @HiveField(8)
  String? category;

  @HiveField(9)
  String? project; // プロジェクト名

  // 同期用フィールド
  @override
  @HiveField(10)
  String? cloudId;

  @override
  @HiveField(11)
  DateTime? lastSynced;

  @override
  @HiveField(12)
  bool isDeleted;

  @override
  @HiveField(13)
  String deviceId;

  @override
  @HiveField(14)
  int version;

  SubProject({
    required this.id,
    required this.name,
    this.description,
    required this.createdAt,
    required this.lastModified,
    this.isArchived = false,
    required this.userId,
    required this.projectId,
    this.category,
    this.project,
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
      'createdAt': createdAt.toIso8601String(),
      'lastModified': lastModified.toIso8601String(),
      'isArchived': isArchived,
      'userId': userId,
      'projectId': projectId,
      'category': category,
      'project': project,
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
    project = json['project'];
    isArchived = json['isArchived'] ?? isArchived;
    projectId = json['projectId'] ?? projectId;

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
  }

  @override
  bool hasConflictWith(SyncableModel other) {
    if (other is! SubProject) return false;

    // SubProject固有の競合チェック
    return lastModified != other.lastModified ||
        version != other.version ||
        name != other.name ||
        description != other.description ||
        projectId != other.projectId;
  }

  @override
  SyncableModel resolveConflictWith(SyncableModel other) {
    if (other is! SubProject) return this;

    // Field-Level-Merge戦略（Projectと同様）
    if (other.lastModified.isAfter(lastModified)) {
      // リモートが新しい場合
      name = other.name;
      description = other.description;
      category = other.category;
      project = other.project;
      isArchived = other.isArchived;

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

  factory SubProject.fromJson(Map<String, dynamic> json) {
    return SubProject(
      id: json['id'],
      name: json['name'],
      description: json['description'],
      createdAt: DateTime.parse(json['createdAt']),
      lastModified: DateTime.parse(json['lastModified']),
      isArchived: json['isArchived'] ?? false,
      userId: json['userId'] ?? '',
      projectId: json['projectId'],
      category: json['category'],
      project: json['project'],
      // 同期フィールド
      cloudId: json['cloudId'],
      // lastSynced はローカル専用メタデータなので、クラウドJSONからは復元しない。
      lastSynced: null,
      isDeleted: json['isDeleted'] ?? false,
      deviceId: json['deviceId'] ?? '',
      version: json['version'] ?? 1,
    );
  }

  // サブプロジェクトをアーカイブ
  void archive() {
    isArchived = true;
    markAsModified();
  }

  // サブプロジェクトを復元
  void unarchive() {
    isArchived = false;
    markAsModified();
  }

  // copyWithメソッド（同期フィールド対応）
  SubProject copyWith({
    String? id,
    String? name,
    String? description,
    DateTime? createdAt,
    DateTime? lastModified,
    bool? isArchived,
    String? userId,
    String? projectId,
    String? category,
    String? project,
    // 同期フィールド
    String? cloudId,
    DateTime? lastSynced,
    bool? isDeleted,
    String? deviceId,
    int? version,
  }) {
    return SubProject(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      lastModified: lastModified ?? this.lastModified,
      isArchived: isArchived ?? this.isArchived,
      userId: userId ?? this.userId,
      projectId: projectId ?? this.projectId,
      category: category ?? this.category,
      project: project ?? this.project,
      // 同期フィールドを保持
      cloudId: cloudId ?? this.cloudId,
      lastSynced: lastSynced ?? this.lastSynced,
      isDeleted: isDeleted ?? this.isDeleted,
      deviceId: deviceId ?? this.deviceId,
      version: version ?? this.version,
    );
  }
}
