import '../../models/deck.dart';
import '../../models/flashcard.dart';
import 'debug_utils.dart';

/// 競合解決を担当するサービス
class ConflictResolver {
  /// カードの競合解決（タイムスタンプ優先）
  static bool resolveCardConflict(FlashCard localCard, FlashCard cloudCard) {
    bool hasChanges = false;
    bool useCloudData = false;
    bool useLocalData = false;

    // デバッグログ追加
    SyncDebugUtils.logCardComparison(
        localCard, cloudCard, "resolveCardConflict");

    // --- 1. firestoreUpdatedAt (サーバータイムスタンプ) 比較 --- (最優先)
    final localServerTs = localCard.firestoreUpdatedAt;
    final cloudServerTs = cloudCard.firestoreUpdatedAt;

    if (localServerTs != null && cloudServerTs != null) {
      if (cloudServerTs.compareTo(localServerTs) > 0) {
        useCloudData = true;
      } else if (localServerTs.compareTo(cloudServerTs) > 0) {
        useLocalData = true; // ローカル優先
      }
      // 同じなら次の比較へ
    } else if (cloudServerTs != null && localServerTs == null) {
      // クラウドにのみサーバータイムスタンプがある場合 (ローカルが古い or 未同期)
      useCloudData = true;
    } else if (localServerTs != null && cloudServerTs == null) {
      // ローカルにのみサーバータイムスタンプがある場合 (クラウドが古い or 未設定)
      useLocalData = true; // ローカル優先
    }
    // 両方 null なら次の比較へ

    // --- 2. updatedAt (ローカル/デバイスタイムスタンプ) 比較 --- (サーバータイムスタンプで決着しない場合)
    if (!useCloudData && !useLocalData) {
      final localUpdatedAt = localCard.updatedAt;
      final cloudUpdatedAt = cloudCard.updatedAt; // これはデバイス時刻の可能性もあるので注意

      if (localUpdatedAt != null && cloudUpdatedAt != null) {
        if (cloudUpdatedAt > localUpdatedAt) {
          useCloudData = true;
        } else if (localUpdatedAt > cloudUpdatedAt) {
          useLocalData = true; // ローカル優先
        }
        // 同じなら次の比較へ
      } else if (cloudUpdatedAt != null && localUpdatedAt == null) {
        // クラウドにのみタイムスタンプがある場合（ローカルが古い）
        useCloudData = true;
      } else if (localUpdatedAt != null && cloudUpdatedAt == null) {
        // ローカルにのみタイムスタンプがある場合（クラウドが古い or 未設定）
        useLocalData = true; // ローカル優先
      }
      // 両方 null なら次の比較へ
    }

    // --- 3. nextReview 比較 --- (タイムスタンプで決着がつかない場合)
    if (!useCloudData && !useLocalData) {
      final localNextReview = localCard.nextReview;
      final cloudNextReview = cloudCard.nextReview;

      // デバッグログ追加
      if (localNextReview != null || cloudNextReview != null) {
        // ms を表示
        // ms を表示
      }

      // 1. 両方に日付がある場合
      if (localNextReview != null && cloudNextReview != null) {
        if (cloudNextReview.isAfter(localNextReview)) {
          useCloudData = true; // クラウドデータを採用
        } else if (localNextReview.isAfter(cloudNextReview)) {
          useLocalData = true; // ローカル優先
        } else {
          // nextReviewも同じ場合は何もしない (useCloud/useLocalDataはfalseのまま)
        }
        // 2. クラウドにのみ日付がある場合 (ローカルはnull=未学習)
      } else if (cloudNextReview != null && localNextReview == null) {
        useCloudData = true;
        // 3. ローカルにのみ日付がある場合 (クラウドはnull)
      } else if (localNextReview != null && cloudNextReview == null) {
        useLocalData = true; // ローカル優先 (未学習状態よりは学習済みを優先)
      }
      // 4. 両方nullの場合は何もしない
    }

    // --- データの反映 ---
    if (useCloudData) {
      // クラウドデータでローカルを上書き
      bool changedByCloud = updateLocalCardFromCloud(localCard, cloudCard);
      if (changedByCloud) {
        hasChanges = true;
        // updatedAt は _updateLocalCardFromCloud 内で更新される
      } else {}
    } else if (useLocalData) {
      // ローカルデータが優先される場合、基本的には何もしない
    } else {
      // useCloudData も useLocalData も false の場合 (完全に一致 or 比較不能)
    }

    return hasChanges;
  }

