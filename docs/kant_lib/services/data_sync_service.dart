import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/syncable_model.dart';
import 'auth_service.dart';
import 'sync_kpi.dart';
import 'conflict_detector.dart';

import 'app_settings_service.dart';
import 'block_local_data_manager.dart';
import 'sync_all_history_service.dart';
import 'sync_context.dart';
import '../utils/kant_inbox_trace.dart';

/// Firestoreアップロードの結果を明示するアウトカム
enum UploadOutcome {
  written,
  skippedRemoteNewerAdopted,
  skippedRemoteDeleted,
  failed,
}

/// Firestoreアップロード結果の詳細
class UploadResult<T extends SyncableModel> {
  final UploadOutcome outcome;
  final String? cloudId;
  final T? adoptedRemote;
  final bool localApplied;
  final String? reason;

  const UploadResult({
    required this.outcome,
    this.cloudId,
    this.adoptedRemote,
    this.localApplied = false,
    this.reason,
  });

  UploadResult<T> copyWith({
    UploadOutcome? outcome,
    String? cloudId,
    T? adoptedRemote,
    bool? localApplied,
    String? reason,
  }) {
    return UploadResult<T>(
      outcome: outcome ?? this.outcome,
      cloudId: cloudId ?? this.cloudId,
      adoptedRemote: adoptedRemote ?? this.adoptedRemote,
      localApplied: localApplied ?? this.localApplied,
      reason: reason ?? this.reason,
    );
  }
}

/// データ型別同期サービスの基盤クラス
abstract class DataSyncService<T extends SyncableModel> {
  final String collectionName;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  // upload 事前GET（復活防止/競合回避）の過剰実行を抑止（G-16）
  static final Map<String, DateTime> _preflightFetchAt = <String, DateTime>{};
  // watchStart の履歴スパムを防ぐ（同一collectionの連続記録を間引く）
  static final Map<String, DateTime> _watchHistoryAt = <String, DateTime>{};
  // cloudId欠損時の id 検索を短時間で間引くキャッシュ
  static final Map<String, DateTime> _idLookupAt = <String, DateTime>{};

  DataSyncService(this.collectionName);

