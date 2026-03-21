// ignore_for_file: library_prefixes, unused_local_variable, empty_catches, constant_identifier_names

import 'dart:convert';
import 'dart:math' as Math; // ★ インポートを追加
import 'dart:io';
import 'dart:typed_data'; // Uint8List のためにインポート
import 'package:collection/collection.dart'; // firstWhereOrNull のためにインポート
import 'package:flutter/foundation.dart'; // kIsWeb のためにインポート
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Hive関連
import 'package:path_provider/path_provider.dart'; // path_provider をインポート
// UUID生成用
import 'conditional_saver.dart' as file_saver; // 条件付きインポートを追加
// ignore: unused_import
import 'package:intl/intl.dart'; // DateFormat のためにインポート
// ★★★ share_plus をインポート ★★★
import 'package:share_plus/share_plus.dart';

import '../models/flashcard.dart';
// import '../models/sm2_data.dart'; // Sm2Data のためにインポート -> 削除
import 'hive_service.dart'; // HiveService をインポート
// ★★★ SyncServiceをインポート ★★★
// ★★★ FirebaseServiceをインポート (getUserIdのため) ★★★

class CsvService {
  // ★★★ 統一されたCSVヘッダー定義 ★★★
  static const List<String> STANDARD_CSV_HEADERS = [
    'FirebaseID',
    'HiveKey',
    'DeckName',
    'Chapter',
    'Headline',
    'Question',
    'Answer',
    'Explanation',
    'Supplement',
    'QuestionEnglishFlag',
    'AnswerEnglishFlag',
    'NextReview(UTC)',
    'Repetitions',
    'EFactor',
    'IntervalDays',
    '最終更新日時(UTC)',
  ];

  // ★★★ 統一されたファイル名生成 ★★★
  static String generateCsvFileName(String prefix) {
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    return '${prefix}_$timestamp.csv';
  }

  // ★★★ 統一されたCSVデータ生成 ★★★
  static List<List<String>> generateCsvData(List<FlashCard> cards) {
    final List<List<String>> rows = [STANDARD_CSV_HEADERS];

    for (final card in cards) {
      // updatedAtをISO形式の文字列に変換
      String updatedAtStr = '';
      if (card.updatedAt != null) {
        try {
          final updatedAtDate =
              DateTime.fromMillisecondsSinceEpoch(card.updatedAt!);
          updatedAtStr = updatedAtDate.toUtc().toIso8601String();
        } catch (e) {
          updatedAtStr = '';
        }
      }

      rows.add([
        card.id, // Firebase ID
        card.key?.toString() ?? '', // Hive Key
        card.deckName,
        card.chapter,
        card.headline,
        card.question,
        card.answer,
        card.explanation,
        card.supplement ?? '',
        card.questionEnglishFlag.toString(),
        card.answerEnglishFlag.toString(),
        card.nextReview?.toUtc().toIso8601String() ?? '',
        card.repetitions.toString(),
        card.eFactor.toString(),
        card.intervalDays.toString(),
        updatedAtStr,
      ]);
    }

    return rows;
  }

  // ★★★ 統一されたCSV文字列生成 ★★★
  static String generateCsvString(List<FlashCard> cards) {
    final rows = generateCsvData(cards);
    final csv = const ListToCsvConverter().convert(rows);
    return '\uFEFF$csv'; // UTF-8 BOM付き
  }

  // ★★★ 統一されたWeb用CSVダウンロード ★★★
  static Future<void> downloadCsvForWeb(
      List<FlashCard> cards, String fileNamePrefix) async {
    if (cards.isEmpty) {
      throw Exception('エクスポートするカードがありません。');
    }

    final csvWithBom = generateCsvString(cards);
    final bytes = utf8.encode(csvWithBom);
    final fileName = generateCsvFileName(fileNamePrefix);

    try {
      file_saver.saveFileWeb(Uint8List.fromList(bytes), fileName);
    } catch (e) {
      throw Exception('WebでのCSVファイルのエクスポートに失敗しました: $e');
    }
  }

