import 'package:hive/hive.dart';
import 'syncable_model.dart';

part 'inbox_task.g.dart';

// Sentinel for copyWith omitted vs explicit null
const Object _noValue = Object();

@HiveType(typeId: 20)
class InboxTask extends HiveObject with SyncableModel {
  @HiveField(0)
  String id;

  @HiveField(1)
  String title;

  @HiveField(2)
  String? projectId;

  @HiveField(3)
  DateTime? dueDate;

  @HiveField(4)
  DateTime executionDate;

  @HiveField(5)
  int? startHour;

  @HiveField(6)
  int? startMinute;

  @HiveField(7)
  int estimatedDuration;

  @HiveField(9)
  String? memo;

  @HiveField(10)
  DateTime createdAt;

  @HiveField(11)
  @override
  DateTime lastModified;

  @HiveField(12)
  @override
  String userId;

  @HiveField(13)
  String? blockId;

  @HiveField(14)
  bool isCompleted;

  @HiveField(15)
  bool isRunning;

  // 同期用フィールド
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

  @HiveField(21)
  DateTime? startTime;

  @HiveField(22)
  DateTime? endTime;

  @HiveField(23)
  String? subProjectId; // サブプロジェクトID

  // 「いつか」(Someday) フラグ: タイムライン/インボックスの通常表示・割当から除外
  @HiveField(24)
  bool isSomeday = false;

  @HiveField(25)
  String? modeId;

  /// レポート集計から除外する（タスク由来の集計対象外）
  @HiveField(26)
  bool excludeFromReport = false;

  /// 重要フラグ（通知対象）
  @HiveField(27)
  bool isImportant = false;

  /// Transient: このインスタンスが「クラウドJSONから生成された時」に、
  /// どのキーが *存在していたか* を保持する（欠落キー保持マージ用）。
  ///
  /// - Hiveへは保存しない（@HiveField を付けない）
  /// - ローカル生成（ユーザー操作等）の場合は null のままでOK
  Set<String>? _presentCloudKeys;
  Set<String>? get presentCloudKeys => _presentCloudKeys;
  void setPresentCloudKeys(Iterable<String> keys) {
    _presentCloudKeys = Set<String>.from(keys);
  }

  InboxTask({
    required this.id,
    required this.title,
    this.projectId,
    this.dueDate,
    required this.executionDate,
    this.startHour,
    this.startMinute,
    required this.estimatedDuration,
    this.memo,
    required this.createdAt,
    required this.lastModified,
    required this.userId,
    this.blockId,
    this.isCompleted = false,
    this.isRunning = false,
    this.startTime,
    this.endTime,
    this.subProjectId,
    this.isSomeday = false,
    this.modeId,
    this.excludeFromReport = false,
    this.isImportant = false,
    // 同期用フィールド
    this.cloudId,
    this.lastSynced,
    this.isDeleted = false,
    this.deviceId = '',
    this.version = 1,
  });

  // 実行時間を分で取得
  int get durationInMinutes {
    return estimatedDuration;
  }

  // SyncableModel の実装
  @override
  Map<String, dynamic> toCloudJson() {
    return {
      'id': id,
      'title': title,
      'projectId': projectId,
      'dueDate': dueDate?.toIso8601String(),
      'executionDate': executionDate.toIso8601String(),
      'startHour': startHour,
      'startMinute': startMinute,
      'estimatedDuration': estimatedDuration,
      'memo': memo,
      'createdAt': createdAt.toIso8601String(),
      'lastModified': lastModified.toIso8601String(),
      'userId': userId,
      'blockId': blockId,
      'isCompleted': isCompleted,
      'isRunning': isRunning,
      'subProjectId': subProjectId,
      'isSomeday': isSomeday,
      'modeId': modeId,
      'excludeFromReport': excludeFromReport,
      'isImportant': isImportant,
      // NOTE:
      // lastSynced は端末ローカルの同期状態なのでクラウドへ送信しない。
      'isDeleted': isDeleted,
      'deviceId': deviceId,
      'version': version,
    };
  }

