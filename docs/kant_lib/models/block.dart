import 'package:hive/hive.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'syncable_model.dart';
import '../services/day_key_service.dart';

part 'block.g.dart';

// Sentinel to distinguish between omitted and explicit null in copyWith
const Object _noValue = Object();

@HiveType(typeId: 99)
class Block extends HiveObject with SyncableModel {
  @HiveField(0)
  String id;

  @HiveField(1)
  String title;

  @HiveField(2)
  TaskCreationMethod creationMethod; // ルーティン/ハンド作成

  @HiveField(3)
  String? projectId; // プロジェクトID

  @HiveField(4)
  DateTime? dueDate; // 期限

  @HiveField(5)
  DateTime executionDate; // 実行日（年月日）

  @HiveField(6)
  int startHour; // 開始時刻（時間）

  @HiveField(7)
  int startMinute; // 開始時刻（分）

  @HiveField(8)
  int estimatedDuration; // 予定実行時間（分）

  // 稼働時間（分）= ブロック全体から休憩を除いた時間
  @HiveField(30)
  int workingMinutes;

  // --- Multi-day (Phase 2: read compatibility only) ---
  // 正規形の区間（UTC）
  @HiveField(31)
  DateTime? startAt;

  @HiveField(32)
  DateTime? endAtExclusive;

  @HiveField(33)
  bool allDay = false;

  @HiveField(34)
  List<String>? dayKeys;

  @HiveField(35)
  List<String>? monthKeys;

  /// レポート集計から除外する
  @HiveField(36)
  bool excludeFromReport = false;

  @HiveField(10)
  String? memo; // メモ

  @HiveField(11)
  DateTime createdAt;

  @HiveField(12)
  @override
  DateTime lastModified;

  @HiveField(13)
  @override
  String userId;

  @HiveField(14)
  String? subProjectId; // サブプロジェクトID

  @HiveField(15)
  String? subProject; // サブプロジェクト名（表示用）

  @HiveField(16)
  String? modeId; // モードID

  @HiveField(17)
  String? blockName; // ブロック名

  @HiveField(18)
  bool isCompleted; // 完了フラグ

  @HiveField(19)
  String? taskId; // 紐づくタスクID（インボックスタスク用）

  // ルーティン由来フラグ（taskIdとは別管理）
  @HiveField(25)
  bool isRoutineDerived = false;

  // 中断によって作成された予定ブロックであることを示すフラグ
  @HiveField(26)
  bool isPauseDerived = false;

  // イベント（非実行、プロジェクト等を持たない予定）
  @HiveField(27)
  bool isEvent = false;

  // スキップ（未了でもタイムラインに表示しない）
  @HiveField(28)
  bool isSkipped = false;

  // 場所（予定ブロックのロケーション）
  @HiveField(29)
  String? location;

  // 同期用フィールド
  @override
  @HiveField(20)
  String? cloudId;

  @override
  @HiveField(21)
  DateTime? lastSynced;

  @override
  @HiveField(22)
  bool isDeleted;

  @override
  @HiveField(23)
  String deviceId;

  @override
  @HiveField(24)
  int version;

  Block({
    required this.id,
    required this.title,
    this.creationMethod = TaskCreationMethod.manual,
    this.projectId,
    this.dueDate,
    required this.executionDate,
    required this.startHour,
    required this.startMinute,
    this.estimatedDuration = 60, // デフォルト60分
    int? workingMinutes,
    this.startAt,
    this.endAtExclusive,
    this.allDay = false,
    this.dayKeys,
    this.monthKeys,
    this.excludeFromReport = false,
    this.memo,
    required this.createdAt,
    required this.lastModified,
    required this.userId,
    this.subProjectId,
    this.subProject,
    this.modeId,
    this.blockName,
    this.isCompleted = false,
    this.taskId,
    this.isRoutineDerived = false,
    this.isPauseDerived = false,
    this.isEvent = false,
    this.isSkipped = false,
    this.location,
    // 同期用フィールド
    this.cloudId,
    this.lastSynced,
    this.isDeleted = false,
    this.deviceId = '',
    this.version = 1,
  }) : workingMinutes =
            _normalizeWorkingMinutes(estimatedDuration, workingMinutes) {
    // lastModifiedが設定されていない場合はcreatedAtを使用
  }

