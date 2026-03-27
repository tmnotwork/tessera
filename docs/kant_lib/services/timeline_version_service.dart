import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/synced_day.dart';
import 'auth_service.dart';
import 'sync_kpi.dart';
import 'version_cursor_service.dart';

class DayVersionDoc {
  DayVersionDoc({
    required this.dateKey,
    this.lastWriteAt,
    this.hash,
    this.source,
    this.version,
    this.changeLogVersion,
    this.documentId,
    this.exists = true,
  });

  final String dateKey;
  final DateTime? lastWriteAt;
  final String? hash;
  final String? source;
  final int? version;
  final int? changeLogVersion;
  final String? documentId;
  final bool exists;

  DateTime? get date {
    final parts = dateKey.split('-');
    if (parts.length != 3) return null;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  bool get hasVersion => hash != null || version != null;

  static DayVersionDoc missing(String dateKey) =>
      DayVersionDoc(dateKey: dateKey, exists: false);
}

class VersionFeedResult {
  VersionFeedResult({
    required this.entries,
    required this.cursor,
    required this.hasMore,
  });

  final List<DayVersionDoc> entries;
  final VersionCursor cursor;
  final bool hasMore;

  static VersionFeedResult empty(VersionCursor cursor) =>
      VersionFeedResult(entries: const [], cursor: cursor, hasMore: false);
}

class TimelineVersionService {
  static const _collectionName = 'dayVersions';

