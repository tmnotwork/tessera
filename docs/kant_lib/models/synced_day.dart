import 'package:hive/hive.dart';

part 'synced_day.g.dart';

@HiveType(typeId: 120)
enum SyncedDayKind {
  @HiveField(0)
  timeline,
  @HiveField(1)
  inbox,
  @HiveField(2)
  report,
}

@HiveType(typeId: 121)
enum SyncedDayStatus {
  @HiveField(0)
  seeded,
  @HiveField(1)
  ready,
  @HiveField(2)
  stale,
  @HiveField(3)
  evicted,
}

@HiveType(typeId: 122)
class SyncedDay extends HiveObject {
  SyncedDay({
    required this.dateKey,
    required this.kind,
    this.status = SyncedDayStatus.seeded,
    this.lastVersionHash,
    this.lastVersionWriteAt,
    this.lastVersionCheckAt,
    this.lastFetchedAt,
    this.lastChangeAt,
    this.lastChangeDocId,
    this.lastFullSyncAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// YYYY-MM-DD ?????
  @HiveField(0)
  final String dateKey;

  @HiveField(1)
  SyncedDayKind kind;

  @HiveField(2)
  SyncedDayStatus status;

  /// `/dayVersions/{date}` ? hash ??????????????
  @HiveField(3)
  String? lastVersionHash;

  /// Firestore ? `lastWriteAt`
  @HiveField(4)
  DateTime? lastVersionWriteAt;

  /// ????????Doc???????
  @HiveField(5)
  DateTime? lastVersionCheckAt;

  /// ???????????????
  @HiveField(6)
  DateTime? lastFetchedAt;

  @HiveField(7)
  DateTime createdAt;

  @HiveField(8)
  DateTime updatedAt;

  @HiveField(9)
  DateTime? lastChangeAt;

  @HiveField(10)
  String? lastChangeDocId;

  /// 最後に全件同期（dayKey/monthKey同期）が完了した時刻
  /// changeLog差分同期では更新しない
  /// 定期的な全件reconciliationの判定に使用
  @HiveField(11)
  DateTime? lastFullSyncAt;

  String get id => '${kind.name}#$dateKey';

  SyncedDay copyWith({
    SyncedDayStatus? status,
    String? lastVersionHash,
    bool clearVersionHash = false,
    DateTime? lastVersionWriteAt,
    bool clearVersionWriteAt = false,
    DateTime? lastVersionCheckAt,
    bool clearVersionCheckAt = false,
    DateTime? lastFetchedAt,
    bool clearLastFetchedAt = false,
    DateTime? lastChangeAt,
    bool clearLastChangeAt = false,
    String? lastChangeDocId,
    bool clearLastChangeDocId = false,
    DateTime? lastFullSyncAt,
    bool clearLastFullSyncAt = false,
  }) {
    return SyncedDay(
      dateKey: dateKey,
      kind: kind,
      status: status ?? this.status,
      lastVersionHash:
          clearVersionHash ? null : (lastVersionHash ?? this.lastVersionHash),
      lastVersionWriteAt: clearVersionWriteAt
          ? null
          : (lastVersionWriteAt ?? this.lastVersionWriteAt),
      lastVersionCheckAt: clearVersionCheckAt
          ? null
          : (lastVersionCheckAt ?? this.lastVersionCheckAt),
      lastFetchedAt:
          clearLastFetchedAt ? null : (lastFetchedAt ?? this.lastFetchedAt),
      lastChangeAt:
          clearLastChangeAt ? null : (lastChangeAt ?? this.lastChangeAt),
      lastChangeDocId: clearLastChangeDocId
          ? null
          : (lastChangeDocId ?? this.lastChangeDocId),
      lastFullSyncAt:
          clearLastFullSyncAt ? null : (lastFullSyncAt ?? this.lastFullSyncAt),
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  bool get isReady => status == SyncedDayStatus.ready;
  bool get isStale => status == SyncedDayStatus.stale;

  SyncedDay markStatus(SyncedDayStatus next) {
    return copyWith(status: next);
  }
}
