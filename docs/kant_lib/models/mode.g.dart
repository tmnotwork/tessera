// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'mode.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ModeAdapter extends TypeAdapter<Mode> {
  @override
  final int typeId = 4;

  @override
  Mode read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Mode(
      id: fields[0] as String,
      name: fields[1] as String,
      description: fields[2] as String?,
      userId: fields[3] as String,
      createdAt: fields[4] as DateTime,
      lastModified: fields[5] as DateTime,
      isActive: fields[6] as bool,
      cloudId: fields[7] as String?,
      lastSynced: fields[8] as DateTime?,
      isDeleted: fields[9] as bool,
      deviceId: fields[10] as String,
      version: fields[11] as int,
    );
  }

  @override
  void write(BinaryWriter writer, Mode obj) {
    writer
      ..writeByte(12)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.description)
      ..writeByte(3)
      ..write(obj.userId)
      ..writeByte(4)
      ..write(obj.createdAt)
      ..writeByte(5)
      ..write(obj.lastModified)
      ..writeByte(6)
      ..write(obj.isActive)
      ..writeByte(7)
      ..write(obj.cloudId)
      ..writeByte(8)
      ..write(obj.lastSynced)
      ..writeByte(9)
      ..write(obj.isDeleted)
      ..writeByte(10)
      ..write(obj.deviceId)
      ..writeByte(11)
      ..write(obj.version);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
