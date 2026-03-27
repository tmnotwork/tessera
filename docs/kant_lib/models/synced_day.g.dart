// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'synced_day.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class SyncedDayAdapter extends TypeAdapter<SyncedDay> {
  @override
  final int typeId = 122;

  @override
  SyncedDay read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return SyncedDay(
      dateKey: fields[0] as String,
      kind: fields[1] as SyncedDayKind,
      status: fields[2] as SyncedDayStatus,
      lastVersionHash: fields[3] as String?,
      lastVersionWriteAt: fields[4] as DateTime?,
      lastVersionCheckAt: fields[5] as DateTime?,
      lastFetchedAt: fields[6] as DateTime?,
      lastChangeAt: fields[9] as DateTime?,
      lastChangeDocId: fields[10] as String?,
      lastFullSyncAt: fields[11] as DateTime?,
      createdAt: fields[7] as DateTime?,
      updatedAt: fields[8] as DateTime?,
    );
  }

  @override
  void write(BinaryWriter writer, SyncedDay obj) {
    writer
      ..writeByte(12)
      ..writeByte(0)
      ..write(obj.dateKey)
      ..writeByte(1)
      ..write(obj.kind)
      ..writeByte(2)
      ..write(obj.status)
      ..writeByte(3)
      ..write(obj.lastVersionHash)
      ..writeByte(4)
      ..write(obj.lastVersionWriteAt)
      ..writeByte(5)
      ..write(obj.lastVersionCheckAt)
      ..writeByte(6)
      ..write(obj.lastFetchedAt)
      ..writeByte(7)
      ..write(obj.createdAt)
      ..writeByte(8)
      ..write(obj.updatedAt)
      ..writeByte(9)
      ..write(obj.lastChangeAt)
      ..writeByte(10)
      ..write(obj.lastChangeDocId)
      ..writeByte(11)
      ..write(obj.lastFullSyncAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncedDayAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class SyncedDayKindAdapter extends TypeAdapter<SyncedDayKind> {
  @override
  final int typeId = 120;

  @override
  SyncedDayKind read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return SyncedDayKind.timeline;
      case 1:
        return SyncedDayKind.inbox;
      case 2:
        return SyncedDayKind.report;
      default:
        return SyncedDayKind.timeline;
    }
  }

  @override
  void write(BinaryWriter writer, SyncedDayKind obj) {
    switch (obj) {
      case SyncedDayKind.timeline:
        writer.writeByte(0);
        break;
      case SyncedDayKind.inbox:
        writer.writeByte(1);
        break;
      case SyncedDayKind.report:
        writer.writeByte(2);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncedDayKindAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class SyncedDayStatusAdapter extends TypeAdapter<SyncedDayStatus> {
  @override
  final int typeId = 121;

  @override
  SyncedDayStatus read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return SyncedDayStatus.seeded;
      case 1:
        return SyncedDayStatus.ready;
      case 2:
        return SyncedDayStatus.stale;
      case 3:
        return SyncedDayStatus.evicted;
      default:
        return SyncedDayStatus.seeded;
    }
  }

  @override
  void write(BinaryWriter writer, SyncedDayStatus obj) {
    switch (obj) {
      case SyncedDayStatus.seeded:
        writer.writeByte(0);
        break;
      case SyncedDayStatus.ready:
        writer.writeByte(1);
        break;
      case SyncedDayStatus.stale:
        writer.writeByte(2);
        break;
      case SyncedDayStatus.evicted:
        writer.writeByte(3);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncedDayStatusAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