  /// デッキの競合解決（タイムスタンプ優先）
  static bool resolveDeckConflict(Deck localDeck, Deck cloudDeck) {
    bool hasChanges = false;
    bool useCloudData = false;
    bool useLocalData = false;

    // --- 1. firestoreUpdatedAt (サーバータイムスタンプ) 比較 --- (最優先)
    final localServerTs = localDeck.firestoreUpdatedAt;
    final cloudServerTs = cloudDeck.firestoreUpdatedAt;

    if (localServerTs != null && cloudServerTs != null) {
      if (cloudServerTs.compareTo(localServerTs) > 0) {
        useCloudData = true;
      } else if (localServerTs.compareTo(cloudServerTs) > 0) {
        useLocalData = true; // ローカル優先
      }
      // 同じなら次の比較へ
    } else if (cloudServerTs != null && localServerTs == null) {
      // クラウドにのみサーバータイムスタンプがある場合
      useCloudData = true;
    } else if (localServerTs != null && cloudServerTs == null) {
      // ローカルにのみサーバータイムスタンプがある場合
      useLocalData = true; // ローカル優先
    }
    // 両方 null なら次の比較へ

    // --- 2. firestoreUpdatedAt のみで比較 --- (サーバータイムスタンプで決着しない場合はローカル優先)
    if (!useCloudData && !useLocalData) {
      // デッキの場合は firestoreUpdatedAt のみで比較し、決着がつかない場合はローカル優先
      useLocalData = true; // ローカル優先
    }

    // --- データの反映 ---
    if (useCloudData) {
      // クラウドデータでローカルを上書き
      bool changedByCloud = updateLocalDeckFromCloud(localDeck, cloudDeck);
      if (changedByCloud) {
        hasChanges = true;
      } else {}
    } else if (useLocalData) {
      // ローカルデータが優先される場合、基本的には何もしない
    } else {
      // useCloudData も useLocalData も false の場合 (完全に一致 or 比較不能)
    }

    return hasChanges;
  }

  /// デッキの内容が異なるか比較するヘルパー関数
  static bool isDeckContentDifferent(Deck deck1, Deck deck2) {
    return deck1.deckName != deck2.deckName ||
        deck1.description != deck2.description ||
        deck1.questionEnglishFlag != deck2.questionEnglishFlag ||
        deck1.answerEnglishFlag != deck2.answerEnglishFlag ||
        deck1.isArchived != deck2.isArchived;
  }

  /// カードの内容が異なるか比較するヘルパー関数
  static bool isCardContentDifferent(FlashCard card1, FlashCard card2) {
    // IDがnullの場合の比較を安全に行う
    final idMatch =
        // ignore: unnecessary_null_comparison
        (card1.id == card2.id) || (card1.id == null && card2.id == null);

    return card1.question != card2.question ||
        card1.answer != card2.answer ||
        card1.explanation != card2.explanation ||
        card1.deckName != card2.deckName ||
        card1.nextReview?.millisecondsSinceEpoch !=
            card2.nextReview?.millisecondsSinceEpoch ||
        card1.repetitions != card2.repetitions ||
        card1.eFactor != card2.eFactor ||
        card1.intervalDays != card2.intervalDays ||
        card1.questionEnglishFlag != card2.questionEnglishFlag ||
        card1.answerEnglishFlag != card2.answerEnglishFlag ||
        card1.chapter != card2.chapter ||
        // updatedAt は意図的に比較しない (タイムスタンプ比較は呼び出し元で行う)
        // firestoreUpdatedAt も同様
        !idMatch; // IDも比較
  }

