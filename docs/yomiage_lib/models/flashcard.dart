// ignore_for_file: prefer_interpolation_to_compose_strings, prefer_const_constructors, avoid_print

import 'package:hive/hive.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; // Timestampクラスのために追加
import 'dart:math' show min; // minをインポート

part 'flashcard.g.dart';

@HiveType(typeId: 1)
class FlashCard extends HiveObject {
  @HiveField(12)
  late String id;

  @HiveField(0)
  String question;

  @HiveField(1)
  String answer;

  @HiveField(2)
  String explanation;

  @HiveField(3)
  String deckName;

  // ↓ ここからSM-2で使うフィールドを追加
  @HiveField(4)
  DateTime? nextReview; // 次回出題日時 (nullならまだ未学習など)

  @HiveField(5)
  int repetitions; // 連続正解回数

  @HiveField(6)
  double eFactor; // E-Factor (熟練度係数)

  @HiveField(7)
  int intervalDays; // 次の出題までの間隔（日単位）

  @HiveField(8)
  bool questionEnglishFlag; // 質問が英語かどうかのフラグ

  @HiveField(9)
  bool answerEnglishFlag; // 回答が英語かどうかのフラグ

  // ★★★ 追加: Firestore ドキュメントID ★★★
  @HiveField(10)
  String? firestoreId; // Firestore上のユニークID

  // ★★★ 追加: 最終更新日時 ★★★
  @HiveField(11)
  int? updatedAt; // ローカルでの最終更新日時

  // Firestoreの更新タイムスタンプを保持するプロパティ（Hiveには保存しない）
  Timestamp? firestoreUpdatedAt;

  // ▼▼▼ 新しいフィールドを追加 ▼▼▼
  @HiveField(13)
  String chapter;
  // ▲▲▲ 追加ここまで ▲▲▲

  @HiveField(14)
  DateTime? firestoreCreatedAt; // Firestoreから読み込んだ作成日時

  // ★★★ 新フィールド: 見出し ★★★
  @HiveField(15) // 次の利用可能な番号
  String headline;

  // ★★★ 新フィールド: 補足 ★★★
  @HiveField(16) // 次の利用可能な番号
  String? supplement;

  // Phase 3: 論理削除（移行完了後に使用）
  @HiveField(17, defaultValue: false)
  bool isDeleted;

  @HiveField(18)
  DateTime? deletedAt;

  FlashCard({
    this.id = '',
    required this.question,
    required this.answer,
    this.explanation = '',
    required this.deckName,
    this.nextReview,
    this.repetitions = 0,
    this.eFactor = 2.5, // 初期値: 2.5
    this.intervalDays = 0,
    this.questionEnglishFlag = false, // デフォルト: 日本語
    this.answerEnglishFlag = true, // デフォルト: 英語
    this.firestoreId, // ★★★ コンストラクタに追加 ★★★
    this.firestoreUpdatedAt,
    this.updatedAt, // ★★★ コンストラクタに追加 ★★★
    this.chapter = '', // ▼▼▼ コンストラクタに追加（デフォルト値設定）▼▼▼
    this.firestoreCreatedAt,
    this.headline = '', // ★★★ headline の初期値を追加 ★★★
    this.supplement = '', // ★★★ supplement の初期値を追加 ★★★
    this.isDeleted = false,
    this.deletedAt,
  });

  // 今日学習すべきかどうかを判断するプロパティ
  bool isDueToday(DateTime today) {
    final todayEnd = DateTime(today.year, today.month, today.day, 23, 59, 59);
    return nextReview == null ||
        nextReview!.isBefore(todayEnd) ||
        nextReview!.isAtSameMomentAs(todayEnd);
  }

  // 理解度情報をリセットするメソッド
  void resetLearningStatus() {
    repetitions = 0;
    eFactor = 2.5;
    intervalDays = 0;
    nextReview = DateTime.now();
  }

