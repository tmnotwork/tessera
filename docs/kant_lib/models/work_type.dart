import 'package:hive/hive.dart';

part 'work_type.g.dart';

@HiveType(typeId: 26)
enum WorkType {
  @HiveField(0)
  work, // 勤務
  @HiveField(1)
  free, // 自由
}

/// WorkType の値を詳細確認するデバッグ関数（簡略化）
void debugWorkTypeValues() {
  // 過度なデバッグログを削除 - 必要時のみコメント解除
  // print('🔍 DEBUG: WorkType.values: ${WorkType.values}');
}