  /// Firestore に保存する日時文字列を UTC(Z) に正規化する。
  ///
  /// 背景:
  /// - このアプリは lastModified を Firestore に「ISO8601文字列」で保存している。
  /// - 差分同期は Firestore 側で `lastModified > cursorIso` を *文字列比較* で実行するため、
  ///   lastModified が UTC(Z) とローカル（Zなし/オフセット付き）で混在すると、
  ///   “実時刻”としては同じ/古いのに文字列としては大きく見えて diffFetch が永遠にヒットし、
  ///   cursor が進まず read が増え続ける。
  ///
  /// ここでは write payload のみを正規化し、今後の混在を根絶する。
  /// 既存データの混在は「一度正規化して書き戻す」別途の移行で解消する（必要なら実装可能）。
  String? _normalizeUtcIsoString(dynamic v) {
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

  Map<String, dynamic> _buildWriteMap(T item) {
    // Prefer Firestore-optimized write map if the model provides it.
    // This must NOT be used for outbox persistence (outbox stores JSON-safe maps).
    try {
      final dynamic dyn = item as dynamic;
      final dynamic map = dyn.toFirestoreWriteMap();
      if (map is Map) {
        return Map<String, dynamic>.from(map);
      }
    } catch (_) {
      // ignore - fall back to legacy JSON map
    }
    final data = item.toCloudJson();

    // 差分カーソルに関わる時刻フィールドだけ UTC(Z) に揃える（他フィールドは意味が異なるため触らない）。
    // NOTE: createdAt/lastModified/lastSynced/updatedAt は「瞬間」を表し、UTC正規化しても意味が壊れない。
    for (final k in const ['createdAt', 'lastModified', 'lastSynced', 'updatedAt']) {
      if (!data.containsKey(k)) continue;
      final normalized = _normalizeUtcIsoString(data[k]);
      if (normalized != null) {
        data[k] = normalized;
      }
    }
    return data;
  }

  bool get _writeUpdatedAtServerTimestamp =>
      collectionName == 'routine_tasks_v2' ||
      collectionName == 'routine_blocks_v2' ||
      collectionName == 'routine_templates_v2';

  /// 差分同期に使用するカーソルキー（AppSettingsService）。未設定ならフル同期のみ。
  String? get diffCursorKey => null;

  /// ユーザーのコレクション参照を取得
  CollectionReference get userCollection {
    final userId = AuthService.getCurrentUserId();

    if (userId == null || userId.isEmpty) {
      throw StateError('User not authenticated');
    }

    final collectionRef =
        _firestore.collection('users').doc(userId).collection(collectionName);
    return collectionRef;
  }

  /// アイテムをFirebaseにアップロード
  Future<void> uploadToFirebase(T item) async {
    await uploadToFirebaseWithOutcome(item);
  }

  /// アップロードの結果を返却する版
  Future<UploadResult<T>> uploadToFirebaseWithOutcome(T item,
      {bool skipPreflight = false}) async {
    const int maxRetries = 3;
    UploadResult<T> lastResult = UploadResult<T>(
      outcome: UploadOutcome.failed,
      cloudId: item.cloudId,
    );

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        // DeviceId取得（呼び出し側で markAsModified 済みのため、ここでは lastModified を触らない）
        // final deviceId = await DeviceInfoService.getDeviceId();

        // 事前にリモートを確認（cloudId または fallback id）
        // NOTE:
        // - routine_tasks は論理削除の“復活”が無劣化を破るため、actual_tasks 同様にガードする。
        // - その他のコレクションは読み取り削減のため従来通り省略。
        try {
          if (!skipPreflight &&
              collectionName != 'actual_tasks' &&
              collectionName != 'routine_tasks' &&
              collectionName != 'routine_templates' &&
              collectionName != 'routine_tasks_v2' &&
              collectionName != 'routine_blocks_v2' &&
              collectionName != 'routine_templates_v2') {
            // スキップ
          } else if (!skipPreflight) {
            String? key;
            if (item.cloudId != null && item.cloudId!.isNotEmpty) {
              key = item.cloudId!;
            } else {
              try {
                key = (item as dynamic).id as String?;
              } catch (_) {
                key = null;
              }
            }
            if (key != null && key.isNotEmpty) {
              // 同一docに対する短時間の連続GETを抑制（read削減）
              final now = DateTime.now();
              final cacheKey = '$collectionName::$key';
              final lastAt = _preflightFetchAt[cacheKey];
              if (lastAt != null &&
                  now.difference(lastAt) < const Duration(seconds: 10)) {
                // スキップ（直近で確認済み）
              } else {
                _preflightFetchAt[cacheKey] = now;
                // サイズ上限（メモリ肥大防止）
                if (_preflightFetchAt.length > 300) {
                  // 古いものから間引く
                  final entries = _preflightFetchAt.entries.toList()
                    ..sort((a, b) => a.value.compareTo(b.value));
                  for (int i = 0; i < entries.length - 200; i++) {
                    _preflightFetchAt.remove(entries[i].key);
                  }
                }

                // サーバー由来のみを参照（キャッシュは使用しない）
                final existing = await userCollection
                    .doc(key)
                    .get(const GetOptions(source: Source.server))
                    .timeout(const Duration(seconds: 10));
                if (existing.exists) {
                  final rawData = existing.data();
                  final existingData = rawData is Map<String, dynamic>
                      ? rawData
                      : <String, dynamic>{};
                  // 論理削除済みなら復活させない
                  final remoteDeleted =
                      (existingData['isDeleted'] ?? false) == true;
                  if (remoteDeleted) {
                    try {
                      final normalized = {
                        ...existingData,
                        'cloudId': existing.id
                      };
                      await _applyRemoteJsonPreservingMissing<T>(normalized);
                    } catch (_) {}
                    return UploadResult<T>(
                      outcome: UploadOutcome.skippedRemoteDeleted,
                      cloudId: existing.id,
                      localApplied: true,
                      reason: 'remoteDeleted',
                    );
                  }
                  // remote が新しければローカルに採用して中止
                  // NOTE: 端末の時計ズレで lastModified 比較だけだと更新が永遠に上がらないことがあるため、
                  // version を優先して判断する（version が上なら upload を許可する）。
                  int? remoteVer;
                  try {
                    final v = existingData['version'];
                    if (v is int) remoteVer = v;
                    if (v is String) remoteVer = int.tryParse(v);
                  } catch (_) {
                    remoteVer = null;
                  }
                  final int localVer = item.version;
                  if (remoteVer != null) {
                    if (localVer > remoteVer) {
                      // local の方が確実に新しい → pre-adopt はしない
                      remoteVer = remoteVer; // no-op (keep for logging)
                    } else if (remoteVer > localVer) {
                      // remote の方が新しい → pre-adopt へ
                    } else {
                      // same version → lastModified 比較へ
                    }
                  }
                  DateTime? remoteLm;
                  final lmRaw = existingData['lastModified'];
                  if (lmRaw is String) remoteLm = DateTime.tryParse(lmRaw);
                  if (lmRaw is Timestamp) remoteLm = lmRaw.toDate();
                  String? remoteDid;
                  try {
                    final d = existingData['deviceId'];
                    if (d is String) remoteDid = d;
                  } catch (_) {
                    remoteDid = null;
                  }
                  final bool deterministicTieBreak =
                      collectionName == 'routine_tasks_v2' ||
                          collectionName == 'routine_blocks_v2' ||
                          collectionName == 'routine_templates_v2';
                  final bool remoteWinsByVersion =
                      (remoteVer != null && remoteVer > localVer);
                  final bool remoteWinsByTie = deterministicTieBreak &&
                      remoteVer != null &&
                      remoteVer == localVer &&
                      remoteDid != null &&
                      remoteDid.isNotEmpty &&
                      item.deviceId.isNotEmpty &&
                      // ConflictDetector と同じルール: local<remote なら local 勝ち。つまり remote 勝ちは local>=remote。
                      (item.deviceId.compareTo(remoteDid) >= 0);
                  final bool remoteWinsByTime = !deterministicTieBreak &&
                      (remoteVer == null || remoteVer == localVer) &&
                      remoteLm != null &&
                      remoteLm.isAfter(item.lastModified);
                  if (remoteWinsByVersion || remoteWinsByTie || remoteWinsByTime) {
                    try {
                      final normalized = {
                        ...existingData,
                        'cloudId': existing.id
                      };
                      // 欠落キーはローカル保持で適用
                      await _applyRemoteJsonPreservingMissing<T>(normalized);
                    } catch (_) {}
                    return UploadResult<T>(
                      outcome: UploadOutcome.skippedRemoteNewerAdopted,
                      cloudId: existing.id,
                      localApplied: true,
                      reason: 'remoteAhead',
                    );
                  }
                }
              }
            }
          }
        } catch (_) {}

        // カテゴリ専用: cloudId が無い新規作成時に name で既存を検索して重複を避ける
        if (collectionName == 'categories' &&
            (item.cloudId == null || item.cloudId!.isEmpty)) {
          try {
            String? name;
            String? userId;
            try {
              name = ((item as dynamic).name as String?)?.trim();
            } catch (_) {}
            try {
              userId = ((item as dynamic).userId as String?);
            } catch (_) {}
            if (name != null && name.isNotEmpty && userId != null && userId.isNotEmpty) {
              final q = await userCollection
                  .where('isDeleted', isEqualTo: false)
                  .where('nameLower', isEqualTo: name.toLowerCase())
                  .limit(1)
                  .get(const GetOptions(source: Source.server));
              if (q.docs.isNotEmpty) {
                // 既存がある → それを採用して update に切り替える
                final doc = q.docs.first;
                item.cloudId = doc.id;
              }
            }
          } catch (_) {}
        }

        // Firebase操作
        if (item.cloudId != null && item.cloudId!.isNotEmpty) {
          // 既存ドキュメントの更新
          final docRef = userCollection.doc(item.cloudId!);
          final data = _buildWriteMap(item);
          if (_writeUpdatedAtServerTimestamp) {
            data['updatedAt'] = FieldValue.serverTimestamp();
            await docRef.set(data, SetOptions(merge: true));
          } else {
            await docRef.set(data);
          }
          try {
            SyncKpi.writes += 1;
          } catch (_) {}
        } else {
          // cloudId 未付与: 可能ならローカル id を docId として採用（決定的なdocID）
          String? fallbackId;
          try {
            fallbackId = (item as dynamic).id as String?;
          } catch (_) {
            fallbackId = null;
          }

          // routine_tasks / routine_templates は過去データで「docId != json.id」があり得る。
          // cloudId が無いまま doc(id) を作ると重複docが生まれ、他端末で古い方に戻る原因になるため、
          // 事前に "id == fallbackId" の既存docを検索して紐付ける。
          final shouldRescueById =
              collectionName == 'routine_tasks' ||
                  collectionName == 'routine_templates' ||
                  collectionName == 'actual_tasks';
          if (shouldRescueById &&
              fallbackId != null &&
              fallbackId.isNotEmpty) {
            try {
              final cacheKey = '$collectionName::lookup::$fallbackId';
              final now = DateTime.now();
              final lastLookup = _idLookupAt[cacheKey];
              if (lastLookup == null ||
                  now.difference(lastLookup) >
                      const Duration(seconds: 10)) {
                _idLookupAt[cacheKey] = now;
                if (_idLookupAt.length > 300) {
                  final entries = _idLookupAt.entries.toList()
                    ..sort((a, b) => a.value.compareTo(b.value));
                  for (int i = 0; i < entries.length - 200; i++) {
                    _idLookupAt.remove(entries[i].key);
                  }
                }
                final q = await userCollection
                    .where('id', isEqualTo: fallbackId)
                    .limit(1)
                    .get(const GetOptions(source: Source.server));
                if (q.docs.isNotEmpty) {
                  final doc = q.docs.first;
                  final data = doc.data() as Map<String, dynamic>;
                  if ((data['isDeleted'] ?? false) == true) {
                    // リモートが墓石なら復活させない
                    return UploadResult<T>(
                      outcome: UploadOutcome.skippedRemoteDeleted,
                      cloudId: doc.id,
                      localApplied: false,
                      reason: 'remoteDeletedByIdLookup',
                    );
                  }
                  item.cloudId = doc.id;
                }
              }
            } catch (_) {}
          }

          // 上の検索で cloudId が埋まった場合は update へ
          if (item.cloudId != null && item.cloudId!.isNotEmpty) {
            final docRef = userCollection.doc(item.cloudId!);
            final data = _buildWriteMap(item);
            if (_writeUpdatedAtServerTimestamp) {
              data['updatedAt'] = FieldValue.serverTimestamp();
              await docRef.set(data, SetOptions(merge: true));
            } else {
              await docRef.set(data);
            }
            try {
              SyncKpi.writes += 1;
            } catch (_) {}
          } else
          if (fallbackId != null && fallbackId.isNotEmpty) {
            final docRef = userCollection.doc(fallbackId);
            final data = _buildWriteMap(item);
            if (_writeUpdatedAtServerTimestamp) {
              data['updatedAt'] = FieldValue.serverTimestamp();
              await docRef.set(data, SetOptions(merge: true));
            } else {
              await docRef.set(data);
            }
            try {
              SyncKpi.writes += 1;
            } catch (_) {}
            item.cloudId = fallbackId;
          } else {
            // 最終手段として add を使用
            final data = _buildWriteMap(item);
            if (_writeUpdatedAtServerTimestamp) {
              data['updatedAt'] = FieldValue.serverTimestamp();
            }
            final docRef = await userCollection.add(data);
            try {
              SyncKpi.writes += 1;
            } catch (_) {}
            item.cloudId = docRef.id;
          }
        }

        // 同期完了マーク
        item.markAsSynced();

        // IMPORTANT:
        // markAsSynced() は in-memory の lastSynced を更新するだけなので、
        // ここでローカル(Hive)へ永続化しないと needsSync が永遠に true のままになり、
        // 「ユーザー無操作でも毎回アップロード→Firestore write が増える」状態になり得る。
        try {
          // ほとんどのモデルは HiveObject なので save() が使える。
          await (item as dynamic).save();
        } catch (_) {
          // フォールバック: サービス実装の saveToLocal を試す（環境差分に強くする）。
          try {
            await saveToLocal(item);
          } catch (_) {}
        }

        // カテゴリの場合はローカルへ永続化（cloudId/lastSynced の反映）
        // NOTE:
        // categories は書き込み後に doc を再GETしてローカルへ適用していたが、
        // - 追加のreadを発生させる
        // - lastSynced 等のローカル専用メタデータがサーバー値で巻き戻り得る
        // ため廃止する。cloudId は上の書き込みで確定しており、ローカル永続化は save() で十分。
        return UploadResult<T>(
          outcome: UploadOutcome.written,
          cloudId: item.cloudId,
          localApplied: false,
        );
      } catch (e) {
        lastResult = UploadResult<T>(
          outcome: UploadOutcome.failed,
          cloudId: item.cloudId,
          reason: e.toString(),
        );
        if (attempt == maxRetries) {
          rethrow;
        }

        // リトライ前に少し待機
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
    return lastResult;
  }

  /// リモートJSONを、欠落キーはローカル保持で適用（Block専用の適用器があれば使用）
  Future<void> _applyRemoteJsonPreservingMissing<U>(
      Map<String, dynamic> normalized) async {
    // Block 型に対しては専用の適用ロジックを使う
    try {
      // 動的チェックで Block を判定
      if (U.toString() == 'Block') {
        await BlockLocalDataManager.applyRemoteJsonToLocal(normalized);
        return;
      }
    } catch (_) {}

    // 既定: 従来通り createFromCloudJson→saveToLocal にフォールバック
    try {
      final item = createFromCloudJson(normalized);
      await saveToLocal(item);
    } catch (_) {}
  }

  /// Firebaseから全データをダウンロード
  Future<List<T>> downloadFromFirebase() async {
    try {
      // 削除されていないアイテムのみを取得するクエリ
      // Firebase consistency対策：
      // - まずサーバーから最新を取得
      // - 失敗時（オフライン等）はキャッシュにフォールバック
      QuerySnapshot<Object?> querySnapshot;
      try {
        querySnapshot = await userCollection
            .where('isDeleted', isEqualTo: false)
            .get(const GetOptions(source: Source.server))
            .timeout(
          const Duration(seconds: 120),
          onTimeout: () {
            throw TimeoutException('Firebase download operation timed out');
          },
        );
      } catch (e) {
        // オフライン時などはキャッシュで継続（ただし最新保証はできない）
        try {
          querySnapshot = await userCollection
              .where('isDeleted', isEqualTo: false)
              .get(const GetOptions(source: Source.cache));
        } catch (_) {
          rethrow;
        }
      }
      try { SyncKpi.queryReads += querySnapshot.docs.length; } catch (_) {}

      final items = <T>[];

      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;

          // 念のため、ローカルでもisDeletedフラグをチェック
          final isDeleted = data['isDeleted'] ?? false;
          if (isDeleted == true) {
            continue; // 削除されたアイテムはスキップ
          }

          data['cloudId'] = doc.id; // cloudIdを確実に設定

          // Timestamp/String 正規化（共通フィールド）
          void norm(String k) {
            final dt = FirestoreHelper.timestampToDateTime(data[k]);
            if (dt != null) data[k] = dt.toIso8601String();
          }

          for (final k in const [
            'createdAt',
            'lastModified',
            'lastSynced',
            'executionDate',
            'dueDate',
            'startTime',
            'endTime',
          ]) {
            norm(k);
          }

          // データの詳細をログ出力（デバッグ用）
          if (collectionName == 'blocks') {
            // final startHour = data['startHour'];
            // final startMinute = data['startMinute'];
            // final estimatedDuration = data['estimatedDuration'];

            // 不正な値を検出
            // if (startMinute != null && (startMinute < 0 || startMinute > 59)) {
            //   // 不正な値は無視
            // }
            // if (startHour != null && (startHour < 0 || startHour > 23)) {
            //   // 不正な値は無視
            // }
          }

          final item = createFromCloudJson(data);
          items.add(item);
        } catch (e) {
          if (collectionName == 'blocks') {
            // 破損データの詳細分析と処理
            if (e.toString().contains('RangeError')) {
              // IMPORTANT:
              // 「読み込み（パース）に失敗した」という理由だけで Firestore 側のデータを更新すると、
              // - 読み取りが書き込みを誘発する（課金/監査/推論が難しくなる）
              // - 一時的な不整合やパーサの不具合で誤ってデータを“削除扱い”にするリスクがある
              //
              // ここではサーバー更新は行わず、ログ/履歴で検知するだけに留める。
              try {
                print('⚠️ Corrupted block detected during download (docId=${doc.id}): $e');
              } catch (_) {}
            }
          }
        }
      }

      return items;
    } catch (e) {
      rethrow;
    }
  }

  /// 特定アイテムをFirebaseから取得
  Future<T?> downloadItemFromFirebase(String cloudId) async {
    try {
      // サーバー強制で最新の状態を取得（キャッシュ経由の古い状態を避ける）
      final doc = await userCollection
          .doc(cloudId)
          .get(const GetOptions(source: Source.server));
      try { SyncKpi.docGets += 1; } catch (_) {}
      if (!doc.exists) return null;

      final data = doc.data() as Map<String, dynamic>;
      data['cloudId'] = doc.id;
      return createFromCloudJson(data);
    } catch (e) {
      return null;
    }
  }

  /// アイテムをFirebaseから削除（論理削除）
  Future<void> deleteFromFirebase(String cloudId) async {
    try {
      // ユーザー認証確認
      final userId = AuthService.getCurrentUserId();
      if (userId == null) {
        throw StateError('User not authenticated for Firebase deletion');
      }

      // ドキュメント参照の取得
      final docRef = userCollection.doc(cloudId);

      final updateData = {
        'isDeleted': true,
        'lastModified': DateTime.now().toUtc().toIso8601String(),
        if (_writeUpdatedAtServerTimestamp) 'updatedAt': FieldValue.serverTimestamp(),
      };

      // まず update を試み、存在しない場合は set(merge)
      try {
        await docRef.update(updateData);
        try {
          SyncKpi.writes += 1;
        } catch (_) {}
      } catch (_) {
        await docRef.set(updateData, SetOptions(merge: true));
        try {
          SyncKpi.writes += 1;
        } catch (_) {}
      }

      // Post-delete verification GET removed to reduce reads; rely on write success
    } catch (e) {
      rethrow;
    }
  }

  /// Firebase内の全ドキュメント（削除済み含む）を確認するデバッグメソッド
  Future<void> debugFirebaseContents() async {
    try {
      // 全ドキュメントを取得（isDeletedフィルターなし、サーバーから強制取得）
      final allSnapshot =
          await userCollection.get(const GetOptions(source: Source.server));

      // int deletedCount = 0;
      // int activeCount = 0;

      for (final _ in allSnapshot.docs) {
        // isDeletedフィールドは現在使用していない
      }
    } catch (e) {
      // エラーは無視
    }
  }

  /// ローカルとリモートの競合を解決
  Future<T> resolveConflict(T local, T remote) async {
    final bool deterministicTieBreak =
        collectionName == 'routine_tasks_v2' ||
            collectionName == 'routine_blocks_v2' ||
            collectionName == 'routine_templates_v2';
    final conflictInfo =
        ConflictDetector.getConflictInfo(local, remote, deterministicTieBreak);

    switch (conflictInfo.resolution) {
      case ConflictResolution.localNewer:
      case ConflictResolution.localWins:
        // ローカル優先：リモートに上書き
        await uploadToFirebase(local);
        return local;

      case ConflictResolution.remoteNewer:
      case ConflictResolution.remoteWins:
        // リモート優先：ローカルに上書き
        await saveToLocal(remote);
        return remote;

      case ConflictResolution.needsManual:
        // 手動解決が必要
        return await handleManualConflict(local, remote);
    }
  }

  /// メイン同期処理
  Future<SyncResult> performSync({
    bool forceFullSync = false,
    bool uploadLocalChanges = true,
  }) async {
    try {
      // Phase 1: ローカルアイテムをアップロード
      final localItems = await getLocalItems();

      // NOTE (read分析用):
      // diff cursor は AppSettings(Hive) に保存される。Box が未オープンだと getCursor が null になり、
      // 意図せず fullFetch(全件GET) に落ちて read が爆増し得るため、ここで先に開いておく。
      // （失敗しても同期自体は続行する）
      bool settingsReady = false;
      try {
        if (diffCursorKey != null) {
          await AppSettingsService.initialize();
          settingsReady = true;
        }
      } catch (_) {
        settingsReady = false;
      }
      String? resolvedUserId;
      try {
        resolvedUserId = AuthService.getCurrentUserId();
      } catch (_) {
        resolvedUserId = null;
      }

      if (uploadLocalChanges) {
        for (final item in localItems) {
          if (!item.needsSync) continue;
          String? historyId;
          try {
            // 「ユーザー無操作でも write が増える」原因を追えるよう、
            // performSync 経由の自動アップロードも cloudWrite として履歴に残す。
            try {
              String? localId;
              try {
                localId = (item as dynamic).id as String?;
              } catch (_) {
                localId = null;
              }
              historyId = await SyncAllHistoryService.recordEventStart(
                type: 'cloudWrite',
                reason: 'performSync auto upload (needsSync)',
                origin: 'DataSyncService.performSync:$collectionName',
                userId: resolvedUserId,
                includeKpiSnapshot: false,
                extra: <String, dynamic>{
                  'collection': collectionName,
                  'operation': 'autoUpload',
                  if (localId != null) 'localId': localId,
                  'cloudId': item.cloudId,
                  'isDeleted': item.isDeleted,
                  'version': item.version,
                  'lastModifiedUtc': item.lastModified.toUtc().toIso8601String(),
                  'lastSyncedUtc': item.lastSynced?.toUtc().toIso8601String(),
                },
              );
            } catch (_) {
              historyId = null;
            }

            final res = await uploadToFirebaseWithOutcome(item);
            try {
              if (historyId != null) {
                await SyncAllHistoryService.recordFinish(
                  id: historyId!,
                  success: true,
                  extra: <String, dynamic>{
                    'outcome': res.outcome.name,
                    'cloudId': res.cloudId ?? item.cloudId,
                    'localApplied': res.localApplied,
                    if (res.reason != null) 'note': res.reason,
                  },
                );
              }
            } catch (_) {}
          } catch (e) {
            print('❌ Failed to sync local item: $e');
            try {
              if (historyId != null) {
                await SyncAllHistoryService.recordFailed(
                  id: historyId!,
                  error: e.toString(),
                );
              }
            } catch (_) {}
          }
        }
      }

      // Phase 2: リモートから差分もしくはフル同期を取得
      QuerySnapshot<Object?>? snapshot;
      bool usedDiff = false;
      bool diffAttempted = false;
      DateTime? cursorUtc;
      String? cursorRaw;
      if (!forceFullSync) {
        cursorUtc = _getDiffCursor();
        if (cursorUtc != null) {
          try {
            cursorRaw = cursorUtc.toUtc().toIso8601String();
          } catch (_) {
            cursorRaw = null;
          }
        } else if (diffCursorKey != null) {
          // 解析用: カーソルが null の場合は raw string を記録する（欠損/パース失敗/未オープンの判別用）
          try {
            cursorRaw = AppSettingsService.getString(diffCursorKey!);
          } catch (_) {
            cursorRaw = null;
          }
        }
      }

      // Web/IndexedDB(Hive) は一時的に "database connection is closing" 等で
      // getString/getCursor が null になり得る。ここで1回だけ reopen+re-read を試み、
      // 「偽の欠損」で fullFetch に落ちるのを防ぐ。
      if (!forceFullSync &&
          diffCursorKey != null &&
          settingsReady &&
          cursorUtc == null) {
        final beforeRaw = cursorRaw;
        final beforeBoxOpen = AppSettingsService.isBoxOpen;
        final beforeOpening = AppSettingsService.isOpeningBox;
        final missingRaw = beforeRaw == null || beforeRaw.isEmpty;
        final boxClosed = !beforeBoxOpen;
        // raw はあるのに cursor が null ＝ ISO文字列ではない/破損/パース不能の可能性
        final parseFailed = !missingRaw;
        bool retried = false;
        try {
          // cursor が null の時点で「偽欠損/パース不能」を疑う価値があるため、
          // boxがopenでrawがあっても、1回だけ reopen+re-read を試みる。
          retried = true;
          try {
            await AppSettingsService.initialize();
          } catch (_) {}

          String? retryRaw;
          DateTime? retryUtc;
          try {
            retryRaw = AppSettingsService.getString(diffCursorKey!);
          } catch (_) {
            retryRaw = null;
          }
          try {
            retryUtc = AppSettingsService.getCursor(diffCursorKey!);
          } catch (_) {
            retryUtc = null;
          }
          if (retryUtc == null && retryRaw != null && retryRaw.isNotEmpty) {
            retryUtc = DateTime.tryParse(retryRaw)?.toUtc();
          }
          if (retryUtc != null) {
            cursorUtc = retryUtc;
            try {
              cursorRaw = retryUtc.toUtc().toIso8601String();
            } catch (_) {}
          }
          if (retryRaw != null && retryRaw.isNotEmpty) {
            cursorRaw = retryRaw;
          }
        } catch (_) {}
        if (retried) {
          try {
            await SyncAllHistoryService.recordSimpleEvent(
              type: 'cursorReadRetry',
              reason: 'performSync cursor reopen+re-read retry',
              origin: 'DataSyncService.performSync:$collectionName',
              userId: resolvedUserId,
              extra: <String, dynamic>{
                'collection': collectionName,
                'diffCursorKey': diffCursorKey,
                'why': <String, dynamic>{
                  'missingRaw': missingRaw,
                  'boxClosed': boxClosed,
                  'parseFailed': parseFailed,
                },
                'before': <String, dynamic>{
                  'appSettingsBoxOpen': beforeBoxOpen,
                  'appSettingsOpening': beforeOpening,
                  'cursorRaw': beforeRaw,
                },
                'after': <String, dynamic>{
                  'appSettingsBoxOpen': AppSettingsService.isBoxOpen,
                  'appSettingsOpening': AppSettingsService.isOpeningBox,
                  'cursorRaw': cursorRaw,
                  'cursorParsedPresent': cursorUtc != null,
                  if (cursorUtc != null)
                    'cursorParsedIso': cursorUtc.toUtc().toIso8601String(),
                },
              },
            );
          } catch (_) {}
        }
      }

      // 根因特定用: diffカーソルの読み取り状態を記録（fullFetchに落ちる直前の状態を追えるようにする）
      // - cursorPersist(readback ok) の直後でも、ここが null になるなら「読み出し時点の不安定/別コンテキスト」が確定する。
      if (!forceFullSync && diffCursorKey != null) {
        try {
          final parsed = cursorUtc;
          await SyncAllHistoryService.recordSimpleEvent(
            type: 'cursorRead',
            reason: 'performSync cursor read (before diff/fullFetch decision)',
            origin: 'DataSyncService.performSync:$collectionName',
            userId: resolvedUserId,
            extra: <String, dynamic>{
              'collection': collectionName,
              if (SyncContext.origin != null) 'triggerOrigin': SyncContext.origin,
              'forceFullSync': forceFullSync,
              'settingsReady': settingsReady,
              'appSettingsBoxOpen': AppSettingsService.isBoxOpen,
              'appSettingsOpening': AppSettingsService.isOpeningBox,
              'diffCursorKey': diffCursorKey,
              'cursorRaw': cursorRaw,
              'cursorParsedPresent': parsed != null,
              if (parsed != null) 'cursorParsedIso': parsed.toUtc().toIso8601String(),
              'localCount': localItems.length,
            },
          );
        } catch (_) {}
      }

      if (!forceFullSync) {
        // cursor が欠損している場合でも、ローカルに十分なデータがあるなら
        // 「ローカルの lastModified」から seed して fullFetch を回避する（read爆発対策）。
        //
        // 前提:
        // - localItems は Hive に保存された実体（webでもIDB）で、cursor より堅牢に残ることが多い。
        // - 端末時計ズレ/レース対策として now-5min を上限(cap)にする。
        if (cursorUtc == null && diffCursorKey != null && settingsReady) {
          try {
            DateTime? maxLocalUtc;
            for (final item in localItems) {
              try {
                final lm = item.lastModified.toUtc();
                if (maxLocalUtc == null || lm.isAfter(maxLocalUtc)) {
                  maxLocalUtc = lm;
                }
              } catch (_) {}
            }
            if (maxLocalUtc != null) {
              final cap = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
              final seeded = maxLocalUtc.isAfter(cap) ? cap : maxLocalUtc;
              await AppSettingsService.setCursor(diffCursorKey!, seeded);
              cursorUtc = seeded;
              cursorRaw = seeded.toUtc().toIso8601String();
              try {
                await SyncAllHistoryService.recordSimpleEvent(
                  type: 'cursorSeed',
                  reason: 'seed diff cursor from local lastModified',
                  origin: 'DataSyncService.performSync:$collectionName',
                  userId: resolvedUserId,
                  extra: <String, dynamic>{
                    'collection': collectionName,
                    'diffCursorKey': diffCursorKey,
                    'localCount': localItems.length,
                    'maxLocalIso': maxLocalUtc.toIso8601String(),
                    'capIso': cap.toIso8601String(),
                    'seededIso': seeded.toIso8601String(),
                  },
                );
              } catch (_) {}
            }
          } catch (_) {}
        }

        final cursor = cursorUtc;
        if (cursor != null) {
          diffAttempted = true;
          final cursorIso = cursor.toUtc().toIso8601String();
          try {
            snapshot = await userCollection
                .where('lastModified', isGreaterThan: cursorIso)
                .get(const GetOptions(source: Source.server))
                .timeout(const Duration(seconds: 120));
            usedDiff = true;
            // 解析用: diff で何件取れたかを履歴に残す（collection別のread肥大の切り分け用）
            try {
              await SyncAllHistoryService.recordSimpleEvent(
                type: 'diffFetch',
                reason: 'performSync diff fetch',
                origin: 'DataSyncService.performSync:$collectionName',
                userId: resolvedUserId,
                extra: <String, dynamic>{
                  'collection': collectionName,
                if (SyncContext.origin != null) 'triggerOrigin': SyncContext.origin,
                  'forceFullSync': forceFullSync,
                  'settingsReady': settingsReady,
                  'diffCursorKey': diffCursorKey,
                  'cursorRaw': cursorRaw,
                  'cursorIso': cursorIso,
                  'docs': snapshot.docs.length,
                },
              );
            } catch (_) {}
            try {
              SyncKpi.queryReads += snapshot.docs.length;
            } catch (_) {}
          } catch (e) {
            // IMPORTANT: 失敗時に黙って全件GETへ落とさない（read爆発と隠れ回帰を防ぐ）
            print('❌ Diff sync failed for $collectionName: $e');
            return SyncResult(
              success: false,
              error: 'Diff sync failed for $collectionName: $e',
              failedCount: 1,
            );
          }
        }
      }

      // diffAttempted=true なのに snapshot が無い＝上で return 済みのはず。
      // 初回（cursorなし）や forceFullSync の場合のみ、明示的にフル取得する。
      if (snapshot == null) {
        final cursor = cursorUtc;
        final historyId = await SyncAllHistoryService.recordEventStart(
          type: 'fullFetch',
          reason: 'performSync full fetch',
          origin: 'DataSyncService.performSync:$collectionName',
          userId: resolvedUserId,
          extra: <String, dynamic>{
            'collection': collectionName,
            'forceFullSync': forceFullSync,
            'diffAttempted': diffAttempted,
            'diffCursorKey': diffCursorKey,
            'cursorPresent': cursor != null,
            // 解析用: fullFetch に落ちた時点のカーソル状態/Box状態を記録
            'settingsReady': settingsReady,
            'cursorRaw': cursorRaw,
            if (cursor != null) 'cursorIso': cursor.toUtc().toIso8601String(),
          },
        );
        // 根因特定用: fullFetchに落ちた瞬間の状態を別イベントで記録（cursorReadと突き合わせる）
        try {
          await SyncAllHistoryService.recordSimpleEvent(
            type: 'cursorRead',
            reason: 'performSync cursor read (at fullFetch)',
            origin: 'DataSyncService.performSync:$collectionName',
            userId: resolvedUserId,
            extra: <String, dynamic>{
              'collection': collectionName,
              if (SyncContext.origin != null) 'triggerOrigin': SyncContext.origin,
              'phase': 'atFullFetch',
              'forceFullSync': forceFullSync,
              'settingsReady': settingsReady,
              'appSettingsBoxOpen': AppSettingsService.isBoxOpen,
              'appSettingsOpening': AppSettingsService.isOpeningBox,
              'diffCursorKey': diffCursorKey,
              'cursorRaw': cursorRaw,
              'cursorParsedPresent': cursor != null,
              if (cursor != null) 'cursorParsedIso': cursor.toUtc().toIso8601String(),
              'localCount': localItems.length,
            },
          );
        } catch (_) {}
        snapshot = await userCollection.get().timeout(const Duration(seconds: 120));
        // fullFetch の内訳に read を載せる（recordFinish の前に加算する必要がある）
        try {
          SyncKpi.queryReads += snapshot.docs.length;
        } catch (_) {}
        // 解析用: fullFetch の件数も別イベントで残す（集計しやすくする）
        try {
          await SyncAllHistoryService.recordSimpleEvent(
            type: 'fullFetchDetail',
            reason: 'performSync full fetch (detail)',
            origin: 'DataSyncService.performSync:$collectionName',
            userId: resolvedUserId,
            extra: <String, dynamic>{
              'collection': collectionName,
              if (SyncContext.origin != null) 'triggerOrigin': SyncContext.origin,
              'forceFullSync': forceFullSync,
              'diffAttempted': diffAttempted,
              'diffCursorKey': diffCursorKey,
              'cursorPresent': cursor != null,
              'settingsReady': settingsReady,
              'cursorRaw': cursorRaw,
              'docs': snapshot.docs.length,
            },
          );
        } catch (_) {}
        await SyncAllHistoryService.recordFinish(
          id: historyId,
          success: true,
          extra: <String, dynamic>{
            'docs': snapshot.docs.length,
          },
        );
      }

      if (usedDiff) {
        return await _applyDiffSnapshot(snapshot, localItems);
      }

      final remoteItems = <T>[];
      DateTime? maxRemoteLastModified;

      for (final doc in snapshot.docs) {
        try {
          final raw = doc.data();
          if (raw is! Map<String, dynamic>) {
            continue;
          }
          final data = Map<String, dynamic>.from(raw);
          data['cloudId'] = doc.id;

          final lm = _extractLastModifiedUtc(data);
          if (lm != null) {
            final currentMax = maxRemoteLastModified;
            if (currentMax == null || lm.isAfter(currentMax)) {
              maxRemoteLastModified = lm;
            }
          }

          if ((data['isDeleted'] ?? false) == true) {
            // tombstone（isDeleted=true）はフル同期でも削除伝播として扱う。
            // これにより「候補数比例のdoc GET」に頼らず削除を反映できる（G-15）。
            try {
              await _deleteLocalForDiff(data, doc.id, localItems);
            } catch (_) {}
            continue;
          }

          void norm(String k) {
            final dt = FirestoreHelper.timestampToDateTime(data[k]);
            if (dt != null) data[k] = dt.toIso8601String();
          }

          for (final k in const [
            'createdAt',
            'lastModified',
            'lastSynced',
            'executionDate',
            'dueDate',
            'startTime',
            'endTime',
          ]) {
            norm(k);
          }
          final item = createFromCloudJson(data);
          remoteItems.add(item);
        } catch (e) {
          print('❌ Failed to process remote item: $e');
        }
      }

      if (localItems.isEmpty) {
        // 初回（ローカルが空）: getLocalItemByCloudId を呼ばずにそのまま保存（O(N^2) を回避）
        for (final remoteItem in remoteItems) {
          try {
            await saveToLocal(remoteItem);
          } catch (e) {
            print('❌ Failed to save remote item locally: $e');
          }
        }
      } else {
        for (final remoteItem in remoteItems) {
          try {
            final String? cid = remoteItem.cloudId;
            if (cid == null || cid.isEmpty) {
              await saveToLocal(remoteItem);
              continue;
            }

            final localItem = await getLocalItemByCloudId(cid);
            if (localItem == null) {
              await saveToLocal(remoteItem);
              continue;
            }

            final hasDiff = localItem.hasConflictWith(remoteItem);
            if (!hasDiff) {
              continue;
            }

            await resolveConflict(localItem, remoteItem);
          } catch (e) {
            print('❌ Failed to reconcile remote item locally: $e');
          }
        }
      }

      // NOTE:
      // 「クエリ結果に居ない=削除」として候補数比例のdoc GETで検証する方式は read を押し上げるため禁止（G-15）。
      // 削除伝播は tombstone（isDeleted=true）を差分/フル同期で拾うことを前提とする。
      //
      // 互換: レガシーデータで lastModified/createdAt/updatedAt が欠損している場合、
      // maxRemoteLastModified が null となりカーソルが永遠に初期化されず fullFetch が繰り返され得る。
      // その場合でも「取りこぼしを避けつつ」差分運用へ移行するため、now-5min を種として入れる。
      if (maxRemoteLastModified == null && diffCursorKey != null) {
        try {
          maxRemoteLastModified =
              DateTime.now().toUtc().subtract(const Duration(minutes: 5));
        } catch (_) {}
      }
      await _persistDiffCursor(maxRemoteLastModified);

      return SyncResult(
        success: true,
        syncedCount: remoteItems.length,
        failedCount: 0,
        conflicts: const [],
      );
    } catch (e) {
      print('❌ ERROR: Sync failed: $e');
      return SyncResult(
        success: false,
        syncedCount: 0,
        failedCount: 1,
        conflicts: [],
      );
    }
  }

  /// 削除されたアイテムを検出・処理する
  Future<int> _processDeletedItems(
      List<T> localItems, List<T> remoteItems) async {
    // G-15:
    // 「候補数に比例する doc GET（Source.server）で存在/削除を確認する」方式は禁止。
    // 削除伝播は tombstone（isDeleted=true）を差分/フル同期で拾う前提に統一する。
    //
    // 互換のためメソッドは残すが、呼ばれてもreadを増やさないよう no-op にしておく。
    return 0;
  }

  DateTime? _getDiffCursor() {
    final key = diffCursorKey;
    if (key == null) return null;
    return AppSettingsService.getCursor(key);
  }

  Future<SyncResult> _applyDiffSnapshot(
      QuerySnapshot<Object?> snapshot, List<T> localItems) async {
    int syncedCount = 0;
    int failedCount = 0;
    final conflicts = <ConflictResolution>[];
    DateTime? maxRemoteLastModified;

    for (final doc in snapshot.docs) {
      try {
        final raw = doc.data();
        if (raw is! Map<String, dynamic>) {
          continue;
        }
        final data = Map<String, dynamic>.from(raw);
        data['cloudId'] = doc.id;

        final lm = _extractLastModifiedUtc(data);
        if (lm != null) {
          final currentMax = maxRemoteLastModified;
          if (currentMax == null || lm.isAfter(currentMax)) {
            maxRemoteLastModified = lm;
          }
        }

        final isDeleted = (data['isDeleted'] ?? false) == true;
        if (isDeleted) {
          final removed = await _deleteLocalForDiff(data, doc.id, localItems);
          if (removed) syncedCount++;
          continue;
        }

        void norm(String k) {
          final dt = FirestoreHelper.timestampToDateTime(data[k]);
          if (dt != null) data[k] = dt.toIso8601String();
        }

        for (final k in const [
          'createdAt',
          'lastModified',
          'lastSynced',
          'executionDate',
          'dueDate',
          'startTime',
          'endTime',
        ]) {
          norm(k);
        }

        final remoteItem = createFromCloudJson(data);
        final cid = (remoteItem.cloudId?.isNotEmpty ?? false)
            ? remoteItem.cloudId!
            : doc.id;

        T? localItem;
        try {
          localItem = await getLocalItemByCloudId(cid);
        } catch (e) {
          localItem = null;
          if (collectionName == 'inbox_tasks') {
            print(
                '[RollbackCandidate] inbox_tasks getLocalItemByCloudId exception cid=$cid docId=${doc.id} error=$e',
            );
          }
        }

        if (localItem == null) {
          if (collectionName == 'inbox_tasks') {
            print(
                '[RollbackCandidate] inbox_tasks localItem==null applying remote (no conflict check) cid=$cid docId=${doc.id}',
            );
            kantInboxTrace(
              'diff_inbox_local_null_apply_remote',
              'cid=$cid docId=${doc.id} remoteBlockId=${(remoteItem as dynamic).blockId} remoteV=${remoteItem.version}',
            );
          }
          await saveToLocal(remoteItem);
          syncedCount++;
          continue;
        }

        final hasDiff = localItem.hasConflictWith(remoteItem);
        if (collectionName == 'inbox_tasks' && hasDiff) {
          kantInboxTrace(
            'diff_inbox_hasDiff',
            'cid=$cid localV=${localItem.version} remoteV=${remoteItem.version} '
            'localBlock=${(localItem as dynamic).blockId} remoteBlock=${(remoteItem as dynamic).blockId} '
            'localLm=${localItem.lastModified} remoteLm=${remoteItem.lastModified}',
          );
        }
        if (!hasDiff) {
          continue;
        }

        await resolveConflict(localItem, remoteItem);
        syncedCount++;
      } catch (e) {
        failedCount++;
        print('❌ Diff sync processing failed for $collectionName: $e');
      }
    }

    await _persistDiffCursor(maxRemoteLastModified);

    return SyncResult(
      success: failedCount == 0,
      syncedCount: syncedCount,
      failedCount: failedCount,
      conflicts: conflicts,
    );
  }

  Future<void> _persistDiffCursor(DateTime? latest) async {
    if (latest == null) {
      // 解析用: カーソルが保存されない根因（maxRemoteLastModifiedが取れない等）を切り分ける
      try {
        await SyncAllHistoryService.recordSimpleEvent(
          type: 'cursorPersistSkip',
          reason: 'persist cursor skipped (latest null)',
          origin: 'DataSyncService._persistDiffCursor:$collectionName',
          extra: <String, dynamic>{
            'collection': collectionName,
            'diffCursorKey': diffCursorKey,
          },
        );
      } catch (_) {}
      return;
    }
    final key = diffCursorKey;
    if (key == null) {
      try {
        await SyncAllHistoryService.recordSimpleEvent(
          type: 'cursorPersistSkip',
          reason: 'persist cursor skipped (no diffCursorKey)',
          origin: 'DataSyncService._persistDiffCursor:$collectionName',
          extra: <String, dynamic>{
            'collection': collectionName,
          },
        );
      } catch (_) {}
      return;
    }

    final current = AppSettingsService.getCursor(key);
    // 差分取得クエリは `lastModified > cursorIso` であり、ページングもしていない（limitなし）。
    // そのため、cursor を「最大 lastModified（UTC）」そのものに進めるのが最も安全で、
    // - 重複取得（-1msの後退で同じdocを何度も拾う）を防ぎ
    // - cursor が進まないことで diffFetch がループする状況を抑える
    // 期待がある。
    //
    // ※ ただし Firestore 側の lastModified が UTC(Z) と混在している場合は、
    //    文字列比較の歪みで “実時刻”が進まないのにヒットするケースがあり、
    //    それは別途のデータ正規化（移行）で根治する必要がある。
    var candidate = latest.toUtc();
    if (candidate.millisecondsSinceEpoch < 0) {
      candidate = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    if (current != null && candidate.isBefore(current)) {
      candidate = current;
    }

    // 正規ルート: maxRemoteLastModified 由来のカーソルを保存する
    await AppSettingsService.setCursor(key, candidate);
    // 解析用: 直後に読み返して「本当に保存されたか」を記録する（根本原因の特定用）
    try {
      final raw = AppSettingsService.getString(key);
      await SyncAllHistoryService.recordSimpleEvent(
        type: 'cursorPersist',
        reason: 'persist cursor (readback)',
        origin: 'DataSyncService._persistDiffCursor:$collectionName',
        extra: <String, dynamic>{
          'collection': collectionName,
          'diffCursorKey': key,
          'candidateIso': candidate.toUtc().toIso8601String(),
          'readBackRaw': raw,
          'readBackOk': raw != null && raw.isNotEmpty,
        },
      );
    } catch (_) {}
  }

  DateTime? _extractLastModifiedUtc(Map<String, dynamic> data) {
    try {
      // 差分カーソルの基準:
      // - 既定は lastModified
      // - 互換/レガシーで lastModified が欠損している場合があるため、
      //   updatedAt/createdAt にフォールバックして「カーソルが永遠に初期化されず fullFetch が繰り返される」
      //   事象を防ぐ。
      DateTime? pick(dynamic v) => FirestoreHelper.timestampToDateTime(v)?.toUtc();
      return pick(data['lastModified']) ??
          pick(data['updatedAt']) ??
          pick(data['createdAt']);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _deleteLocalForDiff(
      Map<String, dynamic> data, String docId, List<T> localItems) async {
    try {
      final localByCloud = await getLocalItemByCloudId(docId);
      if (localByCloud != null) {
        await deleteLocalItem(localByCloud);
        return true;
      }
    } catch (_) {}

    try {
      final fallback = data['id'];
      if (fallback is String && fallback.isNotEmpty) {
        final localById = await getLocalItemByCloudId(fallback);
        if (localById != null) {
          await deleteLocalItem(localById);
          return true;
        }
        if (await _deleteLocalMatching(localItems,
            (item) => _cloudIdOf(item) == fallback || _idOf(item) == fallback)) {
          return true;
        }
      }
    } catch (_) {}

    if (await _deleteLocalMatching(
        localItems, (item) => _cloudIdOf(item) == docId)) {
      return true;
    }

    return false;
  }

  Future<bool> _deleteLocalMatching(
      List<T> items, bool Function(T item) predicate) async {
    for (final item in items) {
      try {
        if (predicate(item)) {
          await deleteLocalItem(item);
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  String? _cloudIdOf(T item) {
    try {
      final cid = (item as dynamic).cloudId as String?;
      if (cid != null && cid.isNotEmpty) {
        return cid;
      }
    } catch (_) {}
    return null;
  }

  String? _idOf(T item) {
    try {
      final id = (item as dynamic).id as String?;
      if (id != null && id.isNotEmpty) {
        return id;
      }
    } catch (_) {}
    return null;
  }

  /// Firebaseで論理削除されたアイテムをチェック
  Future<Set<String>> _checkLogicallyDeletedItems(List<T> candidates) async {
    // G-15:
    // 削除判定のための「存在確認（候補数比例の問い合わせ）」自体を通常同期から排除する。
    // 削除伝播は tombstone（isDeleted=true）を差分/フル同期で取得して反映する。
    return <String>{};
  }

  /// Firestoreの変更を監視するストリーム
  Stream<List<T>> watchFirebaseChanges() {
    try { SyncKpi.watchStarts += 1; } catch (_) {}
    try {
      final now = DateTime.now().toUtc();
      final last = _watchHistoryAt[collectionName];
      if (last == null || now.difference(last) > const Duration(seconds: 30)) {
        _watchHistoryAt[collectionName] = now;
        // ignore: unawaited_futures
        SyncAllHistoryService.recordSimpleEvent(
          type: 'watchStart',
          reason: 'firestore watch start',
          origin: 'DataSyncService.watchFirebaseChanges:$collectionName',
          extra: <String, dynamic>{
            'collection': collectionName,
            if (SyncContext.origin != null) 'triggerOrigin': SyncContext.origin,
            'where': 'isDeleted == false',
          },
        );
      }
    } catch (_) {}
    bool isFirst = true;
    final stream = userCollection
        .where('isDeleted', isEqualTo: false)
        .snapshots()
        .map((snapshot) {
      // 課金readの厳密値ではないが、原因切り分けのための概算。
      // - 初回: docs.length（初回スナップショット）
      // - 以後: docChanges.length（差分）
      try {
        if (isFirst) {
          SyncKpi.watchInitialReads += snapshot.docs.length;
        } else {
          SyncKpi.watchChangeReads += snapshot.docChanges.length;
        }
      } catch (_) {}
      isFirst = false;

      // キャッシュも許容し、即時にローカル表示→裏で最新化
      final items = <T>[];
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          void norm(String k) {
            final dt = FirestoreHelper.timestampToDateTime(data[k]);
            if (dt != null) data[k] = dt.toIso8601String();
          }

          for (final k in const [
            'createdAt',
            'lastModified',
            'lastSynced',
            'executionDate',
            'dueDate',
            'startTime',
            'endTime',
          ]) {
            norm(k);
          }
          final item = createFromCloudJson(data);
          items.add(item);
        } catch (e) {
          // パースエラーは無視
        }
      }
      return items;
    });
    return stream.handleError((e, st) {
      // 監視エラーを握ってUI継続（ネットワーク一時障害対策）
      try {
        print('⚠️ Firestore watch error: $e');
      } catch (_) {}
    });
  }

  // 抽象メソッド - 各データ型で実装
  T createFromCloudJson(Map<String, dynamic> json);
  Future<List<T>> getLocalItems();
  Future<T?> getLocalItemByCloudId(String cloudId);
  Future<void> saveToLocal(T item);
  Future<T> handleManualConflict(T local, T remote);
  Future<void> deleteLocalItem(T item);
}

/// Firestore操作のヘルパー
class FirestoreHelper {
  /// Timestampを安全にDateTimeに変換
  static DateTime? timestampToDateTime(dynamic timestamp) {
    if (timestamp is Timestamp) {
      return timestamp.toDate();
    }
    if (timestamp is String) {
      return DateTime.tryParse(timestamp);
    }
    return null;
  }

  /// DateTimeをFirestore互換の文字列に変換
  static String dateTimeToString(DateTime dateTime) {
    return dateTime.toIso8601String();
  }

  /// 安全にリストを取得
  static List<T> safeList<T>(dynamic value, T Function(dynamic) converter) {
    if (value is List) {
      return value.map(converter).toList();
    }
    return [];
  }
}
