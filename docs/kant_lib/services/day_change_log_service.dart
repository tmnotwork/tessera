import 'package:cloud_firestore/cloud_firestore.dart';

import 'auth_service.dart';
import 'sync_kpi.dart';
import 'timeline_version_service.dart';

class DayChangeLogEntry {
  DayChangeLogEntry({
    required this.collection,
    required this.docId,
    required this.deleted,
    required this.documentId,
    this.changedAt,
  });

  final String collection;
  final String docId;
  final bool deleted;
  final String documentId;
  final DateTime? changedAt;
}

class DayChangeLogPage {
  const DayChangeLogPage({
    required this.entries,
    required this.hasMore,
    this.lastChangedAt,
    this.lastDocId,
  });

  final List<DayChangeLogEntry> entries;
  final bool hasMore;
  final DateTime? lastChangedAt;
  final String? lastDocId;

  static const empty = DayChangeLogPage(entries: [], hasMore: false);
}

class DayChangeLogService {
  DayChangeLogService._();

  static const String _changesSubcollection = 'changes';

  static CollectionReference<Map<String, dynamic>>? _changesRef(DateTime date) {
    final uid = AuthService.getCurrentUserId();
    if (uid == null || uid.isEmpty) return null;
    final dayKey = TimelineVersionService.dateKey(date);
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('dayVersions')
        .doc(dayKey)
        .collection(_changesSubcollection);
  }

  static DateTime? _parseUtc(dynamic v) {
    if (v is Timestamp) return v.toDate().toUtc();
    if (v is DateTime) return v.toUtc();
    if (v is String) return DateTime.tryParse(v)?.toUtc();
    return null;
  }

  static DayChangeLogEntry? _fromSnapshot(
      QueryDocumentSnapshot<Map<String, dynamic>> snap) {
    final data = snap.data();
    final collection = data['collection'];
    final docId = data['docId'];
    if (collection is! String || collection.isEmpty) return null;
    if (docId is! String || docId.isEmpty) return null;
    final op = data['op'];
    final deleted =
        data['deleted'] == true || data['isDeleted'] == true || op == 'delete';
    final changedAt = _parseUtc(data['changedAt']);
    return DayChangeLogEntry(
      collection: collection,
      docId: docId,
      deleted: deleted,
      documentId: snap.id,
      changedAt: changedAt,
    );
  }

  static Future<DayChangeLogPage> fetchChanges(
    DateTime date, {
    DateTime? cursorAt,
    String? cursorDocId,
    int limit = 200,
  }) async {
    final ref = _changesRef(date);
    if (ref == null) return DayChangeLogPage.empty;
    try {
      Query<Map<String, dynamic>> query = ref
          .orderBy('changedAt')
          .orderBy(FieldPath.documentId)
          .limit(limit);
      if (cursorAt != null &&
          cursorDocId != null &&
          cursorDocId.isNotEmpty) {
        query = query.startAfter(
            [Timestamp.fromDate(cursorAt.toUtc()), cursorDocId]);
      }
      final snap = await query
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
      try {
        SyncKpi.queryReads += snap.docs.length;
      } catch (_) {}
      if (snap.docs.isEmpty) return DayChangeLogPage.empty;
      final entries = <DayChangeLogEntry>[];
      for (final doc in snap.docs) {
        final entry = _fromSnapshot(doc);
        if (entry != null) entries.add(entry);
      }
      if (entries.isEmpty) return DayChangeLogPage.empty;
      final last = entries.last;
      return DayChangeLogPage(
        entries: entries,
        hasMore: snap.docs.length == limit,
        lastChangedAt: last.changedAt,
        lastDocId: last.documentId,
      );
    } catch (e) {
      throw e;
    }
  }
}
