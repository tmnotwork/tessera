import 'package:cloud_firestore/cloud_firestore.dart';

import '../hive_service.dart';

/// Firestore差分同期で使うカーソル（Timestamp + docId）
///
/// - 同一Timestampが複数あっても取りこぼさないため、docIdを併用する
/// - Timestampは秒/ナノ秒で永続化する（ミリ秒int保存は禁止）
class SyncCursor {
  final int seconds;
  final int nanos;
  final String docId;

  const SyncCursor({
    required this.seconds,
    required this.nanos,
    required this.docId,
  });

  Timestamp toTimestamp() => Timestamp(seconds, nanos);

  static SyncCursor fromSnapshot({
    required Timestamp timestamp,
    required String docId,
  }) {
    return SyncCursor(
      seconds: timestamp.seconds,
      nanos: timestamp.nanoseconds,
      docId: docId,
    );
  }
}

/// Hive(settingsBox) にカーソルを保存/復元するユーティリティ
class SyncCursorStore {
  // feature flag（移行完了時に true にする。デフォルト false で既存挙動維持）
  static const String _useServerUpdatedAtKey =
      'firebaseSync.useServerUpdatedAt';

  static const String _cardsSecondsKey =
      'firebaseSync.cursor.cards.serverUpdatedAtSeconds';
  static const String _cardsNanosKey =
      'firebaseSync.cursor.cards.serverUpdatedAtNanos';
  static const String _cardsDocIdKey = 'firebaseSync.cursor.cards.docId';

  static const String _decksSecondsKey =
      'firebaseSync.cursor.decks.serverUpdatedAtSeconds';
  static const String _decksNanosKey =
      'firebaseSync.cursor.decks.serverUpdatedAtNanos';
  static const String _decksDocIdKey = 'firebaseSync.cursor.decks.docId';

  static bool isServerUpdatedAtSyncEnabled() {
    final settingsBox = HiveService.getSettingsBox();
    return settingsBox.get(_useServerUpdatedAtKey, defaultValue: false) == true;
  }

  static void setServerUpdatedAtSyncEnabled(bool enabled) {
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put(_useServerUpdatedAtKey, enabled);
  }

  static SyncCursor? loadCardsCursor() {
    final settingsBox = HiveService.getSettingsBox();
    final int? seconds = settingsBox.get(_cardsSecondsKey);
    final int? nanos = settingsBox.get(_cardsNanosKey);
    final String? docId = settingsBox.get(_cardsDocIdKey);
    if (seconds == null || nanos == null || docId == null || docId.isEmpty) {
      return null;
    }
    return SyncCursor(seconds: seconds, nanos: nanos, docId: docId);
  }

  static SyncCursor? loadDecksCursor() {
    final settingsBox = HiveService.getSettingsBox();
    final int? seconds = settingsBox.get(_decksSecondsKey);
    final int? nanos = settingsBox.get(_decksNanosKey);
    final String? docId = settingsBox.get(_decksDocIdKey);
    if (seconds == null || nanos == null || docId == null || docId.isEmpty) {
      return null;
    }
    return SyncCursor(seconds: seconds, nanos: nanos, docId: docId);
  }

  static void saveCardsCursor(SyncCursor cursor) {
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put(_cardsSecondsKey, cursor.seconds);
    settingsBox.put(_cardsNanosKey, cursor.nanos);
    settingsBox.put(_cardsDocIdKey, cursor.docId);
  }

  static void saveDecksCursor(SyncCursor cursor) {
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put(_decksSecondsKey, cursor.seconds);
    settingsBox.put(_decksNanosKey, cursor.nanos);
    settingsBox.put(_decksDocIdKey, cursor.docId);
  }

  static void clearCardsCursor() {
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.delete(_cardsSecondsKey);
    settingsBox.delete(_cardsNanosKey);
    settingsBox.delete(_cardsDocIdKey);
  }

  static void clearDecksCursor() {
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.delete(_decksSecondsKey);
    settingsBox.delete(_decksNanosKey);
    settingsBox.delete(_decksDocIdKey);
  }
}

/// 移行期間の削除ログ（card_operations / deck_operations）を「増分」で読むためのカーソルとローカルキャッシュ
class DeletionLogCursorStore {
  DeletionLogCursorStore._();

  // card_operations/deck_operations は uid 配下なので、settingsBox 側に保存してよい（uid切替時にクリア推奨）
  static const String _cardOpsSecondsKey =
      'firebaseSync.cursor.deletionLog.cards.timestampSeconds';
  static const String _cardOpsNanosKey =
      'firebaseSync.cursor.deletionLog.cards.timestampNanos';
  static const String _cardOpsDocIdKey =
      'firebaseSync.cursor.deletionLog.cards.docId';