  /// ヘルパー: クラウドデータでローカルカードを更新する処理
  static bool updateLocalCardFromCloud(
      FlashCard localCard, FlashCard cloudCard) {
    bool changed = false;

    // デバッグログ追加
    SyncDebugUtils.logCardUpdateDetails(localCard, "更新前",
        source: "updateLocalCardFromCloud");

    // 基本情報の更新
    if (localCard.question != cloudCard.question) {
      localCard.question = cloudCard.question;
      changed = true;
    }
    if (localCard.answer != cloudCard.answer) {
      localCard.answer = cloudCard.answer;
      changed = true;
    }
    if (localCard.explanation != cloudCard.explanation) {
      localCard.explanation = cloudCard.explanation;
      changed = true;
    }
    if (localCard.questionEnglishFlag != cloudCard.questionEnglishFlag) {
      localCard.questionEnglishFlag = cloudCard.questionEnglishFlag;
      changed = true;
    }
    if (localCard.answerEnglishFlag != cloudCard.answerEnglishFlag) {
      localCard.answerEnglishFlag = cloudCard.answerEnglishFlag;
      changed = true;
    }
    if (localCard.deckName != cloudCard.deckName) {
      localCard.deckName = cloudCard.deckName;
      changed = true;
    }
    if (localCard.headline != cloudCard.headline) {
      localCard.headline = cloudCard.headline;
      changed = true;
    }
    if ((localCard.supplement ?? '') != (cloudCard.supplement ?? '')) {
      localCard.supplement = cloudCard.supplement;
      changed = true;
    }
    if (localCard.firestoreId != cloudCard.firestoreId) {
      localCard.firestoreId = cloudCard.firestoreId;
      changed = true;
    }
    if (localCard.chapter != cloudCard.chapter) {
      localCard.chapter = cloudCard.chapter;
      changed = true;
    }

    // 学習データの更新
    if (localCard.nextReview?.millisecondsSinceEpoch !=
        cloudCard.nextReview?.millisecondsSinceEpoch) {
      localCard.nextReview = cloudCard.nextReview;
      changed = true;
    }
    if (localCard.repetitions != cloudCard.repetitions) {
      localCard.repetitions = cloudCard.repetitions;
      changed = true;
    }
    if (localCard.eFactor != cloudCard.eFactor) {
      localCard.eFactor = cloudCard.eFactor;
      changed = true;
    }
    if (localCard.intervalDays != cloudCard.intervalDays) {
      localCard.intervalDays = cloudCard.intervalDays;
      changed = true;
    }

    // Phase 3: 論理削除フラグ
    if (localCard.isDeleted != cloudCard.isDeleted) {
      localCard.isDeleted = cloudCard.isDeleted;
      changed = true;
    }
    if (localCard.deletedAt != cloudCard.deletedAt) {
      localCard.deletedAt = cloudCard.deletedAt;
      changed = true;
    }

    // firestoreUpdatedAt (サーバータイムスタンプ) をコピー
    // Timestamp オブジェクトは不変なので、直接代入でOK
    if (localCard.firestoreUpdatedAt != cloudCard.firestoreUpdatedAt) {
      localCard.firestoreUpdatedAt = cloudCard.firestoreUpdatedAt;
      changed = true;
    }

    // firestoreCreatedAt (サーバータイムスタンプ) をコピー
    if (localCard.firestoreCreatedAt != cloudCard.firestoreCreatedAt) {
      localCard.firestoreCreatedAt = cloudCard.firestoreCreatedAt;
      changed = true;
    }

    // 変更があった場合はローカルに保存
    if (changed) {
      localCard.updateTimestamp(); // 更新日時を明示的に更新
      localCard.save();
    }

    // デバッグログ追加
    SyncDebugUtils.logCardUpdateDetails(localCard, "更新後",
        source: "updateLocalCardFromCloud");

    return changed;
  }

  /// ヘルパー: クラウドデータでローカルデッキを更新する処理
  static bool updateLocalDeckFromCloud(Deck localDeck, Deck cloudDeck) {
    bool changed = false;

    // 基本情報の更新
    if (localDeck.deckName != cloudDeck.deckName) {
      localDeck.deckName = cloudDeck.deckName;
      changed = true;
    }
    if (localDeck.description != cloudDeck.description) {
      localDeck.description = cloudDeck.description;
      changed = true;
    }
    if (localDeck.questionEnglishFlag != cloudDeck.questionEnglishFlag) {
      localDeck.questionEnglishFlag = cloudDeck.questionEnglishFlag;
      changed = true;
    }
    if (localDeck.answerEnglishFlag != cloudDeck.answerEnglishFlag) {
      localDeck.answerEnglishFlag = cloudDeck.answerEnglishFlag;
      changed = true;
    }
    if (localDeck.isArchived != cloudDeck.isArchived) {
      localDeck.isArchived = cloudDeck.isArchived;
      changed = true;
    }
    // Phase 3: 論理削除フラグ
    if (localDeck.isDeleted != cloudDeck.isDeleted) {
      localDeck.isDeleted = cloudDeck.isDeleted;
      changed = true;
    }
    if (localDeck.deletedAt != cloudDeck.deletedAt) {
      localDeck.deletedAt = cloudDeck.deletedAt;
      changed = true;
    }
    // firestoreUpdatedAt (サーバータイムスタンプ) をコピー
    if (localDeck.firestoreUpdatedAt != cloudDeck.firestoreUpdatedAt) {
      localDeck.firestoreUpdatedAt = cloudDeck.firestoreUpdatedAt;
      changed = true;
    }

    // 変更があった場合はローカルに保存
    if (changed) {
      localDeck.save();
    }

    return changed;
  }
}
