import '../models/syncable_model.dart';

/// 競合検出器
class ConflictDetector {
  /// 2つのデータ間の競合を検出する
  static ConflictResolution detectConflict<T extends SyncableModel>(
    T localData,
    T remoteData,
    [bool deterministicDeviceIdTieBreakWhenVersionEqual = false]
  ) {
    // 1. 削除フラグの確認
    if (localData.isDeleted && !remoteData.isDeleted) {
      return ConflictResolution.needsManual; // 削除と更新の競合
    }
    if (!localData.isDeleted && remoteData.isDeleted) {
      return ConflictResolution.needsManual; // 更新と削除の競合
    }

    // 2. バージョン比較
    if (localData.version > remoteData.version) {
      return ConflictResolution.localNewer;
    }
    if (remoteData.version > localData.version) {
      return ConflictResolution.remoteNewer;
    }

    // 3. 同じバージョンの場合の判定
    // - V2（Lamport clock）を前提にするデータでは、端末時計に依存しない決定的解決を優先する。
    if (deterministicDeviceIdTieBreakWhenVersionEqual) {
      final comparison = localData.deviceId.compareTo(remoteData.deviceId);
      if (comparison < 0) {
        return ConflictResolution.localWins;
      }
      if (comparison > 0) {
        return ConflictResolution.remoteWins;
      }
      // 同一deviceId（理論上稀）だけは時刻で保険
      if (localData.lastModified.isAfter(remoteData.lastModified)) {
        return ConflictResolution.localNewer;
      }
      if (remoteData.lastModified.isAfter(localData.lastModified)) {
        return ConflictResolution.remoteNewer;
      }
      return ConflictResolution.remoteWins;
    }

    // 3'. 互換: 同じバージョンの場合、最終更新時刻で判定
    final localTime = localData.lastModified;
    final remoteTime = remoteData.lastModified;
    
    final timeDifference = localTime.difference(remoteTime).abs();
    
    // 1秒以内の差は同時刻とみなす
    if (timeDifference.inSeconds <= 1) {
      // 同時刻の場合、端末IDで決定的に解決
      final comparison = localData.deviceId.compareTo(remoteData.deviceId);
      return comparison < 0
          ? ConflictResolution.localWins
          : ConflictResolution.remoteWins;
    }

    // 明確な時刻差がある場合
    if (localTime.isAfter(remoteTime)) {
      return ConflictResolution.localNewer;
    } else {
      return ConflictResolution.remoteNewer;
    }
  }

  /// 競合の詳細情報を取得
  static ConflictInfo getConflictInfo<T extends SyncableModel>(
    T localData,
    T remoteData,
    [bool deterministicDeviceIdTieBreakWhenVersionEqual = false]
  ) {
    final resolution = detectConflict(
      localData,
      remoteData,
      deterministicDeviceIdTieBreakWhenVersionEqual,
    );
    final timeDifference = localData.lastModified.difference(remoteData.lastModified);
    
    return ConflictInfo(
      resolution: resolution,
      localVersion: localData.version,
      remoteVersion: remoteData.version,
      localLastModified: localData.lastModified,
      remoteLastModified: remoteData.lastModified,
      timeDifference: timeDifference,
      localDeviceId: localData.deviceId,
      remoteDeviceId: remoteData.deviceId,
      isSignificantConflict: _isSignificantConflict(resolution, timeDifference),
    );
  }

  /// 重要な競合かどうかを判定
  static bool _isSignificantConflict(
    ConflictResolution resolution,
    Duration timeDifference,
  ) {
    // 手動解決が必要な場合は重要
    if (resolution == ConflictResolution.needsManual) {
      return true;
    }

    // 1時間以上の差がある場合は重要
    if (timeDifference.abs().inHours >= 1) {
      return true;
    }

    return false;
  }
}

/// 競合の詳細情報
class ConflictInfo {
  final ConflictResolution resolution;
  final int localVersion;
  final int remoteVersion;
  final DateTime localLastModified;
  final DateTime remoteLastModified;
  final Duration timeDifference;
  final String localDeviceId;
  final String remoteDeviceId;
  final bool isSignificantConflict;

  ConflictInfo({
    required this.resolution,
    required this.localVersion,
    required this.remoteVersion,
    required this.localLastModified,
    required this.remoteLastModified,
    required this.timeDifference,
    required this.localDeviceId,
    required this.remoteDeviceId,
    required this.isSignificantConflict,
  });

  @override
  String toString() {
    return 'ConflictInfo{resolution: $resolution, '
        'versions: $localVersion vs $remoteVersion, '
        'timeDiff: ${timeDifference.inSeconds}s, '
        'significant: $isSignificantConflict}';
  }
}