  // ★★★ 統一されたネイティブ用CSV共有 ★★★
  static Future<void> shareCsvForNative(
      List<FlashCard> cards, String fileNamePrefix) async {
    if (cards.isEmpty) {
      throw Exception('エクスポートするカードがありません。');
    }

    final csvWithBom = generateCsvString(cards);
    final fileName = generateCsvFileName(fileNamePrefix);

    try {
      final directory = await getTemporaryDirectory();
      final filePath = '${directory.path}/$fileName';
      final file = File(filePath);
      await file.writeAsString(csvWithBom, encoding: utf8);

      final result = await Share.shareXFiles(
        [XFile(filePath)],
        subject: '単語カードデータ CSV',
        text: '読み上げ単語帳アプリからエクスポートされたCSVデータです。',
      );

      if (result.status != ShareResultStatus.success &&
          result.status != ShareResultStatus.dismissed) {
        throw Exception('CSVファイルの共有に失敗しました: ${result.status}');
      }
    } catch (e) {
      throw Exception('CSVファイルの共有準備中にエラーが発生しました: $e');
    }
  }

  // ★★★ 統一された全データエクスポート ★★★
  static Future<void> exportAllCards({bool isWeb = false}) async {
    final cardBox = HiveService.getCardBox();
    final cards = cardBox.values.where((c) => !c.isDeleted).toList();

    if (isWeb) {
      await downloadCsvForWeb(cards, 'all_decks');
    } else {
      await shareCsvForNative(cards, 'all_decks');
    }
  }

  // ★★★ 統一された特定デッキエクスポート ★★★
  static Future<void> exportDeckCards(String deckName,
      {bool isWeb = false}) async {
    final cardBox = HiveService.getCardBox();
    final cards =
        cardBox.values
            .where((card) => !card.isDeleted && card.deckName == deckName)
            .toList();

    if (cards.isEmpty) {
      throw Exception('デッキ「$deckName」にはエクスポートするカードがありません。');
    }

    final safeDeckName = deckName.replaceAll(RegExp(r'[\\/*?:\"<>|]'), '_');

    if (isWeb) {
      await downloadCsvForWeb(cards, safeDeckName);
    } else {
      await shareCsvForNative(cards, safeDeckName);
    }
  }

  // === ネイティブプラットフォーム用 CSVインポート ===
  // ★★★ static メソッドに変更 ★★★
  static Future<Map<String, dynamic>> pickAndImportCsv() async {
    int successCount = 0;
    int updatedCount = 0;
    List<Map<String, dynamic>> errors = [];
    String message = '';

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );

