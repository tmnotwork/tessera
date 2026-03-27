import '../../models/actual_task.dart' as actual;
import '../../models/inbox_task.dart' as inbox;
import '../../models/project.dart';
import '../../models/sub_project.dart';
import '../../models/block.dart' as block;
import '../../services/project_service.dart';
import '../../services/sub_project_service.dart';

class TimelineHelpers {
  // タスクの状態判定
  static bool isTaskCompleted(dynamic task) {
    if (task is inbox.InboxTask) return task.isCompleted;
    if (task is actual.ActualTask) return task.isCompleted;
    if (task is block.Block) return false; // Blockは常に未完了
    return false;
  }

  static bool isTaskPaused(dynamic task) {
    if (task is inbox.InboxTask) {
      // InboxTaskの再生状態は持たないため、未完了＝予定/一時停止扱い
      return task.isCompleted == false;
    }
    if (task is actual.ActualTask) return task.isPaused;
    if (task is block.Block) return false; // Blockは常に予定状態
    return false;
  }

  static bool isTaskPlanned(dynamic task) {
    if (task is inbox.InboxTask) {
      return !task.isCompleted;
    } else if (task is actual.ActualTask) {
      return false; // ActualTaskは実行中タスクなので予定状態ではない
    } else if (task is block.Block) {
      return true; // Blockは常に予定状態
    }
    return false;
  }

  // タスク情報取得
  static String? getTaskDetails(dynamic task) {
    if (task is inbox.InboxTask) return task.memo;
    if (task is actual.ActualTask) return task.memo;
    if (task is block.Block) return task.memo;
    return null;
  }

  static String getTaskStartTimeText(dynamic task) {
    if (task is inbox.InboxTask) {
      return '開始: ${task.startHour.toString().padLeft(2, '0')}:${task.startMinute.toString().padLeft(2, '0')}';
    }
    if (task is actual.ActualTask) {
      return '開始: ${_formatTime(task.startTime)}';
    }
    return '開始時刻未設定';
  }

  static DateTime? getTaskStartTime(dynamic task) {
    if (task is inbox.InboxTask) return null; // Inboxは予定のため実行開始時刻は持たない
    if (task is actual.ActualTask) return task.startTime;
    return null;
  }

  static DateTime? getTaskEndTime(dynamic task) {
    if (task is inbox.InboxTask) return null; // Inboxは予定終端は持たない
    if (task is actual.ActualTask) return task.endTime;
    return null;
  }

  static Project? getTaskProject(dynamic task) {
    String? projectId;
    if (task is inbox.InboxTask) {
      projectId = task.projectId;
    } else if (task is actual.ActualTask) {
      projectId = task.projectId;
    } else if (task is block.Block) {
      projectId = task.projectId;
    }

    if (projectId != null) {
      return ProjectService.getProjectById(projectId);
    }
    return null;
  }

  static SubProject? getTaskSubProject(dynamic task) {
    String? subProjectId;
    if (task is inbox.InboxTask) {
      // InboxTaskにはsubProjectIdがない場合がある
      return null;
    } else if (task is actual.ActualTask) {
      subProjectId = task.subProjectId;
    } else if (task is block.Block) {
      subProjectId = task.subProjectId;
    }

    if (subProjectId != null) {
      return SubProjectService.getSubProjectById(subProjectId);
    }
    return null;
  }

  // 時間フォーマット
  static String _formatTime(DateTime? time) {
    if (time == null) return '未設定';
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  // HH:MM:SS形式の時間入力をフォーマット
  static String formatTimeForInput(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
           '${time.minute.toString().padLeft(2, '0')}:'
           '${time.second.toString().padLeft(2, '0')}';
  }

  // HH:MM:SS形式の文字列を DateTime に変換
  // 入力を「時刻（h/m/s）」としてパースする（※日付は混ぜない）
  // - "HH:mm" / "H:mm" / "HH:mm:ss"
  // - 数字のみ: "930"(=09:30) / "0930" / "123045"(=12:30:45)
  static ({int hour, int minute, int second})? parseTimeInput(String input) {
    return _parseTimeInputCore(input, allowHour24: false);
  }

  /// 終了時刻用パース: 24:00 を許可（24:xx は不可）
  /// hour=24 のときは minute=0, second=0 のみ有効
  static ({int hour, int minute, int second})? parseEndTimeInput(String input) {
    return _parseTimeInputCore(input, allowHour24: true);
  }

  static ({int hour, int minute, int second})? _parseTimeInputCore(
    String input, {
    required bool allowHour24,
  }) {
    try {
      String s = input.trim();
      if (s.isEmpty) return null;
      s = s.replaceAll('：', ':');

      // パターン1: コロン区切り
      if (s.contains(':')) {
        final parts = s.split(':');
        if (parts.isEmpty) return null;
        final hh = int.tryParse(parts[0]) ?? -1;
        final mm = parts.length > 1 ? (int.tryParse(parts[1]) ?? -1) : 0;
        final ss = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
        final maxHour = allowHour24 ? 24 : 23;
        if (hh < 0 || hh > maxHour || mm < 0 || mm > 59 || ss < 0 || ss > 59) return null;
        // hour=24 の場合は minute=0, second=0 のみ許可
        if (hh == 24 && (mm != 0 || ss != 0)) return null;
        return (hour: hh, minute: mm, second: ss);
      }

      // パターン2: 数字のみ（HHmm または HHmmss または Hmm）
      final digits = s.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.isEmpty) return null;
      if (digits.length == 3) {
        // 例: 930 -> 09:30
        final hh = int.tryParse(digits.substring(0, 1)) ?? -1;
        final mm = int.tryParse(digits.substring(1, 3)) ?? -1;
        // 3桁では hour=24 にはならない（最大 9:59）
        if (hh < 0 || hh > 23 || mm < 0 || mm > 59) return null;
        return (hour: hh, minute: mm, second: 0);
      }
      if (digits.length == 4) {
        final hh = int.tryParse(digits.substring(0, 2)) ?? -1;
        final mm = int.tryParse(digits.substring(2, 4)) ?? -1;
        final maxHour = allowHour24 ? 24 : 23;
        if (hh < 0 || hh > maxHour || mm < 0 || mm > 59) return null;
        // hour=24 の場合は minute=0 のみ許可
        if (hh == 24 && mm != 0) return null;
        return (hour: hh, minute: mm, second: 0);
      }
      if (digits.length == 6) {
        final hh = int.tryParse(digits.substring(0, 2)) ?? -1;
        final mm = int.tryParse(digits.substring(2, 4)) ?? -1;
        final ss = int.tryParse(digits.substring(4, 6)) ?? -1;
        final maxHour = allowHour24 ? 24 : 23;
        if (hh < 0 || hh > maxHour || mm < 0 || mm > 59 || ss < 0 || ss > 59) return null;
        // hour=24 の場合は minute=0, second=0 のみ許可
        if (hh == 24 && (mm != 0 || ss != 0)) return null;
        return (hour: hh, minute: mm, second: ss);
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
