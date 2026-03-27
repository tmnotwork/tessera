import 'package:hive/hive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'syncable_model.dart';
import '../services/day_key_service.dart';

part 'actual_task.g.dart';

@HiveType(typeId: 18)
enum ActualTaskStatus {
  @HiveField(0)
  running, // 実行中
  @HiveField(1)
  completed, // 完了
  @HiveField(2)
  paused, // 中断
}

@HiveType(typeId: 5)
class ActualTask extends HiveObject with SyncableModel {
  @HiveField(0)
  String id;

  @HiveField(1)
  String title;

  @HiveField(2)
  ActualTaskStatus status; // 実行中/完了/中断

  @HiveField(3)
  String? projectId; // プロジェクトID

  @HiveField(4)
  DateTime? dueDate; // 期限

  @HiveField(5)
  DateTime startTime; // 開始時刻（日時分秒）

  @HiveField(6)
  DateTime? endTime; // 終了時刻（日時分秒）

  @HiveField(7)
  int actualDuration; // 実際の実行時間（分）

  @HiveField(9)
  String? memo; // メモ

  @HiveField(10)
  DateTime createdAt;

  @HiveField(11)
  @override
  DateTime lastModified;

  @HiveField(12)
  @override
  String userId;

  @HiveField(13)
  String? blockId; // 対応するBlockのID

  @HiveField(14)
  String? subProjectId; // サブプロジェクトID

  @HiveField(15)
  String? subProject; // サブプロジェクト名（表示用）

  @HiveField(16)
  String? modeId; // モードID

  @HiveField(17)
  String? blockName; // ブロック名

  @HiveField(24)
  String? sourceInboxTaskId; // 起源インボックスタスクID

  // 場所（実績側にも保持・予定からコピー）
  @HiveField(23)
  String? location;

  // 同期用フィールド
  @override
  @HiveField(18)
  String? cloudId;

  @override
  @HiveField(19)
  DateTime? lastSynced;

  @override
  @HiveField(20)
  bool isDeleted;

  @override
  @HiveField(21)
  String deviceId;

  @override
  @HiveField(22)
  int version;

  // --- Multi-day (Phase 2: read compatibility only) ---
  // 正規形の区間（UTC）
  @HiveField(25)
  DateTime? startAt;

  @HiveField(26)
  DateTime? endAtExclusive;

  @HiveField(27)
  List<String>? dayKeys;

  @HiveField(28)
  List<String>? monthKeys;

  @HiveField(29)
  bool allDay = false;

  /// レポート集計から除外する
  @HiveField(30)
  bool excludeFromReport = false;

  ActualTask({
    required this.id,
    required this.title,
    this.status = ActualTaskStatus.running,
    this.projectId,
    this.dueDate,
    required this.startTime,
    this.endTime,
    this.actualDuration = 0,
    this.memo,
    required this.createdAt,
    required this.lastModified,
    required this.userId,
    this.blockId,
    this.subProjectId,
    this.subProject,
    this.modeId,
    this.blockName,
    this.sourceInboxTaskId,
    this.location,
    this.startAt,
    this.endAtExclusive,
    this.dayKeys,
    this.monthKeys,
    this.allDay = false,
    this.excludeFromReport = false,
    // 同期用フィールド
    this.cloudId,
    this.lastSynced,
    this.isDeleted = false,
    this.deviceId = '',
    this.version = 1,
  }) {
    // lastModifiedが設定されていない場合はcreatedAtを使用
  }

