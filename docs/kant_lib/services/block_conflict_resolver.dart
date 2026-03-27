import '../models/block.dart';
import 'block_local_data_manager.dart';
import 'block_cloud_operations.dart';
import 'block_sync_service.dart';

/// ブロックの競合解決を担当するクラス
class BlockConflictResolver {
  /// 手動競合解決: Device-Based-Append戦略
  /// 異なる端末からの予定は両方保持
  static Future<Block> handleManualConflict(Block local, Block remote) async {
    // 異なる端末からの記録の場合は両方保持
    if (local.deviceId != remote.deviceId) {
      // リモートブロックに新しいIDを割り当てて両方保存
      final remoteBlockCopy = Block.fromJson(remote.toCloudJson());
      remoteBlockCopy.id = '${remote.id}_${remote.deviceId}';
      remoteBlockCopy.cloudId = null; // 新しいcloudIdが割り当てられる

      await BlockLocalDataManager.saveToLocal(remoteBlockCopy);
      return local; // ローカルブロックをそのまま返す
    }

    // 同じ端末からの場合は最新を採用
    if (remote.lastModified.isAfter(local.lastModified)) {
      try {
        final cid = remote.cloudId ?? remote.id;
        await BlockCloudOperations.fetchAndApplyRemote(
            cid, BlockSyncService().userCollection);
      } catch (_) {
        await BlockLocalDataManager.saveToLocal(remote);
      }
      return remote;
    } else {
      return local;
    }
  }

  /// 自動競合解決: Last-Write-Wins戦略
  /// 端末に依らず lastModified が新しい方を採用
  static Future<Block> resolveConflict(Block local, Block remote) async {
    if (remote.lastModified.isAfter(local.lastModified)) {
      try {
        final cid = remote.cloudId ?? remote.id;
        await BlockCloudOperations.fetchAndApplyRemote(
            cid, BlockSyncService().userCollection);
      } catch (_) {
        await BlockLocalDataManager.saveToLocal(remote);
      }
      return remote;
    } else {
      return local;
    }
  }

  /// 競合情報の分析
  static ConflictAnalysis analyzeConflict(Block local, Block remote) {
    final isDeviceConflict = local.deviceId != remote.deviceId;
    final isTimeConflict = local.lastModified != remote.lastModified;
    final isContentConflict = _hasContentDifferences(local, remote);

    return ConflictAnalysis(
      isDeviceConflict: isDeviceConflict,
      isTimeConflict: isTimeConflict,
      isContentConflict: isContentConflict,
      localNewer: local.lastModified.isAfter(remote.lastModified),
      remoteNewer: remote.lastModified.isAfter(local.lastModified),
    );
  }

  /// コンテンツの差異をチェック
  static bool _hasContentDifferences(Block local, Block remote) {
    return local.title != remote.title ||
        local.memo != remote.memo ||
        local.isCompleted != remote.isCompleted ||
        local.isSkipped != remote.isSkipped ||
        local.startHour != remote.startHour ||
        local.startMinute != remote.startMinute ||
        local.estimatedDuration != remote.estimatedDuration ||
        local.workingMinutes != remote.workingMinutes ||
        local.projectId != remote.projectId ||
        local.subProjectId != remote.subProjectId ||
        local.modeId != remote.modeId ||
        local.blockName != remote.blockName;
  }
}

/// 競合分析結果
class ConflictAnalysis {
  final bool isDeviceConflict;
  final bool isTimeConflict;
  final bool isContentConflict;
  final bool localNewer;
  final bool remoteNewer;

  ConflictAnalysis({
    required this.isDeviceConflict,
    required this.isTimeConflict,
    required this.isContentConflict,
    required this.localNewer,
    required this.remoteNewer,
  });

  /// 競合の重要度を評価
  ConflictSeverity get severity {
    if (isDeviceConflict && isContentConflict) {
      return ConflictSeverity.high;
    } else if (isContentConflict) {
      return ConflictSeverity.medium;
    } else if (isTimeConflict) {
      return ConflictSeverity.low;
    } else {
      return ConflictSeverity.none;
    }
  }

  /// 推奨される解決戦略
  ConflictResolutionStrategy get recommendedStrategy {
    if (isDeviceConflict) {
      return ConflictResolutionStrategy.keepBoth;
    } else if (remoteNewer) {
      return ConflictResolutionStrategy.useRemote;
    } else {
      return ConflictResolutionStrategy.useLocal;
    }
  }
}

/// 競合の重要度
enum ConflictSeverity {
  none, // 競合なし
  low, // 時間のみの差異
  medium, // コンテンツの差異
  high, // デバイス間 + コンテンツの差異
}

/// 推奨される解決戦略
enum ConflictResolutionStrategy {
  keepBoth,
  useRemote,
  useLocal,
}