  // 開始時刻をTimeOfDayとして取得
  TimeOfDay get startTime => TimeOfDay(hour: startHour, minute: startMinute);

  // DateTime型の開始時刻（executionDate + startHour/startMinute）
  DateTime get startDateTime => DateTime(
        executionDate.year,
        executionDate.month,
        executionDate.day,
        startHour,
        startMinute,
      );

  // 終了時刻（開始＋estimatedDuration分）
  DateTime get endDateTime =>
      startDateTime.add(Duration(minutes: estimatedDuration));

  /// planned(Block) の正規形（startAt/endAtExclusive/dayKeys/monthKeys）を、
  /// 旧フィールド（executionDate/startHour/startMinute/estimatedDuration）または
  /// 指定したローカル時刻から再計算して返す。
  ///
  /// NOTE:
  /// - 現行実装では startLocal/endLocal は「端末ローカル」の DateTime を前提に UTC へ変換する。
  ///   Final State（accountTimeZoneIdのwall-clock→UTC）への完全統一は別途対応。
  /// - `TaskProvider.getBlocksForDate()` は dayKeys/startAt を優先して日所属判定するため、
  ///   executionDate だけ更新しても表示が移動しないケースがある。編集時は本メソッドで連動させる。
  Block recomputeCanonicalRange({
    DateTime? startLocalOverride,
    DateTime? endLocalExclusiveOverride,
    bool allDayOverride = false,
  }) {
    final startLocal = startLocalOverride ?? startDateTime;
    final endLocalExclusive =
        endLocalExclusiveOverride ?? startLocal.add(Duration(minutes: estimatedDuration));

    // Safety: invalid or zero-length ranges should not be persisted.
    if (!startLocal.isBefore(endLocalExclusive)) {
      return copyWith(
        startAt: null,
        endAtExclusive: null,
        dayKeys: null,
        monthKeys: null,
      );
    }

    // Final State direction:
    // UI入力は accountTimeZoneId の wall-clock として解釈し、UTCへ正規化する。
    final startAtUtc = DayKeyService.toUtcFromAccountWallClock(startLocal);
    final endAtUtcExclusive = DayKeyService.toUtcFromAccountWallClock(endLocalExclusive);
    final keys = DayKeyService.computeDayKeysUtc(startAtUtc, endAtUtcExclusive);
    final months = DayKeyService.computeMonthKeysFromDayKeys(keys);
    return copyWith(
      startAt: startAtUtc,
      endAtExclusive: endAtUtcExclusive,
      allDay: allDayOverride,
      dayKeys: keys,
      monthKeys: months,
    );
  }

  // 休憩時間（分）
  int get breakMinutes {
    final diff = estimatedDuration - workingMinutes;
    return diff < 0 ? 0 : diff;
  }

