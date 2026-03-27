// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'inbox_task.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class InboxTaskAdapter extends TypeAdapter<InboxTask> {
  @override
  final int typeId = 20;

  @override
  InboxTask read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return InboxTask(
      id: fields[0] as String,
      title: fields[1] as String,
      projectId: fields[2] as String?,
      dueDate: fields[3] as DateTime?,
      executionDate: fields[4] as DateTime,
      startHour: fields[5] as int?,
      startMinute: fields[6] as int?,
      estimatedDuration: fields[7] as int,
      memo: fields[9] as String?,
      createdAt: fields[10] as DateTime,
      lastModified: fields[11] as DateTime,
      userId: fields[12] as String,
      blockId: fields[13] as String?,
      isCompleted: fields[14] as bool,
      isRunning: fields[15] as bool,
      startTime: fields[21] as DateTime?,
      endTime: fields[22] as DateTime?,
      subProjectId: fields[23] as String?,
      isSomeday: fields[24] as bool,
      modeId: fields[25] as String?,
      excludeFromReport: fields[26] as bool,
      isImportant: fields[27] as bool,
      cloudId: fields[16] as String?,
      lastSynced: fields[17] as DateTime?,
      isDeleted: fields[18] as bool,
      deviceId: fields[19] as String,
      version: fields[20] as int,
    );
  }

  @override
  void write(BinaryWriter writer, InboxTask obj) {
    writer
      ..writeByte(27)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.projectId)
      ..writeByte(3)
      ..write(obj.dueDate)
      ..writeByte(4)
      ..write(obj.executionDate)
      ..writeByte(5)
      ..write(obj.startHour)
      ..writeByte(6)
      ..write(obj.startMinute)
      ..writeByte(7)
      ..write(obj.estimatedDuration)
      ..writeByte(9)
      ..write(obj.memo)
      ..writeByte(10)
      ..write(obj.createdAt)
      ..writeByte(11)
      ..write(obj.lastModified)
      ..writeByte(12)
      ..write(obj.userId)
      ..writeByte(13)
      ..write(obj.blockId)
      ..writeByte(14)
      ..write(obj.isCompleted)
      ..writeByte(15)
      ..write(obj.isRunning)
      ..writeByte(16)
      ..write(obj.cloudId)
      ..writeByte(17)
      ..write(obj.lastSynced)
      ..writeByte(18)
      ..write(obj.isDeleted)
      ..writeByte(19)
      ..write(obj.deviceId)
      ..writeByte(20)
      ..write(obj.version)
      ..writeByte(21)
      ..write(obj.startTime)
      ..writeByte(22)
      ..write(obj.endTime)
      ..writeByte(23)
      ..write(obj.subProjectId)
      ..writeByte(24)
      ..write(obj.isSomeday)
      ..writeByte(25)
      ..write(obj.modeId)
      ..writeByte(26)
      ..write(obj.excludeFromReport)
      ..writeByte(27)
      ..write(obj.isImportant);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InboxTaskAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
