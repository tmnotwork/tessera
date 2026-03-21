// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'flashcard.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class FlashCardAdapter extends TypeAdapter<FlashCard> {
  @override
  final int typeId = 1;

  @override
  FlashCard read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return FlashCard(
      id: fields[12] as String,
      question: fields[0] as String,
      answer: fields[1] as String,
      explanation: fields[2] as String,
      deckName: fields[3] as String,
      nextReview: fields[4] as DateTime?,
      repetitions: fields[5] as int,
      eFactor: fields[6] as double,
      intervalDays: fields[7] as int,
      questionEnglishFlag: fields[8] as bool,
      answerEnglishFlag: fields[9] as bool,
      firestoreId: fields[10] as String?,
      updatedAt: fields[11] as int?,
      chapter: fields[13] as String,
      firestoreCreatedAt: fields[14] as DateTime?,
      headline: fields[15] as String,
      supplement: fields[16] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, FlashCard obj) {
    writer
      ..writeByte(17)
      ..writeByte(12)
      ..write(obj.id)
      ..writeByte(0)
      ..write(obj.question)
      ..writeByte(1)
      ..write(obj.answer)
      ..writeByte(2)
      ..write(obj.explanation)
      ..writeByte(3)
      ..write(obj.deckName)
      ..writeByte(4)
      ..write(obj.nextReview)
      ..writeByte(5)
      ..write(obj.repetitions)
      ..writeByte(6)
      ..write(obj.eFactor)
      ..writeByte(7)
      ..write(obj.intervalDays)
      ..writeByte(8)
      ..write(obj.questionEnglishFlag)
      ..writeByte(9)
      ..write(obj.answerEnglishFlag)
      ..writeByte(10)
      ..write(obj.firestoreId)
      ..writeByte(11)
      ..write(obj.updatedAt)
      ..writeByte(13)
      ..write(obj.chapter)
      ..writeByte(14)
      ..write(obj.firestoreCreatedAt)
      ..writeByte(15)
      ..write(obj.headline)
      ..writeByte(16)
      ..write(obj.supplement);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FlashCardAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