  // copyWithメソッド
  Block copyWith({
    String? id,
    String? title,
    TaskCreationMethod? creationMethod,
    Object? projectId = _noValue,
    DateTime? dueDate,
    DateTime? executionDate,
    int? startHour,
    int? startMinute,
    int? estimatedDuration,
    int? workingMinutes,
    Object? startAt = _noValue,
    Object? endAtExclusive = _noValue,
    bool? allDay,
    Object? dayKeys = _noValue,
    Object? monthKeys = _noValue,
    bool? excludeFromReport,
    String? memo,
    DateTime? createdAt,
    DateTime? lastModified,
    String? userId,
    Object? subProjectId = _noValue,
    Object? subProject = _noValue,
    String? modeId,
    String? blockName,
    bool? isCompleted,
    String? taskId,
    bool? isRoutineDerived,
    bool? isPauseDerived,
    bool? isEvent,
    bool? isSkipped,
    Object? location = _noValue,
    // 同期フィールドも追加
    String? cloudId,
    DateTime? lastSynced,
    bool? isDeleted,
    String? deviceId,
    int? version,
  }) {
    final String? newProjectId =
        identical(projectId, _noValue) ? this.projectId : projectId as String?;
    final String? newSubProjectId =
        identical(subProjectId, _noValue) ? this.subProjectId : subProjectId as String?;
    final String? newSubProject =
        identical(subProject, _noValue) ? this.subProject : subProject as String?;
    final String? newLocation =
        identical(location, _noValue) ? this.location : location as String?;

    final DateTime? newStartAt =
        identical(startAt, _noValue) ? this.startAt : startAt as DateTime?;
    final DateTime? newEndAtExclusive = identical(endAtExclusive, _noValue)
        ? this.endAtExclusive
        : endAtExclusive as DateTime?;
    final List<String>? newDayKeys = identical(dayKeys, _noValue)
        ? this.dayKeys
        : dayKeys as List<String>?;
    final List<String>? newMonthKeys = identical(monthKeys, _noValue)
        ? this.monthKeys
        : monthKeys as List<String>?;
    final nextEstimatedDuration = estimatedDuration ?? this.estimatedDuration;
    final nextWorkingMinutes = _normalizeWorkingMinutes(
      nextEstimatedDuration,
      workingMinutes ?? this.workingMinutes,
    );
    return Block(
      id: id ?? this.id,
      title: title ?? this.title,
      creationMethod: creationMethod ?? this.creationMethod,
      projectId: newProjectId,
      dueDate: dueDate ?? this.dueDate,
      executionDate: executionDate ?? this.executionDate,
      startHour: startHour ?? this.startHour,
      startMinute: startMinute ?? this.startMinute,
      estimatedDuration: nextEstimatedDuration,
      workingMinutes: nextWorkingMinutes,
      startAt: newStartAt,
      endAtExclusive: newEndAtExclusive,
      allDay: allDay ?? this.allDay,
      dayKeys: newDayKeys,
      monthKeys: newMonthKeys,
      excludeFromReport: excludeFromReport ?? this.excludeFromReport,
      memo: memo ?? this.memo,
      createdAt: createdAt ?? this.createdAt,
      lastModified: lastModified ?? this.lastModified,
      userId: userId ?? this.userId,
      subProjectId: newSubProjectId,
      subProject: newSubProject,
      modeId: modeId ?? this.modeId,
      blockName: blockName ?? this.blockName,
      isCompleted: isCompleted ?? this.isCompleted,
      taskId: taskId ?? this.taskId,
      isRoutineDerived: isRoutineDerived ?? this.isRoutineDerived,
      isPauseDerived: isPauseDerived ?? this.isPauseDerived,
      isEvent: isEvent ?? this.isEvent,
      isSkipped: isSkipped ?? this.isSkipped,
      location: newLocation,
      // 同期フィールドを保持
      cloudId: cloudId ?? this.cloudId,
      lastSynced: lastSynced ?? this.lastSynced,
      isDeleted: isDeleted ?? this.isDeleted,
      deviceId: deviceId ?? this.deviceId,
      version: version ?? this.version,
    );
  }

  // SyncableModel の実装
  /// executionDateをUTCの深夜（00:00:00 UTC）に正規化
  /// これにより、タイムゾーンの違いによる日付のずれを防ぐ
  static DateTime normalizeExecutionDateToUtcMidnight(DateTime date) {
    // 年月日を抽出してUTCの深夜として作成
    return DateTime.utc(date.year, date.month, date.day);
  }

