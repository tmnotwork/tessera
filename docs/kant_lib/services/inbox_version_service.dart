import 'package:cloud_firestore/cloud_firestore.dart';

import 'auth_service.dart';
import 'app_settings_service.dart';
import 'sync_kpi.dart';

/// Inbox の更新検知用 “1ドキュメント” バージョン。
///
/// 目的:
/// - Inbox 画面オープン時の確認を 1 read に固定する（dayVersions の watch を廃止）。
/// - Inbox 以外の更新（block/actual 等）では bump しないため、不要な同期を抑止できる。
class InboxVersionService {
  InboxVersionService._();

  static const String _metaCollection = 'meta';
  static const String _docId = 'inboxVersion';
  static const String _fieldRev = 'rev';
  static const String _fieldUpdatedAt = 'updatedAt';

  /// ローカルに保持する「最後に確認した rev」。
  ///
  /// NOTE: Firestore の rev と一致する保証はない（複数端末で増えるため）。
  /// ただし remoteRev > localSeenRev なら「更新あり」は確実。
  static const String keySeenRev = 'meta.inboxVersion.seenRev';

  static DocumentReference<Map<String, dynamic>>? _docRef() {
    final uid = AuthService.getCurrentUserId();
    if (uid == null || uid.isEmpty) return null;
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection(_metaCollection)
        .doc(_docId);
  }

  static int getLocalSeenRev() {
    try {
      return AppSettingsService.getInt(keySeenRev, defaultValue: 0);
    } catch (_) {
      return 0;
    }
  }

  static Future<void> setLocalSeenRev(int value) async {
    try {
      await AppSettingsService.initialize();
    } catch (_) {}
    try {
      await AppSettingsService.setInt(keySeenRev, value);
    } catch (_) {}
  }

  /// リモートの rev を 1回だけ取得する（= 1 doc get）。
  ///
  /// - doc が無い場合は 0 として扱う
  /// - 失敗時は null
  static Future<int?> fetchRemoteRev() async {
    final ref = _docRef();
    if (ref == null) return null;
    try {
      final snap = await ref
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 10));
      try {
        SyncKpi.docGets += 1;
      } catch (_) {}
      if (!snap.exists) return 0;
      final data = snap.data();
      if (data == null) return 0;
      final v = data[_fieldRev];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    } catch (_) {
      return null;
    }
  }

  /// Inbox のクラウド書き込み成功後に bump する（best-effort）。
  static Future<void> bump() async {
    final ref = _docRef();
    if (ref == null) return;
    try {
      await ref.set(
        <String, dynamic>{
          _fieldRev: FieldValue.increment(1),
          _fieldUpdatedAt: FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      try {
        SyncKpi.writes += 1;
      } catch (_) {}
      // ローカル seenRev も “少なくとも増やす” ことで、同一端末での再オープン時に不要同期を減らす。
      try {
        final current = getLocalSeenRev();
        await setLocalSeenRev(current + 1);
      } catch (_) {}
    } catch (_) {
      // bump に失敗しても UI/同期は継続（次回の手動/定期同期で回復する）
    }
  }
}

