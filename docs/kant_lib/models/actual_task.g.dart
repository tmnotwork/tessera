// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'actual_task.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ActualTaskAdapter extends TypeAdapter<ActualTask> {
  @override
  final int typeId = 5;

  @override
  ActualTask read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ActualTask(
      id: fields[0] as String,
      title: fields[1] as String,
      status: fields[2] as ActualTaskStatus,
      projectId: fields[3] as String?,
      dueDate: fields[4] as DateTime?,
      startTime: fields[5] as DateTime,
      endTime: fields[6] as DateTime?,
      actualDuration: fields[7] as int,
      memo: fields[9] as String?,
      createdAt: fields[10] as DateTime,
      lastModified: fields[11] as DateTime,
      userId: fields[12] as String,
      blockId: fields[13] as String?,
      subProjectId: fields[14] as String?,
      subProject: fields[15] as String?,
      modeId: fields[16] as String?,
      blockName: fields[17] as String?,
      sourceInboxTaskId: fields[24] as String?,
      location: fields[23] as String?,
      startAt: fields[25] as DateTime?,
      endAtExclusive: fields[26] as DateTime?,
      dayKeys: (fields[27] as List?)?.cast<String>(),
      monthKeys: (fields[28] as List?)?.cast<String>(),
      allDay: fields[29] as bool,
      excludeFromReport: fields[30] as bool,
      cloudId: fields[18] as String?,
      lastSynced: fields[19] as DateTime?,
      isDeleted: fields[20] as bool,
      deviceId: fields[21] as String,
      version: fields[22] as int,
    );
  }

  @override
  void write(BinaryWriter writer, ActualTask obj) {
    writer
      ..writeByte(30)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.status)
      ..writeByte(3)
      ..write(obj.projectId)
      ..writeByte(4)
      ..write(obj.dueDate)
      ..writeByte(5)
      ..write(obj.startTime)
      ..writeByte(6)
      ..write(obj.endTime)
      ..writeByte(7)
      ..write(obj.actualDuration)
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
      ..write(obj.subProjectId)
      ..writeByte(15)
      ..write(obj.subProject)
      ..writeByte(16)
      ..write(obj.modeId)
      ..writeByte(17)
      ..write(obj.blockName)
      ..writeByte(24)
      ..write(obj.sourceInboxTaskId)
      ..writeByte(23)
      ..write(obj.location)
      ..writeByte(18)
      ..write(obj.cloudId)
      ..writeByte(19)
      ..write(obj.lastSynced)
      ..writeByte(20)
      ..write(obj.isDeleted)
      ..writeByte(21)
      ..write(obj.deviceId)
      ..writeByte(22)
      ..write(obj.version)
      ..writeByte(25)
      ..write(obj.startAt)
      ..writeByte(26)
      ..write(obj.endAtExclusive)
      ..writeByte(27)
      ..write(obj.dayKeys)
      ..writeByte(28)
      ..write(obj.monthKeys)
      ..writeByte(29)
      ..write(obj.allDay)
      ..writeByte(30)
      ..write(obj.excludeFromReport);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActualTaskAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class ActualTaskStatusAdapter extends TypeAdapter<ActualTaskStatus> {
  @override
  final int typeId = 18;

  @override
  ActualTaskStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return ActualTaskStatus.running;
      case 1:
        return ActualTaskStatus.completed;
      case 2:
        return ActualTaskStatus.paused;
      default:
        return ActualTaskStatus.running;
    }
  }

  @override
  void write(BinaryWriter writer, ActualTaskStatus obj) {
    switch (obj) {
      case ActualTaskStatus.running:
        writer.writeByte(0);
        break;
      case ActualTaskStatus.completed:
        writer.writeByte(1);
        break;
      case ActualTaskStatus.paused:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActualTaskStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