  // SyncableModel の実装
  @override
  Map<String, dynamic> toCloudJson() {
    // Safe enum serialization with validation
    int safeStatusIndex;
    try {
      safeStatusIndex = status.index;
      if (safeStatusIndex < 0 ||
          safeStatusIndex >= ActualTaskStatus.values.length) {
        print(
            '⚠️ Invalid status index in toCloudJson: $safeStatusIndex, using running');
        safeStatusIndex = ActualTaskStatus.running.index;
      }
    } catch (e) {
      print('⚠️ Error accessing status in toCloudJson: $e, using running');
      safeStatusIndex = ActualTaskStatus.running.index;
    }

    return {
      'id': id,
      'title': title,
      'status': safeStatusIndex,
      'projectId': projectId,
      'dueDate': dueDate?.toIso8601String(),
      'startTime': startTime.toIso8601String(),
      'endTime': endTime?.toIso8601String(),
      'actualDuration': actualDuration,
      'excludeFromReport': excludeFromReport,
      'memo': memo,
      'createdAt': createdAt.toIso8601String(),
      'lastModified': lastModified.toIso8601String(),
      'userId': userId,
      'blockId': blockId,
      'subProjectId': subProjectId,
      'subProject': subProject,
      'modeId': modeId,
      'blockName': blockName,
      'sourceInboxTaskId': sourceInboxTaskId,
      'location': location,
      // NOTE:
      // lastSynced は端末ローカルの同期状態なのでクラウドへ送信しない。
      'isDeleted': isDeleted,
      'deviceId': deviceId,
      'version': version,
    };
  }

  /// Firestore へ書き込むための Map（Timestamp を含む）
  /// Phase 3: 新フィールドを併記して保存開始（outbox には使わない）
  Map<String, dynamic> toFirestoreWriteMap() {
    startAt ??= startTime.toUtc();
    endAtExclusive ??= endTime?.toUtc();
    allDay = allDay; // keep current value (default false)

    // 0分実績（start==end）でも dayKeys 同期に乗るように、
    // canonical の endExclusive だけ最小幅を持たせる。
    // endTime / actualDuration は別フィールドとして保持されるため、表示上の0分は維持される。
    if (startAt != null &&
        endAtExclusive != null &&
        startAt!.isAtSameMomentAs(endAtExclusive!)) {
      endAtExclusive = startAt!.add(const Duration(seconds: 1));
    }

    // For running actual (endAtExclusive==null), do NOT force dayKeys/monthKeys.
    if (startAt != null && endAtExclusive != null) {
      if (dayKeys == null || dayKeys!.isEmpty) {
        dayKeys = _computeDayKeysLocal(startAt!, endAtExclusive!);
      }
      if ((monthKeys == null || monthKeys!.isEmpty) &&
          dayKeys != null &&
          dayKeys!.isNotEmpty) {
        monthKeys = _computeMonthKeysFromDayKeys(dayKeys!);
      }
    }

    final data = toCloudJson();
    if (startAt != null) {
      data['startAt'] = Timestamp.fromDate(startAt!);
    }
    // For running, omit or keep null explicitly; prefer explicit null to avoid stale values
    if (endAtExclusive != null) {
      data['endAtExclusive'] = Timestamp.fromDate(endAtExclusive!);
    } else {
      data['endAtExclusive'] = null;
    }
    data['allDay'] = allDay;
    if (dayKeys != null) data['dayKeys'] = dayKeys;
    if (monthKeys != null) data['monthKeys'] = monthKeys;
    return data;
  }

  // 従来のJSON変換メソッド（互換性のため保持）
  Map<String, dynamic> toJson() {
    return toCloudJson();
  }

