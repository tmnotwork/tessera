import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import '../../models/deck.dart';
import '../../models/flashcard.dart';
import '../firebase_service.dart';
import '../hive_service.dart';
import 'feature_flags.dart';

/// Phase 2.5: 永続キュー（pending operations）
///
/// 目的:
/// - オフライン/ネットワーク不安定時でも、ローカル変更を「必ず」後でクラウドに反映させる
/// - アプリ再起動を跨いでも残る（Hiveに永続化）
///
/// 注意:
/// - 本実装は「まず既存挙動を壊さない」ために、現状の即時同期を維持しつつ
///   “同期失敗時にキューへ積む” 方式で導入する。
/// - 計画書の理想（ローカル反映 + enqueue を原子化）に進む前段階として使う。
class PendingOperationsService {
  PendingOperationsService._();

  static const _uuid = Uuid();

  static const String _enabledKey = 'firebaseSync.pendingOps.enabled';

  static bool isEnabled() {
    final settingsBox = HiveService.getSettingsBox();
    return settingsBox.get(_enabledKey, defaultValue: true) == true;
  }

  static void setEnabled(bool enabled) {
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put(_enabledKey, enabled);
  }

  static String _boxName(String uid) => 'pending_operations_$uid';

  static Future<Box<Map>> _openBox(String uid) async {
    return Hive.openBox<Map>(_boxName(uid));
  }

  static Map<String, dynamic> _serializeCardPayload(FlashCard card) {
    int? nextReviewMillis;
    if (card.nextReview != null) {
      nextReviewMillis = card.nextReview!.millisecondsSinceEpoch;
    }

    return {
      'question': card.question,
      'answer': card.answer,
      'explanation': card.explanation,
      'deckName': card.deckName,
      'chapter': card.chapter,
      'headline': card.headline,
      'supplement': card.supplement ?? '',
      'nextReviewMillis': nextReviewMillis,
      'repetitions': card.repetitions,
      'eFactor': card.eFactor,
      'intervalDays': card.intervalDays,
      'questionEnglishFlag': card.questionEnglishFlag,
      'answerEnglishFlag': card.answerEnglishFlag,
      'updatedAtMillis': card.updatedAt,
    };
  }

  static FlashCard _cloneCard(FlashCard c) {
    // HiveObject をそのまま使い回すと rollback で参照が壊れるので、値コピーで作り直す
    return FlashCard(
      id: c.id,
      question: c.question,
      answer: c.answer,
      explanation: c.explanation,
      deckName: c.deckName,
      nextReview: c.nextReview,
      repetitions: c.repetitions,
      eFactor: c.eFactor,
      intervalDays: c.intervalDays,
      questionEnglishFlag: c.questionEnglishFlag,
      answerEnglishFlag: c.answerEnglishFlag,
      firestoreId: c.firestoreId,
      firestoreUpdatedAt: c.firestoreUpdatedAt,
      updatedAt: c.updatedAt,
      chapter: c.chapter,
      firestoreCreatedAt: c.firestoreCreatedAt,
      headline: c.headline,
      supplement: c.supplement,
      isDeleted: c.isDeleted,
      deletedAt: c.deletedAt,
    );
  }

  static Deck _cloneDeck(Deck d) {
    return Deck(
      id: d.id,
      deckName: d.deckName,
      questionEnglishFlag: d.questionEnglishFlag,
      answerEnglishFlag: d.answerEnglishFlag,
      description: d.description,
      isArchived: d.isArchived,
      firestoreUpdatedAt: d.firestoreUpdatedAt,
      isDeleted: d.isDeleted,
      deletedAt: d.deletedAt,
    );
  }

  /// Phase 2.5（完成形）: ローカル反映＋enqueue を同一クリティカルセクションで実行する
  ///
  /// - enqueue が失敗したらローカル変更をロールバックする
  /// - 成功時に opId を返す（即時同期が成功したら削除してもよい）
  static Future<String?> putCardAndMaybeEnqueue(FlashCard card,
      {dynamic hiveKey}) async {
    final key = hiveKey ?? (card.id.isNotEmpty ? card.id : card.key);
    if (key == null) return null;
    final box = HiveService.getCardBox();
    final prev = box.get(key);
    final FlashCard? prevCopy = prev != null ? _cloneCard(prev) : null;

    try {
      await box.put(key, card);
      if (!FirebaseSyncFeatureFlags.alwaysEnqueueOnLocalWrite()) return null;
      final opId = await enqueueCardUpsert(card);
      if (opId == null) {
        throw Exception('pending enqueue failed (card upsert)');
      }
      return opId;
    } catch (_) {
      if (prevCopy != null) {
        await box.put(key, prevCopy);
      } else {
        await box.delete(key);
      }
      rethrow;
    }
  }