  // 不正な日付（1970年付近のエポック日時）をチェックして修正するメソッド
  bool checkAndFixInvalidDate() {
    bool wasFixed = false;

    // 1970年付近の不正な日付をチェック
    if (nextReview != null) {
      final earliestValidDate = DateTime(2000, 1, 1);
      if (nextReview!.isBefore(earliestValidDate)) {
        // repetitionsと整合性のある日付に修正
        final now = DateTime.now();
        if (repetitions == 0) {
          // 未学習なら今日に設定
          nextReview = now;
        } else if (repetitions == 1) {
          // 1回学習なら2日後
          nextReview = now.add(Duration(days: 2));
        } else if (repetitions == 2) {
          // 2回学習なら6日後
          nextReview = now.add(Duration(days: 6));
        } else {
          // それ以上なら次の間隔に応じて設定
          nextReview =
              now.add(Duration(days: intervalDays > 0 ? intervalDays : 1));
        }
        wasFixed = true;
      }
    }

    return wasFixed;
  }

  // Firestoreに保存するためのMapに変換するメソッド
  // 注意: updatedAtフィールドはここでは追加しない（Firebase Serviceでトランザクション内で追加する）
  // 注意: firestoreId もここでは含めない（ドキュメントIDとして使用するため）
  Map<String, dynamic> toFirestore() {
    // 保存前にフラグを同期
    // syncMemorizedFlag();

    // 不正な日付を修正
    checkAndFixInvalidDate();

    // 保存時に更新日時を設定
    updateTimestamp();

    // nextReviewが現在の日時より前の場合は、現在の日時にリセット
    if (nextReview != null &&
        nextReview!.isBefore(DateTime.now().subtract(Duration(days: 1)))) {
      print('⚠️ nextReviewが過去の日付になっています。現在の日時にリセットします: $nextReview');
      nextReview = DateTime.now();
    }

    // nextReviewをTimestampに変換
    final nextReviewTimestamp =
        nextReview != null ? Timestamp.fromDate(nextReview!) : null;

    // ★★★ updatedAt も Timestamp に変換 ★★★
    final updatedAtTimestamp = updatedAt != null
        ? Timestamp.fromMillisecondsSinceEpoch(updatedAt!)
        : null;

    print('📊 [toFirestore] デバッグ情報:');
    print('  カード「${question.substring(0, min(20, question.length))}...」');
    print('  - nextReview (DateTime): $nextReview');
    print('  - nextReview (Timestamp): $nextReviewTimestamp');
    print('  - repetitions: $repetitions');
    print('  - eFactor: $eFactor');
    print('  - intervalDays: $intervalDays');
    print('  - headline: $headline');
    print('  - supplement: $supplement');
    print('  - updatedAt (ミリ秒): $updatedAt');
    print('  - updatedAt (Timestamp): $updatedAtTimestamp'); // ★★★ ログ追加

    return {
      'question': question,
      'answer': answer,
      'explanation': explanation,
      'deckName': deckName,
      'nextReview': nextReviewTimestamp, // 既にTimestamp
      'repetitions': repetitions,
      'eFactor': eFactor,
      'intervalDays': intervalDays,
      'questionEnglishFlag': questionEnglishFlag,
      'answerEnglishFlag': answerEnglishFlag,
      'updatedAt': updatedAtTimestamp, // ★★★ Timestampで保存
      'chapter': chapter,
      'headline': headline, // ★★★ headline を追加 ★★★
      'supplement': supplement, // ★★★ supplement を追加 ★★★
      // firestoreId は Firestore には保存しない
      // hiveKey も Firestore には保存しない
      // isChecked も Firestore には保存しない
    };
  }

  // 更新日時を現在時刻で更新するメソッド
  void updateTimestamp() {
    updatedAt = DateTime.now().millisecondsSinceEpoch;
    print('📅 [FlashCard] updatedAtを更新: $updatedAt');
  }

  // 共有用のシンプルなMapに変換するメソッド
  Map<String, dynamic> toSharedData() {
    // nullや無効な値を適切に処理
    String safeString(String? value) {
      if (value == null) return '';

      // 制御文字を除去
      String sanitized =
          value.replaceAll(RegExp(r'[\u0000-\u001F\u007F-\u009F]'), '');

      // 非常に長いテキストを切り詰める
      if (sanitized.length > 5000) {
        sanitized = sanitized.substring(0, 5000) + '...（省略）';
      }

      return sanitized;
    }

    return {
      'question': safeString(question),
      'answer': safeString(answer),
      'explanation': safeString(explanation),
      'questionEnglishFlag': questionEnglishFlag,
      'answerEnglishFlag': answerEnglishFlag,
      'chapter': safeString(chapter), // ▼▼▼ toSharedData に追加 ▼▼▼
      'supplement': safeString(supplement), // ★★★ supplement を追加 ★★★
    };
  }
}
