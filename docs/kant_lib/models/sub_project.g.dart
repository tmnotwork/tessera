// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sub_project.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SubProjectAdapter extends TypeAdapter<SubProject> {
  @override
  final int typeId = 3;

  @override
  SubProject read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SubProject(
      id: fields[0] as String,
      name: fields[1] as String,
      description: fields[2] as String?,
      createdAt: fields[3] as DateTime,
      lastModified: fields[4] as DateTime,
      isArchived: fields[5] as bool,
      userId: fields[6] as String,
      projectId: fields[7] as String,
      category: fields[8] as String?,
      project: fields[9] as String?,
      cloudId: fields[10] as String?,
      lastSynced: fields[11] as DateTime?,
      isDeleted: fields[12] as bool,
      deviceId: fields[13] as String,
      version: fields[14] as int,
    );
  }

  @override
  void write(BinaryWriter writer, SubProject obj) {
    writer
      ..writeByte(15)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.description)
      ..writeByte(3)
      ..write(obj.createdAt)
      ..writeByte(4)
      ..write(obj.lastModified)
      ..writeByte(5)
      ..write(obj.isArchived)
      ..writeByte(6)
      ..write(obj.userId)
      ..writeByte(7)
      ..write(obj.projectId)
      ..writeByte(8)
      ..write(obj.category)
      ..writeByte(9)
      ..write(obj.project)
      ..writeByte(10)
      ..write(obj.cloudId)
      ..writeByte(11)
      ..write(obj.lastSynced)
      ..writeByte(12)
      ..write(obj.isDeleted)
      ..writeByte(13)
      ..write(obj.deviceId)
      ..writeByte(14)
      ..write(obj.version);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubProjectAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