  static Future<String?> deleteCardAndMaybeEnqueue(dynamic hiveKey,
      {required String? firestoreId}) async {
    final key = hiveKey;
    if (key == null) return null;
    final box = HiveService.getCardBox();
    final prev = box.get(key);
    if (prev == null) return null;
    final prevCopy = _cloneCard(prev);

    try {
      await box.delete(key);
      if (!FirebaseSyncFeatureFlags.alwaysEnqueueOnLocalWrite()) return null;
      final targetId =
          (firestoreId != null && firestoreId.isNotEmpty) ? firestoreId : prev.id;
      if (targetId.isEmpty) return null;
      final opId = await enqueueCardDelete(targetId);
      if (opId == null) {
        throw Exception('pending enqueue failed (card delete)');
      }
      return opId;
    } catch (_) {
      await box.put(key, prevCopy);
      rethrow;
    }
  }

  static Future<String?> putDeckAndMaybeEnqueue(Deck deck,
      {dynamic hiveKey}) async {
    final key = hiveKey ?? (deck.id.isNotEmpty ? deck.id : deck.key);
    if (key == null) return null;
    final box = HiveService.getDeckBox();
    final prev = box.get(key);
    final Deck? prevCopy = prev != null ? _cloneDeck(prev) : null;

    try {
      await box.put(key, deck);
      if (!FirebaseSyncFeatureFlags.alwaysEnqueueOnLocalWrite()) return null;
      final opId = await enqueueDeckUpsert(deck);
      if (opId == null) {
        throw Exception('pending enqueue failed (deck upsert)');
      }
      return opId;
    } catch (_) {
      if (prevCopy != null) {
        await box.put(key, prevCopy);
      } else {
        await box.delete(key);
      }
      rethrow;
    }
  }

  static Future<String?> deleteDeckAndMaybeEnqueue(dynamic hiveKey,
      {required String deckName}) async {
    final key = hiveKey;
    if (key == null) return null;
    final box = HiveService.getDeckBox();
    final prev = box.get(key);
    if (prev == null) return null;
    final prevCopy = _cloneDeck(prev);

    try {
      await box.delete(key);
      if (!FirebaseSyncFeatureFlags.alwaysEnqueueOnLocalWrite()) return null;
      final opId = await enqueueDeckDeleteByName(deckName);
      if (opId == null) {
        throw Exception('pending enqueue failed (deck delete)');
      }
      return opId;
    } catch (_) {
      await box.put(key, prevCopy);
      rethrow;
    }
  }

  static Map<String, dynamic> _serializeDeckPayload(Deck deck) {
    return {
      'deckName': deck.deckName,
      'description': deck.description,
      'questionEnglishFlag': deck.questionEnglishFlag,
      'answerEnglishFlag': deck.answerEnglishFlag,
      'isArchived': deck.isArchived,
    };
  }

  static Future<String?> enqueueCardUpsert(FlashCard card, {String? uid}) async {
    final userId = uid ?? FirebaseService.getUserId();
    if (userId == null || !isEnabled()) return null;

    final targetDocId = (card.firestoreId != null && card.firestoreId!.isNotEmpty)
        ? card.firestoreId!
        : card.id;
    if (targetDocId.isEmpty) return null;

    final opId = _uuid.v4();
    final op = <String, dynamic>{
      'opId': opId,
      'uid': userId,
      'entityType': 'card',
      'opType': 'upsert',
      'targetDocId': targetDocId,
      'payload': _serializeCardPayload(card),
      'enqueuedAtMillis': DateTime.now().millisecondsSinceEpoch,
      // 競合検知用（今は未使用だが将来用に枠を用意）
      'baseServerUpdatedAtSeconds': null,
      'baseServerUpdatedAtNanos': null,
    };

    final box = await _openBox(userId);
    await box.put(opId, op);
    return opId;
  }