  @override
  void fromCloudJson(Map<String, dynamic> json) {
    title = json['title'] ?? title;

    // Safe enum deserialization with validation
    if (json['status'] != null) {
      final statusIndex = json['status'] as int;
      if (statusIndex >= 0 && statusIndex < ActualTaskStatus.values.length) {
        status = ActualTaskStatus.values[statusIndex];
      } else {
        print('⚠️ Invalid status value: $statusIndex, using current value');
      }
    }

    projectId = json['projectId'];
    dueDate = json['dueDate'] != null ? DateTime.parse(json['dueDate']) : null;
    if (json['startTime'] != null) {
      startTime = DateTime.parse(json['startTime']);
    }
    endTime = json['endTime'] != null ? DateTime.parse(json['endTime']) : null;

    // --- Multi-day (Phase 2: read compatibility only) ---
    if (json.containsKey('startAt')) {
      startAt = _parseFlexibleDateTime(json['startAt']);
      // 新スキーマのみが来ても既存UIが壊れないようにフォールバック
      if (json['startTime'] == null && startAt != null) {
        startTime = startAt!.toLocal();
      }
    }
    if (json.containsKey('endAtExclusive')) {
      endAtExclusive = _parseFlexibleDateTime(json['endAtExclusive']);
      if (json['endTime'] == null && endAtExclusive != null) {
        endTime = endAtExclusive!.toLocal();
      }
    }
    if (json.containsKey('dayKeys')) {
      dayKeys = _parseStringList(json['dayKeys']);
    }
    if (json.containsKey('monthKeys')) {
      monthKeys = _parseStringList(json['monthKeys']);
    }
    if (json.containsKey('allDay')) {
      allDay = json['allDay'] == true;
    }
    if (json.containsKey('excludeFromReport')) {
      excludeFromReport = json['excludeFromReport'] == true;
    }
    actualDuration = json['actualDuration'] ?? actualDuration;
    memo = json['memo'];

    if (json['createdAt'] != null) {
      createdAt = DateTime.parse(json['createdAt']);
    }
    if (json['lastModified'] != null) {
      lastModified = DateTime.parse(json['lastModified']);
    }
    // lastSynced はローカル専用メタデータなので、クラウド由来では上書きしない。

    userId = json['userId'] ?? userId;
    blockId = json['blockId'];
    subProjectId = json['subProjectId'];
    subProject = json['subProject'];
    modeId = json['modeId'];
    blockName = json['blockName'];
    if (json.containsKey('sourceInboxTaskId')) {
      sourceInboxTaskId = json['sourceInboxTaskId'];
    }
    if (json.containsKey('location')) {
      location = json['location'];
    }

    isDeleted = json['isDeleted'] ?? isDeleted;
    deviceId = json['deviceId'] ?? deviceId;
    version = json['version'] ?? version;
  }

  // 従来のfactory（互換性のため保持）
  factory ActualTask.fromJson(Map<String, dynamic> json) {
    // Safe enum deserialization
    ActualTaskStatus safeStatus = ActualTaskStatus.values[0]; // default value
    if (json['status'] != null) {
      final statusIndex = json['status'] as int;
      if (statusIndex >= 0 && statusIndex < ActualTaskStatus.values.length) {
        safeStatus = ActualTaskStatus.values[statusIndex];
      } else {
        print(
            '⚠️ Invalid status value in fromJson: $statusIndex, using default');
      }
    }

    return ActualTask(
      id: json['id'],
      title: json['title'],
      status: safeStatus,
      projectId: json['projectId'],
      dueDate: json['dueDate'] != null ? DateTime.parse(json['dueDate']) : null,
      startTime: DateTime.parse(json['startTime']),
      endTime: json['endTime'] != null ? DateTime.parse(json['endTime']) : null,
      actualDuration: json['actualDuration'] ?? 0,
      memo: json['memo'],
      startAt: _parseFlexibleDateTime(json['startAt']),
      endAtExclusive: _parseFlexibleDateTime(json['endAtExclusive']),
      dayKeys: _parseStringList(json['dayKeys']),
      monthKeys: _parseStringList(json['monthKeys']),
      allDay: json['allDay'] == true,
      createdAt: DateTime.parse(json['createdAt']),
      lastModified: json['lastModified'] != null
          ? DateTime.parse(json['lastModified'])
          : DateTime.now(),
      userId: json['userId'] ?? '',
      blockId: json['blockId'],
      subProjectId: json['subProjectId'],
      subProject: json['subProject'],
      modeId: json['modeId'],
      blockName: json['blockName'],
      sourceInboxTaskId: json['sourceInboxTaskId'],
      location: json['location'],
      // 同期フィールド
      cloudId: json['cloudId'],
      // lastSynced はローカル専用メタデータなので、クラウドJSONからは復元しない。
      lastSynced: null,
      isDeleted: json['isDeleted'] ?? false,
      deviceId: json['deviceId'] ?? '',
      version: json['version'] ?? 1,
    );
  }

  // タスク開始
  void start() {
    final newStartTime = DateTime.now();
    startTime = newStartTime;
    status = ActualTaskStatus.running;
    markAsModified();
  }