  @override
  void fromCloudJson(Map<String, dynamic> json) {
    title = json['title'] ?? title;
    if (json.containsKey('projectId')) {
      projectId = json['projectId'];
    }
    if (json.containsKey('dueDate')) {
      dueDate =
          json['dueDate'] != null ? DateTime.parse(json['dueDate']) : null;
    }
    if (json['executionDate'] != null) {
      executionDate = DateTime.parse(json['executionDate']);
    }
    if (json.containsKey('startHour')) {
      startHour = json['startHour'];
    }
    if (json.containsKey('startMinute')) {
      startMinute = json['startMinute'];
    }
    estimatedDuration = json['estimatedDuration'] ?? estimatedDuration;
    if (json.containsKey('memo')) {
      memo = json['memo'];
    }

    if (json['createdAt'] != null) {
      createdAt = DateTime.parse(json['createdAt']);
    }
    if (json['lastModified'] != null) {
      lastModified = DateTime.parse(json['lastModified']);
    }
    // lastSynced はローカル専用メタデータなので、クラウド由来では上書きしない。

    userId = json['userId'] ?? userId;
    if (json.containsKey('blockId')) {
      blockId = json['blockId'];
    }
    isCompleted = json['isCompleted'] ?? isCompleted;
    isRunning = json['isRunning'] ?? isRunning;
    if (json.containsKey('subProjectId')) {
      subProjectId = json['subProjectId'];
    }
    if (json.containsKey('isSomeday')) {
      isSomeday = json['isSomeday'] == true;
    }
    if (json.containsKey('modeId')) {
      modeId = json['modeId'];
    }
    if (json.containsKey('excludeFromReport')) {
      excludeFromReport = json['excludeFromReport'] == true;
    }
    if (json.containsKey('isImportant')) {
      isImportant = json['isImportant'] == true;
    }

    isDeleted = json['isDeleted'] ?? isDeleted;
    deviceId = json['deviceId'] ?? deviceId;
    version = json['version'] ?? version;
  }

  @override
  bool hasConflictWith(SyncableModel other) {
    if (other is! InboxTask) return false;

    // InboxTask固有の競合チェック
    // blockId / projectId / modeId は「集約・割当」の実体。含めないと差分同期が
    // resolveConflict を通さず、または version だけでリモート勝ちになり
    // Firestore の blockId=null でローカル割当が消える（巻き戻り）。
    return lastModified != other.lastModified ||
        version != other.version ||
        title != other.title ||
        executionDate != other.executionDate ||
        blockId != other.blockId ||
        projectId != other.projectId ||
        subProjectId != other.subProjectId ||
        modeId != other.modeId ||
        isCompleted != other.isCompleted ||
        isRunning != other.isRunning ||
        excludeFromReport != other.excludeFromReport ||
        isImportant != other.isImportant;
  }

  @override
  SyncableModel resolveConflictWith(SyncableModel other) {
    if (other is! InboxTask) return this;

    // Firebaseを唯一の真実とみなし、リモート内容を常に優先する
    fromCloudJson(other.toCloudJson());
    version = other.version;
    lastModified = other.lastModified;
    deviceId = other.deviceId;

    return this;
  }

  // JSON変換メソッド（互換性のため）
  Map<String, dynamic> toJson() {
    return toCloudJson();
  }