  static Future<String?> enqueueCardDelete(String firestoreId,
      {String? uid}) async {
    final userId = uid ?? FirebaseService.getUserId();
    if (userId == null || !isEnabled()) return null;
    if (firestoreId.isEmpty) return null;

    final opId = _uuid.v4();
    final op = <String, dynamic>{
      'opId': opId,
      'uid': userId,
      'entityType': 'card',
      'opType': 'delete',
      'targetDocId': firestoreId,
      'payload': <String, dynamic>{},
      'enqueuedAtMillis': DateTime.now().millisecondsSinceEpoch,
      'baseServerUpdatedAtSeconds': null,
      'baseServerUpdatedAtNanos': null,
    };

    final box = await _openBox(userId);
    await box.put(opId, op);
    return opId;
  }

  static Future<String?> enqueueDeckDeleteByName(String deckName,
      {String? uid}) async {
    final userId = uid ?? FirebaseService.getUserId();
    if (userId == null || !isEnabled()) return null;
    if (deckName.trim().isEmpty) return null;

    final opId = _uuid.v4();
    final op = <String, dynamic>{
      'opId': opId,
      'uid': userId,
      'entityType': 'deck',
      'opType': 'delete_by_name',
      'targetDocId': deckName.trim(),
      'payload': <String, dynamic>{'deckName': deckName.trim()},
      'enqueuedAtMillis': DateTime.now().millisecondsSinceEpoch,
      'baseServerUpdatedAtSeconds': null,
      'baseServerUpdatedAtNanos': null,
    };

    final box = await _openBox(userId);
    await box.put(opId, op);
    return opId;
  }

  static Future<String?> enqueueDeckUpsert(Deck deck, {String? uid}) async {
    final userId = uid ?? FirebaseService.getUserId();
    if (userId == null || !isEnabled()) return null;

    final targetDocId = deck.id;
    if (targetDocId.isEmpty) return null;

    final opId = _uuid.v4();
    final op = <String, dynamic>{
      'opId': opId,
      'uid': userId,
      'entityType': 'deck',
      'opType': 'upsert',
      'targetDocId': targetDocId,
      'payload': _serializeDeckPayload(deck),
      'enqueuedAtMillis': DateTime.now().millisecondsSinceEpoch,
      'baseServerUpdatedAtSeconds': null,
      'baseServerUpdatedAtNanos': null,
    };

    final box = await _openBox(userId);
    await box.put(opId, op);
    return opId;
  }

  /// キューを縮約して返す（同一 targetDocId の最後の状態のみ残す）
  static List<Map> _coalesce(List<Map> ops) {
    final latestByTarget = <String, Map>{};
    for (final op in ops) {
      final target = (op['targetDocId'] ?? '').toString();
      if (target.isEmpty) continue;
      final prev = latestByTarget[target];
      if (prev == null) {
        latestByTarget[target] = op;
        continue;
      }
      final prevAt = (prev['enqueuedAtMillis'] as int?) ?? 0;
      final nextAt = (op['enqueuedAtMillis'] as int?) ?? 0;
      if (nextAt >= prevAt) {
        latestByTarget[target] = op;
      }
    }

    final result = latestByTarget.values.toList();
    result.sort((a, b) {
      final aAt = (a['enqueuedAtMillis'] as int?) ?? 0;
      final bAt = (b['enqueuedAtMillis'] as int?) ?? 0;
      return aAt.compareTo(bAt);
    });
    return result;
  }

