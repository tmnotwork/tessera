import '../models/block.dart';
import 'block_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'block_local_data_manager.dart';
import 'sync_kpi.dart';

/// ブロックのCloud操作を担当するクラス
class BlockCloudOperations {
  /// CloudJSONからBlockオブジェクトを作成
  static Block createFromCloudJson(Map<String, dynamic> json) {
    try {
      // 一部の古いデータではフィールドに id が入っていない場合があるため、cloudId を代用
      final normalized = Map<String, dynamic>.from(json);

      final dynamic rawId = normalized['id'];
      if (rawId == null || (rawId is String && rawId.isEmpty)) {
        final cid = normalized['cloudId'];
        if (cid is String && cid.isNotEmpty) {
          normalized['id'] = cid;
        }
      }

      // Timestamp/String 正規化（パース失敗防止）
      DateTime? dt0(dynamic v) => FirestoreHelper.timestampToDateTime(v);
      void norm(String key) {
        final dt = dt0(normalized[key]);
        if (dt != null) normalized[key] = dt.toIso8601String();
      }

      norm('createdAt');
      norm('lastModified');
      norm('lastSynced');
      norm('executionDate');
      norm('dueDate');

      return Block.fromJson(normalized);
    } catch (e) {
      print('❌ ERROR: Failed to create Block from cloud JSON: $e');
      rethrow;
    }
  }