  // タスク中断
  void pause() {
    endTime = DateTime.now();
    status = ActualTaskStatus.paused;
    _calculateActualDuration();
    markAsModified();
  }

  // タスク完了
  void complete() {
    endTime = DateTime.now();
    status = ActualTaskStatus.completed;
    _calculateActualDuration();
    markAsModified();
  }

  // タスク再開
  void restart() {
    startTime = DateTime.now();
    endTime = null;
    status = ActualTaskStatus.running;
    actualDuration = 0;
    markAsModified();
  }

  // 実際の実行時間を計算
  void _calculateActualDuration() {
    if (endTime != null) {
      actualDuration = endTime!.difference(startTime).inMinutes;
    }
  }

  // タスクが実行中かチェック
  bool get isRunning {
    return status == ActualTaskStatus.running;
  }

  // タスクが完了しているかチェック
  bool get isCompleted {
    return status == ActualTaskStatus.completed;
  }

  // タスクが中断されているかチェック
  bool get isPaused {
    return status == ActualTaskStatus.paused;
  }

  @override
  bool hasConflictWith(SyncableModel other) {
    if (other is! ActualTask) return false;

    // ActualTask固有の競合チェック
    return lastModified != other.lastModified ||
        version != other.version ||
        title != other.title ||
        status != other.status ||
        startTime != other.startTime ||
        endTime != other.endTime ||
        startAt != other.startAt ||
        endAtExclusive != other.endAtExclusive ||
        allDay != other.allDay ||
        excludeFromReport != other.excludeFromReport ||
        !_stringListEquals(dayKeys, other.dayKeys) ||
        !_stringListEquals(monthKeys, other.monthKeys);
  }

  @override
  SyncableModel resolveConflictWith(SyncableModel other) {
    if (other is! ActualTask) return this;

    // Device-Based-Append戦略：異なる端末からの記録は両方保持
    if (deviceId != other.deviceId) {
      // 注意: 実際のフォーク（新IDで複製して保存）は
      // ActualTaskSyncService.resolveConflict / handleManualConflict 側で実施済み。
      // モデル側ではセマンティクス維持のため現在レコードを返す。
      return this;
    }

    // 同じ端末からの場合は通常の時刻ベース解決
    if (other.lastModified.isAfter(lastModified)) {
      // リモートが新しい場合
      fromCloudJson(other.toCloudJson());
      // toCloudJson は旧フィールド中心のため、追加分は明示的にコピーして欠落させない
      startAt = other.startAt;
      endAtExclusive = other.endAtExclusive;
      dayKeys = other.dayKeys;
      monthKeys = other.monthKeys;
      allDay = other.allDay;
      excludeFromReport = other.excludeFromReport;
      version = other.version + 1;
      lastModified = DateTime.now();
    } else {
      // ローカルが新しい場合
      version++;
      lastModified = DateTime.now();
    }

    return this;
  }

  // 実行時間を取得（分単位）
  int get durationInMinutes {
    // 終了時刻がある場合は、常に start/end の差分を正とみなして採用する。
    // （タイムラインで start/end だけ編集された場合でも、実績時間が必ず追随する）
    if (endTime != null) {
      final mins = endTime!.difference(startTime).inMinutes;
      return mins < 0 ? 0 : mins;
    }
    // endTime が無い場合のみ、保存値 actualDuration をフォールバックとして使う。
    if (actualDuration > 0) return actualDuration;
    final mins = DateTime.now().difference(startTime).inMinutes;
    return mins < 0 ? 0 : mins;
  }

  // その日のタスクかチェック
  bool isTaskForDate(DateTime date) {
    final stLocal = startTime.toLocal();
    final dLocal = date.toLocal();
    final taskDate = DateTime(stLocal.year, stLocal.month, stLocal.day);
    final targetDate = DateTime(dLocal.year, dLocal.month, dLocal.day);
    return taskDate.isAtSameMomentAs(targetDate);
  }