  static Future<bool> flushPendingOperations() async {
    final userId = FirebaseService.getUserId();
    if (userId == null || !isEnabled()) return true;

    final box = await _openBox(userId);
    if (box.isEmpty) return true;

    // 誤送信防止: uidが一致しない要素は無視（基本的に入らない想定）
    final allOps = box.values
        .whereType<Map>()
        .where((m) => (m['uid'] ?? '').toString() == userId)
        .toList();

    final ops = _coalesce(allOps);
    if (ops.isEmpty) return true;

    bool allFlushed = true;

    for (final op in ops) {
      final opId = (op['opId'] ?? '').toString();
      final entityType = (op['entityType'] ?? '').toString();
      final opType = (op['opType'] ?? '').toString();
      final targetDocId = (op['targetDocId'] ?? '').toString();
      final payload = (op['payload'] is Map) ? (op['payload'] as Map) : <String, dynamic>{};

      if (opId.isEmpty || entityType.isEmpty || opType.isEmpty || targetDocId.isEmpty) {
        // 不正データは捨てる（無限リトライ防止）
        await box.delete(opId);
        continue;
      }

      try {
        if (entityType == 'card' && opType == 'upsert') {
          await _flushCardUpsert(targetDocId, payload.cast<String, dynamic>());
        } else if (entityType == 'card' && opType == 'delete') {
          await FirebaseService.deleteCard(targetDocId);
        } else if (entityType == 'deck' && opType == 'upsert') {
          await _flushDeckUpsert(targetDocId, payload.cast<String, dynamic>());
        } else if (entityType == 'deck' && opType == 'delete_by_name') {
          final deckName = (payload['deckName'] ?? targetDocId).toString();
          final deletePath = await FirebaseService.findDeckByName(deckName);
          if (deletePath != null) {
            await FirebaseService.deleteDeckByPath(deletePath);
          }
        } else {
          // 未対応は捨てる（無限リトライ防止）
        }

        // 成功したopを削除（部分成功）
        await box.delete(opId);
      } catch (e) {
        // ネットワーク系は後で再試行（ここでは停止）
        allFlushed = false;
        break;
      }
    }

    return allFlushed;
  }

  static Future<void> deleteOpById(String opId, {String? uid}) async {
    final userId = uid ?? FirebaseService.getUserId();
    if (userId == null) return;
    final box = await _openBox(userId);
    await box.delete(opId);
  }

  static Future<void> _flushCardUpsert(
      String docId, Map<String, dynamic> payload) async {
    final data = <String, dynamic>{};

    data['question'] = (payload['question'] ?? '').toString();
    data['answer'] = (payload['answer'] ?? '').toString();
    data['explanation'] = (payload['explanation'] ?? '').toString();
    data['deckName'] = (payload['deckName'] ?? '').toString();
    data['chapter'] = (payload['chapter'] ?? '').toString();
    data['headline'] = (payload['headline'] ?? '').toString();
    data['supplement'] = (payload['supplement'] ?? '').toString();
    data['repetitions'] = payload['repetitions'] ?? 0;
    data['eFactor'] = payload['eFactor'] ?? 2.5;
    data['intervalDays'] = payload['intervalDays'] ?? 0;
    data['questionEnglishFlag'] = payload['questionEnglishFlag'] ?? false;
    data['answerEnglishFlag'] = payload['answerEnglishFlag'] ?? true;

    final nextReviewMillis = payload['nextReviewMillis'];
    if (nextReviewMillis is int) {
      data['nextReview'] = Timestamp.fromMillisecondsSinceEpoch(nextReviewMillis);
    }

    // updatedAt / serverUpdatedAt はサーバーで確定させる
    data['updatedAt'] = FieldValue.serverTimestamp();
    data['serverUpdatedAt'] = FieldValue.serverTimestamp();
    data['isDeleted'] = false;

    await FirebaseService.firestore
        .collection('users/${FirebaseService.getUserId()}/cards')
        .doc(docId)
        .set(data, SetOptions(merge: true));
  }

  static Future<void> _flushDeckUpsert(
      String docId, Map<String, dynamic> payload) async {
    final data = <String, dynamic>{
      'deckName': (payload['deckName'] ?? '').toString(),
      'description': (payload['description'] ?? '').toString(),
      'questionEnglishFlag': payload['questionEnglishFlag'] ?? false,
      'answerEnglishFlag': payload['answerEnglishFlag'] ?? true,
      'isArchived': payload['isArchived'] ?? false,
      'updatedAt': FieldValue.serverTimestamp(),
      'serverUpdatedAt': FieldValue.serverTimestamp(),
      'isDeleted': false,
    };

    await FirebaseService.firestore
        .collection('users/${FirebaseService.getUserId()}/decks')
        .doc(docId)
        .set(data, SetOptions(merge: true));
  }
}

/// Phase 2.5: オンライン復帰の検知
class PendingOpsConnectivityMonitor {
  PendingOpsConnectivityMonitor._();

  static StreamSubscription<List<ConnectivityResult>>? _sub;

  static void start() {
    _sub?.cancel();
    _sub = Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) async {
      final isOnline = results.any((r) => r != ConnectivityResult.none);
      if (!isOnline) return;

      // online遷移時に即時flush（失敗しても次回に回す）
      try {
        await PendingOperationsService.flushPendingOperations();
      } catch (_) {}
    });
  }

  static void stop() {
    _sub?.cancel();
    _sub = null;
  }
}

