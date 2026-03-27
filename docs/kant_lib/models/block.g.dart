// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'block.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class BlockAdapter extends TypeAdapter<Block> {
  @override
  final int typeId = 99;

  @override
  Block read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Block(
      id: fields[0] as String,
      title: fields[1] as String,
      creationMethod: fields[2] as TaskCreationMethod,
      projectId: fields[3] as String?,
      dueDate: fields[4] as DateTime?,
      executionDate: fields[5] as DateTime,
      startHour: fields[6] as int,
      startMinute: fields[7] as int,
      estimatedDuration: fields[8] as int,
      workingMinutes: fields[30] as int?,
      startAt: fields[31] as DateTime?,
      endAtExclusive: fields[32] as DateTime?,
      allDay: fields[33] as bool,
      dayKeys: (fields[34] as List?)?.cast<String>(),
      monthKeys: (fields[35] as List?)?.cast<String>(),
      excludeFromReport: fields[36] as bool,
      memo: fields[10] as String?,
      createdAt: fields[11] as DateTime,
      lastModified: fields[12] as DateTime,
      userId: fields[13] as String,
      subProjectId: fields[14] as String?,
      subProject: fields[15] as String?,
      modeId: fields[16] as String?,
      blockName: fields[17] as String?,
      isCompleted: fields[18] as bool,
      taskId: fields[19] as String?,
      isRoutineDerived: fields[25] as bool,
      isPauseDerived: fields[26] as bool,
      isEvent: fields[27] as bool,
      isSkipped: fields[28] as bool,
      location: fields[29] as String?,
      cloudId: fields[20] as String?,
      lastSynced: fields[21] as DateTime?,
      isDeleted: fields[22] as bool,
      deviceId: fields[23] as String,
      version: fields[24] as int,
    );
  }

  @override
  void write(BinaryWriter writer, Block obj) {
    writer
      ..writeByte(36)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.creationMethod)
      ..writeByte(3)
      ..write(obj.projectId)
      ..writeByte(4)
      ..write(obj.dueDate)
      ..writeByte(5)
      ..write(obj.executionDate)
      ..writeByte(6)
      ..write(obj.startHour)
      ..writeByte(7)
      ..write(obj.startMinute)
      ..writeByte(8)
      ..write(obj.estimatedDuration)
      ..writeByte(30)
      ..write(obj.workingMinutes)
      ..writeByte(31)
      ..write(obj.startAt)
      ..writeByte(32)
      ..write(obj.endAtExclusive)
      ..writeByte(33)
      ..write(obj.allDay)
      ..writeByte(34)
      ..write(obj.dayKeys)
      ..writeByte(35)
      ..write(obj.monthKeys)
      ..writeByte(36)
      ..write(obj.excludeFromReport)
      ..writeByte(10)
      ..write(obj.memo)
      ..writeByte(11)
      ..write(obj.createdAt)
      ..writeByte(12)
      ..write(obj.lastModified)
      ..writeByte(13)
      ..write(obj.userId)
      ..writeByte(14)
      ..write(obj.subProjectId)
      ..writeByte(15)
      ..write(obj.subProject)
      ..writeByte(16)
      ..write(obj.modeId)
      ..writeByte(17)
      ..write(obj.blockName)
      ..writeByte(18)
      ..write(obj.isCompleted)
      ..writeByte(19)
      ..write(obj.taskId)
      ..writeByte(25)
      ..write(obj.isRoutineDerived)
      ..writeByte(26)
      ..write(obj.isPauseDerived)
      ..writeByte(27)
      ..write(obj.isEvent)
      ..writeByte(28)
      ..write(obj.isSkipped)
      ..writeByte(29)
      ..write(obj.location)
      ..writeByte(20)
      ..write(obj.cloudId)
      ..writeByte(21)
      ..write(obj.lastSynced)
      ..writeByte(22)
      ..write(obj.isDeleted)
      ..writeByte(23)
      ..write(obj.deviceId)
      ..writeByte(24)
      ..write(obj.version);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlockAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class TaskCreationMethodAdapter extends TypeAdapter<TaskCreationMethod> {
  @override
  final int typeId = 16;

  @override
  TaskCreationMethod read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return TaskCreationMethod.manual;
      case 1:
        return TaskCreationMethod.routine;
      default:
        return TaskCreationMethod.manual;
    }
  }

  @override
  void write(BinaryWriter writer, TaskCreationMethod obj) {
    switch (obj) {
      case TaskCreationMethod.manual:
        writer.writeByte(0);
        break;
      case TaskCreationMethod.routine:
        writer.writeByte(1);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TaskCreationMethodAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