      if (result != null) {
        PlatformFile file = result.files.single;
        Uint8List bytes;

        // ネイティブ環境でのファイル読み込み
        if (file.path == null) {
          throw Exception('ネイティブ環境でファイルパスが取得できませんでした。');
        }
        final filePath = file.path!;
        bytes = await File(filePath).readAsBytes();

        // 文字コード推定とデコード (UTF-8のみ)
        String decodedCsv = '';
        try {
          decodedCsv = utf8.decode(bytes, allowMalformed: false);
        } catch (e) {
          throw Exception('ファイルをUTF-8としてデコードできませんでした。');
        }

        if (decodedCsv.startsWith('\uFEFF')) {
          decodedCsv = decodedCsv.substring(1);
        }

        List<List<dynamic>> csvData = const CsvToListConverter(
          shouldParseNumbers: false,
        ).convert(decodedCsv);

        if (csvData.isEmpty) {
          throw Exception('CSVファイルが空か、ヘッダー行がありません。');
        }
        final headerRow = csvData
            .removeAt(0)
            .map((h) => h?.toString().toLowerCase().trim() ?? '')
            .toList();

        // ★★★ static な _processCsvData を呼び出す ★★★
        final processResult = await _processCsvData(headerRow, csvData);

        successCount = processResult['successCount'] ?? 0;
        updatedCount = processResult['updatedCount'] ?? 0;
        errors = processResult['errors'] ?? [];

        await HiveService.refreshDatabase();
      } else {
        message = 'ファイルが選択されませんでした。';
      }
    } catch (e) {
      message = 'CSVインポート中にエラーが発生しました: $e';
      errors.add({'rowNumber': 'N/A', 'error': e.toString(), 'data': []});
    }

    return {
      'successCount': successCount,
      'updatedCount': updatedCount,
      'errors': errors,
      'message': message,
      // refreshNeeded はネイティブ版では常に true とする (UI側で判定)
      'refreshNeeded': successCount > 0 || updatedCount > 0,
    };
  }

  // === Webプラットフォーム用 CSVインポート ===
  // ★★★ static メソッドに変更し、UI関連コードを削除 ★★★
  static Future<Map<String, dynamic>> pickAndImportCsvWeb() async {
    int successCount = 0;
    int updatedCount = 0;
    List<Map<String, dynamic>> errors = [];
    String message = '';
    bool refreshNeeded = false; // Web版でも更新が必要かフラグ

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true, // Webではバイトデータを直接取得
      );
    } catch (e) {
      message = 'ファイル選択中にエラーが発生しました: $e';
      // UIフィードバックは呼び出し元で行うため、ここではメッセージ設定のみ
      return {
        // エラーでもMapを返す
        'successCount': 0,
        'updatedCount': 0,
        'errors': [
          {'rowNumber': 'N/A', 'error': 'ファイルピッカーエラー: $e', 'data': []}
        ],
        'message': message,
        'refreshNeeded': false,
      };
    }

    if (result != null && result.files.isNotEmpty) {
      PlatformFile file = result.files.single;
      if (file.bytes != null) {
        Uint8List bytes = file.bytes!;
        try {
          String decodedCsv = '';
          try {
            decodedCsv = utf8.decode(bytes, allowMalformed: false);
          } catch (e) {
            throw Exception('ファイルをUTF-8としてデコードできませんでした。');
          }

          if (decodedCsv.startsWith('\uFEFF')) {
            decodedCsv = decodedCsv.substring(1);
          }

          List<List<dynamic>> csvData = const CsvToListConverter(
            shouldParseNumbers: false,
          ).convert(decodedCsv);

          if (csvData.isEmpty) {
            throw Exception('CSVファイルが空か、ヘッダー行がありません。');
          }
          final headerRow = csvData
              .removeAt(0)
              .map((h) => h?.toString().toLowerCase().trim() ?? '')
              .toList();

          // ★★★ static な _processCsvData を呼び出す ★★★
          final processResult = await _processCsvData(headerRow, csvData);
          // ★★★ 一時的な CsvService インスタンス化は不要になったため削除 ★★★
          // final tempHiveService = HiveService();
          // final tempContainer = ProviderContainer();
          // final tempCsvService = CsvService(tempContainer.read, tempHiveService);
          // final processResult = await tempCsvService._processCsvData(headerRow, csvData);
          // tempContainer.dispose(); // ダミーコンテナを破棄

          successCount = processResult['successCount'] ?? 0;
          updatedCount = processResult['updatedCount'] ?? 0;
          errors = processResult['errors'] ?? [];

          if (successCount > 0 || updatedCount > 0) {
            await HiveService.refreshDatabase(); // 変更があった場合のみリフレッシュ
            refreshNeeded = true; // 更新があったことを示す
            message =
                'CSVファイルのインポートが完了しました。 ($successCount 件新規追加, $updatedCount 件更新)';
          } else if (errors.isEmpty) {
            message = 'CSVファイルからインポートする新しいデータまたは更新するデータがありませんでした。';
          }
        } catch (e) {
          message = 'CSV処理中にエラーが発生しました: $e';
          errors.add({'rowNumber': 'N/A', 'error': e.toString(), 'data': []});
        }
      } else {
        message = 'ファイルデータが読み込めませんでした。';
        errors.add({'rowNumber': 'N/A', 'error': message, 'data': []});
      }
    } else {
      message = 'ファイルが選択されませんでした。';
      // ユーザーがキャンセルした場合などはエラー扱いしないことが多いが、ここではメッセージを設定
    }

    // エラーメッセージの生成 (エラーがある場合)
    if (errors.isNotEmpty) {
      message = 'CSVインポート中にエラーが発生しました。詳細はエラーリストを確認してください。';
    }

    // 結果をMapで返す
    return {
      'successCount': successCount,
      'updatedCount': updatedCount,
      'errors': errors,
      'message': message,
      'refreshNeeded': refreshNeeded, // UI側で画面更新が必要か判定するために追加
    };
  }

  // CSVデータを行ごとに処理し、Hive に保存または更新する
  // ★★★ static メソッドに変更 ★★★
  static Future<Map<String, dynamic>> _processCsvData(
      List<String> headerRow, List<List<dynamic>> csvData) async {
    int successCount = 0;
    int updatedCount = 0;
    List<Map<String, dynamic>> errors = [];
    List<Map<String, dynamic>> temporaryCardDataList = []; // 一時リスト

    // --- ヘッダーから列インデックスを取得 ---
    final questionIndex = headerRow.indexOf('question');
    final answerIndex = headerRow.indexOf('answer');
    final deckNameIndex = headerRow.indexOf('deckname');
    final explanationIndex = headerRow.indexOf('explanation');
    final chapterIndex = headerRow.indexOf('chapter');
    final questionEnglishFlagIndex = headerRow.indexOf('questionenglishflag');
    final answerEnglishFlagIndex = headerRow.indexOf('answerenglishflag');
    final nextReviewIndex =
        headerRow.indexWhere((h) => h.toLowerCase() == 'nextreview(utc)');
    final repetitionsIndex = headerRow.indexOf('repetitions');
    final eFactorIndex = headerRow.indexOf('efactor');
    final intervalDaysIndex = headerRow.indexOf('intervaldays');
    final headlineIndex = headerRow.indexOf('headline');
    final supplementIndex =
        headerRow.indexOf('supplement'); // ★ supplementインデックス

    // --- 必須列の存在チェック ---
    if (questionIndex == -1 || answerIndex == -1 || deckNameIndex == -1) {
      errors.add({
        'rowNumber': 'N/A',
        'error': '必須ヘッダー (question, answer, deckName) が見つかりません。',
        'data': headerRow
      });
      return {
        'successCount': 0,
        'updatedCount': 0,
        'errors': errors,
        'message': '必須ヘッダーが見つかりません。',
      };
    }

    for (int i = 0; i < csvData.length; i++) {
      final row = csvData[i];
      try {
        if (row.length <=
            Math.max(questionIndex, Math.max(answerIndex, deckNameIndex))) {
          errors
              .add({'rowNumber': i + 2, 'error': '行の列数が不足しています。', 'data': row});
          continue;
        }

        final String question = row[questionIndex]?.toString().trim() ?? '';
        final String answer = row[answerIndex]?.toString().trim() ?? '';
        final String deckName = row[deckNameIndex]?.toString().trim() ?? '';

        if (question.isEmpty || answer.isEmpty || deckName.isEmpty) {
          errors.add({
            'rowNumber': i + 2,
            'error': 'question, answer, deckName のいずれかが空です。',
            'data': row
          });
          continue;
        }

        final String explanation = explanationIndex != -1 &&
                row.length > explanationIndex &&
                row[explanationIndex] != null
            ? row[explanationIndex].toString().trim()
            : '';
        final String chapter = chapterIndex != -1 &&
                row.length > chapterIndex &&
                row[chapterIndex] != null
            ? row[chapterIndex].toString().trim()
            : '';
        final String headline = headlineIndex != -1 &&
                row.length > headlineIndex &&
                row[headlineIndex] != null
            ? row[headlineIndex].toString().trim()
            : '';
        final String supplement = supplementIndex != -1 &&
                row.length > supplementIndex &&
                row[supplementIndex] != null
            ? row[supplementIndex].toString().trim()
            : ''; // ★ supplement の値を取得

        bool englishQuestion = false;
        if (questionEnglishFlagIndex != -1 &&
            row.length > questionEnglishFlagIndex &&
            row[questionEnglishFlagIndex] != null) {
          englishQuestion =
              row[questionEnglishFlagIndex].toString().toLowerCase() ==
                      'true' ||
                  row[questionEnglishFlagIndex].toString() == '1';
        }

        bool englishAnswer = true;
        if (answerEnglishFlagIndex != -1 &&
            row.length > answerEnglishFlagIndex &&
            row[answerEnglishFlagIndex] != null) {
          englishAnswer =
              row[answerEnglishFlagIndex].toString().toLowerCase() == 'true' ||
                  row[answerEnglishFlagIndex].toString() == '1';
        }

        final Map<String, dynamic> temporaryCardData = {
          'question': question,
          'answer': answer,
          'deckName': deckName,
          'explanation': explanation,
          'chapter': chapter,
          'headline': headline,
          'questionEnglishFlag': englishQuestion,
          'answerEnglishFlag': englishAnswer,
          'supplement': supplement, // ★ temporaryCardData に supplement を追加
        };

        // SM2関連データのパースと追加
        if (nextReviewIndex != -1 &&
            row.length > nextReviewIndex &&
            row[nextReviewIndex] != null &&
            row[nextReviewIndex].toString().isNotEmpty) {
          try {
            final rawNextReview =
                row[nextReviewIndex].toString(); // パース対象の文字列を保持
            temporaryCardData['nextReview'] =
                DateTime.parse(rawNextReview) // rawNextReview を使用
                    .millisecondsSinceEpoch;
          } catch (e) {
            // パース失敗時はエラーとして記録
            errors.add({
              'rowNumber': i + 2,
              'error':
                  'nextReview の日付形式が無効です: ${row[nextReviewIndex]} (エラー: $e)',
              'data': row
            });
            // temporaryCardData['nextReview'] には何も設定しない（または null を明示的に設定）
          }
        }
        if (repetitionsIndex != -1 &&
            row.length > repetitionsIndex &&
            row[repetitionsIndex] != null) {
          temporaryCardData['repetitions'] =
              int.tryParse(row[repetitionsIndex].toString()) ?? 0;
        }
        if (eFactorIndex != -1 &&
            row.length > eFactorIndex &&
            row[eFactorIndex] != null) {
          temporaryCardData['eFactor'] =
              double.tryParse(row[eFactorIndex].toString()) ?? 2.5;
        }
        if (intervalDaysIndex != -1 &&
            row.length > intervalDaysIndex &&
            row[intervalDaysIndex] != null) {
          temporaryCardData['intervalDays'] =
              int.tryParse(row[intervalDaysIndex].toString()) ?? 0;
        }

        temporaryCardDataList.add(temporaryCardData);
      } catch (e) {
        errors.add({
          'rowNumber': i + 2,
          'error': '行処理中にエラー: ${e.toString()}',
          'data': row
        });
      }
    }

    final cardBox = HiveService.getCardBox();
    for (final cardData in temporaryCardDataList) {
      try {
        FlashCard? existingCard = cardBox.values.firstWhereOrNull(
          (c) =>
              c.question == cardData['question'] &&
              c.deckName == cardData['deckName'],
        );

        if (existingCard != null) {
          bool needsSave = false;
          if (existingCard.answer != cardData['answer']) {
            existingCard.answer = cardData['answer'];
            needsSave = true;
          }
          if (cardData['explanation'] != null &&
              existingCard.explanation != cardData['explanation']) {
            existingCard.explanation = cardData['explanation'];
            needsSave = true;
          }
          if (cardData['chapter'] != null &&
              existingCard.chapter != cardData['chapter']) {
            existingCard.chapter = cardData['chapter'];
            needsSave = true;
          }
          if (cardData['headline'] != null &&
              existingCard.headline != cardData['headline']) {
            existingCard.headline = cardData['headline'];
            needsSave = true;
          }
          if (cardData['questionEnglishFlag'] != null &&
              existingCard.questionEnglishFlag !=
                  cardData['questionEnglishFlag']) {
            existingCard.questionEnglishFlag = cardData['questionEnglishFlag'];
            needsSave = true;
          }
          if (cardData['answerEnglishFlag'] != null &&
              existingCard.answerEnglishFlag != cardData['answerEnglishFlag']) {
            existingCard.answerEnglishFlag = cardData['answerEnglishFlag'];
            needsSave = true;
          }
          if (cardData['supplement'] != null &&
              existingCard.supplement != cardData['supplement']) {
            existingCard.supplement =
                cardData['supplement'] as String; // ★ supplementの更新
            needsSave = true;
          }

          // SM2データの更新
          if (cardData['nextReview'] != null) {
            final newNextReview =
                DateTime.fromMillisecondsSinceEpoch(cardData['nextReview']);
            if (existingCard.nextReview != newNextReview) {
              existingCard.nextReview = newNextReview;
              needsSave = true;
            }
          }
          if (cardData['repetitions'] != null &&
              existingCard.repetitions != cardData['repetitions']) {
            existingCard.repetitions = cardData['repetitions'];
            needsSave = true;
          }
          if (cardData['eFactor'] != null &&
              existingCard.eFactor != cardData['eFactor']) {
            existingCard.eFactor = cardData['eFactor'];
            needsSave = true;
          }
          if (cardData['intervalDays'] != null &&
              existingCard.intervalDays != cardData['intervalDays']) {
            existingCard.intervalDays = cardData['intervalDays'];
            needsSave = true;
          }

          if (needsSave) {
            existingCard.updateTimestamp();
            await existingCard.save();
            updatedCount++;
          }
        } else {
          // キー統一: 新規作成時にローカルIDを付与し、キーはそのIDで保存
          final newId = HiveService().generateUniqueId();
          final newCard = FlashCard(
            id: newId,
            question: cardData['question'],
            answer: cardData['answer'],
            deckName: cardData['deckName'],
            explanation: cardData['explanation'] ?? '',
            chapter: cardData['chapter'] ?? '',
            headline: cardData['headline'] ?? '',
            questionEnglishFlag: cardData['questionEnglishFlag'] ?? false,
            answerEnglishFlag: cardData['answerEnglishFlag'] ?? true,
            supplement: cardData['supplement'] as String? ??
                '', // ★ 新規カードにsupplementを設定
            nextReview: cardData['nextReview'] != null
                ? DateTime.fromMillisecondsSinceEpoch(cardData['nextReview'])
                : null,
            repetitions: cardData['repetitions'] ?? 0,
            eFactor: cardData['eFactor'] ?? 2.5,
            intervalDays: cardData['intervalDays'] ?? 0,
          );
          newCard.updateTimestamp();
          await cardBox.put(newId, newCard);
          successCount++;
        }
      } catch (e) {
        errors.add({
          'rowNumber': 'N/A', // 個々の行番号特定は難しいので全体エラーとして扱う
          'error': 'カード保存/更新中にエラー: ${e.toString()}',
          'data': cardData
        });
      }
    }

    return {
      'successCount': successCount,
      'updatedCount': updatedCount,
      'errors': errors,
    };
  }

  // === CSV エクスポート ===
  // ★★★ 統一メソッドを使用するように変更 ★★★
  static Future<void> exportCsv(String deckName, {bool isWeb = false}) async {
    await exportDeckCards(deckName, isWeb: isWeb);
  }

  // === CSV エクスポート (全データ) ===
  // ★★★ 統一メソッドを使用するように変更 ★★★
  static Future<void> exportAllCsv({bool isWeb = false}) async {
    await exportAllCards(isWeb: isWeb);
  }

  // FlashCardリストをCSV文字列に変換 (エラー処理なし、呼び出し元で対応)
  // ★★★ static メソッドに変更 ★★★
  static String flashCardsToCsvData(List<FlashCard> cards) {
    final List<List<dynamic>> csvData = [];

    // ヘッダー行
    csvData.add([
      'question',
      'answer',
      'explanation',
      'deckName',
      'chapter',
      'headline',
      'questionEnglishFlag',
      'answerEnglishFlag',
      'nextReview', // ISO8601形式の文字列を想定
      'repetitions',
      'eFactor',
      'intervalDays',
      'supplement', // ★ ヘッダーにsupplement
      'updatedAt', // Unixエポックミリ秒の文字列を想定
    ]);

    // データ行
    for (final card in cards) {
      final row = [
        card.question,
        card.answer,
        card.explanation,
        card.deckName,
        card.chapter,
        card.headline,
        card.questionEnglishFlag.toString(), // bool値を文字列に
        card.answerEnglishFlag.toString(), // bool値を文字列に
        card.nextReview?.toUtc().toIso8601String() ??
            '', // null許容, UTC, ISO8601
        card.repetitions.toString(),
        card.eFactor.toString(),
        card.intervalDays.toString(),
        card.supplement ?? '', // ★ supplementのデータ
        card.updatedAt?.toString() ?? '', // null許容
      ];
      csvData.add(row);
    }

    return const ListToCsvConverter().convert(csvData);
  }
}

// Riverpod プロバイダー (修正)
// CsvService自体は状態を持たないので、単純なインスタンスを提供するか、
// staticメソッドのみを使用するならProviderは不要かもしれない。
// 一旦、空のインスタンスを提供する形にしておく。
final csvServiceProvider = Provider<CsvService>((ref) {
  // ★★★ CsvService のコンストラクタがなくなったので、引数なしでインスタンス化 ★★★
  return CsvService();
});

// ★★★ import 'dart:html' as html; はファイルの先頭に移動済み ★★★
// import 'dart:html' as html;
