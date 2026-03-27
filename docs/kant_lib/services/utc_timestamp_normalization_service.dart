import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'auth_service.dart';

enum UtcTimestampNormalizationStatus {
  completed,
  skipped,
  failed,
}

class UtcTimestampNormalizationCollectionReport {
  UtcTimestampNormalizationCollectionReport({
    required this.collection,
    required this.scannedDocs,
    required this.updatedDocs,
    required this.updatedFields,
  });

  final String collection;
  final int scannedDocs;
  final int updatedDocs;
  final int updatedFields;
}

class UtcTimestampNormalizationReport {
  UtcTimestampNormalizationReport({
    required this.status,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.targetCollections,
    required this.collections,
    this.note,
  });

  final UtcTimestampNormalizationStatus status;
  final DateTime startedAtUtc;
  final DateTime endedAtUtc;
  final List<String> targetCollections;
  final List<UtcTimestampNormalizationCollectionReport> collections;
  final String? note;

  int get totalScanned =>
      collections.fold<int>(0, (s, r) => s + r.scannedDocs);
  int get totalUpdatedDocs =>
      collections.fold<int>(0, (s, r) => s + r.updatedDocs);
  int get totalUpdatedFields =>
      collections.fold<int>(0, (s, r) => s + r.updatedFields);

  String toText() {
    final b = StringBuffer();
    b.writeln('=== UTC正規化（手動）レポート ===');
    b.writeln('status: ${status.name}');
    b.writeln('startedAtUtc: ${startedAtUtc.toIso8601String()}');
    b.writeln('endedAtUtc: ${endedAtUtc.toIso8601String()}');
    b.writeln('targets: ${targetCollections.join(', ')}');
    if (note != null && note!.isNotEmpty) {
      b.writeln('note: $note');
    }
    b.writeln('');
    b.writeln('--- 集計 ---');
    b.writeln('scannedDocs: $totalScanned');
    b.writeln('updatedDocs: $totalUpdatedDocs');
    b.writeln('updatedFields: $totalUpdatedFields');
    b.writeln('');
    b.writeln('--- コレクション別 ---');
    for (final r in collections) {
      b.writeln(
          '- ${r.collection}: scanned=${r.scannedDocs} updatedDocs=${r.updatedDocs} updatedFields=${r.updatedFields}');
    }
    b.writeln('');
    b.writeln('※ これは「過去データの lastModified 形式揺れ（UTC/Z 以外）」を揃えるための操作です。');
    b.writeln('※ 実行後、同じ差分同期がループして read が増える問題が解消することがあります。');
    return b.toString();
  }
}

/// Firestore 上の時刻文字列（主に lastModified）を UTC(Z) の ISO8601 に正規化する。
///
/// 目的:
/// - 差分同期が `lastModified > cursorIso`（文字列比較）で動いている場合、
///   lastModified が UTC(Z) とローカル表現で混在すると diffFetch が繰り返しヒットし続け、
///   cursor が進まないことで read が増え続けることがある。
///
/// 注意:
/// - この処理は「読み取り（全件走査）」と「必要な分の書き込み（更新）」を発生させます。
/// - ユーザーが明示的に実行するメンテナンス操作として提供します。
class UtcTimestampNormalizationService {
  UtcTimestampNormalizationService._();

  static const List<String> defaultTargetCollections = <String>[
    // NOTE:
    // ここは「設定 > UTC正規化（手動）」のデフォルト対象。
    // diff同期が `lastModified > cursorIso`（文字列比較）で動いているコレクションは、
    // lastModified の形式揺れがあると同じ更新を何度も拾って read が増え続け得る。
    //
    // 以前はタスク系のみ（read/writesの上限を守る目的）だったが、
    // カテゴリ等のマスタ系でも同様の問題が観測されたため、軽量なマスタ系を追加する。
    'inbox_tasks',
    'actual_tasks',
    // マスタ/設定系（通常は件数が少ない想定）
    'categories',
    'modes',
    'projects',
    'sub_projects',
  ];

