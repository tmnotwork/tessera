// ignore_for_file: avoid_print, unused_local_variable, unnecessary_brace_in_string_interps, prefer_adjacent_string_concatenation, curly_braces_in_flow_control_structures

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart'; // FirebaseExceptionとDocumentChangeTypeを使用するために追加
import 'package:hive/hive.dart';
// AlertDialogなどに必要
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/deck.dart';
import '../models/flashcard.dart';
import 'firebase_service.dart';
import 'hive_service.dart';
// 新しく分割したサービスをインポート
import 'sync/critical_operation.dart';
import 'sync/notification_service.dart';
import 'sync/conflict_resolver.dart';
import 'sync/state_manager.dart';
import 'sync/sync_cursor.dart';
import 'sync/pending_operations.dart';
import 'sync/feature_flags.dart';

class SyncService {
  // シングルトンインスタンス
  static final SyncService _instance = SyncService._internal();

  // プライベートコンストラクタ
  SyncService._internal();

  // ファクトリコンストラクタ
  factory SyncService() => _instance;

  // リアルタイム更新の購読オブジェクト
  StreamSubscription? _realtimeSubscription;

  // Hive変更監視の購読（stopで確実に解除する）
  StreamSubscription? _deckBoxWatchSubscription;
  StreamSubscription? _cardBoxWatchSubscription;

  // 自動同期タイマー
  Timer? _autoSyncTimer;

  // データ変更後の遅延同期用タイマー
  Timer? _debounceTimer;

  // /config/sync の読み取り頻度を抑える（read最小化）
  DateTime? _lastRemoteSyncConfigFetchAt;

  // 新しいサービスへの委譲メソッド
  Stream<SyncStatus> get syncStatusStream =>
      SyncStateManager.instance.syncStatusStream;
  SyncStatus get status => SyncStateManager.instance.status;
  static DateTime? getLastSyncTime() =>
      SyncStateManager.instance.getLastSyncTime();
  void _updateStatus(SyncStatus newStatus) =>
      SyncNotificationService.updateStatus(newStatus);
  static void _updateLastSyncTime() => SyncStateManager.instance.completeSync();

  // 強制的にクラウド同期を実行するメソッド
  static Future<bool> forceCloudSync() async {
    print('強制クラウド同期を開始します...');
    // シングルトンインスタンスを取得し、双方向同期を実行
    final instance = SyncService();
    final result = await instance.syncBidirectional();
    print('強制クラウド同期が完了しました。変更の有無: $result');

    // 同期時刻を更新
    _updateLastSyncTime();

    return result;
  }

  // 自動同期を開始
  void startAutoSync({Duration interval = const Duration(minutes: 15)}) {
    // 既存のタイマーがあれば停止
    stopAutoSync();

    // オンライン復帰の検知（pending ops flush）
    PendingOpsConnectivityMonitor.start();

    // Hiveのデータ変更を監視して自動同期
    _setupDataChangeListeners();

    // Phase 4 要件: 起動/ログイン直後は
    // 0) flushPendingOperations
    // 1) 差分get（syncBidirectional 内）
    // 2) 差分購読開始
    //
    // 既存挙動を壊さないため、ここでは「初回同期完了後に購読開始」へ順序を揃える。
    unawaited(_initialSyncThenStartRealtimeAndTimer(interval));
  }

  /// Firestoreの /config/sync を読み、段階導入フラグを自動適用する。
  ///
  /// - 読み取りは最小限（短時間に多重起動しない）
  /// - ドキュメントが存在しない/フィールドがない場合は何もしない（既存挙動維持）
  Future<void> _maybeApplyRemoteSyncConfig() async {
    // 未ログインなら読み取り不要（また、ログイン前に読んでも意味がない）
    if (FirebaseService.getUserId() == null) return;

    final now = DateTime.now();
    if (_lastRemoteSyncConfigFetchAt != null &&
        now.difference(_lastRemoteSyncConfigFetchAt!) <
            const Duration(minutes: 5)) {
      return;
    }
    _lastRemoteSyncConfigFetchAt = now;

    try {
      final snap =
          await FirebaseFirestore.instance.doc('config/sync').get();
      if (!snap.exists) return;
      final data = snap.data();
      if (data == null) return;

      bool? readBool(String key) {
        final v = data[key];
        return v is bool ? v : null;
      }

      // 互換: フィールドがあればそれを優先、なければ何もしない
      final bool? useServerUpdatedAt = readBool('useServerUpdatedAt');
      if (useServerUpdatedAt != null) {
        SyncCursorStore.setServerUpdatedAtSyncEnabled(useServerUpdatedAt);
      }

      final bool? useLogicalDelete = readBool('useLogicalDelete');
      if (useLogicalDelete != null) {
        FirebaseSyncFeatureFlags.setUseLogicalDelete(useLogicalDelete);
      }

      final bool? useIncrementalDeletionLog = readBool('useIncrementalDeletionLog');
      if (useIncrementalDeletionLog != null) {
        FirebaseSyncFeatureFlags.setUseIncrementalDeletionLog(
            useIncrementalDeletionLog);
      }

      final bool? alwaysEnqueueOnLocalWrite = readBool('alwaysEnqueueOnLocalWrite');
      if (alwaysEnqueueOnLocalWrite != null) {
        FirebaseSyncFeatureFlags.setAlwaysEnqueueOnLocalWrite(
            alwaysEnqueueOnLocalWrite);
      }

      print('ℹ️ /config/sync を適用: '
          'useServerUpdatedAt=${useServerUpdatedAt ?? "<unset>"} '
          'useLogicalDelete=${useLogicalDelete ?? "<unset>"} '
          'useIncrementalDeletionLog=${useIncrementalDeletionLog ?? "<unset>"} '
          'alwaysEnqueueOnLocalWrite=${alwaysEnqueueOnLocalWrite ?? "<unset>"}');
    } catch (e) {
      // 失敗しても同期自体は続行（既存挙動維持）
      print('⚠️ /config/sync の取得に失敗: $e');
    }
  }

  Future<void> _initialSyncThenStartRealtimeAndTimer(Duration interval) async {
    try {
      // 段階導入フラグをサーバー側設定から自動適用（読めない場合は何もしない）
      await _maybeApplyRemoteSyncConfig();
      await syncBidirectional();
    } finally {
      // リアルタイム同期をセットアップ（差分get後のカーソルから購読）
      _setupRealtimeSync();

      // 新しいタイマーを開始（初回同期が終わってから）
      _autoSyncTimer = Timer.periodic(interval, (_) {
        syncBidirectional();
      });
    }
  }

  // Hiveデータ変更リスナーの設定
  void _setupDataChangeListeners() {
    // 既存購読があれば解除（startAutoSyncの再呼び出し等で増殖しないようにする）
    _deckBoxWatchSubscription?.cancel();
    _deckBoxWatchSubscription = null;
    _cardBoxWatchSubscription?.cancel();
    _cardBoxWatchSubscription = null;

    // デッキの変更を直接監視
    final deckBox = HiveService.getDeckBox();
    _deckBoxWatchSubscription =
        deckBox.watch().listen((event) => _onDeckBoxEvent(event));

    // カードの変更を直接監視
    final cardBox = HiveService.getCardBox();
    _cardBoxWatchSubscription =
        cardBox.watch().listen((event) => _onCardBoxEvent(event));
  }

  void _onDeckBoxEvent(BoxEvent event) {
    // 重要操作/同期中の反射でenqueueしない（無限ループ・不要送信防止）
    if (CriticalOperationService.isInProgress) return;
    if (SyncStateManager.instance.isSyncing) return;

    if (FirebaseSyncFeatureFlags.alwaysEnqueueOnLocalWrite() &&
        FirebaseService.getUserId() != null &&
        !event.deleted) {
      final deck = HiveService.getDeckBox().get(event.key);
      if (deck != null && !deck.isDeleted) {
        // 失敗しても後続のsyncBidirectionalで救済されるため、ここでは落とさない
        unawaited(PendingOperationsService.enqueueDeckUpsert(deck));
      }
    }

    _onLocalDataChanged();
  }

  void _onCardBoxEvent(BoxEvent event) {
    if (CriticalOperationService.isInProgress) return;
    if (SyncStateManager.instance.isSyncing) return;

    if (FirebaseSyncFeatureFlags.alwaysEnqueueOnLocalWrite() &&
        FirebaseService.getUserId() != null &&
        !event.deleted) {
      final card = HiveService.getCardBox().get(event.key);
      if (card != null && !card.isDeleted) {
        unawaited(PendingOperationsService.enqueueCardUpsert(card));
      }
    }

    _onLocalDataChanged();
  }

  // ローカルデータ変更時の処理
  void _onLocalDataChanged() {
    // ★★★ 重要操作中はスキップ - 新しいサービスを使用 ★★★
    if (CriticalOperationService.isInProgress) {
      print('ローカルデータ変更検知: クリティカル操作中のため同期をスキップ');
      return;
    }
    // すでに同期中の場合は何もしない
    if (SyncStateManager.instance.isSyncing) return;

    // ログインしていない場合は何もしない
    if (FirebaseService.getUserId() == null) return;

    // ユーザーの操作による変更後、短時間での複数回同期を防ぐため
    // 前回のタイマーをキャンセル
    _debounceTimer?.cancel();

    // 3秒後に同期を開始
    _debounceTimer = Timer(const Duration(seconds: 3), () {
      syncBidirectional();
    });
  }

  // 自動同期を停止
  void stopAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;

    _debounceTimer?.cancel();
    _debounceTimer = null;

    // リアルタイム同期購読を解除
    _realtimeSubscription?.cancel();
    _realtimeSubscription = null;
    FirebaseService.stopRealTimeSync();

    // Hive変更監視購読を解除（購読増殖を防止）
    _deckBoxWatchSubscription?.cancel();
    _deckBoxWatchSubscription = null;
    _cardBoxWatchSubscription?.cancel();
    _cardBoxWatchSubscription = null;

    // オンライン復帰監視を停止
    PendingOpsConnectivityMonitor.stop();

