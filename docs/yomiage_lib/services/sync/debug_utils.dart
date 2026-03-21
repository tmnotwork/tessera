// ignore_for_file: avoid_print

import '../../models/flashcard.dart';

/// 同期処理のデバッグ・ログ出力を担当するユーティリティクラス
///
/// 責任: デバッグ・ログ出力
/// 独立性: 外部依存なし、内部依存なし
/// 影響範囲: ログ出力のみ、既存機能に影響なし
class SyncDebugUtils {
  /// デバッグログの制御
  static const bool _enableDebugLogs = false;

  /// カードの比較結果を詳細にログ出力する
  ///
  /// [localCard] ローカルカード
  /// [cloudCard] クラウドカード
  /// [source] 呼び出し元の識別子
  static void logCardComparison(
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
    if (localCard.explanation != cloudCard.explanation) {
      diffFields.add('explanation');
    }
    if (localNextReview != cloudNextReview) diffFields.add('nextReview');
    if (localCard.repetitions != cloudCard.repetitions) {
      diffFields.add('repetitions');
    }
    if ((localCard.eFactor - cloudCard.eFactor).abs() > 0.001) {
      diffFields.add('eFactor');
    }
    if (localCard.intervalDays != cloudCard.intervalDays) {
      diffFields.add('intervalDays');
    }

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

  /// カードの更新前後での値の変化をログ出力する
  ///
  /// [card] 対象のカード
  /// [when] 更新前/更新後の識別子
  /// [source] 呼び出し元の識別子（オプション）
  static void logCardUpdateDetails(FlashCard card, String when,
      {String source = ''}) {
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

  /// 二つの数値のうち小さい方を返す
  ///
  /// [a] 比較対象の数値1
  /// [b] 比較対象の数値2
  /// 戻り値: 小さい方の数値
  static int min(int a, int b) => a < b ? a : b;

  /// デバッグログの有効/無効を設定する
  ///
  /// [enabled] デバッグログを有効にするかどうか
  static void setDebugLogsEnabled(bool enabled) {
    // 注意: 現在は定数で制御しているため、このメソッドは将来の拡張用
    // 実際の実装では、設定ファイルや環境変数から読み込むことを想定
    print('デバッグログ設定: ${enabled ? "有効" : "無効"}');
  }

  /// 現在のデバッグログ設定状態を取得する
  ///
  /// 戻り値: デバッグログが有効かどうか
  static bool get isDebugLogsEnabled => _enableDebugLogs;
}