  static String? _normalizeUtcIsoString(dynamic v) {
    try {
      if (v == null) return null;
      if (v is String) {
        final parsed = DateTime.tryParse(v);
        if (parsed == null) return null;
        return parsed.toUtc().toIso8601String();
      }
      if (v is DateTime) {
        return v.toUtc().toIso8601String();
      }
      if (v is Timestamp) {
        return v.toDate().toUtc().toIso8601String();
      }
    } catch (_) {}
    return null;
  }

  static Map<String, dynamic> _buildNormalizedUpdate(Map<String, dynamic> data) {
    final out = <String, dynamic>{};
    // 差分カーソルに関係する可能性が高いフィールドに限定（不要な書き込みを避ける）
    for (final k in const ['lastModified', 'createdAt', 'lastSynced', 'updatedAt']) {
      if (!data.containsKey(k)) continue;
      final normalized = _normalizeUtcIsoString(data[k]);
      if (normalized == null) continue;
      final current = data[k];
      if (current is String && current == normalized) continue;
      // Timestamp/DateTime で入っている場合も、文字列に統一する（モデル側も文字列前提）
      out[k] = normalized;
    }
    return out;
  }

  static Future<UtcTimestampNormalizationReport> runManual({
    List<String> targetCollections = defaultTargetCollections,
    int pageSize = 300,
  }) async {
    final startedAtUtc = DateTime.now().toUtc();
    try {
      final userId = AuthService.getCurrentUserId();
      if (userId == null || userId.isEmpty) {
        return UtcTimestampNormalizationReport(
          status: UtcTimestampNormalizationStatus.skipped,
          startedAtUtc: startedAtUtc,
          endedAtUtc: DateTime.now().toUtc(),
          targetCollections: targetCollections,
          collections: const [],
          note: 'User not authenticated',
        );
      }

      final firestore = FirebaseFirestore.instance;
      final results = <UtcTimestampNormalizationCollectionReport>[];

      for (final collectionName in targetCollections) {
        int scanned = 0;
        int updatedDocs = 0;
        int updatedFields = 0;

        final col = firestore.collection('users').doc(userId).collection(collectionName);

        DocumentSnapshot<Object?>? lastDoc;
        while (true) {
          Query<Object?> q = col.orderBy(FieldPath.documentId).limit(pageSize);
          if (lastDoc != null) {
            q = q.startAfterDocument(lastDoc);
          }

          final snap =
              await q.get(const GetOptions(source: Source.server)).timeout(
                    const Duration(seconds: 25),
                  );
          if (snap.docs.isEmpty) break;

          WriteBatch? batch;
          int batchOps = 0;

          for (final doc in snap.docs) {
            scanned++;
            final raw = doc.data();
            if (raw is! Map<String, dynamic>) continue;

            final update = _buildNormalizedUpdate(raw);
            if (update.isEmpty) continue;

            batch ??= firestore.batch();
            batch.update(doc.reference, update);
            batchOps++;
            updatedDocs++;
            updatedFields += update.length;

            // Firestore write batch limit is 500
            if (batchOps >= 450) {
              await batch.commit();
              batch = null;
              batchOps = 0;
            }
          }

          if (batch != null && batchOps > 0) {
            await batch.commit();
          }

          lastDoc = snap.docs.last;

          // allow UI/event loop to breathe a bit
          await Future<void>.delayed(Duration.zero);
        }

        results.add(
          UtcTimestampNormalizationCollectionReport(
            collection: collectionName,
            scannedDocs: scanned,
            updatedDocs: updatedDocs,
            updatedFields: updatedFields,
          ),
        );
      }

      return UtcTimestampNormalizationReport(
        status: UtcTimestampNormalizationStatus.completed,
        startedAtUtc: startedAtUtc,
        endedAtUtc: DateTime.now().toUtc(),
        targetCollections: targetCollections,
        collections: results,
      );
    } catch (e) {
      return UtcTimestampNormalizationReport(
        status: UtcTimestampNormalizationStatus.failed,
        startedAtUtc: startedAtUtc,
        endedAtUtc: DateTime.now().toUtc(),
        targetCollections: targetCollections,
        collections: const [],
        note: e.toString(),
      );
    }
  }
}