    // データ変更リスナーは自動的に破棄される（BoxEvent購読）
  }

  // リアルタイム同期のセットアップ
  void _setupRealtimeSync() {
    // 既存の購読があれば解除
    _realtimeSubscription?.cancel();

    // Firebaseのリアルタイム同期を開始
    FirebaseService.startRealTimeSync();

    // データ変更を監視
    _realtimeSubscription =
        FirebaseService.dataChangeStream.listen((changeData) {
      // ★★★ 重要操作中はスキップ - 新しいサービスを使用 ★★★
      if (CriticalOperationService.isInProgress) {
        print('リアルタイム変更処理開始: クリティカル操作中のため処理を中断');
        return;
      }
      _handleRealtimeChange(changeData);
    });
  }

  // リアルタイム変更のハンドリング
  Future<void> _handleRealtimeChange(Map<String, dynamic> changeData) async {
    // ★★★ 重要操作中はスキップ - 新しいサービスを使用 ★★★
    if (CriticalOperationService.isInProgress) {
      print('リアルタイム変更処理開始: クリティカル操作中のため処理を中断');
      return;
    }
    print('リアルタイム変更を検知: ${changeData.keys.join(', ')}');

    // 同期中の場合は遅延処理
    if (SyncStateManager.instance.isSyncing) {
      print('現在同期中のため、リアルタイム更新を後で処理します');

      // 待機時間を設定（最大5回、各1秒）
      for (int i = 0; i < 5; i++) {
        // 1秒待機
        await Future.delayed(const Duration(seconds: 1));

        // 再チェック - 同期状態が解除されていれば続行
        if (!SyncStateManager.instance.isSyncing) {
          print('同期が完了したため、リアルタイム更新を処理します');
          break;
        }

        // ★★★ 待機中にもクリティカル操作をチェック - 新しいサービスを使用 ★★★
        if (CriticalOperationService.isInProgress) {
          print('リアルタイム更新待機中: クリティカル操作が開始されたため処理を中断');
          return;
        }

        // 最大待機回数に達したらログを出力
        if (i == 4) {
          print('リアルタイム更新の待機がタイムアウトしました。同期後に再取得されるでしょう');
          return; // 処理を中断
        }
      }
    }

    try {
      // 同期中フラグをセット（リアルタイム更新中の他の同期を防止）
      SyncStateManager.instance.startSync();

      final type = changeData['type'];
      final changeTypeStr = changeData['changeType'] as String? ??
          ''; // 例: "DocumentChangeType.added"
      final changeType =
          _parseChangeType(changeTypeStr); // ★★★ ヘルパーメソッド呼び出し ★★★
      final Map<String, dynamic>? meta =
          changeData['meta'] is Map ? (changeData['meta'] as Map).cast<String, dynamic>() : null;

      if (type == 'deck') {
        // ★★★ changeData['data'] を Deck にキャスト ★★★
        final Deck deck = changeData['data'] as Deck;
        await _handleDeckChange(deck, changeTypeStr); // 古い引数を維持
        _maybeAdvanceRealtimeCursor(entityType: 'deck', meta: meta);
      } else if (type == 'card') {
        // ★★★ changeData['data'] を FlashCard にキャスト ★★★
        final FlashCard cloudCard = changeData['data'] as FlashCard;
        final firestoreId = cloudCard.firestoreId; // キャスト後なら直接アクセス可能

        if (firestoreId == null || firestoreId.isEmpty) {
          print('⚠️ リアルタイム変更: Firestore ID がないカードデータを受信しました。スキップします。');
        } else {
          print('⚡️ リアルタイム カード変更: ID=$firestoreId, Type=$changeTypeStr');
          final cardBox = HiveService.getCardBox();
          FlashCard? localCard;
          dynamic localCardKey; // Hiveのキーを保持

          // ローカルで同じ Firestore ID を持つカードを探す
          for (var key in cardBox.keys) {
            final card = cardBox.get(key);
            if (card != null && card.firestoreId == firestoreId) {
              localCard = card;
              localCardKey = key;
              break;
            }
          }

          switch (changeType) {
            case DocumentChangeType.added:
            case DocumentChangeType.modified:
              if (localCard != null) {
                // ローカルに存在 -> 更新
                print('  -> ローカルカードを更新 (ID: $firestoreId)');
                final changed = _resolveCardConflict(localCard, cloudCard);
                if (changed) {
                  await localCard.save(); // Hiveキーは変わらない
                }
              } else {
                // ローカルに存在しない -> 追加
                print('  -> ローカルにカードを追加 (ID: $firestoreId)');
                // ローカルに暫定キーで存在していないか念のため走査して統合
                dynamic provisionalKey;
                for (var k in cardBox.keys) {
                  final c = cardBox.get(k);
                  if (c != null && (c.firestoreId == null || c.firestoreId!.isEmpty)) {
                    // 内容が同じ可能性をチェック（デッキ名/質問/回答）
                    final sameContent =
                        c.deckName == cloudCard.deckName &&
                        c.question.trim() == cloudCard.question.trim() &&
                        c.answer.trim() == cloudCard.answer.trim();
                    if (sameContent) {
                      provisionalKey = k;
                      break;
                    }
                  }
                }
                if (provisionalKey != null) {
                  // 暫定カードへIDを紐付けてリキー
                  final provisional = cardBox.get(provisionalKey);
                  if (provisional != null) {
                    provisional.firestoreId = firestoreId;
                    provisional.id = firestoreId; // ローカルIDも揃える
                    // 値はクラウドを優先して更新
                    ConflictResolver.updateLocalCardFromCloud(provisional, cloudCard);
                    await provisional.save();
                    // キーを firestoreId に統一
                    await HiveService.rekeyCard(provisionalKey, firestoreId);
                  }
                } else {
                  // そのまま追加（キーは Firestore ID）
                  await cardBox.put(firestoreId, cloudCard);
                }
              }
              break;
            case DocumentChangeType.removed:
              if (localCard != null && localCardKey != null) {
                // ローカルに存在 -> 削除
                print('  -> ローカルからカードを削除 (ID: $firestoreId)');
                await cardBox.delete(localCardKey);
              } else {
                print('  -> 削除対象のローカルカードが見つかりません (ID: $firestoreId)');
              }
              break;
          }
          _maybeAdvanceRealtimeCursor(entityType: 'card', meta: meta);
        }
      }

      print('リアルタイム更新の処理が完了しました');
      SyncStateManager.instance.completeSync();
    } catch (e, stacktrace) {
      // スタックトレース追加
      print('リアルタイム更新の処理中にエラー: $e');
      print('Stacktrace: $stacktrace'); // デバッグ用
      SyncStateManager.instance.setSyncError(e.toString());
    } finally {
      // 同期状態は SyncStateManager が管理
    }
  }

  // ★★★ ヘルパーメソッド定義を追加 ★★★
  DocumentChangeType _parseChangeType(String changeTypeStr) {
    if (changeTypeStr.contains('added')) return DocumentChangeType.added;
    if (changeTypeStr.contains('modified')) return DocumentChangeType.modified;
    if (changeTypeStr.contains('removed')) return DocumentChangeType.removed;
    print('⚠️ 未知の DocumentChangeType 文字列: $changeTypeStr');
    return DocumentChangeType.modified; // 不明な場合は modified として扱う
  }

  static bool _isCursorAfter(SyncCursor a, SyncCursor b) {
    if (a.seconds != b.seconds) return a.seconds > b.seconds;
    if (a.nanos != b.nanos) return a.nanos > b.nanos;
    return a.docId.compareTo(b.docId) > 0;
  }

  void _maybeAdvanceRealtimeCursor({
    required String entityType, // 'deck' | 'card'
    required Map<String, dynamic>? meta,
  }) {
    if (!SyncCursorStore.isServerUpdatedAtSyncEnabled()) return;
    if (meta == null) return;
    if (meta['hasPendingWrites'] == true) return;

    final ts = meta['serverUpdatedAt'];
    final docId = (meta['docId'] ?? '').toString();
    if (ts is! Timestamp) return;
    if (docId.isEmpty) return;

    final next = SyncCursor.fromSnapshot(timestamp: ts, docId: docId);
    if (entityType == 'deck') {
      final current = SyncCursorStore.loadDecksCursor();
      if (current == null || _isCursorAfter(next, current)) {
        SyncCursorStore.saveDecksCursor(next);
      }
    } else if (entityType == 'card') {
      final current = SyncCursorStore.loadCardsCursor();
      if (current == null || _isCursorAfter(next, current)) {
        SyncCursorStore.saveCardsCursor(next);
      }
    }
  }

  // デッキの変更を処理
  Future<void> _handleDeckChange(Deck deck, String changeType) async {
    final deckBox = HiveService.getDeckBox();
    // ★ deck.id (FirestoreのID) を使ってローカルのデッキを検索
    final localDeck = deckBox.get(deck.id);

    if (changeType.contains('added') || changeType.contains('modified')) {
      // FirestoreのIDをキーとしてputで追加または更新
      await deckBox.put(deck.id, deck);
      if (localDeck == null) {
        print(
            '⬇️ 同期: 新規デッキ「${deck.deckName}」をローカルに追加/更新しました (ID/Key: ${deck.id})');
      } else {
        print('🔄 同期: 既存デッキ「${deck.deckName}」を更新しました (ID/Key: ${deck.id})');
        // 必要であれば更新日時の比較などをここに追加
      }
    } else if (changeType.contains('removed')) {
      // デッキの削除
      if (localDeck != null) {
        // FirestoreのIDをキーとしてdeleteで削除
        await deckBox.delete(deck.id);

        // 関連するカードも削除 (deckName 基準で削除)
        final cardBox = HiveService.getCardBox();
        // ★ keys を先に取得して deleteAll で削除するのが安全かつ効率的
        final cardsToRemoveKeys = cardBox.keys.where((key) {
          final card = cardBox.get(key);
          return card != null && card.deckName == deck.deckName;
        }).toList();
        await cardBox.deleteAll(cardsToRemoveKeys);
        print(
            '🗑️ 同期: デッキ「${deck.deckName}」と関連カード ${cardsToRemoveKeys.length} 枚を削除しました (ID/Key: ${deck.id})');
      } else {
        print(
            'ℹ️ 同期: 削除対象のデッキ「${deck.deckName}」(ID: ${deck.id}) はローカルに見つかりませんでした。');
      }
    }
  }

  // カードの変更を処理

  // 双方向同期（クラウドとローカルを相互に同期）
  Future<bool> syncBidirectional() async {
    // ★★★ 重要操作中はスキップ - 新しいサービスを使用 ★★★
    if (CriticalOperationService.isInProgress) {
      print('同期スキップ: クリティカルな操作が進行中です。');
      return false;
    }
    if (SyncStateManager.instance.isSyncing) {
      print('すでに同期中のため、この同期リクエストをスキップします');
      return false;
    }
    final userId = FirebaseService.getUserId(); // 先に取得
    if (userId == null) {
      print('ユーザーがログインしていないため、同期をスキップします');
      return false;
    }

    SyncStateManager.instance.startSync();
    print('💫 双方向同期処理を開始します (IDベース)');

    // 同期開始タイムスタンプを記録
    final syncStartTime = DateTime.now();

    // ローカルデータの取得
    final deckBox = HiveService.getDeckBox();
    final cardBox = HiveService.getCardBox();
    final initialDeckCount = deckBox.length;
    final initialCardCount = cardBox.length;
    List<Deck> localDecks = deckBox.values.toList();
    List<FlashCard> localCards = cardBox.values.toList();
    print('同期前のローカルデータ: デッキ$initialDeckCount件、カード$initialCardCount件');

    try {
      // Phase 2.5: 先にpending operationsをflush（オフライン中の変更を必ず反映）
      // 失敗しても同期全体は続行する（次のトリガで再試行）
      try {
        await PendingOperationsService.flushPendingOperations();
      } catch (e) {
        print('⚠️ pending operations flush に失敗（続行）: $e');
      }

      // ★★★ 先に削除ログを取得（移行完了までは互換のため必要） ★★★
      final bool useLogicalDelete = FirebaseSyncFeatureFlags.useLogicalDelete();
      Set<String> deletedDeckNames = <String>{};
      Set<String> deletedCardFirestoreIds = <String>{};
      Set<String> clearedDeckNames = <String>{};

      if (!useLogicalDelete) {
        print('🔍 削除ログの取得を開始...');
        deletedDeckNames = await _fetchDeletedDeckNames(); // L449相当
        deletedCardFirestoreIds =
            await fetchDeletedCardKeys(); // ★ 修正: publicメソッド呼び出し
        clearedDeckNames = await _fetchClearedDeckNames(); // L452相当
        print(
            '🔍 削除ログ取得完了: 削除デッキ名=${deletedDeckNames.length}件, 削除カードID=${deletedCardFirestoreIds.length}件, クリアデッキ名=${clearedDeckNames.length}件');
      } else {
        print('🔍 論理削除モードのため、削除ログ取得はスキップします');
      }

      // ★★★ 次にクラウドからデータを取得 ★★★
      print('🌥️ クラウドからのデータ取得を開始...');
      // 注意: syncCloudToLocal が内部で削除ログを再度取得していないか確認が必要
      final cloudData =
          await FirebaseService.syncCloudToLocalDiff(); // Phase 2（フラグOFFなら従来どおり全件）
      final List<Deck> cloudDecks = cloudData['decks'];
      final List<FlashCard> cloudCards = cloudData['cards'];
      print(
          '🌥️ クラウドからの取得結果: デッキ${cloudDecks.length}件, カード${cloudCards.length}件');

      // --- Firestore ID ベースの同期ロジック ---

      // === マッピング作成 ===
      // ローカルカードを Firestore ID でマップ化 (IDがないものと一時IDは別途処理)
      final localCardsByFirestoreId = <String, FlashCard>{};
      final localCardsWithoutFirestoreId = <FlashCard>[];
      final localCardsWithTemporaryId = <FlashCard>[];

      for (final card in localCards) {
        if (card.firestoreId != null && card.firestoreId!.isNotEmpty) {
          // ★★★ 一時IDかどうかチェック ★★★
          if (card.firestoreId!.startsWith('temp_')) {
            localCardsWithTemporaryId.add(card);
            print('🆔 一時IDカードを検出: ${card.question} (ID: ${card.firestoreId})');
          } else {
            localCardsByFirestoreId[card.firestoreId!] = card;
          }
        } else {
          localCardsWithoutFirestoreId.add(card);
        }
      }
      print(
          '🗺️ ローカルカードマッピング: IDあり=${localCardsByFirestoreId.length}件, IDなし=${localCardsWithoutFirestoreId.length}件, 一時ID=${localCardsWithTemporaryId.length}件');

      // クラウドカードを Firestore ID でマップ化
      final cloudCardsByFirestoreId = <String, FlashCard>{};
      for (final card in cloudCards) {
        if (card.firestoreId != null && card.firestoreId!.isNotEmpty) {
          cloudCardsByFirestoreId[card.firestoreId!] = card;
        } else {
          // クラウド側でIDがないのは通常ありえないはずだが、念のためログ
          print('⚠️ クラウドカードに Firestore ID がありません: ${card.question}');
        }
      }
      print('🗺️ クラウドカードマッピング: IDあり=${cloudCardsByFirestoreId.length}件');

      // デッキのマッピング (現状は名前ベースのまま、必要ならIDベースに修正)
      final localDecksByName = <String, Deck>{};
      for (final deck in localDecks) {
        localDecksByName[deck.deckName] = deck;
      }
      final cloudDecksByName = <String, Deck>{};
      for (final deck in cloudDecks) {
        cloudDecksByName[deck.deckName] = deck;
      }

      // ★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★
      // ★★★ デッキ同期を先に行うように修正 ★★★
      // ★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★
      print('🔄 デッキ同期処理を開始');
      int addedLocalDecks = 0;
      int updatedLocalDecks = 0; // 必要なら更新ロジックも追加
      int addedCloudDecks = 0;

      // ローカルの既存デッキ名を保持するSet（重複追加防止用）
      final Set<String> currentLocalDeckNames = localDecksByName.keys.toSet();

      // クラウド -> ローカル (デッキ)
      for (final cloudDeck in cloudDecks) {
        // Phase 3: 論理削除モードでは isDeleted を優先
        if (useLogicalDelete && cloudDeck.isDeleted) {
          print('🚫 論理削除済みクラウドデッキを反映: ${cloudDeck.deckName}');
          if (currentLocalDeckNames.contains(cloudDeck.deckName)) {
            final localDeckToDelete = localDecksByName[cloudDeck.deckName]!;
            localDeckToDelete.isDeleted = true;
            localDeckToDelete.deletedAt = cloudDeck.deletedAt;
            await localDeckToDelete.save();
          }
          continue;
        }

        // 移行前互換: 削除ログにあるデッキはスキップ
        if (!useLogicalDelete && deletedDeckNames.contains(cloudDeck.deckName)) {
          print('🚫 削除ログにあるクラウドデッキをスキップ: ${cloudDeck.deckName}');
          // 対応するローカルデッキがあれば削除
          if (currentLocalDeckNames.contains(cloudDeck.deckName)) {
            final localDeckToDelete = localDecksByName[cloudDeck.deckName]!;
            await localDeckToDelete.delete();
            print('🗑️ ローカルからもデッキを削除: ${cloudDeck.deckName}');
            currentLocalDeckNames.remove(cloudDeck.deckName);
            localDecksByName.remove(cloudDeck.deckName);
          }
          continue;
        }

        // ★★★ 修正: ローカルに同名デッキが存在しない場合のみ追加 ★★★
        if (!currentLocalDeckNames.contains(cloudDeck.deckName)) {
          // ローカルに存在しない -> 追加
          print('📥 クラウドの新規デッキをローカルに追加: ${cloudDeck.deckName}');
          await deckBox.put(cloudDeck.id, cloudDeck); // IDをキーとして追加
          // ★★★ 追加後にSetとMapを更新 ★★★
          currentLocalDeckNames.add(cloudDeck.deckName);
          localDecksByName[cloudDeck.deckName] = cloudDeck;
          addedLocalDecks++;
        }
      }

      // ローカル -> クラウド (デッキ) - 削除されたデッキ以外
      for (final localDeck in localDecks) {
        // ★★★ 修正: localDecksByNameではなくクラウドのマップでチェック ★★★
        if (!cloudDecksByName.containsKey(localDeck.deckName) &&
            !localDeck.isDeleted &&
            (useLogicalDelete || !deletedDeckNames.contains(localDeck.deckName))) {
          // クラウドに存在しない -> 追加
          print('📤 ローカルの新規デッキをクラウドに保存: ${localDeck.deckName}');
          try {
            await FirebaseService.saveDeck(localDeck);
            addedCloudDecks++;
          } catch (e) {
            print('❌ ローカルデッキのクラウド保存エラー: ${localDeck.deckName}, $e');
          }
        }
      }
      print('デッキ同期結果: ローカル追加=$addedLocalDecks, クラウド追加=$addedCloudDecks');
      // ★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★★

      // === クラウド→ローカルの同期 (カード) ===
      print('⬇️ クラウド → ローカル同期 (カード)');
      int newLocalCards = 0;
      int updatedLocalCards = 0;
      int skippedCloudCards = 0;

      // ローカルの既存カードFirestore IDを保持するSet（重複追加防止用）
      final Set<String> currentLocalCardFirestoreIds =
          localCardsByFirestoreId.keys.toSet();

      for (final cloudCard in cloudCards) {
        final firestoreId = cloudCard.firestoreId;

        // ID がないカードはスキップ (基本的には発生しないはず)
        if (firestoreId == null || firestoreId.isEmpty) {
          print('⚠️ クラウドカードに Firestore ID がないためスキップ: ${cloudCard.question}');
          skippedCloudCards++;
          continue;
        }

        // Phase 3: 論理削除モードでは isDeleted を優先
        if (useLogicalDelete && cloudCard.isDeleted) {
          skippedCloudCards++;
          if (currentLocalCardFirestoreIds.contains(firestoreId)) {
            final localCardToDelete = localCardsByFirestoreId[firestoreId]!;
            localCardToDelete.isDeleted = true;
            localCardToDelete.deletedAt = cloudCard.deletedAt;
            // firestoreUpdatedAt は conflict resolver 済みの前提だが、念のため
            localCardToDelete.firestoreUpdatedAt = cloudCard.firestoreUpdatedAt;
            await localCardToDelete.save();
            print('🗑️ ローカルへ論理削除を反映: ID=$firestoreId');
          }
          continue;
        }

        // 移行前互換: 削除ログにあるカードはスキップ
        if (!useLogicalDelete && deletedCardFirestoreIds.contains(firestoreId)) {
          // ★ 取得したIDリストでチェック
          print('🚫 削除ログにあるクラウドカードをスキップ: ID=$firestoreId');
          skippedCloudCards++;
          // 対応するローカルカードがあれば削除
          if (currentLocalCardFirestoreIds.contains(firestoreId)) {
            final localCardToDelete = localCardsByFirestoreId[firestoreId]!;
            // ★ HiveService.deleteCardSafely を使う方が安全
            try {
              await HiveService.deleteCardSafely(localCardToDelete.key);
              print('🗑️ ローカルからも削除 (削除ログ適用): ID=$firestoreId');
              currentLocalCardFirestoreIds.remove(firestoreId); // Setからも削除
              localCardsByFirestoreId.remove(firestoreId); // マップからも削除
            } catch (e) {
              print('❌ ローカルカード削除エラー (削除ログ適用): ID=$firestoreId, $e');
              // エラーが発生しても処理は続行
            }
          }
          continue;
        }

        // クリア済みデッキのカードはスキップ（移行前互換）
        if (!useLogicalDelete && clearedDeckNames.contains(cloudCard.deckName)) {
          print(
              '🚫 クリア済みデッキ「${cloudCard.deckName}」のクラウドカードをスキップ: ID=$firestoreId');
          skippedCloudCards++;
          // 対応するローカルカードがあれば削除
          if (currentLocalCardFirestoreIds.contains(firestoreId)) {
            final localCardToDelete = localCardsByFirestoreId[firestoreId]!;
            // ★ HiveService.deleteCardSafely を使う方が安全
            try {
              await HiveService.deleteCardSafely(localCardToDelete.key);
              print('🗑️ ローカルからも削除 (クリア済みデッキ): ID=$firestoreId');
              currentLocalCardFirestoreIds.remove(firestoreId); // Setからも削除
              localCardsByFirestoreId.remove(firestoreId); // マップからも削除
            } catch (e) {
              print('❌ ローカルカード削除エラー (クリア済みデッキ): ID=$firestoreId, $e');
              // エラーが発生しても処理は続行
            }
          }
          continue;
        }

        // --- ローカル存在チェック ---
        // ★★★ 修正: ローカルに同IDカードが存在しない場合のみ追加 ★★★
        if (!currentLocalCardFirestoreIds.contains(firestoreId)) {
          // 新規カード -> ローカルに追加
          // デッキが存在するか確認（デッキが先に同期される想定だが念のため）
          if (localDecksByName.containsKey(cloudCard.deckName)) {
            // ★★★ Hiveに追加する際にキーをFirestore IDにするか検討 ★★★
            // 現在は add() で自動キー付与
            print(
                '📥 [SyncService] 新規カード追加前: ID=$firestoreId, nextReview=${cloudCard.nextReview}'); // ★ ログ追加
            // Hiveキーを Firestore ID に統一
            await cardBox.put(firestoreId, cloudCard);
            // ★★★ 追加後にSetとMapを更新 ★★★
            currentLocalCardFirestoreIds.add(firestoreId);
            localCardsByFirestoreId[firestoreId] = cloudCard; // Mapにも追加（更新用に）
            newLocalCards++;
            print(
                '📥 クラウドの新規カードをローカルに追加: ID=$firestoreId, Q=${cloudCard.question}');
          } else {
            print(
                '⚠️ ローカルにデッキ「${cloudCard.deckName}」が存在しないため、カードを追加できませんでした: ID=$firestoreId');
            skippedCloudCards++;
          }
        } else {
          // 既存カード -> 更新チェック
          final localCard = localCardsByFirestoreId[firestoreId]!;
          bool changed = _resolveCardConflict(localCard, cloudCard);
          if (changed) {
            // デバッグログは新しいサービスで制御
            // _debugPrint(
            //     '🔄 [SyncService] 既存カード更新前: ID=$firestoreId, nextReview=${localCard.nextReview}');
            await localCard.save();
            updatedLocalCards++;
          }
          // print('🔄 ローカルに既存のカード(ID: $firestoreId)があるためスキップまたは更新チェック');
        }
      }
      // デバッグログは新しいサービスで制御
      // _debugPrint(
      //     'クラウド→ローカル同期(カード)結果: 追加=$newLocalCards, 更新=$updatedLocalCards, スキップ=$skippedCloudCards');

      // === ローカル→クラウドの同期 (カード) ===
      // デバッグログは新しいサービスで制御
      // _debugPrint('⬆️ ローカル → クラウド同期 (カード)');
      int newCloudCards = 0;
      int updatedCloudCards = 0; // 更新カウンターを分ける
      int skippedLocalCards = 0;
      int fixedLocalCards = 0;

      // Firestore ID がないローカルカードの処理
      if (localCardsWithoutFirestoreId.isNotEmpty) {
        print(
            'ℹ️ Firestore ID がないローカルカードを処理します (${localCardsWithoutFirestoreId.length}件)');
        for (final localCard in localCardsWithoutFirestoreId) {
          if (useLogicalDelete && localCard.isDeleted) {
            // 論理削除済みのローカルカードは新規作成しない
            continue;
          }
          // ★★★ 強化された重複チェック ★★★
          print('🔍 IDなしカードの重複チェック: ${localCard.question}');

          // 1. 最新のクラウドデータを再取得（リアルタイム性向上）
          List<FlashCard> freshCloudCards;
          try {
            freshCloudCards = await FirebaseService.getCards();
            print('🔍 最新のクラウドデータを取得: ${freshCloudCards.length}件');
          } catch (e) {
            print('⚠️ 最新クラウドデータ取得エラー、既存データを使用: $e');
            freshCloudCards = cloudCards;
          }

          // 2. より厳密な重複チェック（複数条件）
          final potentialMatches = freshCloudCards.where((cc) {
            // 基本条件：Question/Answer/DeckName完全一致
            final basicMatch =
                cc.question.trim() == localCard.question.trim() &&
                    cc.answer.trim() == localCard.answer.trim() &&
                    cc.deckName == localCard.deckName;

            if (!basicMatch) return false;

            // 追加条件：作成時期が近い（1分以内）
            if (localCard.updatedAt != null && cc.updatedAt != null) {
              final timeDiff = (localCard.updatedAt! - cc.updatedAt!).abs();
              final isRecentlyCreated = timeDiff <= 60000; // 1分以内
              print(
                  '🔍 時間差チェック: ${timeDiff}ms (${isRecentlyCreated ? '近い' : '離れている'})');
              return isRecentlyCreated;
            }

            return true; // タイムスタンプがない場合は基本条件のみで判定
          }).toList();

          if (potentialMatches.isNotEmpty) {
            // 重複の可能性があるカードが見つかった
            final bestMatch = potentialMatches.first;
            print(
                '🔗 IDなしローカルカードに既存クラウドIDを紐付け: ${localCard.question} -> ID=${bestMatch.firestoreId}');
            print('   📊 重複候補数: ${potentialMatches.length}件');

            localCard.firestoreId = bestMatch.firestoreId;
            await localCard.save();
            fixedLocalCards++;
            // このカードは後続のループで更新処理される可能性がある
            localCardsByFirestoreId[localCard.firestoreId!] = localCard;
          } else {
            // 重複なし -> 新規としてクラウドに保存
            print('📤 IDなしローカルカードを新規としてクラウドに保存: ${localCard.question}');
            print('   🔍 重複チェック結果: 類似カードなし');

            try {
              // ★★★ 保存前に最終確認：同時に作成されたカードがないかチェック ★★★
              final lastMinuteCheck =
                  await _performLastMinuteDuplicateCheck(localCard);
              if (lastMinuteCheck['isDuplicate']) {
                print(
                    '⚠️ 最終確認で重複を検出。既存IDを使用: ${lastMinuteCheck['existingId']}');
                localCard.firestoreId = lastMinuteCheck['existingId'];
                await localCard.save();
                fixedLocalCards++;
                localCardsByFirestoreId[localCard.firestoreId!] = localCard;
                continue;
              }

              await FirebaseService.saveCard(
                  localCard, FirebaseService.getUserId()!);
              await localCard.save(); // HiveにIDを保存 (firestoreIdが設定された状態で)
              newCloudCards++;
              fixedLocalCards++;
              localCardsByFirestoreId[localCard.firestoreId!] = localCard;

              print('✅ 新規カード保存完了: ID=${localCard.firestoreId}');
            } catch (e) {
              print('❌ IDなしローカルカードのクラウド保存エラー: $e');
              skippedLocalCards++;
            }
          }
        }
      }

      // Firestore ID があるローカルカードの処理
      // localCardsByFirestoreId のキーをリスト化してイテレート (ループ中に削除する可能性があるため)
      final localFirestoreIds = localCardsByFirestoreId.keys.toList();
      for (final firestoreId in localFirestoreIds) {
        // マップから最新の状態を取得 (IDなし->IDありになったカードを含むため)
        final localCard = localCardsByFirestoreId[firestoreId];
        if (localCard == null) continue; // スキップされたか削除された可能性

        // Phase 3: ローカルが論理削除ならクラウドへ削除を反映（pendingが無い/失敗時の保険）
        if (useLogicalDelete && localCard.isDeleted) {
          try {
            await FirebaseService.deleteCard(firestoreId);
            updatedCloudCards++;
          } catch (e) {
            print('   ❌ 論理削除カードのクラウド反映に失敗: ID=$firestoreId, $e');
            skippedLocalCards++;
          }
          continue;
        }

        // 削除ログにあるか再確認 (クラウド→ローカルで処理済みのはずだが念のため)
        if (deletedCardFirestoreIds.contains(firestoreId)) {
          // ★ 取得したIDリストでチェック
          print('🚫 削除ログにあるローカルカードをスキップ: ID=$firestoreId');
          // ローカルからも削除されているはず
          skippedLocalCards++;
          continue;
        }

        // ★★★ デバッグログ追加: 同期直前のHiveの値を確認 ★★★
        final currentCardBoxForSync = HiveService.getCardBox(); // 一応ここでBoxを取得
        final currentCardFromHive = currentCardBoxForSync.get(localCard.key);
        print(
            '  [L->C Check Hive] ID: $firestoreId (Hive Key: ${localCard.key})');
        print(
            '    localCard.updatedAt (比較対象): ${localCard.updatedAt}'); // This is the value used in comparison later
        print(
            '    Hive直接取得 updatedAt: ${currentCardFromHive?.updatedAt}'); // This is the current value in Hive
        if (currentCardFromHive?.updatedAt != null) {
          print(
              '    Hive直接取得 日時: ${DateTime.fromMillisecondsSinceEpoch(currentCardFromHive!.updatedAt!).toIso8601String()}');
        }
        // ★★★ ここまで追加 ★★★

        // クラウドに存在するかチェック
        if (cloudCardsByFirestoreId.containsKey(firestoreId)) {
          // 存在する場合 -> 更新チェック
          final cloudCard = cloudCardsByFirestoreId[firestoreId]!;
          bool shouldUpdateCloud = false;

          // --- ★★★ ローカル→クラウド 更新判定ロジック修正 ★★★ ---
          // 優先度: firestoreUpdatedAt -> updatedAt

          // 1. firestoreUpdatedAt (サーバータイムスタンプ) 比較
          final localServerTs = localCard.firestoreUpdatedAt;
          final cloudServerTs = cloudCard.firestoreUpdatedAt;
          bool decidedByServerTs = false;
          // ★★★ デバッグログ追加 ★★★
          print('  [L->C Compare] ID: $firestoreId');
          print(
              '    localServerTs: ${localServerTs?.seconds}.${localServerTs?.nanoseconds}');
          print(
              '    cloudServerTs: ${cloudServerTs?.seconds}.${cloudServerTs?.nanoseconds}');

          if (localServerTs != null && cloudServerTs != null) {
            if (localServerTs.compareTo(cloudServerTs) > 0) {
              print(
                  '🔄 [L->C 更新] ローカルの方が新しい (firestoreUpdatedAt): ID=$firestoreId');
              shouldUpdateCloud = true;
              decidedByServerTs = true;
            } else if (cloudServerTs.compareTo(localServerTs) > 0) {
              print(
                  'ℹ️ [L->C スキップ] クラウドの方が新しい (firestoreUpdatedAt): ID=$firestoreId');
              // shouldUpdateCloud は false のまま
              decidedByServerTs = true;
            }
            // 同じなら updatedAt 比較へ
          } else if (localServerTs != null && cloudServerTs == null) {
            // ローカルにのみサーバータイムスタンプがある (クラウドが古い or 未同期)
            print('🔄 [L->C 更新] ローカルのみ firestoreUpdatedAt あり: ID=$firestoreId');
            shouldUpdateCloud = true;
            decidedByServerTs = true;
          } else if (cloudServerTs != null && localServerTs == null) {
            // クラウドにのみサーバータイムスタンプがある (ローカルが古い or 未同期)
            print(
                'ℹ️ [L->C スキップ] クラウドのみ firestoreUpdatedAt あり: ID=$firestoreId');
            // shouldUpdateCloud は false のまま
            decidedByServerTs = true;
          }
          // 両方 null なら updatedAt 比較へ

          // 2. updatedAt (ローカル/デバイスタイムスタンプ) 比較 (サーバータイムスタンプで決着しない場合)
          if (!decidedByServerTs) {
            final localUpdatedAt = localCard.updatedAt;
            final cloudUpdatedAt = cloudCard.updatedAt; // デバイス時刻の可能性あり
            // ★★★ デバッグログ追加 ★★★
            print('    localUpdatedAt: $localUpdatedAt');
            print(
                '    cloudUpdatedAt: $cloudUpdatedAt'); // Note: cloud側のupdatedAtは使わない比較もある

            if (localUpdatedAt != null && cloudUpdatedAt != null) {
              // if (localUpdatedAt.isAfter(cloudUpdatedAt)) { // <- 変更前
              if (localUpdatedAt > cloudUpdatedAt) {
                // <- 変更後: 数値比較
                print('🔄 [L->C 更新] ローカルの方が新しい (updatedAt): ID=$firestoreId');
                shouldUpdateCloud = true;
                // } else if (cloudUpdatedAt.isAfter(localUpdatedAt)) { // <- 変更前
              } else if (cloudUpdatedAt > localUpdatedAt) {
                // <- 変更後: 数値比較
                print('ℹ️ [L->C スキップ] クラウドの方が新しい (updatedAt): ID=$firestoreId');
                // shouldUpdateCloud は false のまま
              }
              // 同じなら何もしない (変更なし)
            } else if (localUpdatedAt != null && cloudUpdatedAt == null) {
              // ローカルにのみタイムスタンプがある (クラウドが古い形式など)
              print('🔄 [L->C 更新] ローカルのみ updatedAt あり: ID=$firestoreId');
              shouldUpdateCloud = true;
            } else if (cloudUpdatedAt != null && localUpdatedAt == null) {
              // クラウドにのみタイムスタンプがある
              print('ℹ️ [L->C スキップ] クラウドのみ updatedAt あり: ID=$firestoreId');
              // shouldUpdateCloud は false のまま
            } else {
              // 両方 null なら変更なし
              print('ℹ️ [L->C スキップ] 両方の updatedAt が null: ID=$firestoreId');
            }
          }
          // --- ★★★ 更新判定ロジックここまで ★★★ ---

          if (shouldUpdateCloud) {
            try {
              // ローカルのデータでクラウドを上書き
              // ★★★ 修正: userId を追加 ★★★
              await FirebaseService.saveCard(
                  localCard, FirebaseService.getUserId()!); // 修正後
              updatedCloudCards++;
            } catch (e) {
              print('❌ ローカルカードのクラウド更新エラー: ID=$firestoreId, $e');
              skippedLocalCards++;
            }
          }
        } else {
          // クラウドに存在しない場合 (ローカルにはIDがあるのに)
          // クラウドで削除されたが、削除ログにない or ログ取得漏れの可能性
          // または、過去の不整合でローカルだけIDを持っているケース
          print(
              '⚠️ ローカルカードのIDがクラウドに見つかりません: ID=$firestoreId, Q=${localCard.question}');
          // print('   -> クラウドで削除されたか、過去のデータの不整合の可能性があります。');
          // // ここでは一旦スキップ
          // skippedLocalCards++;
          // // 必要に応じて、ローカルカードを削除するなどのリカバリー処理を検討
          // ★★★ スキップせず、クラウドへの再アップロードを試みる ★★★
          print('   -> クラウドへの再アップロードを試みます...');
          try {
            // ★★★ 修正: userId を追加 ★★★
            await FirebaseService.saveCard(
                localCard, FirebaseService.getUserId()!); // 修正後
            print('   ✅ クラウドへの再アップロード成功: ID=$firestoreId');
            // newCloudCards++; // 新規ではないのでカウントしない（更新扱いが適切か？）
            updatedCloudCards++; // 更新としてカウントする
          } catch (e) {
            print('   ❌ クラウドへの再アップロード失敗: ID=$firestoreId, $e');
            skippedLocalCards++; // 失敗した場合はスキップとしてカウント
          }
        }
      }
      // デバッグログは新しいサービスで制御
      // _debugPrint(
      //     'ローカル→クラウド同期(カード)結果: 新規=$newCloudCards, 更新=$updatedCloudCards, スキップ=$skippedLocalCards, ID修正=$fixedLocalCards');

      // === デッキの同期 (現状維持 - 必要なら修正) ===
      print('🔄 デッキ同期処理 (変更なし)');
      // ... (既存のデッキ同期ロジック) ...
      // 重要: デッキ削除ロジックがローカルのカードを道連れにする場合、
      //      firestoreId ベースのカードが存在していても消えてしまう可能性。
      //      デッキ削除時もカードの firestoreId を使って関連削除ログを記録・参照するなど、
      //      より堅牢な連携が必要になるかもしれない。

      // --- 同期完了処理 ---
      final finalDeckCount = deckBox.length;
      final finalCardCount = cardBox.length;
      final hasChanges = initialDeckCount != finalDeckCount ||
          initialCardCount != finalCardCount ||
          newLocalCards > 0 ||
          updatedLocalCards > 0 ||
          skippedCloudCards > 0 || // クラウド→ローカル
          newCloudCards > 0 ||
          updatedCloudCards > 0 ||
          skippedLocalCards > 0 ||
          fixedLocalCards > 0; // ローカル→クラウド
      // デッキの変更も考慮に入れるべき

      final syncDuration = DateTime.now().difference(syncStartTime);
      print(
          '💫 双方向同期処理(IDベース)が完了しました (所要時間: ${syncDuration.inMilliseconds}ms)');
      print('同期後のローカルデータ: デッキ$finalDeckCount件, カード$finalCardCount件');

      if (hasChanges) {
        print('データに変更がありました');
      } else {
        print('データに変更はありませんでした');
      }

      // Phase 2: 差分getのカーソルを保存（適用成功後にのみ進める）
      // - ここに到達している=例外なく処理が完了しているので「適用成功」とみなす
      // - serverUpdatedAt未バックフィル期間は、SyncCursorStore.isServerUpdatedAtSyncEnabled() を false にして運用する
      try {
        if (SyncCursorStore.isServerUpdatedAtSyncEnabled()) {
          final SyncCursor? deckCursor = cloudData['deckCursor'] as SyncCursor?;
          final SyncCursor? cardCursor = cloudData['cardCursor'] as SyncCursor?;
          if (deckCursor != null) {
            SyncCursorStore.saveDecksCursor(deckCursor);
          }
          if (cardCursor != null) {
            SyncCursorStore.saveCardsCursor(cardCursor);
          }
        }
      } catch (e) {
        // カーソル保存失敗は同期全体を失敗にしない（次回は同じ範囲を再取得するだけ）
        print('⚠️ 差分カーソルの保存に失敗: $e');
      }

      _updateStatus(SyncStatus.synced);
      return hasChanges;
    } catch (e, stacktrace) {
      // スタックトレースも出力
      print('❌ 同期エラー: $e');
      print('Stacktrace: $stacktrace'); // デバッグ用にスタックトレースを出力
      SyncStateManager.instance.setSyncError(e.toString());
      return false;
    } finally {
      // 同期状態は SyncStateManager が管理
    }
  }

  // カードの競合解決（タイムスタンプ優先） - 新しいサービスを使用
  bool _resolveCardConflict(FlashCard localCard, FlashCard cloudCard) {
    return ConflictResolver.resolveCardConflict(localCard, cloudCard);
  }

  // ローカルからクラウドへの同期（データ移行用）
  static Future<void> syncToCloud() async {
    if (FirebaseService.getUserId() == null) {
      throw Exception('ユーザーがログインしていません。同期するにはログインしてください。');
    }

    // ローカルデータの取得
    final deckBox = HiveService.getDeckBox();
    final cardBox = HiveService.getCardBox();

    final decks = deckBox.values.toList();
    final cards = cardBox.values.toList();

    // クラウドへの同期
    await FirebaseService.syncLocalToCloud(decks, cards);
  }

  // クラウドからローカルへの同期（マージモード - ローカルデータを保持しつつ学習データを更新）
  static Future<void> syncFromCloud() async {
    if (FirebaseService.getUserId() == null) {
      throw Exception('ユーザーがログインしていません。同期するにはログインしてください。');
    }

    // クラウドからデータを取得
    final cloudData = await FirebaseService.syncCloudToLocal();

    // クラウドのデックとカードを取得
    final List<Deck> cloudDecks = cloudData['decks'];
    final List<FlashCard> cloudCards = cloudData['cards'];

    print('クラウドからデック${cloudDecks.length}件、カード${cloudCards.length}件を取得しました');

    // 削除マーカーを取得（削除済みカードとデッキ）
    final Set<String> deletedCardKeys =
        await fetchDeletedCardKeys(); // ★ 修正: publicメソッド呼び出し
    final Set<String> clearedDeckNames = await _fetchClearedDeckNames();

    print(
        '削除マーカー: カード${deletedCardKeys.length}件、デッキ${clearedDeckNames.length}件');

    final deckBox = HiveService.getDeckBox();
    final cardBox = HiveService.getCardBox();

    int addedDecks = 0;
    int updatedDecks = 0;
    int addedCards = 0;
    int updatedCards = 0;

    // ローカルの既存デッキ名を取得（重複判定用）
    final Set<String> existingDeckNames =
        deckBox.values.map((deck) => deck.deckName).toSet();

    // デッキの同期
    for (var cloudDeck in cloudDecks) {
      // デッキ名でローカルに既に存在するか確認
      if (existingDeckNames.contains(cloudDeck.deckName)) {
        // 同名デッキが存在する場合は更新のみ行う
        final localDeckIndex = deckBox.values
            .toList()
            .indexWhere((d) => d.deckName == cloudDeck.deckName);

        if (localDeckIndex != -1) {
          final localDeck = deckBox.values.elementAt(localDeckIndex);
          localDeck.questionEnglishFlag = cloudDeck.questionEnglishFlag;
          localDeck.answerEnglishFlag = cloudDeck.answerEnglishFlag;
          localDeck.description = cloudDeck.description;
          await localDeck.save();
          updatedDecks++;
          print('🔄 クラウドの既存デッキをローカルで更新: ${cloudDeck.deckName}');
        }
      } else {
        // ローカルに存在しない場合のみ新規追加
        // 重要: Hiveキーは必ずFirestoreのdocId（=deck.id）で統一しないと、
        // 後続の同期で重複・再取得・削除不整合の原因になる。
        final deckId = cloudDeck.id;
        if (deckId.isEmpty) {
          // 想定外だが安全にスキップ
          print('⚠️ クラウドデッキのIDが空のため追加をスキップ: ${cloudDeck.deckName}');
        } else {
          await deckBox.put(deckId, cloudDeck);
          existingDeckNames.add(cloudDeck.deckName); // 追加後のセットも更新
          addedDecks++;
          print('📥 クラウドの新規デッキをローカルに追加: ${cloudDeck.deckName} (ID: $deckId)');
        }
      }
    }

    // ローカルの既存カードIDを取得（重複判定用）
    final Set<String> existingCardFirestoreIds = cardBox.values
        .where(
            (card) => card.firestoreId != null && card.firestoreId!.isNotEmpty)
        .map((card) => card.firestoreId!)
        .toSet();

    // カードの同期
    for (var cloudCard in cloudCards) {
      // 削除マーカーがある場合はスキップ
      if (cloudCard.firestoreId != null &&
          deletedCardKeys.contains(cloudCard.firestoreId)) {
        print('🚫 削除ログにあるクラウドカードをスキップ: ID=${cloudCard.firestoreId}');
        continue;
      }

      // FirestoreIDでローカルに既に存在するか確認
        if (cloudCard.firestoreId != null &&
            existingCardFirestoreIds.contains(cloudCard.firestoreId)) {
        // 同じIDのカードが存在する場合は更新
        final localCardIndex = cardBox.values
            .toList()
            .indexWhere((c) => c.firestoreId == cloudCard.firestoreId);

        if (localCardIndex != -1) {
          final localCard = cardBox.values.elementAt(localCardIndex);
          // 学習データの更新（必要に応じて）
          _mergeCardLearningData(localCard, cloudCard);
          await localCard.save();
          updatedCards++;
        }
      } else {
        // ローカルに存在しない場合のみ新規追加（キーは Firestore ID を使用）
        final String targetKey = cloudCard.firestoreId ?? cloudCard.id;
        if (targetKey.isEmpty) {
          // 想定外だが安全にスキップ
          print('⚠️ Firestore ID/ID が空のため追加をスキップしました');
        } else {
          await cardBox.put(targetKey, cloudCard);
          existingCardFirestoreIds.add(targetKey);
          addedCards++;
          print(
              '📥 クラウドの新規カードをローカルに追加: ID=$targetKey, Q=${cloudCard.question}');
        }
      }
    }

    print(
        'クラウド→ローカル同期(カード)結果: 追加=$addedCards, 更新=$updatedCards, スキップ=${cloudCards.length - addedCards - updatedCards}');
    print(
        'クラウド→ローカル同期(デッキ)結果: 追加=$addedDecks, 更新=$updatedDecks, スキップ=${cloudDecks.length - addedDecks - updatedDecks}');
  }

  // カードの学習データをマージするヘルパーメソッド
  static bool _mergeCardLearningData(FlashCard localCard, FlashCard cloudCard) {
    bool hasChanges = false;
    bool useCloudLearningData = false;
    bool chapterChanged = false; // 章が変更されたかフラグ

    // デバッグログ - 同期前の状態
    print(
        '📊 [_mergeCardLearningData] 同期開始: ${cloudCard.question.substring(0, min(20, cloudCard.question.length))}...');
    print(
        '  ローカル: nextReview=${localCard.nextReview}, repetitions=${localCard.repetitions}');
    print(
        '  クラウド: nextReview=${cloudCard.nextReview}, repetitions=${cloudCard.repetitions}');
    print(
        '  更新日時 - ローカル: ${localCard.updatedAt}, クラウド: ${cloudCard.updatedAt}');
    print(
        '  Firestore更新日時 - ローカル: ${localCard.firestoreUpdatedAt?.seconds}, クラウド: ${cloudCard.firestoreUpdatedAt?.seconds}');

    // クラウドの方が最近更新されている場合は、クラウドデータを優先
    if (cloudCard.firestoreUpdatedAt != null &&
        (localCard.firestoreUpdatedAt == null ||
            cloudCard.firestoreUpdatedAt!.seconds >
                localCard.firestoreUpdatedAt!.seconds)) {
      useCloudLearningData = true;
      print('  ✅ クラウドの方が新しいFirestore更新日時を持つ');
    }

    // updatedAtフィールドでも比較（firestoreUpdatedAtがない場合のフォールバック）
    if (!useCloudLearningData &&
        cloudCard.updatedAt != null &&
        (localCard.updatedAt == null ||
            cloudCard.updatedAt! > localCard.updatedAt!)) {
      // <- 変更後: 数値比較
      useCloudLearningData = true;
      print('  ✅ クラウドの方が新しいupdatedAt日時を持つ');
    }

    // クラウドの方が学習が進んでいる場合もクラウドを優先
    if (!useCloudLearningData &&
        cloudCard.repetitions > localCard.repetitions) {
      useCloudLearningData = true;
      print('  ✅ クラウドの方が多くの反復回数を持つ');
    }

    // クラウドで暗記済み、ローカルで未暗記の場合もクラウドを優先
    if (!useCloudLearningData &&
        cloudCard.repetitions >= 2 &&
        localCard.repetitions < 2) {
      useCloudLearningData = true;
      print('  ✅ クラウドでは暗記済みだがローカルでは未暗記');
    }

    // クラウドの次回出題日が未来（かつローカルより未来）の場合、クラウドを優先
    // これはWeb版での学習結果がAndroidに反映されないバグの主な修正点
    if (!useCloudLearningData &&
        cloudCard.nextReview != null &&
        (localCard.nextReview == null ||
            cloudCard.nextReview!.isAfter(localCard.nextReview!))) {
      useCloudLearningData = true;
      print(
          '  ✅ クラウドの方が未来の次回出題日を持つ: ${cloudCard.nextReview} > ${localCard.nextReview}');
    }

    if (useCloudLearningData) {
      // 学習データを更新
      localCard.nextReview = cloudCard.nextReview;
      localCard.repetitions = cloudCard.repetitions;
      localCard.eFactor = cloudCard.eFactor;
      localCard.intervalDays = cloudCard.intervalDays;

      // ★★★ Firestoreのタイムスタンプは維持 ★★★
      localCard.firestoreUpdatedAt = cloudCard.firestoreUpdatedAt;

      hasChanges = true;
      print('  ✅ クラウドからの学習データでローカルを更新しました');
    } else {
      print('  ⏩ ローカルデータを維持（更新条件を満たさず）');
    }

    // カードに章（chapter）情報がある場合は常に更新
    if (cloudCard.chapter != localCard.chapter &&
        cloudCard.chapter.isNotEmpty) {
      localCard.chapter = cloudCard.chapter;
      hasChanges = true;
      chapterChanged = true; // 章が変更されたフラグを立てる
      print('  ✅ 章情報を更新: ${cloudCard.chapter}');
      // ★★★ 章情報更新時にも updatedAt を更新する (下の共通処理で行う) ★★★
    }

    // ★★★ 何らかの変更があった場合、ローカルのupdatedAtを現在時刻で更新 ★★★
    if (hasChanges) {
      localCard.updatedAt =
          DateTime.now().millisecondsSinceEpoch; // ← 変更後 (int型)
      print('  ⬆️ ローカルの updatedAt を更新: ${localCard.updatedAt}');
    } else if (useCloudLearningData && !hasChanges && !chapterChanged) {
      // 学習データ採用だが実質変更なしの場合も念のためログ
      print('  ℹ️ 学習データはクラウド優先としたが、内容に変更はなかったため updatedAt は更新しません');
    }

    return hasChanges;
  }

  // 削除済みカードキーを取得
  // ★★★ static かつ public に変更 ★★★
  static Future<Set<String>> fetchDeletedCardKeys() async {
    final deletedCardFirestoreIds = <String>{}; // Firestore IDを格納
    final userId = FirebaseService.getUserId();

    if (userId == null) return deletedCardFirestoreIds;

    try {
      // Phase 3 移行後は削除ログを参照しない
      if (FirebaseSyncFeatureFlags.useLogicalDelete()) {
        return deletedCardFirestoreIds;
      }

      // Phase 5: 削除ログの全件getを避け、増分カーソルで読む
      if (FirebaseSyncFeatureFlags.useIncrementalDeletionLog()) {
        final cached = DeletionLogCursorStore.loadDeletedCardIdsCache();
        SyncCursor? cursor = DeletionLogCursorStore.loadDeletedCardOpsCursor();

        const int pageSize = 500;
        for (int page = 0; page < 200; page++) {
          Query<Map<String, dynamic>> query = FirebaseService.firestore
              .collection('users')
              .doc(userId)
              .collection('card_operations')
              .where('operation', isEqualTo: 'deleted_card')
              .orderBy('timestamp')
              .orderBy(FieldPath.documentId)
              .limit(pageSize);

          if (cursor != null) {
            query = query.startAfter([cursor.toTimestamp(), cursor.docId]);
          }

          final snap = await query.get();
          if (snap.docs.isEmpty) break;

          for (final doc in snap.docs) {
            final data = doc.data();
            final v = data['firestoreId'];
            if (v != null) {
              cached.add(v.toString());
            }
          }

          final last = snap.docs.last;
          final lastTs = last.data()['timestamp'];
          if (lastTs is Timestamp) {
            cursor = SyncCursor.fromSnapshot(timestamp: lastTs, docId: last.id);
            DeletionLogCursorStore.saveDeletedCardOpsCursor(cursor);
          }

          if (snap.docs.length < pageSize) break;
        }

        DeletionLogCursorStore.saveDeletedCardIdsCache(cached);
        return cached;
      }

      final firestore = FirebaseService.firestore;
      // 'card_operations' コレクションを検索
      final cardOpsSnapshot = await firestore
          .collection('users')
          .doc(userId)
          .collection('card_operations') // ★ 対象コレクションを変更
          .where('operation', isEqualTo: 'deleted_card') // ★ 操作タイプ
          .get();

      for (final doc in cardOpsSnapshot.docs) {
        final data = doc.data();
        // 'firestoreId' フィールドを取得
        if (data['firestoreId'] != null) {
          // ★ フィールド名を変更
          deletedCardFirestoreIds.add(data['firestoreId'].toString());
        } else {
          print('⚠️ 削除ログに firestoreId がありません: ${doc.id}');
        }
      }
    } catch (e) {
      print('❌ 削除済みカードIDの取得中にエラー: $e');
    }

    return deletedCardFirestoreIds;
  }

  // クリア済みデッキ名を取得
  static Future<Set<String>> _fetchClearedDeckNames() async {
    final clearedDeckNames = <String>{};
    final userId = FirebaseService.getUserId();

    if (userId == null) return clearedDeckNames;

    try {
      if (FirebaseSyncFeatureFlags.useLogicalDelete()) {
        return clearedDeckNames;
      }
      if (FirebaseSyncFeatureFlags.useIncrementalDeletionLog()) {
        final cached = DeletionLogCursorStore.loadClearedDeckNamesCache();
        SyncCursor? cursor = DeletionLogCursorStore.loadClearedDeckOpsCursor();

        const int pageSize = 500;
        for (int page = 0; page < 200; page++) {
          Query<Map<String, dynamic>> query = FirebaseService.firestore
              .collection('users')
              .doc(userId)
              .collection('deck_operations')
              .where('operation', isEqualTo: 'cleared_cards')
              .orderBy('timestamp')
              .orderBy(FieldPath.documentId)
              .limit(pageSize);

          if (cursor != null) {
            query = query.startAfter([cursor.toTimestamp(), cursor.docId]);
          }

          final snap = await query.get();
          if (snap.docs.isEmpty) break;

          for (final doc in snap.docs) {
            final data = doc.data();
            final v = data['deckName'];
            if (v != null) {
              cached.add(v.toString());
            }
          }

          final last = snap.docs.last;
          final lastTs = last.data()['timestamp'];
          if (lastTs is Timestamp) {
            cursor = SyncCursor.fromSnapshot(timestamp: lastTs, docId: last.id);
            DeletionLogCursorStore.saveClearedDeckOpsCursor(cursor);
          }

          if (snap.docs.length < pageSize) break;
        }

        DeletionLogCursorStore.saveClearedDeckNamesCache(cached);
        return cached;
      }

      final firestore = FirebaseService.firestore;
      final deckOpsSnapshot = await firestore
          .collection('users')
          .doc(userId)
          .collection('deck_operations')
          .where('operation', isEqualTo: 'cleared_cards')
          .get();

      for (final doc in deckOpsSnapshot.docs) {
        final data = doc.data();
        if (data['deckName'] != null) {
          clearedDeckNames.add(data['deckName'].toString());
        }
      }
    } catch (e) {
      print('クリア済みデッキ名の取得中にエラー: $e');
    }

    return clearedDeckNames;
  }

  // 初回ログイン時の同期（ローカルデータをクラウドに保存）
  static Future<void> initialSync() async {
    if (FirebaseService.getUserId() == null) return; // ログインしていない場合は何もしない

    print('初回同期処理を開始します');
    try {
      // ローカルデータを取得
      final localDecks = HiveService.getDeckBox().values.toList();
      final localCards = HiveService.getCardBox().values.toList();

      // ★★★ 追加: 削除済みデッキ名リストを取得 ★★★
      final deletedDeckNames = await _fetchDeletedDeckNames();
      print('初回同期: 削除済みデッキ名リスト ${deletedDeckNames.length}件を取得');

      if (localDecks.isEmpty && localCards.isEmpty) {
        print('ローカルに同期対象のデータがありません。初回同期をスキップします。');
        return;
      }
      print('ローカルデータ: デッキ${localDecks.length}件、カード${localCards.length}件');

      // ★★★ 修正: アップロードするデッキリストをフィルタリング ★★★
      final decksToSync = localDecks
          .where((deck) => !deletedDeckNames.contains(deck.deckName))
          .toList();
      print('初回同期: 削除フラグを考慮した結果、アップロード対象デッキ ${decksToSync.length}件');

      // クラウドへ同期（ローカルのデータを正とする）
      await FirebaseService.syncLocalToCloud(decksToSync, localCards);

      print('初回同期処理が正常に完了しました。');
    } catch (e) {
      print('初回同期エラー: $e');
      rethrow;
    }
  }

  // リソースの解放
  void dispose() {
    stopAutoSync();
    _realtimeSubscription?.cancel();
    // ★★★ 同期状態コントローラー - 新しいサービスを使用 ★★★
    // _syncStatusController.close();
  }

  // ローカルの操作をクラウドに直接反映する（新しい一方向同期方式）
  ///
  /// @param operation 操作タイプ ('create', 'update', 'delete_card', 'delete_deck' など)
  /// @param data 操作に関連するデータ (カードキー、デッキ名など)
  static Future<Map<String, dynamic>> syncOperationToCloud(
      String operation, Map<String, dynamic> data) async {
    final userId = FirebaseService.getUserId();
    if (userId == null) {
      print('📱➡️☁️ syncOperationToCloud: ユーザーがログインしていないため、同期をスキップします');
      return {
        'success': false,
        'isNetworkError': false,
        'message': 'ユーザーがログインしていません'
      };
    }

    // シングルトンインスタンスを取得して同期状態を管理
    final instance = SyncService();

    // ★★★ 重要操作中はスキップ - 新しいサービスを使用 ★★★
    if (CriticalOperationService.isInProgress) {
      print('📱➡️☁️ syncOperationToCloud: クリティカル操作中のため同期をスキップ: $operation');
      return {
        'success': false, // 失敗扱いとする
        'isNetworkError': false,
        'message': '他の重要な処理が実行中です'
      };
    }

    // 同期中の場合は一定時間待機して再試行する
    if (SyncStateManager.instance.isSyncing) {
      print('📱➡️☁️ syncOperationToCloud: 他の同期処理が進行中です。待機します...');

      // ★★★ 重要操作（カード作成/更新）の場合は待機時間を延長 ★★★
      final isImportantOperation =
          operation == 'create_card' || operation == 'update_card';
      final maxRetries = isImportantOperation ? 8 : 3; // 重要操作は8回まで
      final waitInterval = isImportantOperation ? 500 : 1000; // 重要操作は0.5秒間隔

      print(
          '📱➡️☁️ syncOperationToCloud: ${isImportantOperation ? '重要操作' : '通常操作'}として処理 (最大${maxRetries}回試行)');

      for (int i = 0; i < maxRetries; i++) {
        // 指定間隔で待機
        await Future.delayed(Duration(milliseconds: waitInterval));

        // 再チェック - 同期状態が解除されていれば続行
        if (!SyncStateManager.instance.isSyncing) {
          print(
              '📱➡️☁️ syncOperationToCloud: 同期状態解除を確認。処理を続行します (${i + 1}回目の待機後)');
          break;
        }

        // ★★★ 追加: 待機中にもクリティカル操作をチェック ★★★
        if (CriticalOperationService.isInProgress) {
          print(
              '📱➡️☁️ syncOperationToCloud: 待機中にクリティカル操作が開始されたため同期をスキップ: $operation');
          return {
            'success': false, // 失敗扱いとする
            'isNetworkError': false,
            'message': '他の重要な処理が実行中です',
            'shouldRetryLater': true // ★ 後で再試行すべきことを示すフラグ
          };
        }

        // 最後の待機でも同期中なら処理方法を分岐
        if (i == maxRetries - 1) {
          if (isImportantOperation) {
            // 重要操作の場合：待機を継続するのではなく、一時的にIDを予約して後で処理
            print(
                '📱➡️☁️ syncOperationToCloud: 重要操作の同期待機タイムアウト。一時処理モードに切り替え: $operation');
            return {
              'success': false,
              'isNetworkError': false,
              'message': '同期待機タイムアウト（重要操作）',
              'shouldRetryLater': true,
              'useTemporaryMode': true // ★ 一時処理モードを示すフラグ
            };
          } else {
            // 通常操作の場合：従来通りスキップ
            print(
                '📱➡️☁️ syncOperationToCloud: 同期待機タイムアウト。操作をスキップします: $operation');
            return {
              'success': false,
              'isNetworkError': false,
              'message': '他の同期処理が進行中です'
            };
          }
        }
      }
    }

    // 同期フラグを設定
    SyncStateManager.instance.startSync();

    print('📱➡️☁️ syncOperationToCloud: 操作「$operation」をクラウドに同期します');
    print('  データ: $data');

    try {
      bool overallSuccess = true; // 処理全体の結果フラグ
      bool hasNetworkError = false; // ネットワークエラーフラグ
      String errorMessage = '';

      // 1. 操作に基づいて適切なFirebase操作を実行
      switch (operation) {
        case 'delete_card':
          // カード削除
          // ★★★ 複数ID (firestoreIds) または 単一ID (firestoreId) を受け取るように修正 ★★★
          // 互換: 過去コードは cardKeys を使っていたので受ける
          final firestoreIdsToDelete =
              (data['firestoreIds'] as List<String>?) ??
                  (data['cardKeys'] as List<String>?); // 複数形キー/旧キー
          final singleFirestoreId = data['firestoreId'] as String?; // 単数形キー

          if (firestoreIdsToDelete != null && firestoreIdsToDelete.isNotEmpty) {
            print('  削除対象カード Firestore ID (複数): $firestoreIdsToDelete');
            for (final firestoreId in firestoreIdsToDelete) {
              // ★ リストをループ
              try {
                await FirebaseService.deleteCard(firestoreId);
                await _logCardOperation(userId, 'deleted_card',
                    firestoreId: firestoreId); // Firestore ID を記録
                print('  カード削除成功: $firestoreId');
              } catch (e) {
                print('  カード削除エラー (ID: $firestoreId): $e');
                overallSuccess = false;
                if (e.toString().contains('network') ||
                    e.toString().contains('socket') ||
                    e.toString().contains('connection') ||
                    e.toString().contains('timeout') ||
                    e.toString().contains('unavailable')) {
                  hasNetworkError = true;
                  errorMessage = 'ネットワーク接続エラー: $e';
                  break; // ネットワークエラーなら早期終了
                } else {
                  errorMessage = 'カード削除エラー: $e';
                }
              }
            }
          } else if (singleFirestoreId != null &&
              singleFirestoreId.isNotEmpty) {
            // 単一の Firestore ID が渡された場合 (個別削除など)
            print('  削除対象カード Firestore ID (単一): $singleFirestoreId');
            try {
              await FirebaseService.deleteCard(singleFirestoreId);
              await _logCardOperation(userId, 'deleted_card',
                  firestoreId: singleFirestoreId);
              print('  カード削除成功: $singleFirestoreId');
            } catch (e) {
              print('  カード削除エラー (ID: $singleFirestoreId): $e');
              overallSuccess = false;
              if (e.toString().contains('network') ||
                  e.toString().contains('socket') ||
                  e.toString().contains('connection') ||
                  e.toString().contains('timeout') ||
                  e.toString().contains('unavailable')) {
                hasNetworkError = true;
                errorMessage = 'ネットワーク接続エラー: $e';
              } else {
                errorMessage = 'カード削除エラー: $e';
              }
            }
          } else {
            print(
                '  警告: delete_card 操作に firestoreIds または firestoreId が指定されていません。');
            overallSuccess = false;
            errorMessage = 'パラメータエラー: キーが指定されていません';
          }
          break;

        case 'delete_deck':
          // デッキ削除
          if (data['deckName'] != null) {
            final deckName = data['deckName'].toString();
            print('  削除対象デッキ名: $deckName');
            List<String> cardIdsToDelete = []; // 削除するカードIDを保持するリスト
            bool deckDeletionSuccess = false; // デッキ削除が成功したか

            try {
              // ★★★ 削除前にカードIDを取得 ★★★
              try {
                // ★★★ カードコレクションへの参照を直接構築 ★★★
                final userIdForPath = FirebaseService.getUserId();
                if (userIdForPath == null)
                  throw Exception('ユーザーIDが取得できませんでした。');
                final cardsCollectionPath = 'users/$userIdForPath/cards';
                final cardsSnapshot = await FirebaseService.firestore
                    .collection(cardsCollectionPath)
                    .where('deckName', isEqualTo: deckName)
                    .get();
                cardIdsToDelete =
                    cardsSnapshot.docs.map((doc) => doc.id).toList();
                print(
                    '  削除対象の関連カードID (${cardIdsToDelete.length}件) を取得しました: $cardIdsToDelete');
              } catch (e) {
                print('  ⚠️ 関連カードIDの取得中にエラー: $e (デッキ削除は続行)');
                // カードID取得エラーは致命的ではないので、デッキ削除は試みる
              }

              // デッキパスを検索して削除
              final deletePath = await FirebaseService.findDeckByName(deckName);
              if (deletePath != null) {
                await FirebaseService.deleteDeckByPath(
                    deletePath); // これがカードも削除するはず
                deckDeletionSuccess = true;
                print('  デッキと関連カードの削除をFirebaseに要求しました: $deckName');
              } else {
                print('  警告: 削除対象デッキがFirebaseに見つかりません: $deckName');
                // デッキが見つからなくてもログは記録する
                deckDeletionSuccess = true; // ログ記録のために成功扱いとする
              }

              // ★★★ デッキ削除操作ログを記録 ★★★
              await _logDeckOperation(userId, 'deleted_deck',
                  deckName: deckName);
              print(
                  "  デッキ削除操作('deleted_deck')をログに記録しました: $deckName"); // ダブルクォートに変更

              // ★★★ カード削除操作ログを記録 (デッキ削除成功後) ★★★
              if (deckDeletionSuccess && cardIdsToDelete.isNotEmpty) {
                print("  関連カードの削除ログ('deleted_card')を記録します..."); // ダブルクォートに変更
                int loggedCardCount = 0;
                for (final cardId in cardIdsToDelete) {
                  try {
                    await _logCardOperation(userId, 'deleted_card',
                        firestoreId: cardId);
                    loggedCardCount++;
                  } catch (logError) {
                    print('  ⚠️ カード削除ログの記録エラー (ID: $cardId): $logError');
                  }
                }
                print('  $loggedCardCount 件のカード削除ログを記録しました。');
              }
            } catch (e) {
              print('  デッキまたは関連カードの削除エラー: $e');
              overallSuccess = false;
              // ネットワークエラーかどうかを判定
              if (e.toString().contains('network') ||
                  e.toString().contains('socket') ||
                  e.toString().contains('connection') ||
                  e.toString().contains('timeout') ||
                  e.toString().contains('unavailable')) {
                hasNetworkError = true;
                errorMessage = 'ネットワーク接続エラー: $e';
              } else {
                errorMessage = 'デッキ削除エラー: $e'; // エラーメッセージを設定
              }
            }
          } else {
            print('  警告: delete_deck 操作に deckName が指定されていません。');
            overallSuccess = false;
            errorMessage = 'パラメータエラー: デッキ名が指定されていません';
          }
          break;

        case 'delete_deck_cards':
          // デッキは残して、カードのみを削除
          bool cardDeleteSuccess = true;
          if (data['deckName'] != null) {
            final deckName = data['deckName'].toString();
            // 互換: 旧実装は cardKeys（Hiveキー）を渡していたが、削除APIは Firestore docId が必要。
            // 新実装は firestoreIds を優先し、cardKeys の場合は可能な範囲で Firestore ID へ解決する。
            final List<String>? firestoreIdsInput =
                (data['firestoreIds'] is List) ? List<String>.from(data['firestoreIds']) : null;
            final List<String>? cardKeysInput =
                (data['cardKeys'] is List) ? List<String>.from(data['cardKeys']) : null;

            List<String> firestoreIdsToDelete = <String>[];
            if (firestoreIdsInput != null && firestoreIdsInput.isNotEmpty) {
              firestoreIdsToDelete = firestoreIdsInput.where((s) => s.trim().isNotEmpty).toList();
            } else if (cardKeysInput != null && cardKeysInput.isNotEmpty) {
              // cardKeys -> firestoreId へ解決（ローカルHiveから可能な範囲で）
              final cardBox = HiveService.getCardBox();
              for (final rawKey in cardKeysInput) {
                final keyStr = rawKey.toString();
                FlashCard? card;
                // 1) 文字列キーとして直接引く
                card = cardBox.get(keyStr);
                // 2) 数値キーの可能性（旧データ等）
                if (card == null) {
                  final int? asInt = int.tryParse(keyStr);
                  if (asInt != null) {
                    card = cardBox.get(asInt);
                  }
                }
                // 3) 値を走査して firestoreId/id で一致を探す（最後の手段）
                if (card == null) {
                  for (final c in cardBox.values) {
                    if ((c.firestoreId != null && c.firestoreId == keyStr) || c.id == keyStr) {
                      card = c;
                      break;
                    }
                  }
                }
                // 見つからない場合はスキップ（Hiveキーだけでは Firestore docId を特定できない）
                if (card == null) continue;

                final String candidate =
                    (card.firestoreId != null && card.firestoreId!.isNotEmpty)
                        ? card.firestoreId!
                        : card.id;
                if (candidate.isNotEmpty) {
                  firestoreIdsToDelete.add(candidate);
                }
              }
              // 重複除去
              firestoreIdsToDelete = firestoreIdsToDelete.toSet().toList();
            }

            if (firestoreIdsToDelete.isNotEmpty) {
              print('  デッキ「$deckName」の${firestoreIdsToDelete.length}枚のカードを削除します');
              for (final firestoreId in firestoreIdsToDelete) {
                try {
                  await FirebaseService.deleteCard(firestoreId);
                  // ★★★ 追加: 削除操作を記録 ★★★
                  // ★★★ firestoreId をログに記録するように修正 ★★★
                  await _logCardOperation(userId, 'deleted_card',
                      // cardKey: firestoreId);
                      firestoreId: firestoreId);
                  print('  カード削除成功: $firestoreId');
                } catch (e) {
                  print('  カード削除エラー: $e');
                  cardDeleteSuccess = false;
                  // ネットワークエラーかどうかを判定
                  if (e.toString().contains('network') ||
                      e.toString().contains('socket') ||
                      e.toString().contains('connection') ||
                      e.toString().contains('timeout') ||
                      e.toString().contains('unavailable')) {
                    hasNetworkError = true;
                    errorMessage = 'ネットワーク接続エラー: $e';
                    break; // ネットワークエラーなら早期終了
                  } else {
                    errorMessage = 'カード削除エラー: $e'; // エラーメッセージを設定
                  }
                }
              }
              // デッキのカードをクリアしたことを記録 (エラーがあっても記録は試みる)
              await _logDeckOperation(userId, 'cleared_cards',
                  deckName: deckName);
            } else {
              print('警告: delete_deck_cards 操作に firestoreIds/cardKeys が指定されていません。');
              cardDeleteSuccess = false;
              errorMessage = 'パラメータエラー: firestoreIds/cardKeys がありません';
            }
          } else {
            print('警告: delete_deck_cards 操作に deckName が指定されていません。');
            cardDeleteSuccess = false;
            errorMessage = 'パラメータエラー: deckName がありません';
          }
          overallSuccess = cardDeleteSuccess;
          break;

        case 'create_card':
        case 'update_card':
          // カード作成/更新
          if (data['card'] != null && data['card'] is FlashCard) {
            // 型チェックを追加
            final card = data['card'] as FlashCard;
            try {
              // ★★★ saveCardをawaitで呼び出し、IDを受け取る ★★★

              // ★★★ 修正: userId を追加 ★★★
              await FirebaseService.saveCard(
                  card, FirebaseService.getUserId()!); // 修正後
              // ★★★ 修正: saveCard実行後に card.firestoreId を使用 ★★★
              final firestoreId = card.firestoreId;
              print(
                  '  ✅ カード保存成功: ${card.question} (${operation == 'create_card' ? '新規' : '更新'}), Firestore ID: $firestoreId');

              // ★★★ 新規作成の場合、結果にIDを追加 ★★★
              if (operation == 'create_card') {
                // 戻り値のMapを直接変更できないため、新しいMapを作成する
                // （このやり方は少し冗長なので、後でリファクタリング検討）
                return {
                  'success': true,
                  'isNetworkError': false,
                  'message': '成功',
                  // 'newFirestoreId': firestoreId // 古いコード (firestoreIdはvoidなので使えない)
                  'newFirestoreId':
                      card.firestoreId // ★★★ 修正: cardオブジェクトからIDを取得 ★★★
                };
              }
              // 更新の場合はIDは不要
            } catch (e) {
              print('  ❌ カード保存エラー: $e');
              overallSuccess = false;
              // ネットワークエラーか判定
              if (e.toString().contains('network') ||
                  e.toString().contains('socket') ||
                  e.toString().contains('connection') ||
                  e.toString().contains('timeout') ||
                  e.toString().contains('unavailable')) {
                hasNetworkError = true;
                errorMessage = 'ネットワーク接続エラー: $e';
              } else {
                errorMessage = 'カード保存エラー: $e';
              }
              // ★★★ エラー発生時はここで抜ける必要あり ★★★
              // （ただし、下の共通returnがあるのでここでは何もしない）
            }
          } else {
            print('  警告: ${operation} 操作に有効なカードデータが指定されていません。');
            overallSuccess = false;
            errorMessage = 'パラメータエラー: カードデータが無効です';
          }
          break;

        case 'create_deck':
        case 'update_deck':
          // デッキ作成/更新
          if (data['deck'] != null && data['deck'] is Deck) {
            // 型チェックを追加
            final deck = data['deck'] as Deck;
            // ★★★ 修正: FirebaseService.saveDeckを呼び出す ★★★
            try {
              await FirebaseService.saveDeck(deck);
              print(
                  '  ✅ デッキ保存成功: ${deck.deckName} (${operation == 'create_deck' ? '新規' : '更新'})');
            } catch (e) {
              print('  ❌ デッキ保存エラー: $e');
              overallSuccess = false;
              // ネットワークエラーか判定
              if (e.toString().contains('network') ||
                  e.toString().contains('socket') ||
                  e.toString().contains('connection') ||
                  e.toString().contains('timeout') ||
                  e.toString().contains('unavailable')) {
                hasNetworkError = true;
                errorMessage = 'ネットワーク接続エラー: $e';
              } else {
                errorMessage = 'デッキ保存エラー: $e';
              }
            }
          } else {
            print('  警告: ${operation} 操作に有効なデッキデータが指定されていません。');
            overallSuccess = false;
            errorMessage = 'パラメータエラー: デッキデータが無効です';
          }
          break;
        default: // ★★★ 追加: 未知の操作タイプへの対応 ★★★
          print('  警告: 未知の操作タイプです: $operation');
          overallSuccess = false;
          errorMessage = '未知の操作タイプです: $operation';
          break;
      }

      // 2. データをディスクに書き込む (エラーがあっても試みる)
      try {
        await HiveService.safeCompact();
      } catch (e) {
        print('  ⚠️ Hiveへの書き込み中にエラー: $e');
        // このエラーは同期結果には含めない (Firebaseへの同期が主目的のため)
      }

      print(
          '📱➡️☁️ syncOperationToCloud: 操作「$operation」の同期が${overallSuccess ? '完了' : '失敗'}しました');

      // Phase 2.5: ネットワーク系で失敗した操作を永続キューへ積む（再起動跨ぎで必ず反映）
      if (!overallSuccess && hasNetworkError) {
        try {
          switch (operation) {
            case 'create_card':
            case 'update_card':
              if (data['card'] is FlashCard) {
                await PendingOperationsService.enqueueCardUpsert(
                    data['card'] as FlashCard);
              }
              break;
            case 'delete_card':
              final ids = (data['firestoreIds'] as List<String>?) ??
                  (data['cardKeys'] as List<String>?);
              final single = data['firestoreId'] as String?;
              if (ids != null && ids.isNotEmpty) {
                for (final id in ids) {
                  await PendingOperationsService.enqueueCardDelete(id);
                }
              } else if (single != null && single.isNotEmpty) {
                await PendingOperationsService.enqueueCardDelete(single);
              }
              break;
            case 'delete_deck':
              final deckName = data['deckName']?.toString();
              if (deckName != null && deckName.isNotEmpty) {
                await PendingOperationsService.enqueueDeckDeleteByName(deckName);
              }
              break;
            case 'delete_deck_cards':
              // 互換: firestoreIds を優先し、cardKeys は Firestore ID に解決できたものだけ enqueue する
              final List<String>? ids =
                  (data['firestoreIds'] is List) ? List<String>.from(data['firestoreIds']) : null;
              if (ids != null && ids.isNotEmpty) {
                for (final id in ids.where((s) => s.trim().isNotEmpty)) {
                  await PendingOperationsService.enqueueCardDelete(id);
                }
                break;
              }
              final List<String>? cardKeys =
                  (data['cardKeys'] is List) ? List<String>.from(data['cardKeys']) : null;
              if (cardKeys != null && cardKeys.isNotEmpty) {
                final cardBox = HiveService.getCardBox();
                final resolved = <String>{};
                for (final rawKey in cardKeys) {
                  final keyStr = rawKey.toString();
                  FlashCard? card = cardBox.get(keyStr);
                  if (card == null) {
                    final int? asInt = int.tryParse(keyStr);
                    if (asInt != null) card = cardBox.get(asInt);
                  }
                  if (card != null) {
                    final id = (card.firestoreId != null && card.firestoreId!.isNotEmpty)
                        ? card.firestoreId!
                        : card.id;
                    if (id.isNotEmpty) resolved.add(id);
                  }
                }
                for (final id in resolved) {
                  await PendingOperationsService.enqueueCardDelete(id);
                }
              }
              break;
            case 'create_deck':
            case 'update_deck':
              if (data['deck'] is Deck) {
                await PendingOperationsService.enqueueDeckUpsert(
                    data['deck'] as Deck);
              }
              break;
          }
        } catch (e) {
          print('⚠️ pending enqueue に失敗（続行）: $e');
        }
      }

      // ★★★ create_card 成功時は上で return しているので、ここは通らない ★★★
      // ★★★ それ以外のケースの戻り値 ★★★
      return {
        'success': overallSuccess,
        'isNetworkError': hasNetworkError,
        'shouldRetryLater': !overallSuccess && hasNetworkError,
        'message': overallSuccess ? '成功' : errorMessage // 失敗時はエラーメッセージを返す
      };
    } catch (e) {
      print('❌ syncOperationToCloud: 同期エラー: $e');
      instance._updateStatus(SyncStatus.error);

      // ネットワークエラーかどうかを判定
      bool isNetworkError = e.toString().contains('network') ||
          e.toString().contains('socket') ||
          e.toString().contains('connection') ||
          e.toString().contains('timeout') ||
          e.toString().contains('unavailable');

      // Phase 2.5: 例外で落ちた場合も、ネットワーク系なら可能な範囲でenqueue
      if (isNetworkError) {
        try {
          switch (operation) {
            case 'create_card':
            case 'update_card':
              if (data['card'] is FlashCard) {
                await PendingOperationsService.enqueueCardUpsert(
                    data['card'] as FlashCard);
              }
              break;
            case 'delete_card':
              final ids = (data['firestoreIds'] as List<String>?) ??
                  (data['cardKeys'] as List<String>?);
              final single = data['firestoreId'] as String?;
              if (ids != null && ids.isNotEmpty) {
                for (final id in ids) {
                  await PendingOperationsService.enqueueCardDelete(id);
                }
              } else if (single != null && single.isNotEmpty) {
                await PendingOperationsService.enqueueCardDelete(single);
              }
              break;
            case 'delete_deck':
              final deckName = data['deckName']?.toString();
              if (deckName != null && deckName.isNotEmpty) {
                await PendingOperationsService.enqueueDeckDeleteByName(deckName);
              }
              break;
            case 'delete_deck_cards':
              if (data['cardKeys'] is List) {
                final cardKeys = List<String>.from(data['cardKeys']);
                for (final id in cardKeys) {
                  await PendingOperationsService.enqueueCardDelete(id);
                }
              }
              break;
            case 'create_deck':
            case 'update_deck':
              if (data['deck'] is Deck) {
                await PendingOperationsService.enqueueDeckUpsert(
                    data['deck'] as Deck);
              }
              break;
          }
        } catch (enqueueError) {
          print('⚠️ 例外時pending enqueueに失敗（続行）: $enqueueError');
        }
      }

      return {
        'success': false,
        'isNetworkError': isNetworkError,
        'shouldRetryLater': isNetworkError,
        'message': isNetworkError ? 'ネットワーク接続エラー: $e' : '同期エラー: $e'
      };
    } finally {
      // 同期フラグを必ず解除
      SyncStateManager.instance.resetSyncState();
      instance._updateStatus(SyncStatus.idle);
    }
  }

  /// 削除専用の一方向同期（新しい一方向同期方式に基づく実装）
  static Future<bool> syncDeletionToCloud(
      String deckName, List<String> deletedCardKeys) async {
    final userId = FirebaseService.getUserId();
    if (userId == null) {
      print('💫 syncDeletionToCloud: ユーザーがログインしていないため、削除同期をスキップします');
      return false;
    }

    // シングルトンインスタンスを取得（同期状態はsyncOperationToCloud内で管理）
    final instance = SyncService();

    print(
        '💫 syncDeletionToCloud: 削除情報の同期を開始します（非推奨API - 新しいsyncOperationToCloudの使用を検討してください）');
    print('  デッキ名: $deckName');
    print('  削除カード数: ${deletedCardKeys.length}');

    try {
      bool success = true;

      // カード削除の同期
      if (deletedCardKeys.isNotEmpty) {
        final cardResult = await syncOperationToCloud(
            'delete_card', {'cardKeys': deletedCardKeys});
        if (!cardResult['success']) {
          success = false;
          print('  カード削除の同期に失敗しました');
        }
      }

      // デッキ削除の同期
      if (deckName.isNotEmpty) {
        final deckResult =
            await syncOperationToCloud('delete_deck', {'deckName': deckName});
        if (!deckResult['success']) {
          success = false;
          print('  デッキ削除の同期に失敗しました');
        }

        // ★★★ 追加: デッキ削除時、削除ログを記録 ★★★
        if (userId.isNotEmpty) {
          await _logDeckOperation(userId, 'deleted_deck', deckName: deckName);
          print('✅ デッキ削除ログを記録しました: $deckName');
        }
      }

      print('💫 syncDeletionToCloud: 削除情報の同期が${success ? '成功' : '一部失敗'}しました');
      return success;
    } catch (e) {
      print('❌ syncDeletionToCloud: 削除情報の同期中にエラーが発生しました: $e');
      return false;
    }
  }

  // ★★★ 追加: カード操作ログ記録用メソッド ★★★
  /// Firestoreにカード操作のログを記録する内部メソッド
  static Future<void> _logCardOperation(String userId, String operationType,
      {String? firestoreId, String? deckName}) async {
    if (userId.isEmpty) return;

    final logData = <String, dynamic>{
      'operation': operationType,
      'timestamp': FieldValue.serverTimestamp(),
    };

    if (firestoreId != null) {
      logData['firestoreId'] = firestoreId;
    }
    if (deckName != null) {
      logData['deckName'] = deckName;
    }

    try {
      final firestore = FirebaseService.firestore;
      await firestore
          .collection('users')
          .doc(userId)
          .collection('card_operations')
          .add(logData);
      print('✅ カード操作ログ記録成功: $operationType ($logData)');
    } catch (e) {
      print('❌ カード操作ログ記録エラー: $e');
      // ログ記録のエラーは同期処理全体を妨げないようにする
    }
  }

  // ★★★ 追加: デッキ操作ログ記録用メソッド (必要に応じて使用) ★★★
  /// Firestoreにデッキ操作のログを記録する内部メソッド
  static Future<void> _logDeckOperation(String userId, String operationType,
      {String? deckName}) async {
    if (userId.isEmpty) return;

    final logData = <String, dynamic>{
      'operation': operationType,
      'timestamp': FieldValue.serverTimestamp(),
    };

    if (deckName != null) {
      logData['deckName'] = deckName;
    }

    try {
      final firestore = FirebaseService.firestore;
      await firestore
          .collection('users')
          .doc(userId)
          .collection('deck_operations')
          .add(logData);
      print('✅ デッキ操作ログ記録成功: $operationType ($logData)');
    } catch (e) {
      print('❌ デッキ操作ログ記録エラー: $e');
    }
  }

  // 削除されたデッキ名を取得
  static Future<Set<String>> _fetchDeletedDeckNames() async {
    final deletedDeckNames = <String>{};
    final userId = FirebaseService.getUserId();

    if (userId == null) return deletedDeckNames;

    try {
      if (FirebaseSyncFeatureFlags.useLogicalDelete()) {
        return deletedDeckNames;
      }
      if (FirebaseSyncFeatureFlags.useIncrementalDeletionLog()) {
        final cached = DeletionLogCursorStore.loadDeletedDeckNamesCache();
        SyncCursor? cursor = DeletionLogCursorStore.loadDeletedDeckOpsCursor();

        const int pageSize = 500;
        for (int page = 0; page < 200; page++) {
          Query<Map<String, dynamic>> query = FirebaseService.firestore
              .collection('users')
              .doc(userId)
              .collection('deck_operations')
              .where('operation', isEqualTo: 'deleted_deck')
              .orderBy('timestamp')
              .orderBy(FieldPath.documentId)
              .limit(pageSize);

          if (cursor != null) {
            query = query.startAfter([cursor.toTimestamp(), cursor.docId]);
          }

          final snap = await query.get();
          if (snap.docs.isEmpty) break;

          for (final doc in snap.docs) {
            final data = doc.data();
            final v = data['deckName'];
            if (v != null) {
              cached.add(v.toString());
            }
          }

          final last = snap.docs.last;
          final lastTs = last.data()['timestamp'];
          if (lastTs is Timestamp) {
            cursor = SyncCursor.fromSnapshot(timestamp: lastTs, docId: last.id);
            DeletionLogCursorStore.saveDeletedDeckOpsCursor(cursor);
          }

          if (snap.docs.length < pageSize) break;
        }

        DeletionLogCursorStore.saveDeletedDeckNamesCache(cached);
        return cached;
      }

      final firestore = FirebaseService.firestore;
      final deckOpsSnapshot = await firestore
          .collection('users')
          .doc(userId)
          .collection('deck_operations')
          .where('operation',
              isEqualTo: 'deleted_deck') // 'cleared_cards'ではなく'deleted_deck'を検索
          .get();

      for (final doc in deckOpsSnapshot.docs) {
        final data = doc.data();
        if (data['deckName'] != null) {
          deletedDeckNames.add(data['deckName'].toString());
        }
      }
    } catch (e) {
      print('削除済みデッキ名の取得中にエラー: $e');
    }

    return deletedDeckNames;
  }

  // 公開用: 削除済みデッキ名を取得
  static Future<Set<String>> fetchDeletedDeckNames() async {
    return await _fetchDeletedDeckNames();
  }

  // ★★★ 学習データ比較用のヘルパーメソッドを追加 ★★★

  // ★★★ 追加: デッキ削除ログのクリーンアップメソッド ★★★
  /// 指定されたデッキ名の 'deleted_deck' ログを Firebase から削除する
  static Future<void> cleanupDeckDeletionLogIfNeeded(
      String userId, String deckName) async {
    if (userId.isEmpty || deckName.isEmpty) {
      print('🧹 cleanupDeckDeletionLogIfNeeded: userId または deckName が空のためスキップ');
      return;
    }

    print('🧹 cleanupDeckDeletionLogIfNeeded: ログクリーンアップ開始 - デッキ名: $deckName');

    try {
      final firestore = FirebaseService.firestore;
      final deckOpsRef = firestore
          .collection('users')
          .doc(userId)
          .collection('deck_operations');

      // 削除対象のログを検索
      final querySnapshot = await deckOpsRef
          .where('operation', isEqualTo: 'deleted_deck')
          .where('deckName', isEqualTo: deckName)
          .get();

      if (querySnapshot.docs.isEmpty) {
        print('🧹 cleanupDeckDeletionLogIfNeeded: 削除対象のログは見つかりませんでした');
        return;
      }

      // 見つかったログを削除
      int deletedCount = 0;
      final batch = firestore.batch();
      for (final doc in querySnapshot.docs) {
        batch.delete(doc.reference);
        deletedCount++;
        print('   - 削除対象ログID: ${doc.id}');
      }
      await batch.commit();
      print('🧹 cleanupDeckDeletionLogIfNeeded: $deletedCount 件の削除ログを削除しました');
    } catch (e) {
      print('❌ cleanupDeckDeletionLogIfNeeded: 削除ログのクリーンアップ中にエラー: $e');
      // エラーが発生しても処理は続行する（ログ削除の失敗はデッキ作成をブロックしない）
    }
  }

  // --- 同期漏れ差異チェック機能 --- を --- 同期差異解決機能 --- に変更

  // --- 同期差異解決機能 ---

  /// ローカルとFirebase間のデータ差異を検出し、更新日時に基づいて解決する
  /// 戻り値: 同期結果のサマリ (Map)
  Future<Map<String, int>> resolveDataDiscrepancies() async {
    print("同期差異解決を開始します...\n==========");
    Map<String, int> syncResult = {
      'localDecksAdded': 0,
      'localDecksUpdated': 0,
      'localDecksDeleted': 0,
      'cloudDecksAdded': 0,
      'cloudDecksUpdated': 0, // クラウド側の更新は saveDeck/saveCard 内で処理されるため直接カウントは難しい
      'cloudDecksDeleted': 0,
      'localCardsAdded': 0,
      'localCardsUpdated': 0,
      'localCardsDeleted': 0,
      'cloudCardsAdded': 0,
      'cloudCardsUpdated': 0, // 同上
      'cloudCardsDeleted': 0,
      'skipped': 0,
      'errors': 0,
    };

    final userId = FirebaseService.getUserId();
    if (userId == null) {
      print("ユーザーがログインしていません。");
      syncResult['errors'] = 1;
      // ここでエラーメッセージを返す仕組みを追加しても良い
      return syncResult;
    }

    // 処理中であることを示すためにステータス更新
    _updateStatus(SyncStatus.syncing);

    try {
      // 1. データの取得
      print("ローカルデータの取得を開始...");
      final deckBox = HiveService.getDeckBox();
      final cardBox = HiveService.getCardBox();
      final localDecks = deckBox.values.toList();
      final localCards = cardBox.values.toList();
      print(
          "ローカルデータ取得完了: Decks=${localDecks.length}, Cards=${localCards.length}");

      print("Firebaseデータの取得を開始...");
      final firebaseDecks = await FirebaseService.getDecks();
      final firebaseCards = await FirebaseService.getAllCardsForUser(userId);
      print(
          "Firebaseデータ取得完了: Decks=${firebaseDecks.length}, Cards=${firebaseCards.length}");

      // 削除ログの取得
      print("削除ログの取得を開始...");
      final deletedDeckNames = await _fetchDeletedDeckNames();
      final deletedCardFirestoreIds =
          await fetchDeletedCardKeys(); // ★ 修正: publicメソッド呼び出し
      final clearedDeckNames = await _fetchClearedDeckNames(); // L452相当
      print(
          "削除ログ取得完了: Decks=${deletedDeckNames.length}, Cards=${deletedCardFirestoreIds.length}");

      // Map形式に変換 (IDをキーにする)
      final localDecksMap = {for (var deck in localDecks) deck.id: deck};
      // ★★★ ローカルカードのIDがnullの場合の対応 ★★★
      final localCardsMap = <String, FlashCard>{};
      for (var card in localCards) {
        // ID が null または空文字列でないことを確認
        if (card.id.isNotEmpty) {
          localCardsMap[card.id] = card;
        } else {
          print(
              "⚠️ ローカルカードにIDがありません: ${card.question} (Hive Key: ${card.key})");
          // IDがないカードはここでは扱えないためスキップ
          syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
        }
      }
      final firebaseDecksMap = {for (var deck in firebaseDecks) deck.id: deck};
      // ★★★ クラウドカードのIDがnullの場合の対応 ★★★
      final firebaseCardsMap = <String, FlashCard>{};
      for (var card in firebaseCards) {
        // ID が null または空文字列でないことを確認
        if (card.id.isNotEmpty) {
          firebaseCardsMap[card.id] = card;
        } else {
          print("⚠️ FirebaseカードにIDがありません: ${card.question}");
          // IDがないカードは通常ありえないが、スキップ
          syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
        }
      }

      // --- デッキの同期解決 ---
      print("デッキデータの同期解決を開始...\n---");
      final allDeckIds =
          {...localDecksMap.keys, ...firebaseDecksMap.keys}.toList();

      for (final deckId in allDeckIds) {
        final localDeck = localDecksMap[deckId];
        final fbDeck = firebaseDecksMap[deckId];

        final isDeletedLocally = localDeck == null; // ローカルにない
        final isDeletedInCloud = fbDeck == null; // クラウドにない
        final deckName =
            localDeck?.deckName ?? fbDeck?.deckName; // デッキ名取得 (どちらかにはあるはず)

        // デッキ名が取得できない場合はスキップ (Map作成時にIDがないケースなど)
        if (deckName == null || deckName.isEmpty) {
          // 空文字列もチェック
          print("⚠️ デッキID [$deckId] に対応するデッキ名が取得できませんでした。スキップします。");
          syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
          continue;
        }

        // 削除ログの確認
        bool isInDeckDeletionLog = deletedDeckNames.contains(deckName);

        if (isInDeckDeletionLog) {
          print("🚫 デッキ [$deckName] は削除ログにあるため同期をスキップし、必要なら削除します");
          if (localDeck != null) {
            try {
              await deckBox.delete(localDeck.key); // Hive Keyで削除
              syncResult['localDecksDeleted'] =
                  (syncResult['localDecksDeleted'] ?? 0) + 1;
              print("  🗑️ ローカルデッキを削除しました (削除ログ適用)");
            } catch (e) {
              print("  ❌ ローカルデッキ削除エラー (削除ログ適用): $e");
              syncResult['errors'] = (syncResult['errors'] ?? 0) + 1;
            }
          }
          if (fbDeck != null) {
            // クラウド側の削除はFirebaseService.deleteDeckByPathを呼ぶべきだが、
            // 削除ログがある=クラウド側で削除済みのはずなので、ここでは何もしない。
            print("  ℹ️ クラウドデッキも削除済みのはずです (削除ログ適用)");
            syncResult['cloudDecksDeleted'] =
                (syncResult['cloudDecksDeleted'] ?? 0) + 1; // 削除されたものとしてカウント
          }
          syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
          continue; // 次のデッキへ
        }

        if (!isDeletedLocally && isDeletedInCloud) {
          // ローカルにのみ存在 (削除ログにはない) -> クラウドに追加
          print("📤 ローカルデッキ [${localDeck.deckName}] をクラウドに追加します");
          try {
            await FirebaseService.saveDeck(localDeck);
            syncResult['cloudDecksAdded'] =
                (syncResult['cloudDecksAdded'] ?? 0) + 1;
          } catch (e) {
            print("  ❌ クラウドへのデッキ追加エラー: $e");
            syncResult['errors'] = (syncResult['errors'] ?? 0) + 1;
          }
        } else if (isDeletedLocally && !isDeletedInCloud) {
          // クラウドにのみ存在 (削除ログにはない) -> ローカルに追加
          print("📥 クラウドデッキ [${fbDeck.deckName}] をローカルに追加します");
          try {
            await deckBox.put(fbDeck.id, fbDeck); // IDをキーとして追加
            syncResult['localDecksAdded'] =
                (syncResult['localDecksAdded'] ?? 0) + 1;
          } catch (e) {
            print("  ❌ ローカルへのデッキ追加エラー: $e");
            syncResult['errors'] = (syncResult['errors'] ?? 0) + 1;
          }
        } else if (!isDeletedLocally && !isDeletedInCloud) {
          // 両方に存在 -> 内容比較と更新
          print("🔄 デッキ [${localDeck.deckName}] の内容を比較します");
          final localMillis =
              localDeck.firestoreUpdatedAt?.millisecondsSinceEpoch;
          final firebaseMillis =
              fbDeck.firestoreUpdatedAt?.millisecondsSinceEpoch;

          if (localMillis != null &&
              (firebaseMillis == null || localMillis > firebaseMillis)) {
            // ローカルの方が新しい -> クラウドを更新
            print(
                "  ローカルの方が新しいか、クラウドに時刻情報なし。クラウドを更新します。\n    Local TS: ${localDeck.firestoreUpdatedAt?.toDate().toIso8601String()}, Firebase TS: ${fbDeck.firestoreUpdatedAt?.toDate().toIso8601String()}");
            try {
              // isArchived も含めて更新するため、saveDeck を呼ぶ
              await FirebaseService.saveDeck(localDeck);
              // syncResult['cloudDecksUpdated']++; // saveDeck内で処理されるのでカウントしない
            } catch (e) {
              print("    ❌ クラウドのデッキ更新エラー: $e");
              syncResult['errors'] = (syncResult['errors'] ?? 0) + 1;
            }
          } else if (firebaseMillis != null &&
              (localMillis == null || firebaseMillis > localMillis)) {
            // クラウドの方が新しい -> ローカルを更新
            bool needsUpdate =
                ConflictResolver.isDeckContentDifferent(localDeck, fbDeck) ||
                    localMillis != firebaseMillis; // タイムスタンプも比較

            if (needsUpdate) {
              print("  クラウドの方が新しいため、ローカルを更新します。");
              try {
                bool changed = ConflictResolver.updateLocalDeckFromCloud(
                    localDeck, fbDeck);
                if (changed) {
                  await localDeck.save();
                  syncResult['localDecksUpdated'] =
                      (syncResult['localDecksUpdated'] ?? 0) + 1;
                } else {
                  print("  内容は同じです。更新は不要です。");
                  syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
                }
              } catch (e) {
                print("    ❌ ローカルのデッキ更新エラー: $e");
                syncResult['errors'] = (syncResult['errors'] ?? 0) + 1;
              }
            } else {
              print("  内容は同じです。更新は不要です。");
              syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
            }
          } else {
            // 更新日時が同じか、両方null -> 他のフィールドも比較して必要ならローカルを更新 (クラウド優先の思想で)
            bool needsUpdate =
                ConflictResolver.isDeckContentDifferent(localDeck, fbDeck);
            if (needsUpdate) {
              print("  更新日時は同じか不明ですが、内容が異なるためローカルを更新します (クラウド優先)。");
              try {
                bool changed = ConflictResolver.updateLocalDeckFromCloud(
                    localDeck, fbDeck);
                if (changed) {
                  await localDeck.save();
                  syncResult['localDecksUpdated'] =
                      (syncResult['localDecksUpdated'] ?? 0) + 1;
                } else {
                  print("  内容は同じです。更新は不要です。");
                  syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
                }
              } catch (e) {
                print("    ❌ ローカルのデッキ更新エラー(内容優先): $e");
                syncResult['errors'] = (syncResult['errors'] ?? 0) + 1;
              }
            } else {
              print(
                  "  更新日時も内容も同じです。\n    Local TS: ${localDeck.firestoreUpdatedAt?.toDate().toIso8601String()}, Firebase TS: ${fbDeck.firestoreUpdatedAt?.toDate().toIso8601String()}");
              syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
            }
          }
        } else {
          // 両方とも存在しない (通常は起こらないはず)
          print("⚠️ デッキ [$deckId] はローカルにもクラウドにも存在しません。");
          syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
        }
      }
      print("デッキデータの同期解決完了。\n---");

      // --- カードの同期解決 ---
      print("カードデータの同期解決を開始...\n---");
      // ID を使う (FlashCard の HiveObject.id に Firestore Document ID が入っている想定)
      final allCardIds =
          {...localCardsMap.keys, ...firebaseCardsMap.keys}.toList();

      for (final cardId in allCardIds) {
        final localCard = localCardsMap[cardId];
        final fbCard = firebaseCardsMap[cardId];
        final cardQuestion = localCard?.question ??
            fbCard?.question ??
            "不明なカード($cardId)"; // 質問取得

        final isDeletedLocally = localCard == null;
        final isDeletedInCloud = fbCard == null;
        bool isInCardDeletionLog = deletedCardFirestoreIds.contains(cardId);

        if (isInCardDeletionLog) {
          print(
              "🚫 カード [$cardQuestion / $cardId] は削除ログにあるため同期をスキップし、必要なら削除します");
          if (localCard != null) {
            try {
              await cardBox.delete(localCard.key); // Hiveのキーで削除
              syncResult['localCardsDeleted'] =
                  (syncResult['localCardsDeleted'] ?? 0) + 1;
              print("  🗑️ ローカルカードを削除しました (削除ログ適用)");
            } catch (e) {
              print("  ❌ ローカルカード削除エラー (削除ログ適用): $e");
              syncResult['errors'] = (syncResult['errors'] ?? 0) + 1;
            }
          }
          if (fbCard != null) {
            // クラウド側は削除ログがある=削除済みのはず
            print("  ℹ️ クラウドカードも削除済みのはずです (削除ログ適用)");
            syncResult['cloudCardsDeleted'] =
                (syncResult['cloudCardsDeleted'] ?? 0) + 1; // 削除されたものとしてカウント
          }
          syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
          continue; // 次のカードへ
        }

        if (!isDeletedLocally && isDeletedInCloud) {
          // ローカルにのみ存在 -> クラウドに追加
          print("📤 ローカルカード [$cardQuestion / $cardId] をクラウドに追加します");
          try {
            await FirebaseService.saveCard(localCard, userId);
            syncResult['cloudCardsAdded'] =
                (syncResult['cloudCardsAdded'] ?? 0) + 1;
          } catch (e) {
            print("  ❌ クラウドへのカード追加エラー: $e");
            syncResult['errors'] = (syncResult['errors'] ?? 0) + 1;
          }
        } else if (isDeletedLocally && !isDeletedInCloud) {
          // クラウドにのみ存在 -> ローカルに追加
          print("📥 クラウドカード [$cardQuestion / $cardId] をローカルに追加します");
          try {
            // ローカルに追加する前に、所属デッキがローカルに存在するか確認
            final deckExistsLocally =
                deckBox.values.any((deck) => deck.deckName == fbCard.deckName);
            if (deckExistsLocally) {
              await cardBox.put(fbCard.id, fbCard); // IDをキーとして追加
              syncResult['localCardsAdded'] =
                  (syncResult['localCardsAdded'] ?? 0) + 1;
            } else {
              print(
                  "  ⚠️ 所属デッキ [${fbCard.deckName}] がローカルに存在しないため、カードを追加できませんでした。\n      クラウド側のデッキ情報: ${firebaseDecks.firstWhere((d) => d.deckName == fbCard.deckName, orElse: () => Deck(id: 'N/A', deckName: '見つかりません'))}");
              syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
            }
          } catch (e) {
            print("  ❌ ローカルへのカード追加エラー: $e");
            syncResult['errors'] = (syncResult['errors'] ?? 0) + 1;
          }
        } else if (!isDeletedLocally && !isDeletedInCloud) {
          // 両方に存在 -> 内容比較と更新
          print("🔄 カード [$cardQuestion / $cardId] の内容を比較します");
          final localUpdatedAt = localCard.updatedAt; // int?
          final fbUpdatedAt = fbCard.updatedAt; // int?

          if (localUpdatedAt != null &&
              (fbUpdatedAt == null || localUpdatedAt > fbUpdatedAt)) {
            // ローカルの方が新しい -> クラウドを更新
            print(
                "  ローカルの方が新しい。クラウドを更新します (Local: $localUpdatedAt, Cloud: $fbUpdatedAt)");
            try {
              await FirebaseService.saveCard(localCard, userId);
              // syncResult['cloudCardsUpdated']++;
            } catch (e) {
              print("    ❌ クラウドのカード更新エラー: $e");
              syncResult['errors'] = (syncResult['errors'] ?? 0) + 1;
            }
          } else if (fbUpdatedAt != null &&
              (localUpdatedAt == null || fbUpdatedAt > localUpdatedAt)) {
            // クラウドの方が新しい -> ローカルを更新
            bool needsUpdate =
                _isCardContentDifferent(localCard, fbCard); // 内容比較
            if (needsUpdate) {
              print(
                  "  クラウドの方が新しい。ローカルを更新します (Local: $localUpdatedAt, Cloud: $fbUpdatedAt)");
              try {
                bool changed = ConflictResolver.updateLocalCardFromCloud(
                    localCard, fbCard);
                if (changed) {
                  await localCard.save();
                  syncResult['localCardsUpdated'] =
                      (syncResult['localCardsUpdated'] ?? 0) + 1;
                } else {
                  print("  内容は同じです。更新は不要です。");
                  syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
                }
              } catch (e) {
                print("    ❌ ローカルのカード更新エラー: $e");
                syncResult['errors'] = (syncResult['errors'] ?? 0) + 1;
              }
            } else {
              print("  内容は同じです。更新は不要です。");
              syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
            }
          } else {
            // 更新日時が同じか両方null -> 内容が違う場合のみローカルを更新 (クラウド優先)
            bool needsUpdate = _isCardContentDifferent(localCard, fbCard);
            if (needsUpdate) {
              print("  更新日時は同じか不明ですが、内容が異なるためローカルを更新します (クラウド優先)。");
              try {
                bool changed = ConflictResolver.updateLocalCardFromCloud(
                    localCard, fbCard);
                if (changed) {
                  await localCard.save();
                  syncResult['localCardsUpdated'] =
                      (syncResult['localCardsUpdated'] ?? 0) + 1;
                } else {
                  print("  内容は同じです。更新は不要です。");
                  syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
                }
              } catch (e) {
                print("    ❌ ローカルのカード更新エラー(内容優先): $e");
                syncResult['errors'] = (syncResult['errors'] ?? 0) + 1;
              }
            } else {
              print("  更新日時も内容も同じです。");
              syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
            }
          }
        } else {
          // 両方とも存在しない
          print("⚠️ カード [$cardId] はローカルにもクラウドにも存在しません。");
          syncResult['skipped'] = (syncResult['skipped'] ?? 0) + 1;
        }
      }
      print("カードデータの同期解決完了。\n---");

      print("同期差異解決完了。\n---");

      // 処理完了ステータス
      _updateStatus(SyncStatus.synced); // または SyncStatus.idle

      return syncResult;
    } catch (e, stacktrace) {
      print("同期差異解決中にエラーが発生しました: $e");
      print(stacktrace);
      _updateStatus(SyncStatus.error);
      syncResult['errors'] = (syncResult['errors'] ?? 0) + 1;
      return syncResult; // エラー時はここまでの結果を返す
    } finally {
      SyncStateManager.instance.resetSyncState();
      _updateStatus(SyncStatus.idle); // 完了またはエラー後、アイドル状態に戻す
      // 最終的な状態をディスクに書き込む
      await HiveService.safeCompact().catchError((e) => print("最終書き込みエラー: $e"));
      print("同期プロセス終了。\n==========");
    }
  }

  /// カードの内容が異なるか比較するヘルパー関数 - 新しいサービスを使用
  bool _isCardContentDifferent(FlashCard card1, FlashCard card2) {
    return ConflictResolver.isCardContentDifferent(card1, card2);
  }

  // --- ここから追加 ---

  /// 指定されたデッキ名の削除ログをクリーンアップし、可能であればFirebase上のデッキデータも削除する
  ///
  /// [userId] ユーザーID
  /// [deckName] クリーンアップ対象のデッキ名
  static Future<void> cleanupDeckDeletionLog(
      String userId, String deckName) async {
    if (userId.isEmpty || deckName.isEmpty) {
      print('⚠️ cleanupDeckDeletionLog: userId または deckName が空のためスキップ');
      return;
    }
    print('🧹 cleanupDeckDeletionLog: デッキ "$deckName" の削除ログクリーンアップを開始');

    final firestore = FirebaseService.firestore;
    bool logDeleted = false;
    bool deckDocDeleted = false;

    try {
      // 1. deck_operations から該当ログを削除
      final logQuery = firestore
          .collection('users')
          .doc(userId)
          .collection('deck_operations')
          .where('deckName', isEqualTo: deckName)
          .where('operation', isEqualTo: 'deleted_deck'); // 念のため操作タイプも指定

      final logSnapshot = await logQuery.get();
      if (logSnapshot.docs.isNotEmpty) {
        final batch = firestore.batch();
        for (final doc in logSnapshot.docs) {
          batch.delete(doc.reference);
          print('  - 削除ログを削除対象に追加: ${doc.id}');
        }
        await batch.commit();
        logDeleted = true;
        print('  ✅ "$deckName" の削除ログ (${logSnapshot.docs.length}件) を削除しました。');
      } else {
        print('  ℹ️ "$deckName" の削除ログは見つかりませんでした。');
        logDeleted = true; // ログがない場合も成功とみなす
      }

      // 2. Firebase 上のデッキドキュメントを削除 (デッキ名で検索)
      try {
        print('  🔍 Firebase上のデッキ "$deckName" を検索中...');
        final decks = await FirebaseService.getDecks(); // 全デッキを取得
        final deckToDelete = decks.firstWhere(
          (d) => d.deckName == deckName,
          orElse: () => Deck(id: '', deckName: ''), // 見つからない場合はダミーを返す
        );

        if (deckToDelete.id.isNotEmpty) {
          print(
              '  🗑️ Firebase上のデッキ "$deckName" (ID: ${deckToDelete.id}) を削除します...');
          await FirebaseService.deleteDeck(deckToDelete.id); // IDで削除
          deckDocDeleted = true;
          print('  ✅ Firebase上のデッキ "$deckName" の削除を試みました。');
        } else {
          print('  ℹ️ Firebase上にデッキ "$deckName" は見つかりませんでした。');
          deckDocDeleted = true; // デッキがない場合も成功とみなす
        }
      } catch (e) {
        print('  ❌ Firebase上のデッキ検索・削除中にエラー: $e');
        // デッキドキュメント削除のエラーはログ削除には影響させない
      }
    } catch (e) {
      print('❌ cleanupDeckDeletionLog: 処理中にエラー: $e');
      // エラーが発生しても、できる限りの処理は完了している可能性がある
    } finally {
      print(
          '🧹 cleanupDeckDeletionLog: 処理完了 ($deckName) - LogDeleted: $logDeleted, DeckDocDeleted: $deckDocDeleted');
    }
  }

  // --- ここまで追加 ---

  /// ★★★ 最終確認用重複チェック（保存直前） ★★★
  static Future<Map<String, dynamic>> _performLastMinuteDuplicateCheck(
      FlashCard localCard) async {
    try {
      print('🔍 最終重複チェック開始: ${localCard.question}');

      // 最新のクラウドデータを取得
      final latestCloudCards = await FirebaseService.getCards();

      // 非常に厳密な条件でチェック
      final exactMatches = latestCloudCards.where((cc) {
        final contentMatch = cc.question.trim() == localCard.question.trim() &&
            cc.answer.trim() == localCard.answer.trim() &&
            cc.deckName == localCard.deckName;

        if (!contentMatch) return false;

        // 時間的近接性チェック（30秒以内）
        if (localCard.updatedAt != null && cc.updatedAt != null) {
          final timeDiff = (localCard.updatedAt! - cc.updatedAt!).abs();
          return timeDiff <= 30000; // 30秒以内
        }

        return true;
      }).toList();

      if (exactMatches.isNotEmpty) {
        final match = exactMatches.first;
        print('🚨 最終チェックで重複発見: 既存ID=${match.firestoreId}');
        return {
          'isDuplicate': true,
          'existingId': match.firestoreId,
          'matchCount': exactMatches.length
        };
      }

      print('✅ 最終チェック: 重複なし');
      return {'isDuplicate': false};
    } catch (e) {
      print('⚠️ 最終重複チェックエラー: $e');
      return {'isDuplicate': false, 'error': e.toString()};
    }
  }
} // <- SyncServiceクラスの閉じ括弧

