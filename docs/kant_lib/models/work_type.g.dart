// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'work_type.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class WorkTypeAdapter extends TypeAdapter<WorkType> {
  @override
  final int typeId = 26;

  @override
  WorkType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return WorkType.work;
      case 1:
        return WorkType.free;
      default:
        return WorkType.work;
    }
  }

  @override
  void write(BinaryWriter writer, WorkType obj) {
    switch (obj) {
      case WorkType.work:
        writer.writeByte(0);
        break;
      case WorkType.free:
        writer.writeByte(1);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