  /// Firebaseへのアップロード（競合チェック付き）
  static Future<void> uploadToFirebase(Block item, dynamic syncService,
      CollectionReference userCollection) async {
    // Guard against overwriting newer remote
    try {
      print(
          '🔼 BLOCK UPLOAD: id=${item.id} cloudId=${item.cloudId} isSkipped=${item.isSkipped} isDeleted=${item.isDeleted} lastModified=${item.lastModified.toIso8601String()}');
      final String? key = (item.cloudId != null && item.cloudId!.isNotEmpty)
          ? item.cloudId
          : item.id;
      if (key != null && key.isNotEmpty) {
        final doc = await userCollection
            .doc(key)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 10));
        if (doc.exists) {
          final data = doc.data() as Map<String, dynamic>;
          if ((data['isDeleted'] ?? false) == true) {
            // Firebaseに削除済みゴミが残っている場合、物理削除してから新規ブロックをアップロード
            print(
                '🗑️ CLEANUP: Removing deleted ghost from Firebase cloudId=$key');
            try {
              await userCollection.doc(key).delete();
              try {
                SyncKpi.writes += 1;
              } catch (_) {}
              print(
                  '✅ CLEANUP: Deleted ghost successfully, proceeding with upload');
              // ゴミを削除したので、通常のアップロード処理を続行
            } catch (deleteError) {
              print('❌ CLEANUP: Failed to delete ghost: $deleteError');
              print('⛔ BLOCK UPLOAD ABORT: remote isDeleted=true cloudId=$key');
              return;
            }
          } else {
            DateTime? remoteLm;
            final lmRaw = data['lastModified'];
            if (lmRaw is String) remoteLm = DateTime.tryParse(lmRaw);
            if (lmRaw is Timestamp) remoteLm = lmRaw.toDate();
            // Prefer version to avoid clock-skew rollbacks.
            // - If remote.version > local.version -> treat remote as newer.
            // - If versions equal or missing -> fall back to lastModified.
            int? remoteVersion;
            final vRaw = data['version'];
            if (vRaw is int) {
              remoteVersion = vRaw;
            } else if (vRaw is num) {
              remoteVersion = vRaw.toInt();
            } else if (vRaw is String) {
              remoteVersion = int.tryParse(vRaw);
            }
            final localVersion = item.version;

            final bool remoteNewerByVersion = (remoteVersion != null) &&
                (remoteVersion > localVersion);
            final bool versionsComparable =
                (remoteVersion != null) && (remoteVersion == localVersion);
            final bool remoteNewerByTime = remoteLm != null &&
                remoteLm.isAfter(item.lastModified);

            final bool remoteIsNewer =
                remoteNewerByVersion || (versionsComparable && remoteNewerByTime) ||
                    (remoteVersion == null && remoteNewerByTime);

            try {
              final reason = remoteNewerByVersion
                  ? 'remote.version(${remoteVersion}) > local.version($localVersion)'
                  : (remoteNewerByTime
                      ? (remoteVersion == null
                          ? 'remote.lastModified newer (remote.version missing)'
                          : (versionsComparable
                              ? 'same version, remote.lastModified newer'
                              : 'remote.lastModified newer (version differs but not greater)'))
                      : 'local wins');
              print(
                  '🧪 BLOCK UPLOAD GUARD: cloudId=${doc.id} remoteVersion=${remoteVersion ?? '(missing)'} localVersion=$localVersion remoteLm=${remoteLm?.toIso8601String() ?? '(missing)'} localLm=${item.lastModified.toIso8601String()} decision=${remoteIsNewer ? 'CANCEL(local<-remote)' : 'PROCEED(upload)'} reason=$reason');
            } catch (_) {}

            if (remoteIsNewer) {
              // Remote newer -> adopt to local and stop
              try {
                final merged =
                    createFromCloudJson({...data, 'cloudId': doc.id});
                print(
                    '↩️ REMOTE NEWER: cloudId=${doc.id} applying remote to local');
                await BlockLocalDataManager.saveToLocal(merged);
                print(
                    '↩️ BLOCK UPLOAD CANCELLED: remote newer (remote=${remoteLm?.toIso8601String() ?? '(missing)'})');
              } catch (_) {}
              return;
            }
          }
        }
      }
    } catch (_) {}

    // 親クラスのアップロード処理を実行
    await _performActualUpload(item, syncService);
    try {
      await BlockService.updateBlock(item);
      print(
          '✅ BLOCK UPLOADED: cloudId=${item.cloudId} isSkipped=${item.isSkipped}');
      // Post-write server verification GET removed to reduce read counts
    } catch (_) {}
  }

  /// ローカルアイテムの更新
  static Future<void> updateLocalItem(Block item) async {
    try {
      await BlockService.updateBlock(item);
    } catch (_) {}
  }

  /// Cloud IDの生成
  static String generateCloudId(String deviceId, DateTime timestamp) {
    return 'blk_${deviceId}_${timestamp.microsecondsSinceEpoch}';
  }

  /// Cloud JSONの正規化
  static Map<String, dynamic> normalizeCloudJson(Map<String, dynamic> json) {
    final normalized = Map<String, dynamic>.from(json);

    // ID の正規化
    final dynamic rawId = normalized['id'];
    if (rawId == null || (rawId is String && rawId.isEmpty)) {
      final cid = normalized['cloudId'];
      if (cid is String && cid.isNotEmpty) {
        normalized['id'] = cid;
      }
    }

    return normalized;
  }

  /// Timestampの正規化
  static void normalizeTimestamps(Map<String, dynamic> json) {
    DateTime? dt0(dynamic v) => FirestoreHelper.timestampToDateTime(v);
    void norm(String key) {
      final dt = dt0(json[key]);
      if (dt != null) json[key] = dt.toIso8601String();
    }

    norm('createdAt');
    norm('lastModified');
    norm('lastSynced');
    norm('executionDate');
    norm('dueDate');
  }

  /// 実際のアップロード処理（内部メソッド）
  static Future<void> _performActualUpload(
      Block item, dynamic syncService) async {
    // DataSyncServiceの親クラスのuploadToFirebaseメソッドを呼び出す
    try {
      await syncService.uploadToFirebaseInternal(item);
    } catch (e) {
      print('❌ Failed to upload to Firebase: $e');
      rethrow;
    }
  }

  /// リモートデータの競合チェック
  static Future<bool> hasRemoteConflict(
      Block item, CollectionReference userCollection) async {
    try {
      final String? key = (item.cloudId != null && item.cloudId!.isNotEmpty)
          ? item.cloudId
          : item.id;
      if (key == null || key.isEmpty) return false;

      final doc = await userCollection
          .doc(key)
          .get(const GetOptions(source: Source.server));

      if (!doc.exists) return false;

      final data = doc.data() as Map<String, dynamic>;
      if ((data['isDeleted'] ?? false) == true) return false;

      DateTime? remoteLm;
      final lmRaw = data['lastModified'];
      if (lmRaw is String) remoteLm = DateTime.tryParse(lmRaw);
      if (lmRaw is Timestamp) remoteLm = lmRaw.toDate();

      return remoteLm != null && remoteLm.isAfter(item.lastModified);
    } catch (e) {
      print('⚠️ Failed to check remote conflict: $e');
      return false;
    }
  }

  /// リモートデータの取得と適用
  static Future<Block?> fetchAndApplyRemote(
      String key, CollectionReference userCollection) async {
    try {
      final doc = await userCollection
          .doc(key)
          .get(const GetOptions(source: Source.server));

      if (!doc.exists) return null;

      final data = doc.data() as Map<String, dynamic>;
      if ((data['isDeleted'] ?? false) == true) return null;

      final normalized = {...data, 'cloudId': doc.id};
      try {
        print(
            '🧪 FETCH-REMOTE: cid=${doc.id} isSkipped=${data.containsKey('isSkipped') ? data['isSkipped'] : '(missing)'} isCompleted=${data.containsKey('isCompleted') ? data['isCompleted'] : '(missing)'} lastModified=${data['lastModified']}');
      } catch (_) {}
      print(
          '⬇️ APPLY REMOTE: cloudId=${doc.id} applying remote to local (preserve missing keys)');
      await BlockLocalDataManager.applyRemoteJsonToLocal(normalized);
      try {
        // Return a Block instance for callers that expect it
        return createFromCloudJson(normalized);
      } catch (_) {
        return null;
      }
    } catch (e) {
      print('⚠️ Failed to fetch and apply remote: $e');
      return null;
    }
  }
}

/// Firestore Helperクラス（Timestampの変換用）
class FirestoreHelper {
  /// TimestampをDateTimeに変換
  static DateTime? timestampToDateTime(dynamic value) {
    if (value == null) return null;
    if (value is String) return DateTime.tryParse(value);
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  /// DateTimeをTimestampに変換
  static Timestamp? dateTimeToTimestamp(DateTime? dateTime) {
    if (dateTime == null) return null;
    return Timestamp.fromDate(dateTime);
  }
}