// ★★★ 同期状態を表す列挙型 - 新しいサービスを使用 ★★★
// enum SyncStatus {
//   idle, // アイドル状態
//   syncing, // 同期中
//   synced, // 同期完了
//   error // エラー発生
// }

// SyncService のインスタンスを提供する Provider
final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService();
});

// ######## ここから新機能追加 ########

/// デッキとカードの同期状態を検証するクラス
class SyncVerificationResult {
  final bool isSuccess; // 検証が成功したか
  final String message; // 検証結果のメッセージ
  final List<String> missingDecks; // ローカルに存在しないデッキ名
  final List<String> extraDecks; // Firebaseに存在しないデッキ名
  final int missingCardsCount; // ローカルに存在しないカードの数
  final int repairedDecksCount; // 修復されたデッキの数
  final int repairedCardsCount; // 修復されたカードの数
  final bool hasSyncError; // 同期エラーが発生したか

  SyncVerificationResult({
    required this.isSuccess,
    required this.message,
    this.missingDecks = const [],
    this.extraDecks = const [],
    this.missingCardsCount = 0,
    this.repairedDecksCount = 0,
    this.repairedCardsCount = 0,
    this.hasSyncError = false,
  });
}

extension SyncServiceVerification on SyncService {
  /// すべてのデッキとカードが正しく同期されているか検証し、必要に応じて修復する
  ///
  /// [repair] - 問題があった場合に修復を試みるか（デフォルト: true）
  /// [force] - 問題がなくても強制的に修復を試みるか（デフォルト: false）
  ///
  /// 戻り値: 検証と修復の結果
  static Future<SyncVerificationResult> verifyAndRepairSync({
    bool repair = true,
    bool force = false,
  }) async {
    print('🔍 同期状態の検証を開始します...');
    final userId = FirebaseService.getUserId();

    // ログインしていない場合
    if (userId == null) {
      return SyncVerificationResult(
        isSuccess: false,
        message: 'ユーザーがログインしていません。同期検証にはログインが必要です。',
        hasSyncError: true,
      );
    }

    try {
      // インスタンスを取得して同期状態をチェック
      final instance = SyncService();
      if (SyncStateManager.instance.isSyncing) {
        return SyncVerificationResult(
          isSuccess: false,
          message: '別の同期処理が進行中です。完了後に再試行してください。',
          hasSyncError: true,
        );
      }

      // 同期フラグを設定
      SyncStateManager.instance.startSync();

      try {
        // 1. Firebase上の削除されていないデッキとカードを取得
        print('🌥️ Firebaseからデータを取得中...');
        // Firebase上の削除済みデッキ名を取得
        final deletedDeckNames = await SyncService._fetchDeletedDeckNames();
        print(
            '🗑️ 削除済みデッキ: ${deletedDeckNames.length}件 ${deletedDeckNames.join(', ')}');

        // Firebase上の削除されていないデッキとカードを取得
        final cloudData = await FirebaseService.syncCloudToLocal();
        final List<Deck> cloudDecks = cloudData['decks'];
        final List<FlashCard> cloudCards = cloudData['cards'];

        // 削除済みデッキを除外
        final activeCloudDecks = cloudDecks
            .where((deck) => !deletedDeckNames.contains(deck.deckName))
            .toList();

        print('🌥️ Firebase上のアクティブなデッキ: ${activeCloudDecks.length}件');
        for (final deck in activeCloudDecks) {
          print('  - ${deck.deckName}');
        }

        // 2. ローカルのデッキとカードを取得
        final deckBox = HiveService.getDeckBox();
        final cardBox = HiveService.getCardBox();
        final localDecks = deckBox.values.toList();
        final localCards = cardBox.values.toList();

        print('💾 ローカル上のデッキ: ${localDecks.length}件');
        for (final deck in localDecks) {
          print('  - ${deck.deckName}');
        }

        // 3. 比較して不足を検出
        // ローカルに存在すべきだが存在しないデッキを検出
        final missingDecks = <String>[];
        final localDeckNames = localDecks.map((d) => d.deckName).toSet();

        for (final cloudDeck in activeCloudDecks) {
          if (!localDeckNames.contains(cloudDeck.deckName)) {
            missingDecks.add(cloudDeck.deckName);
          }
        }

        // Firebaseに存在しないローカルデッキを検出（削除されたが削除ログがないかも）
        final cloudDeckNames = activeCloudDecks.map((d) => d.deckName).toSet();
        final extraDecks = <String>[];

        for (final localDeck in localDecks) {
          if (!cloudDeckNames.contains(localDeck.deckName) &&
              !deletedDeckNames.contains(localDeck.deckName)) {
            extraDecks.add(localDeck.deckName);
          }
        }

        // 修復カウンター
        int repairedDecksCount = 0;
        int repairedCardsCount = 0;

        // 4. 問題が検出された場合または強制修復の場合
        final hasIssues = missingDecks.isNotEmpty || extraDecks.isNotEmpty;

        if ((hasIssues && repair) || force) {
          print('🔧 同期の問題を修復します...');

          // 4.1 欠落しているデッキを追加
          for (final missingDeckName in missingDecks) {
            final cloudDeck = activeCloudDecks.firstWhere(
              (d) => d.deckName == missingDeckName,
              orElse: () => Deck(id: '', deckName: missingDeckName),
            );

            if (cloudDeck.id.isNotEmpty) {
              print('➕ 欠落デッキを追加: ${cloudDeck.deckName}');
              await deckBox.put(cloudDeck.id, cloudDeck);
              repairedDecksCount++;

              // このデッキに属するカードも追加
              final deckCards = cloudCards
                  .where((c) => c.deckName == missingDeckName)
                  .toList();
              print('   関連カード: ${deckCards.length}件');

              for (final card in deckCards) {
                if (card.firestoreId != null && card.firestoreId!.isNotEmpty) {
                  print(
                      '   ➕ カード追加: ${card.question.substring(0, min(20, card.question.length))}...');
                  await cardBox.put(card.id, card);
                  repairedCardsCount++;
                }
              }
            }
          }

          // 4.2 余分なデッキは何もしない（削除は危険なため、問題があることを通知するのみ）
          for (final extraDeckName in extraDecks) {
            print('⚠️ ローカルにのみ存在するデッキ: $extraDeckName (削除されていないか確認が必要)');
          }

          print('🔄 最終整合性チェックを実行...');
          await HiveService.refreshDatabase();
        }

        // 5. 結果作成
        final missingCardsCount = cloudCards.length - localCards.length;
        final isSuccess = missingDecks.isEmpty &&
            extraDecks.isEmpty &&
            missingCardsCount <= 0;

        String message;
        if (isSuccess) {
          message = '同期状態は正常です。ローカルとクラウドのデータが一致しています。';
        } else if (hasIssues && repair) {
          message =
              '同期の問題が検出され、修復されました。デッキ: $repairedDecksCount件、カード: $repairedCardsCount件';
        } else if (hasIssues && !repair) {
          message = '同期の問題が検出されましたが、修復は実行されませんでした。';
        } else {
          message =
              '同期状態の検証が完了しました。修復: デッキ${repairedDecksCount}件、カード${repairedCardsCount}件';
        }

        print('✅ 同期状態の検証が完了しました: $message');

        return SyncVerificationResult(
          isSuccess:
              isSuccess || (hasIssues && repair && repairedDecksCount > 0),
          message: message,
          missingDecks: missingDecks,
          extraDecks: extraDecks,
          missingCardsCount: missingCardsCount > 0 ? missingCardsCount : 0,
          repairedDecksCount: repairedDecksCount,
          repairedCardsCount: repairedCardsCount,
        );
      } finally {
        // 同期フラグを解除
        SyncStateManager.instance.resetSyncState();
      }
    } catch (e, stackTrace) {
      print('❌ 同期検証中にエラーが発生しました: $e');
      print('スタックトレース: $stackTrace');

      return SyncVerificationResult(
        isSuccess: false,
        message: '同期検証中にエラーが発生しました: $e',
        hasSyncError: true,
      );
    }
  }