  static const String _deckOpsSecondsKey =
      'firebaseSync.cursor.deletionLog.decks.timestampSeconds';
  static const String _deckOpsNanosKey =
      'firebaseSync.cursor.deletionLog.decks.timestampNanos';
  static const String _deckOpsDocIdKey =
      'firebaseSync.cursor.deletionLog.decks.docId';

  static const String _clearedOpsSecondsKey =
      'firebaseSync.cursor.deletionLog.cleared.timestampSeconds';
  static const String _clearedOpsNanosKey =
      'firebaseSync.cursor.deletionLog.cleared.timestampNanos';
  static const String _clearedOpsDocIdKey =
      'firebaseSync.cursor.deletionLog.cleared.docId';

  static const String _deletedCardIdsCacheKey =
      'firebaseSync.cache.deletionLog.deletedCardIds';
  static const String _deletedDeckNamesCacheKey =
      'firebaseSync.cache.deletionLog.deletedDeckNames';
  static const String _clearedDeckNamesCacheKey =
      'firebaseSync.cache.deletionLog.clearedDeckNames';

  static SyncCursor? loadDeletedCardOpsCursor() {
    final box = HiveService.getSettingsBox();
    final int? seconds = box.get(_cardOpsSecondsKey);
    final int? nanos = box.get(_cardOpsNanosKey);
    final String? docId = box.get(_cardOpsDocIdKey);
    if (seconds == null || nanos == null || docId == null || docId.isEmpty) {
      return null;
    }
    return SyncCursor(seconds: seconds, nanos: nanos, docId: docId);
  }

  static void saveDeletedCardOpsCursor(SyncCursor cursor) {
    final box = HiveService.getSettingsBox();
    box.put(_cardOpsSecondsKey, cursor.seconds);
    box.put(_cardOpsNanosKey, cursor.nanos);
    box.put(_cardOpsDocIdKey, cursor.docId);
  }

  static SyncCursor? loadDeletedDeckOpsCursor() {
    final box = HiveService.getSettingsBox();
    final int? seconds = box.get(_deckOpsSecondsKey);
    final int? nanos = box.get(_deckOpsNanosKey);
    final String? docId = box.get(_deckOpsDocIdKey);
    if (seconds == null || nanos == null || docId == null || docId.isEmpty) {
      return null;
    }
    return SyncCursor(seconds: seconds, nanos: nanos, docId: docId);
  }

  static void saveDeletedDeckOpsCursor(SyncCursor cursor) {
    final box = HiveService.getSettingsBox();
    box.put(_deckOpsSecondsKey, cursor.seconds);
    box.put(_deckOpsNanosKey, cursor.nanos);
    box.put(_deckOpsDocIdKey, cursor.docId);
  }

  static SyncCursor? loadClearedDeckOpsCursor() {
    final box = HiveService.getSettingsBox();
    final int? seconds = box.get(_clearedOpsSecondsKey);
    final int? nanos = box.get(_clearedOpsNanosKey);
    final String? docId = box.get(_clearedOpsDocIdKey);
    if (seconds == null || nanos == null || docId == null || docId.isEmpty) {
      return null;
    }
    return SyncCursor(seconds: seconds, nanos: nanos, docId: docId);
  }

  static void saveClearedDeckOpsCursor(SyncCursor cursor) {
    final box = HiveService.getSettingsBox();
    box.put(_clearedOpsSecondsKey, cursor.seconds);
    box.put(_clearedOpsNanosKey, cursor.nanos);
    box.put(_clearedOpsDocIdKey, cursor.docId);
  }

  static Set<String> loadDeletedCardIdsCache() {
    final box = HiveService.getSettingsBox();
    final dynamic v = box.get(_deletedCardIdsCacheKey);
    if (v is List) {
      return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toSet();
    }
    return <String>{};
  }

  static void saveDeletedCardIdsCache(Set<String> ids) {
    final box = HiveService.getSettingsBox();
    box.put(_deletedCardIdsCacheKey, ids.toList());
  }

  static Set<String> loadDeletedDeckNamesCache() {
    final box = HiveService.getSettingsBox();
    final dynamic v = box.get(_deletedDeckNamesCacheKey);
    if (v is List) {
      return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toSet();
    }
    return <String>{};
  }

  static void saveDeletedDeckNamesCache(Set<String> names) {
    final box = HiveService.getSettingsBox();
    box.put(_deletedDeckNamesCacheKey, names.toList());
  }

  static Set<String> loadClearedDeckNamesCache() {
    final box = HiveService.getSettingsBox();
    final dynamic v = box.get(_clearedDeckNamesCacheKey);
    if (v is List) {
      return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toSet();
    }
    return <String>{};
  }

  static void saveClearedDeckNamesCache(Set<String> names) {
    final box = HiveService.getSettingsBox();
    box.put(_clearedDeckNamesCacheKey, names.toList());
  }
}