  factory InboxTask.fromJson(Map<String, dynamic> json) {
    return InboxTask(
      id: json['id'],
      title: json['title'],
      projectId: json['projectId'],
      dueDate: json['dueDate'] != null ? DateTime.parse(json['dueDate']) : null,
      executionDate: DateTime.parse(json['executionDate']),
      startHour: json['startHour'],
      startMinute: json['startMinute'],
      estimatedDuration: json['estimatedDuration'] ?? 0,
      memo: json['memo'],
      createdAt: DateTime.parse(json['createdAt']),
      lastModified: json['lastModified'] != null
          ? DateTime.parse(json['lastModified'])
          : DateTime.now(),
      userId: json['userId'] ?? '',
      blockId: json['blockId'],
      isCompleted: json['isCompleted'] ?? false,
      isRunning: json['isRunning'] ?? false,
      startTime:
          json['startTime'] != null ? DateTime.parse(json['startTime']) : null,
      endTime: json['endTime'] != null ? DateTime.parse(json['endTime']) : null,
      subProjectId: json['subProjectId'],
      modeId: json['modeId'],
      isSomeday: json['isSomeday'] == true,
      // 同期フィールド
      isImportant: json['isImportant'] == true,
      cloudId: json['cloudId'],
      // lastSynced はローカル専用メタデータなので、クラウドJSONからは復元しない。
      lastSynced: null,
      isDeleted: json['isDeleted'] ?? false,
      deviceId: json['deviceId'] ?? '',
      version: json['version'] ?? 1,
    );
  }

  // copyWithメソッド（同期フィールド対応）
  InboxTask copyWith({
    String? id,
    String? title,
    Object? projectId = _noValue,
    DateTime? dueDate,
    DateTime? executionDate,
    Object? startHour = _noValue,
    Object? startMinute = _noValue,
    int? estimatedDuration,
    Object? memo = _noValue,
    DateTime? createdAt,
    DateTime? lastModified,
    String? userId,
    Object? blockId = _noValue,
    bool? isCompleted,
    bool? isRunning,
    DateTime? startTime,
    DateTime? endTime,
    Object? subProjectId = _noValue,
    Object? modeId = _noValue,
    bool? isSomeday,
    bool? excludeFromReport,
    bool? isImportant,
    // 同期フィールド
    String? cloudId,
    DateTime? lastSynced,
    bool? isDeleted,
    String? deviceId,
    int? version,
  }) {
    final String? newProjectId =
        identical(projectId, _noValue) ? this.projectId : projectId as String?;
    final String? newSubProjectId = identical(subProjectId, _noValue)
        ? this.subProjectId
        : subProjectId as String?;
    final int? newStartHour =
        identical(startHour, _noValue) ? this.startHour : startHour as int?;
    final int? newStartMinute = identical(startMinute, _noValue)
        ? this.startMinute
        : startMinute as int?;
    final String? newBlockId =
        identical(blockId, _noValue) ? this.blockId : blockId as String?;
    final String? newModeId =
        identical(modeId, _noValue) ? this.modeId : modeId as String?;
    final String? newMemo =
        identical(memo, _noValue) ? this.memo : memo as String?;

    return InboxTask(
      id: id ?? this.id,
      title: title ?? this.title,
      projectId: newProjectId,
      dueDate: dueDate ?? this.dueDate,
      executionDate: executionDate ?? this.executionDate,
      startHour: newStartHour,
      startMinute: newStartMinute,
      estimatedDuration: estimatedDuration ?? this.estimatedDuration,
      memo: newMemo,
      createdAt: createdAt ?? this.createdAt,
      lastModified: lastModified ?? this.lastModified,
      userId: userId ?? this.userId,
      blockId: newBlockId,
      isCompleted: isCompleted ?? this.isCompleted,
      isRunning: isRunning ?? this.isRunning,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      subProjectId: newSubProjectId,
      modeId: newModeId,
      isSomeday: isSomeday ?? this.isSomeday,
      excludeFromReport: excludeFromReport ?? this.excludeFromReport,
      isImportant: isImportant ?? this.isImportant,
      // 同期フィールド
      cloudId: cloudId ?? this.cloudId,
      lastSynced: lastSynced ?? this.lastSynced,
      isDeleted: isDeleted ?? this.isDeleted,
      deviceId: deviceId ?? this.deviceId,
      version: version ?? this.version,
    );
  }
}