  /// 手動で同期を強制実行し、すべてのデータを再同期する
  static Future<SyncVerificationResult> forceSyncAndVerify() async {
    try {
      print('💫 強制同期と検証を開始します...');

      // 1. 強制的に双方向同期を実行
      final syncSuccess = await SyncService.forceCloudSync();

      // 2. 同期後にデータベースを更新
      await HiveService.refreshDatabase();

      // 3. 同期状態を検証
      final verificationResult = await verifyAndRepairSync(repair: true);

      return verificationResult;
    } catch (e) {
      print('❌ 強制同期と検証中にエラーが発生しました: $e');
      return SyncVerificationResult(
        isSuccess: false,
        message: '強制同期と検証中にエラーが発生しました: $e',
        hasSyncError: true,
      );
    }
  }
}

/// [min] 二つの数値のうち小さい方を返す (Dart:mathのmin関数と同等)
int min(int a, int b) => a < b ? a : b;

// 既存のコードの最後に追加する新しいデバッグ用のヘルパー関数
/// カードの更新前後の差分を詳細にログ出力するデバッグヘルパー関数
void logCardComparison(
    FlashCard localCard, FlashCard cloudCard, String source) {
  print('');
  print('📊 [カード比較 - $source] ID: ${localCard.id}');

  // 更新日時の比較
  final localUpdatedAt = localCard.updatedAt ?? 0;
  final cloudUpdatedAt = cloudCard.updatedAt ?? 0;
  final localUpdatedAtStr = localUpdatedAt > 0
      ? DateTime.fromMillisecondsSinceEpoch(localUpdatedAt).toIso8601String()
      : 'null';
  final cloudUpdatedAtStr = cloudUpdatedAt > 0
      ? DateTime.fromMillisecondsSinceEpoch(cloudUpdatedAt).toIso8601String()
      : 'null';

  print('  updatedAt比較:');
  print('    ローカル: $localUpdatedAt ($localUpdatedAtStr)');
  print('    クラウド: $cloudUpdatedAt ($cloudUpdatedAtStr)');

  // 次回レビュー日時の比較
  final localNextReview = localCard.nextReview;
  final cloudNextReview = cloudCard.nextReview;
  final localNextReviewStr =
      localNextReview != null ? localNextReview.toIso8601String() : 'null';
  final cloudNextReviewStr =
      cloudNextReview != null ? cloudNextReview.toIso8601String() : 'null';

  print('  nextReview比較:');
  print(
      '    ローカル: ${localNextReview?.millisecondsSinceEpoch} ($localNextReviewStr)');
  print(
      '    クラウド: ${cloudNextReview?.millisecondsSinceEpoch} ($cloudNextReviewStr)');

  // 内容の差分
  final diffFields = <String>[];
  if (localCard.deckName != cloudCard.deckName) diffFields.add('deckName');
  if (localCard.question != cloudCard.question) diffFields.add('question');
  if (localCard.answer != cloudCard.answer) diffFields.add('answer');
  if (localCard.explanation != cloudCard.explanation)
    diffFields.add('explanation');
  if (localNextReview != cloudNextReview) diffFields.add('nextReview');
  if (localCard.repetitions != cloudCard.repetitions)
    diffFields.add('repetitions');
  if ((localCard.eFactor - cloudCard.eFactor).abs() > 0.001)
    diffFields.add('eFactor');
  if (localCard.intervalDays != cloudCard.intervalDays)
    diffFields.add('intervalDays');

  if (diffFields.isEmpty) {
    print('  内容の差分: なし（完全一致）');
  } else {
    print('  内容の差分: ${diffFields.join(', ')}');

    // 詳細な差分（diffFields内のフィールドの実際の値）
    for (final field in diffFields) {
      if (field == 'deckName') {
        print(
            '    deckName: ローカル="${localCard.deckName}", クラウド="${cloudCard.deckName}"');
      } else if (field == 'question') {
        print(
            '    question: ローカル="${localCard.question}", クラウド="${cloudCard.question}"');
      } else if (field == 'answer') {
        print(
            '    answer: ローカル="${localCard.answer}", クラウド="${cloudCard.answer}"');
      } else if (field == 'nextReview') {
        print(
            '    nextReview: ローカル=$localNextReviewStr, クラウド=$cloudNextReviewStr');
      } else if (field == 'repetitions') {
        print(
            '    repetitions: ローカル=${localCard.repetitions}, クラウド=${cloudCard.repetitions}');
      } else if (field == 'eFactor') {
        print(
            '    eFactor: ローカル=${localCard.eFactor}, クラウド=${cloudCard.eFactor}');
      } else if (field == 'intervalDays') {
        print(
            '    intervalDays: ローカル=${localCard.intervalDays}, クラウド=${cloudCard.intervalDays}');
      }
    }
  }
  print('');
}

/// カードの更新前後での値の変化をログ出力するデバッグヘルパー関数
void logCardUpdateDetails(FlashCard card, String when, {String source = ''}) {
  final updatedAtMs = card.updatedAt ?? 0;
  final updatedAtStr = updatedAtMs > 0
      ? DateTime.fromMillisecondsSinceEpoch(updatedAtMs).toIso8601String()
      : 'null';

  final nextReviewMs = card.nextReview; // DateTime? 型
  final nextReviewStr =
      nextReviewMs != null ? nextReviewMs.toIso8601String() : 'null';

  print(
      '📝 [カード状態 - $when${source.isNotEmpty ? " ($source)" : ""}] ID: ${card.id}');
  print('  Question: ${card.question}');
  print('  updatedAt: $updatedAtMs ($updatedAtStr)');
  print('  nextReview: $nextReviewMs ($nextReviewStr)');
  print('  repetitions: ${card.repetitions}');
  print('  eFactor: ${card.eFactor}');
  print('  intervalDays: ${card.intervalDays}');
}
