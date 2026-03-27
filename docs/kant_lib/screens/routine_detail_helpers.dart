import 'package:flutter/material.dart';

import '../models/routine_block_v2.dart';

class RoutineDetailHelpers {
  static int _timeOfDayToMinutes(TimeOfDay t) => t.hour * 60 + t.minute;

  static TimeOfDay _minutesToTimeOfDay(int totalMinutes) {
    final normalized = ((totalMinutes % (24 * 60)) + (24 * 60)) % (24 * 60);
    return TimeOfDay(hour: normalized ~/ 60, minute: normalized % 60);
  }

  /// 各ブロックの占有区間 [startMin, endMin) を列挙。日付跨ぎは [0,end) と [start,24*60) に分割。
  static List<({int start, int end})> _occupiedSegments(
      List<RoutineBlockV2> blocks) {
    final segs = <({int start, int end})>[];
    for (final b in blocks) {
      final s = _timeOfDayToMinutes(b.startTime);
      final e = _timeOfDayToMinutes(b.endTime);
      if (e > s) {
        segs.add((start: s, end: e));
      } else {
        // 日付跨ぎ: [0, end) と [start, 24*60)
        if (e > 0) segs.add((start: 0, end: e));
        if (s < 24 * 60) segs.add((start: s, end: 24 * 60));
      }
    }
    return segs;
  }

  /// 占有区間をマージして重複を除去し、開始時刻でソート
  static List<({int start, int end})> _mergeSegments(
      List<({int start, int end})> segs) {
    if (segs.isEmpty) return [];
    segs = List.from(segs)..sort((a, b) => a.start.compareTo(b.start));
    final merged = <({int start, int end})>[];
    for (final s in segs) {
      if (merged.isEmpty) {
        merged.add(s);
      } else {
        final last = merged.last;
        if (s.start <= last.end) {
          merged[merged.length - 1] = (
            start: last.start,
            end: last.end > s.end ? last.end : s.end,
          );
        } else {
          merged.add(s);
        }
      }
    }
    return merged;
  }

  /// 既存ブロック間のスキマのうち、前から最初に存在するスキマ（1分以上）を返す。
  /// 返す区間の長さは min(スキマ長, [maxBlockMinutes]) で、スキマに収まる。
  /// スキマが1分もなければ null（末尾に追加する場合に使う）。
  /// 日付跨ぎブロック（例: 睡眠 23:00-7:00）を正しく考慮する。
  static ({TimeOfDay start, TimeOfDay end})? findFirstFittingGap(
    List<RoutineBlockV2> blocks, {
    int minGapMinutes = 1,
    int maxBlockMinutes = 60,
  }) {
    final filtered = blocks.where((b) => !b.isDeleted).toList();
    if (filtered.isEmpty) return null;

    final segs = _mergeSegments(_occupiedSegments(filtered));
    if (segs.isEmpty) return null;

    // スキマ1: 0:00 〜 最初の占有区間の開始（1分以上空いていれば前から詰める）
    if (segs.first.start >= minGapMinutes) {
      final blockLen = segs.first.start < maxBlockMinutes
          ? segs.first.start
          : maxBlockMinutes;
      return (
        start: const TimeOfDay(hour: 0, minute: 0),
        end: _minutesToTimeOfDay(blockLen),
      );
    }

    // スキマ2: 占有区間の間
    for (int i = 0; i < segs.length - 1; i++) {
      final gapStart = segs[i].end;
      final gapEnd = segs[i + 1].start;
      final gapMinutes = gapEnd - gapStart;
      if (gapMinutes >= minGapMinutes) {
        final blockLen =
            gapMinutes < maxBlockMinutes ? gapMinutes : maxBlockMinutes;
        return (
          start: _minutesToTimeOfDay(gapStart),
          end: _minutesToTimeOfDay(gapStart + blockLen),
        );
      }
    }

    // スキマ3: 最後の占有区間の終了 〜 24:00
    final lastEnd = segs.last.end;
    final gapToMidnight = 24 * 60 - lastEnd;
    if (gapToMidnight >= minGapMinutes) {
      final blockLen =
          gapToMidnight < maxBlockMinutes ? gapToMidnight : maxBlockMinutes;
      return (
        start: _minutesToTimeOfDay(lastEnd),
        end: _minutesToTimeOfDay(lastEnd + blockLen),
      );
    }

    return null;
  }

  static String calculateDuration(TimeOfDay startTime, TimeOfDay endTime) {
    int startMinutes = startTime.hour * 60 + startTime.minute;
    int endMinutes = endTime.hour * 60 + endTime.minute;
    int durationMinutes = endMinutes - startMinutes;

    if (durationMinutes < 0) {
      durationMinutes += 24 * 60; // 日をまたぐ場合
    }

    // 分表示で統一
    return '$durationMinutes分';
  }
}