  // 翌朝6時までを当日として扱う
  bool isTaskForDateWithNextMorning(DateTime date) {
    final stLocal = startTime.toLocal();
    final dLocal = date.toLocal();
    final taskDate = DateTime(stLocal.year, stLocal.month, stLocal.day);
    final targetDate = DateTime(dLocal.year, dLocal.month, dLocal.day);

    // 翌朝6時までを当日として扱う
    final nextMorning = targetDate.add(const Duration(days: 1));
    final nextMorning6am = DateTime(
      nextMorning.year,
      nextMorning.month,
      nextMorning.day,
      6,
      0,
    );

    // タスクが翌朝6時までなら当日として扱う
    if (stLocal.isBefore(nextMorning6am)) {
      return taskDate.isAtSameMomentAs(targetDate);
    }

    return false;
  }

  // copyWithメソッド（同期フィールド対応）
  ActualTask copyWith({
    String? id,
    String? title,
    ActualTaskStatus? status,
    String? projectId,
    DateTime? dueDate,
    DateTime? startTime,
    DateTime? endTime,
    int? actualDuration,
    String? memo,
    String? location,
    DateTime? createdAt,
    DateTime? lastModified,
    String? userId,
    String? blockId,
    String? subProjectId,
    String? subProject,
    String? modeId,
    String? blockName,
    String? sourceInboxTaskId,
    DateTime? startAt,
    DateTime? endAtExclusive,
    List<String>? dayKeys,
    List<String>? monthKeys,
    bool? allDay,
    bool? excludeFromReport,
    // 同期フィールド
    String? cloudId,
    DateTime? lastSynced,
    bool? isDeleted,
    String? deviceId,
    int? version,
  }) {
    return ActualTask(
      id: id ?? this.id,
      title: title ?? this.title,
      status: status ?? this.status,
      projectId: projectId ?? this.projectId,
      dueDate: dueDate ?? this.dueDate,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      actualDuration: actualDuration ?? this.actualDuration,
      memo: memo ?? this.memo,
      location: location ?? this.location,
      createdAt: createdAt ?? this.createdAt,
      lastModified: lastModified ?? this.lastModified,
      userId: userId ?? this.userId,
      blockId: blockId ?? this.blockId,
      subProjectId: subProjectId ?? this.subProjectId,
      subProject: subProject ?? this.subProject,
      modeId: modeId ?? this.modeId,
      blockName: blockName ?? this.blockName,
      sourceInboxTaskId: sourceInboxTaskId ?? this.sourceInboxTaskId,
      startAt: startAt ?? this.startAt,
      endAtExclusive: endAtExclusive ?? this.endAtExclusive,
      dayKeys: dayKeys ?? this.dayKeys,
      monthKeys: monthKeys ?? this.monthKeys,
      allDay: allDay ?? this.allDay,
      excludeFromReport: excludeFromReport ?? this.excludeFromReport,
      // 同期フィールドを保持
      cloudId: cloudId ?? this.cloudId,
      lastSynced: lastSynced ?? this.lastSynced,
      isDeleted: isDeleted ?? this.isDeleted,
      deviceId: deviceId ?? this.deviceId,
      version: version ?? this.version,
    );
  }
}

DateTime? _parseFlexibleDateTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is Timestamp) return value.toDate().toUtc();
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
  }
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    return parsed?.toUtc();
  }
  return null;
}

List<String>? _parseStringList(dynamic value) {
  if (value == null) return null;
  if (value is List) {
    final out = <String>[];
    for (final v in value) {
      if (v is String) out.add(v);
    }
    return out;
  }
  return null;
}

bool _stringListEquals(List<String>? a, List<String>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<String> _computeDayKeysLocal(DateTime startAtUtc, DateTime endAtUtcExclusive) {
  // Final State: accountTimeZoneId の暦日で dayKeys を生成する（endExclusive）。
  // NOTE: 初期化前はUTCが使われるため、起動時に DayKeyService.initialize() を呼ぶこと。
  return DayKeyService.computeDayKeysUtc(startAtUtc, endAtUtcExclusive);
}

List<String> _computeMonthKeysFromDayKeys(List<String> dayKeys) {
  return DayKeyService.computeMonthKeysFromDayKeys(dayKeys);
}

String _formatYmd(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}
