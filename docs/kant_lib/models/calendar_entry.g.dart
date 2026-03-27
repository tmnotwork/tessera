// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'calendar_entry.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CalendarEntryAdapter extends TypeAdapter<CalendarEntry> {
  @override
  final int typeId = 6;

  @override
  CalendarEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CalendarEntry(
      id: fields[0] as String,
      date: fields[1] as DateTime,
      routineTypeId: fields[2] as String?,
      color: fields[3] as String,
      isHoliday: fields[4] as bool,
      isOff: fields[5] as bool,
      createdAt: fields[6] as DateTime,
      lastModified: fields[7] as DateTime,
      userId: fields[8] as String,
      cloudId: fields[9] as String?,
      lastSynced: fields[10] as DateTime?,
      isDeleted: fields[11] as bool,
      deviceId: fields[12] as String,
      version: fields[13] as int,
    );
  }

  @override
  void write(BinaryWriter writer, CalendarEntry obj) {
    writer
      ..writeByte(14)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.date)
      ..writeByte(2)
      ..write(obj.routineTypeId)
      ..writeByte(3)
      ..write(obj.color)
      ..writeByte(4)
      ..write(obj.isHoliday)
      ..writeByte(5)
      ..write(obj.isOff)
      ..writeByte(6)
      ..write(obj.createdAt)
      ..writeByte(7)
      ..write(obj.lastModified)
      ..writeByte(8)
      ..write(obj.userId)
      ..writeByte(9)
      ..write(obj.cloudId)
      ..writeByte(10)
      ..write(obj.lastSynced)
      ..writeByte(11)
      ..write(obj.isDeleted)
      ..writeByte(12)
      ..write(obj.deviceId)
      ..writeByte(13)
      ..write(obj.version);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CalendarEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
