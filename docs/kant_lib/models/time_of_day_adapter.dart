import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

class TimeOfDayAdapter extends TypeAdapter<TimeOfDay> {
  @override
  final int typeId = 10; // main.dartのコメントと一致させる

  @override
  TimeOfDay read(BinaryReader reader) {
    try {
      final hour = reader.readInt();
      final minute = reader.readInt();
      
      // バリデーション
      if (hour < 0 || hour > 23) {
        print('⚠️ Invalid hour value: $hour, defaulting to 0');
        return const TimeOfDay(hour: 0, minute: 0);
      }
      if (minute < 0 || minute > 59) {
        print('⚠️ Invalid minute value: $minute, defaulting to 0');
        return TimeOfDay(hour: hour, minute: 0);
      }
      
      return TimeOfDay(hour: hour, minute: minute);
    } catch (e) {
      print('❌ Error reading TimeOfDay from Hive: $e');
      // デフォルト値を返す
      return const TimeOfDay(hour: 0, minute: 0);
    }
  }

  @override
  void write(BinaryWriter writer, TimeOfDay obj) {
    try {
      writer.writeInt(obj.hour);
      writer.writeInt(obj.minute);
    } catch (e) {
      print('❌ Error writing TimeOfDay to Hive: $e');
      // エラーの場合はデフォルト値を書き込む
      writer.writeInt(0);
      writer.writeInt(0);
    }
  }
}
