import 'dart:async';

/// ブロック関連のユーティリティ機能を担当するクラス
class BlockUtilities {
  // TaskProviderへの更新通知用StreamController
  static final StreamController<void> _updateController =
      StreamController<void>.broadcast();

  /// TaskProvider更新通知用ストリーム
  static Stream<void> get updateStream => _updateController.stream;

  /// TaskProviderに更新を通知する
  static void notifyTaskProviderUpdate() {
    _updateController.add(null);
  }

  // ===== Block time-change reschedule notices =====
  static final StreamController<BlockRescheduleNotice> _rescheduleNoticeController =
      StreamController<BlockRescheduleNotice>.broadcast();

  /// ブロック時刻変更に伴うタスク再配置の通知（UIでSnackBar表示などに使用）
  static Stream<BlockRescheduleNotice> get rescheduleNoticeStream =>
      _rescheduleNoticeController.stream;

  static void notifyRescheduleNotice(BlockRescheduleNotice notice) {
    try {
      _rescheduleNoticeController.add(notice);
    } catch (_) {}
  }

  /// 削除クールダウンをクリア（テスト用）
  static void clearDeletionCooldown() {
    // クールダウンをクリア
  }
}

/// ブロック時刻変更に伴う「前詰め再配置」の結果通知
class BlockRescheduleNotice {
  final String blockId;
  final String? blockCloudId;
  final String? blockLabel;
  final int overflowMinutes;
  final int rescheduledTaskCount;

  const BlockRescheduleNotice({
    required this.blockId,
    this.blockCloudId,
    this.blockLabel,
    required this.overflowMinutes,
    required this.rescheduledTaskCount,
  });
}