  @override
  Map<String, dynamic> toCloudJson() {
    // TaskCreationMethodの安全性チェック
    int safeCreationMethodIndex;
    try {
      safeCreationMethodIndex = creationMethod.index;
      if (safeCreationMethodIndex < 0 ||
          safeCreationMethodIndex >= TaskCreationMethod.values.length) {
        print(
            '⚠️ Invalid TaskCreationMethod index in toCloudJson: $safeCreationMethodIndex, using manual');
        safeCreationMethodIndex = TaskCreationMethod.manual.index; // デフォルト値
      }
    } catch (e) {
      print(
          '❌ Error getting TaskCreationMethod index in toCloudJson: $e, using manual');
      safeCreationMethodIndex = TaskCreationMethod.manual.index; // デフォルト値
    }

    // executionDateをUTCの深夜に正規化してから保存
    final normalizedExecutionDate = normalizeExecutionDateToUtcMidnight(executionDate);

    return {
      'id': id,
      'title': title,
      'creationMethod': safeCreationMethodIndex,
      'projectId': projectId,
      'dueDate': dueDate?.toIso8601String(),
      'executionDate': normalizedExecutionDate.toIso8601String(),
      'startHour': startHour,
      'startMinute': startMinute,
      'estimatedDuration': estimatedDuration,
      'workingMinutes': workingMinutes,
      'excludeFromReport': excludeFromReport,
      'memo': memo,
      'createdAt': createdAt.toIso8601String(),
      'lastModified': lastModified.toIso8601String(),
      'userId': userId,
      'subProjectId': subProjectId,
      'subProject': subProject,
      'modeId': modeId,
      'blockName': blockName,
      'isCompleted': isCompleted,
      'taskId': taskId,
      'isRoutineDerived': isRoutineDerived,
      'isPauseDerived': isPauseDerived,
      'isEvent': isEvent,
      'isSkipped': isSkipped,
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
    // Derive canonical range if missing (legacy fields remain source for now)
    // Final State direction:
    // legacy fields (executionDate/startHour/...) are interpreted as accountTimeZoneId wall-clock.
    startAt ??= DayKeyService.toUtcFromAccountWallClock(startDateTime);
    endAtExclusive ??= DayKeyService.toUtcFromAccountWallClock(endDateTime);
    allDay = allDay; // keep current value (default false)

    // dayKeys/monthKeys are derived from the local-calendar intersection.
    // NOTE: dayKeys/月境界は DayKeyService.location（accountTimeZoneId）を正とする。
    if (startAt != null && endAtExclusive != null) {
      dayKeys ??= _computeDayKeysLocal(startAt!, endAtExclusive!);
      monthKeys ??= _computeMonthKeysFromDayKeys(dayKeys!);
    }

    final data = toCloudJson();
    if (startAt != null) {
      data['startAt'] = Timestamp.fromDate(startAt!);
    }
    if (endAtExclusive != null) {
      data['endAtExclusive'] = Timestamp.fromDate(endAtExclusive!);
    }
    data['allDay'] = allDay;
    if (dayKeys != null) data['dayKeys'] = dayKeys;
    if (monthKeys != null) data['monthKeys'] = monthKeys;
    return data;
  }

  @override
  void fromCloudJson(Map<String, dynamic> json) {
    title = json['title'] ?? title;
    creationMethod = json['creationMethod'] != null
        ? TaskCreationMethod.values[json['creationMethod']]
        : creationMethod;
    if (json.containsKey('projectId')) {
      projectId = json['projectId'];
    }
    if (json['dueDate'] != null) {
      dueDate = DateTime.parse(json['dueDate']);
    }
    if (json['executionDate'] != null) {
      // executionDateをUTCの深夜に正規化してから設定
      // これにより、タイムゾーンの違いによる日付のずれを防ぐ
      final parsed = DateTime.parse(json['executionDate']);
      executionDate = normalizeExecutionDateToUtcMidnight(parsed);
    }
    startHour = json['startHour'] ?? startHour;
    startMinute = json['startMinute'] ?? startMinute;
    estimatedDuration = json['estimatedDuration'] ?? estimatedDuration;
    if (json.containsKey('workingMinutes')) {
      workingMinutes = _normalizeWorkingMinutes(
        estimatedDuration,
        _parseInt(json['workingMinutes']),
      );
    } else {
      workingMinutes =
          _normalizeWorkingMinutes(estimatedDuration, workingMinutes);
    }
    if (json.containsKey('excludeFromReport')) {
      excludeFromReport = json['excludeFromReport'] == true;
    }
    memo = json['memo'] ?? memo;
    if (json['createdAt'] != null) {
      createdAt = DateTime.parse(json['createdAt']);
    }
    if (json['lastModified'] != null) {
      lastModified = DateTime.parse(json['lastModified']);
    }
    userId = json['userId'] ?? userId;
    if (json.containsKey('subProjectId')) {
      subProjectId = json['subProjectId'];
    }
    if (json.containsKey('subProject')) {
      subProject = json['subProject'];
    }
    modeId = json['modeId'] ?? modeId;
    blockName = json['blockName'] ?? blockName;
    isCompleted = json['isCompleted'] ?? isCompleted;
    taskId = json['taskId'] ?? taskId;
    isRoutineDerived = json['isRoutineDerived'] ?? isRoutineDerived;
    isPauseDerived = json['isPauseDerived'] ?? isPauseDerived;
    isEvent = json['isEvent'] ?? isEvent;
    // 古い形式のデータを考慮
    if (json['isEvent'] == null && json.containsKey('properties')) {
      isEvent = json['properties']['isEvent'] ?? false;
    }
    isSkipped = json['isSkipped'] ?? isSkipped;
    if (json.containsKey('location')) {
      location = json['location'];
    }
    cloudId = json['cloudId'] ?? cloudId;
    // lastSynced はローカル専用メタデータなので、クラウド由来では上書きしない。
    isDeleted = json['isDeleted'] ?? isDeleted;
    deviceId = json['deviceId'] ?? deviceId;
    version = json['version'] ?? version;

    // --- Multi-day (Phase 2: read compatibility only) ---
    if (json.containsKey('startAt')) {
      startAt = _parseFlexibleDateTime(json['startAt']);
    }
    if (json.containsKey('endAtExclusive')) {
      endAtExclusive = _parseFlexibleDateTime(json['endAtExclusive']);
    }
    if (json.containsKey('allDay')) {
      allDay = json['allDay'] == true;
    }
    if (json.containsKey('dayKeys')) {
      dayKeys = _parseStringList(json['dayKeys']);
    }
    if (json.containsKey('monthKeys')) {
      monthKeys = _parseStringList(json['monthKeys']);
    }
  }

  @override
  bool hasConflictWith(SyncableModel other) {
    if (other is! Block) return false;

    // Block固有の競合チェック
    return lastModified != other.lastModified ||
        version != other.version ||
        title != other.title ||
        executionDate != other.executionDate ||
        startHour != other.startHour ||
        startMinute != other.startMinute ||
        estimatedDuration != other.estimatedDuration ||
        workingMinutes != other.workingMinutes ||
        excludeFromReport != other.excludeFromReport ||
        startAt != other.startAt ||
        endAtExclusive != other.endAtExclusive ||
        allDay != other.allDay ||
        !_stringListEquals(dayKeys, other.dayKeys) ||
        !_stringListEquals(monthKeys, other.monthKeys) ||
        isCompleted != other.isCompleted ||
        isSkipped != other.isSkipped;
  }

  @override
  SyncableModel resolveConflictWith(SyncableModel other) {
    if (other is! Block) return this;

    // Device-Based-Append戦略：異なる端末からの予定は両方保持
    if (deviceId != other.deviceId) {
      // 実際のフォーク（新IDで複製して保存）は
      // BlockConflictResolver / BlockSyncService 側で実施済み。
      print('🔄 Different device blocks detected: keep both (fork done in sync layer)');
      return this;
    }

    // 同じ端末からの場合は通常の時刻ベース解決
    if (other.lastModified.isAfter(lastModified)) {
      // リモートが新しい場合
      fromCloudJson(other.toCloudJson());
      // toCloudJson は旧フィールド中心のため、追加分は明示的にコピーして欠落させない
      startAt = other.startAt;
      endAtExclusive = other.endAtExclusive;
      allDay = other.allDay;
      dayKeys = other.dayKeys;
      monthKeys = other.monthKeys;
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

  // JSON変換メソッド（互換性のため）
  Map<String, dynamic> toJson() {
    return toCloudJson();
  }

  factory Block.fromJson(Map<String, dynamic> json) {
    // Safe enum deserialization
    TaskCreationMethod safeCreationMethod = TaskCreationMethod.manual;
    if (json['creationMethod'] != null) {
      final methodIndex = json['creationMethod'] as int;
      if (methodIndex >= 0 && methodIndex < TaskCreationMethod.values.length) {
        safeCreationMethod = TaskCreationMethod.values[methodIndex];
      } else {
        print(
            '⚠️ Invalid creationMethod value in fromJson: $methodIndex, using default (manual)');
        safeCreationMethod = TaskCreationMethod.manual;
      }
    }

    final parsedEstimatedDuration = json['estimatedDuration'] ?? 60;
    return Block(
      id: json['id'],
      title: json['title'],
      creationMethod: safeCreationMethod,
      projectId: json['projectId'],
      dueDate: json['dueDate'] != null ? DateTime.parse(json['dueDate']) : null,
      executionDate: normalizeExecutionDateToUtcMidnight(DateTime.parse(json['executionDate'])),
      startHour: json['startHour'] ?? 0,
      startMinute: json['startMinute'] ?? 0,
      estimatedDuration: parsedEstimatedDuration,
      workingMinutes: _normalizeWorkingMinutes(
        parsedEstimatedDuration,
        _parseInt(json['workingMinutes']),
      ),
      startAt: _parseFlexibleDateTime(json['startAt']),
      endAtExclusive: _parseFlexibleDateTime(json['endAtExclusive']),
      allDay: json['allDay'] == true,
      dayKeys: _parseStringList(json['dayKeys']),
      monthKeys: _parseStringList(json['monthKeys']),
      memo: json['memo'],
      createdAt: DateTime.parse(json['createdAt']),
      lastModified: json['lastModified'] != null
          ? DateTime.parse(json['lastModified'])
          : DateTime.now(),
      userId: json['userId'] ?? '',
      subProjectId: json['subProjectId'],
      subProject: json['subProject'],
      modeId: json['modeId'],
      blockName: json['blockName'],
      isCompleted: json['isCompleted'] ?? false,
      taskId: json['taskId'],
      isRoutineDerived: json['isRoutineDerived'] ?? false,
      isPauseDerived: json['isPauseDerived'] ?? false,
      isEvent: json['isEvent'] ?? json['properties']?['isEvent'] ?? false,
      isSkipped: json['isSkipped'] ?? false,
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

int _parseInt(dynamic value) {
  if (value == null) return 0;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    return int.tryParse(value) ?? 0;
  }
  return 0;
}

int _normalizeWorkingMinutes(int estimatedDuration, int? workingMinutes) {
  const maxMinutes = 24 * 60 * 2; // 48時間分の上限を設定
  int safeEstimated = estimatedDuration;
  if (safeEstimated < 0) safeEstimated = 0;
  if (safeEstimated > maxMinutes) safeEstimated = maxMinutes;
  if (workingMinutes == null) {
    return safeEstimated;
  }
  if (workingMinutes < 0) return 0;
  if (workingMinutes > safeEstimated) return safeEstimated;
  return workingMinutes;
}

@HiveType(typeId: 16)
enum TaskCreationMethod {
  @HiveField(0)
  manual,
  @HiveField(1)
  routine,
}
