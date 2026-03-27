import 'package:hive/hive.dart';
import 'syncable_model.dart';

part 'user.g.dart';

@HiveType(typeId: 0)
class User extends HiveObject with SyncableModel {
  @HiveField(0)
  String id;

  @HiveField(1)
  String email;

  @HiveField(2)
  String passwordHash;

  @HiveField(3)
  String? displayName;

  @HiveField(4)
  DateTime createdAt;

  @HiveField(5)
  @override
  DateTime lastModified;

  @HiveField(6)
  String workType; // 'fixed', 'shift', 'freelance'

  @HiveField(7)
  List<int> workDays; // 0-6 (日曜日-土曜日)

  @HiveField(8)
  bool isActive;

  @override
  @HiveField(9)
  String userId;

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

  User({
    required this.id,
    required this.email,
    required this.passwordHash,
    this.displayName,
    required this.createdAt,
    required this.lastModified,
    this.workType = 'fixed',
    this.workDays = const [1, 2, 3, 4, 5], // 月-金
    this.isActive = true,
    // 同期用フィールド
    this.cloudId,
    this.lastSynced,
    this.isDeleted = false,
    this.deviceId = '',
    this.version = 1,
    required this.userId,
  }) {
    // 初期化時にuserIdをidと同じにする（自己参照）
    if (userId.isEmpty) {
      userId = id;
    }
  }

  // パスワード検証
  bool verifyPassword(String password) {
    // 簡易的な実装（実際はbcrypt等を使用）
    return passwordHash == password;
  }

  // 勤務日かどうかチェック
  bool isWorkDay(DateTime date) {
    return workDays.contains(date.weekday % 7);
  }

  // 勤務形態の表示名
  String get workTypeDisplayName {
    switch (workType) {
      case 'fixed':
        return '定休日制';
      case 'shift':
        return 'シフト制';
      case 'freelance':
        return '自由業';
      default:
        return '未設定';
    }
  }

  // SyncableModel の実装
  @override
  Map<String, dynamic> toCloudJson() {
    return {
      'id': id,
      'email': email,
      'displayName': displayName,
      'workType': workType,
      'workDays': workDays,
      'isActive': isActive,
      'createdAt': createdAt.toIso8601String(),
      'lastModified': lastModified.toIso8601String(),
      // NOTE:
      // lastSynced は端末ローカルの同期状態なのでクラウドへ送信しない。
      'isDeleted': isDeleted,
      'deviceId': deviceId,
      'version': version,
      'userId': userId,
    };
  }

  @override
  void fromCloudJson(Map<String, dynamic> json) {
    email = json['email'] ?? email;
    displayName = json['displayName'];
    workType = json['workType'] ?? workType;
    workDays = List<int>.from(json['workDays'] ?? workDays);
    isActive = json['isActive'] ?? isActive;

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
    if (other is! User) return false;

    // 基本的な競合チェック
    return lastModified != other.lastModified ||
        version != other.version ||
        email != other.email ||
        workType != other.workType;
  }

  @override
  SyncableModel resolveConflictWith(SyncableModel other) {
    if (other is! User) return this;

    // Last-Write-Wins 戦略
    if (other.lastModified.isAfter(lastModified)) {
      // リモートが新しい場合はリモートを採用
      fromCloudJson(other.toCloudJson());
      version = other.version + 1;
      lastModified = DateTime.now();
    } else {
      // ローカルが新しい場合はローカルを保持してバージョンアップ
      version++;
      lastModified = DateTime.now();
    }

    return this;
  }
}