  static String dateKey(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  static CollectionReference<Map<String, dynamic>> _collection(
      String userId) {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection(_collectionName);
  }

  static Future<DayVersionDoc?> fetchRemoteDoc(DateTime date) async {
    final userId = AuthService.getCurrentUserId();
    if (userId == null || userId.isEmpty) return null;
    final key = dateKey(date);
    try {
      final snap = await _collection(userId)
          .doc(key)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
      try {
        SyncKpi.docGets += 1;
      } catch (_) {}
      if (!snap.exists) {
        return DayVersionDoc.missing(key);
      }
      return _fromSnapshot(snap, key: key);
    } catch (_) {
      return null;
    }
  }

  static DayVersionDoc _fromSnapshot(DocumentSnapshot<Map<String, dynamic>> snap,
      {String? key}) {
    final data = snap.data() ?? <String, dynamic>{};
    final writeAtRaw = data['lastWriteAt'];
    DateTime? writeAt;
    if (writeAtRaw is Timestamp) {
      writeAt = writeAtRaw.toDate().toUtc();
    } else if (writeAtRaw is DateTime) {
      writeAt = writeAtRaw.toUtc();
    } else if (writeAtRaw is String) {
      writeAt = DateTime.tryParse(writeAtRaw)?.toUtc();
    }
    final hash = data['hash'] as String?;
    final source = data['source'] as String?;
    final versionValue = data['version'];
    int? version;
    if (versionValue is int) {
      version = versionValue;
    } else if (versionValue is num) {
      version = versionValue.toInt();
    }
    final changeVersionValue = data['changeLogVersion'];
    int? changeLogVersion;
    if (changeVersionValue is int) {
      changeLogVersion = changeVersionValue;
    } else if (changeVersionValue is num) {
      changeLogVersion = changeVersionValue.toInt();
    }
    return DayVersionDoc(
      dateKey: key ?? snap.id,
      lastWriteAt: writeAt,
      hash: hash,
      source: source,
      version: version,
      changeLogVersion: changeLogVersion,
      documentId: snap.id,
      exists: true,
    );
  }

  static Future<int?> fetchRemoteVersion(DateTime date) async {
    final doc = await fetchRemoteDoc(date);
    if (doc == null) return null;
    if (!doc.exists) return 0;
    return doc.version;
  }

  static Future<void> setVersionDocument(
    DateTime date, {
    String? hash,
    String? source,
    int? explicitVersion,
  }) async {
    final userId = AuthService.getCurrentUserId();
    if (userId == null || userId.isEmpty) return;
    final key = dateKey(date);
    final docRef = _collection(userId).doc(key);
    final payload = <String, dynamic>{
      'lastWriteAt': FieldValue.serverTimestamp(),
    };
    if (hash != null) payload['hash'] = hash;
    if (source != null) payload['source'] = source;
    if (explicitVersion != null) {
      payload['version'] = explicitVersion;
    } else {
      payload['version'] = FieldValue.increment(1);
    }
    try {
      await docRef.set(payload, SetOptions(merge: true));
      try {
        SyncKpi.writes += 1;
      } catch (_) {}
    } catch (_) {
      try {
        await docRef.set({
          ...payload,
          if (!payload.containsKey('version')) 'version': 1,
        }, SetOptions(merge: true));
        try {
          SyncKpi.writes += 1;
        } catch (_) {}
      } catch (_) {}
    }
  }

  static Future<void> bumpVersionForDate(
    DateTime date, {
    String? hash,
    String? source,
    int? explicitVersion,
  }) {
    return setVersionDocument(
      date,
      hash: hash,
      source: source,
      explicitVersion: explicitVersion,
    );
  }

  static Future<VersionFeedResult> fetchUpdatesSince({
    required SyncedDayKind kind,
    required VersionCursor cursor,
    int limit = 50,
  }) async {
    final userId = AuthService.getCurrentUserId();
    if (userId == null || userId.isEmpty) {
      return VersionFeedResult.empty(cursor);
    }

    Query<Map<String, dynamic>> query = _collection(userId)
        .orderBy('lastWriteAt')
        .orderBy(FieldPath.documentId)
        .limit(limit);

    final hasCursor = cursor.lastSeenDocId.isNotEmpty ||
        cursor.lastSeenWriteAt.millisecondsSinceEpoch != 0;
    if (hasCursor) {
      query = query.startAfter([
        cursor.lastSeenWriteAt,
        cursor.lastSeenDocId,
      ]);
    }

    try {
      final snap = await query
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
      try {
        SyncKpi.queryReads += snap.docs.length;
      } catch (_) {}
      final entries = snap.docs
          .map((doc) => _fromSnapshot(doc))
          .where((doc) => doc.exists)
          .toList();

      if (entries.isEmpty) {
        // IMPORTANT: 0件の場合はカーソルを前進させない（端末時刻に依存すると取りこぼしになり得る）
        return VersionFeedResult.empty(cursor);
      }

      final last = entries.last;
      // lastWriteAt が欠損している場合は、端末時刻で埋めてカーソルを進めない（取りこぼし防止）
      final lastWriteAt = last.lastWriteAt;
      if (lastWriteAt == null) {
        return VersionFeedResult(
          entries: entries,
          cursor: cursor,
          hasMore: false,
        );
      }
      final nextCursor = cursor.copyWith(
        lastSeenWriteAt: lastWriteAt,
        lastSeenDocId: last.documentId ?? last.dateKey,
      );

      return VersionFeedResult(
        entries: entries,
        cursor: nextCursor,
        hasMore: entries.length == limit,
      );
    } catch (_) {
      return VersionFeedResult.empty(cursor);
    }
  }

  /// dayVersions を軽量トリガーとして監視する（Inbox等の「tasks全件snapshots」を避ける用途）
  static Stream<List<DayVersionDoc>> watchRecentChanges({int limit = 30}) {
    final userId = AuthService.getCurrentUserId();
    if (userId == null || userId.isEmpty) {
      return const Stream<List<DayVersionDoc>>.empty();
    }
    bool first = true;
    return _collection(userId)
        .orderBy('lastWriteAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) {
          try {
            if (first) {
              first = false;
              SyncKpi.watchStarts += 1;
              SyncKpi.watchInitialReads += snap.docs.length;
            } else {
              SyncKpi.watchChangeReads += snap.docChanges.length;
            }
          } catch (_) {}
          return snap.docs.map((d) => _fromSnapshot(d)).toList();
        });
  }
}

