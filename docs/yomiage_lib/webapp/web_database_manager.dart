import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/services/sync_service.dart';
import 'package:yomiage/services/sync/notification_service.dart';

class WebDatabaseManager {
  // デバッグログの制御

  // 初期化とデータベース読み込み
  static Future<void> initAndLoadDatabase({
    required bool isUserLoggedIn,
    required Function(SyncStatus) setSyncStatus,
    required Function(bool) setIsInitialLoading,
    required Function() loadDeckChapters,
    required bool mounted,
  }) async {
    try {
      await HiveService.initHive();
      await HiveService.cleanupDuplicateDecks();
      await loadDeckChapters();

      if (isUserLoggedIn) {
        final syncService = SyncService();
        try {
          // print('Performing initial sync...');
          await syncService.syncBidirectional();
          // print('Initial sync completed.');
          if (mounted) {
            await loadDeckChapters();
            setSyncStatus(SyncStatus.synced);
          }
        } catch (e) {
          // print('Initial sync failed: $e');
          if (mounted) {
            setSyncStatus(SyncStatus.error);
          }
        }
      }
    } catch (e) {
      // print('Initialization or first load failed: $e');
      if (mounted) {
        setSyncStatus(SyncStatus.error);
      }
    } finally {
      if (mounted) {
        setIsInitialLoading(false);
      }
    }
  }

  // デッキチャプターの読み込み
  static Future<void> loadDeckChapters({
    required Function(Map<dynamic, List<String>>) setDeckChapters,
    required bool mounted,
  }) async {
    final deckBox = HiveService.getDeckBox();
    final cardBox = HiveService.getCardBox();
    if (!deckBox.isOpen || !cardBox.isOpen) {
      return;
    }
    final decks = deckBox.values.toList();
    final Map<dynamic, List<String>> chaptersMap = {};

    for (final deck in decks) {
      final cardsInDeck = cardBox.values
          .where((card) => card.deckName == deck.deckName)
          .toList();

      if (cardsInDeck.isNotEmpty) {
        for (int i = 0; i < cardsInDeck.length; i++) {}
      }

      final chapters = cardsInDeck
          .map((card) {
            String chapter = card.chapter;
            chapter = chapter.trim();
            return chapter;
          })
          .where((chapter) => chapter.isNotEmpty)
          .toSet()
          .toList()
        ..sort();

      chaptersMap[deck.key] = chapters;
    }

    if (mounted) {
      setDeckChapters(chaptersMap);

      chaptersMap.forEach((deckKey, chapters) {
        for (final d in deckBox.values) {
          if (d.key == deckKey) {
            break;
          }
        }
      });
    }
  }

  // データベースの状態を更新する
  static Future<void> refreshDatabaseState({
    required Function() loadDeckChapters,
    required Function() setState,
    required bool mounted,
  }) async {
    try {
      await HiveService.refreshDatabase();
      await loadDeckChapters();

      if (mounted) {
        setState();
      }
    } catch (e) {
      // エラー処理
    }
  }
}
