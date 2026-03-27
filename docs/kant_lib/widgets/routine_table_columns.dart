import 'package:flutter/material.dart';

/// Routine系テーブル（ヘッダー/行）で使う列定義。
///
/// ヘッダーと行の「列順・幅」を同一の定義で共有し、縦ズレを防ぐ。
enum RoutineTableColumn {
  time,
  duration,
  blockName,
  project,
  subProject,
  taskName,
  location,
  mode,
  delete,
}

@immutable
class RoutineTableLayout {
  const RoutineTableLayout._();

  static const double timeWidth = 88;
  static const double durationWidth = 72;
  static const double locationWidth = 160;
  static const double deleteWidth = 60;

  static const int blockNameFlex = 2;
  static const int projectFlex = 2;
  static const int subProjectFlex = 2;
  static const int taskNameFlex = 4;
  static const int modeFlex = 2;

  /// 既存画面互換のデフォルト列順。
  static List<RoutineTableColumn> defaultColumns({
    required bool showTimeColumns,
    required bool showDurationColumn,
  }) {
    final cols = <RoutineTableColumn>[];
    if (showTimeColumns) cols.add(RoutineTableColumn.time);
    if (showDurationColumn) cols.add(RoutineTableColumn.duration);
    cols.addAll(const [
      RoutineTableColumn.blockName,
      RoutineTableColumn.project,
      RoutineTableColumn.subProject,
      RoutineTableColumn.taskName,
      RoutineTableColumn.location,
      RoutineTableColumn.mode,
      RoutineTableColumn.delete,
    ]);
    return cols;
  }

  /// 非定型ショートカット編集画面用。
  ///
  /// - ブロック名: 不要
  /// - タスク名: 最左
  /// - 場所: 削除の左（= 最後から2番目）
  static const List<RoutineTableColumn> shortcutEditColumns = [
    RoutineTableColumn.taskName,
    RoutineTableColumn.project,
    RoutineTableColumn.subProject,
    RoutineTableColumn.mode,
    RoutineTableColumn.location,
    RoutineTableColumn.delete,
  ];
}

