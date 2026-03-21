// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'deck.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class DeckAdapter extends TypeAdapter<Deck> {
  @override
  final int typeId = 0;

  @override
  Deck read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Deck(
      id: fields[3] as String,
      deckName: fields[0] as String,
      questionEnglishFlag: fields[1] as bool,
      answerEnglishFlag: fields[2] as bool,
      description: fields[4] as String,
      isArchived: fields[5] == null ? false : fields[5] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, Deck obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.deckName)
      ..writeByte(3)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.questionEnglishFlag)
      ..writeByte(2)
      ..write(obj.answerEnglishFlag)
      ..writeByte(4)
      ..write(obj.description)
      ..writeByte(5)
      ..write(obj.isArchived);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeckAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
