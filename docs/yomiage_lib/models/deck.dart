// ignore_for_file: avoid_print

import 'package:hive/hive.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; // Timestampクラスのために追加

part 'deck.g.dart';

@HiveType(typeId: 0)
class Deck extends HiveObject {
  @HiveField(0)
  String deckName;

  @HiveField(3)
  late String id;

  @HiveField(1)
  bool questionEnglishFlag;

  @HiveField(2)
  bool answerEnglishFlag;

  @HiveField(4)
  String description;

  @HiveField(5, defaultValue: false)
  bool isArchived;

  // Firestoreの更新タイムスタンプを保持するプロパティ（Hiveには保存しない）
  Timestamp? firestoreUpdatedAt;

  // Phase 3: 論理削除（移行完了後に使用）
  @HiveField(6, defaultValue: false)
  bool isDeleted;

  @HiveField(7)
  DateTime? deletedAt;

  Deck({
    required this.id,
    required this.deckName,
    this.questionEnglishFlag = false,
    this.answerEnglishFlag = true,
    this.description = '',
    this.isArchived = false,
    this.firestoreUpdatedAt,
    this.isDeleted = false,
    this.deletedAt,
  });

  // キーをStringとして返すヘルパーメソッド
  String? get keyAsString => key?.toString();

  @override
  String toString() {
    return 'Deck(id: $id, key: $key, deckName: $deckName, questionEnglish: $questionEnglishFlag, answerEnglish: $answerEnglishFlag, description: $description, isArchived: $isArchived, isDeleted: $isDeleted, deletedAt: $deletedAt, updatedAt: $firestoreUpdatedAt)';
  }
}
