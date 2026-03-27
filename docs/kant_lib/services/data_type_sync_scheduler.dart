import 'dart:async';

import 'network_manager.dart';
import 'auth_service.dart';
import 'actual_task_sync_service.dart';
import 'inbox_task_sync_service.dart';
import 'sync_context.dart';
import 'project_sync_service.dart';
import 'category_sync_service.dart';
import 'mode_sync_service.dart';
import 'block_sync_service.dart';
import 'sub_project_sync_service.dart';
import 'routine_template_v2_sync_service.dart';
import 'routine_block_v2_sync_service.dart';
import 'routine_task_v2_sync_service.dart';

/// 同期優先度レベル
enum SyncFrequency {
  realtime,   // リアルタイム（タスク操作時）
  high,       // 高頻度（30秒-2分）
  medium,     // 中頻度（3-5分）
  low,        // 低頻度（8-15分）
}

/// データ型別同期頻度管理システム
/// 使用頻度に応じた最適な同期間隔を設定
class DataTypeSyncScheduler {
  static final DataTypeSyncScheduler _instance = DataTypeSyncScheduler._internal();
  factory DataTypeSyncScheduler() => _instance;
  DataTypeSyncScheduler._internal();

  // 各データ型のタイマー
  static final Map<String, Timer?> _timers = {};
  static final Map<String, DateTime> _lastSyncTimes = {};
  static bool _isInitialized = false;

  /// データ型別同期間隔設定（使用頻度ベース）
  static final Map<String, Duration> _syncIntervals = {
    // 高頻度同期（タスク系）- 1日30回の書き込みに対応
    'actual_tasks': const Duration(seconds: 30),      // 最高頻度
    'inbox_tasks': const Duration(minutes: 1),       // 高頻度  
    
    // 中頻度同期（プロジェクト・設定系）
    'projects': const Duration(minutes: 5),          // 中頻度
    'sub_projects': const Duration(minutes: 5),      // 中頻度
    'blocks': const Duration(minutes: 3),            // 中高頻度（スケジュール関連）
    
    // 低頻度同期（マスタデータ系）
    'categories': const Duration(minutes: 10),       // 低頻度
    'modes': const Duration(minutes: 15),            // 低頻度
    // ルーティン（V2のみ）
    'routine_v2': const Duration(minutes: 5),        // 中低頻度
    
    // カレンダーは期間別同期のため除外
  };



  /// データ型の同期頻度分類
  static final Map<String, SyncFrequency> _syncFrequencies = {
    'actual_tasks': SyncFrequency.realtime,    // TaskSyncManagerで処理
    'inbox_tasks': SyncFrequency.high,
    'blocks': SyncFrequency.medium,
    'projects': SyncFrequency.medium,
    'sub_projects': SyncFrequency.medium,
    'categories': SyncFrequency.low,
    'modes': SyncFrequency.low,
    'routine_v2': SyncFrequency.low,
  };

  /// スケジューラーを初期化
  static Future<void> initialize() async {
    if (_isInitialized) return;
    
    // 各データ型の同期タイマーを開始
    for (final entry in _syncIntervals.entries) {
      _startSyncTimer(entry.key, entry.value);
    }
    
    // ネットワーク状態の監視
    NetworkManager.connectivityStream.listen((isOnline) {
      if (isOnline) {
        _resumeAllTimers();
      } else {
        _pauseAllTimers();
      }
    });
    
    _isInitialized = true;
  }

  /// 特定データ型の同期タイマーを開始
  static void _startSyncTimer(String dataType, Duration interval) {
    _timers[dataType]?.cancel();
    
    _timers[dataType] = Timer.periodic(interval, (timer) async {
      if (NetworkManager.isOnline && AuthService.isLoggedIn()) {
        await _performDataTypeSync(dataType);
      }
    });
  }

  /// 特定データ型の同期を実行
  static Future<void> _performDataTypeSync(String dataType) async {
    try {
      final startTime = DateTime.now();
      
      switch (dataType) {
        case 'actual_tasks':
          // ActualTaskはTaskSyncManagerで処理するため、ここでは軽量な差分チェックのみ
          await ActualTaskSyncService.syncAllTasks();
          break;
        case 'inbox_tasks':
          await SyncContext.runWithOrigin(
            'DataTypeSyncScheduler.inbox_tasks',
            () => InboxTaskSyncService.syncAllInboxTasks(),
          );
          break;
        case 'projects':
          await ProjectSyncService.syncAllProjects();
          break;
        case 'sub_projects':
          await SubProjectSyncService.syncAllSubProjects();
          break;
        case 'blocks':
          await BlockSyncService.syncAllBlocks();
          break;
        case 'categories':
          await CategorySyncService.syncAllCategories();
          break;
        case 'modes':
          await ModeSyncService.syncAllModes();
          break;
        case 'routine_v2':
          await RoutineTemplateV2SyncService.syncAll();
          await RoutineBlockV2SyncService.syncAll();
          await RoutineTaskV2SyncService.syncAll();
          break;
        default:
          print('⚠️ DataTypeSyncScheduler: Unknown data type: $dataType');
          return;
      }
      
      _lastSyncTimes[dataType] = DateTime.now();
    } catch (e) {
      print('❌ DataTypeSyncScheduler: Failed to sync $dataType: $e');
    }
  }

  /// 全タイマーを一時停止
  static void _pauseAllTimers() {
    for (final timer in _timers.values) {
      timer?.cancel();
    }
    _timers.clear();
  }

  /// 全タイマーを再開
  static void _resumeAllTimers() {
    for (final entry in _syncIntervals.entries) {
      _startSyncTimer(entry.key, entry.value);
    }
  }

  /// 特定データ型の同期間隔を動的変更
  static void updateSyncInterval(String dataType, Duration newInterval) {
    if (_syncIntervals.containsKey(dataType)) {
      _syncIntervals[dataType] = newInterval;
      _startSyncTimer(dataType, newInterval);
    }
  }

  /// 同期頻度を一時的に上げる（緊急同期モード）
  static void enableHighFrequencyMode(Duration duration) {
    final originalIntervals = Map<String, Duration>.from(_syncIntervals);
    
    // 全間隔を半分に短縮
    for (final entry in _syncIntervals.entries) {
      final newInterval = Duration(seconds: (entry.value.inSeconds / 2).round());
      updateSyncInterval(entry.key, newInterval);
    }
    
    // 指定時間後に元に戻す
    Timer(duration, () {
      for (final entry in originalIntervals.entries) {
        updateSyncInterval(entry.key, entry.value);
      }
    });
  }

  /// 低頻度モードに切り替え（省電力）
  static void enableLowPowerMode() {
    for (final entry in _syncIntervals.entries) {
      final newInterval = Duration(seconds: (entry.value.inSeconds * 2).round());
      updateSyncInterval(entry.key, newInterval);
    }
  }

  /// 通常モードに戻す
  static void restoreNormalMode() {
    // デフォルト間隔に戻す
    final defaultIntervals = {
      'actual_tasks': const Duration(seconds: 30),
      'inbox_tasks': const Duration(minutes: 1),
      'projects': const Duration(minutes: 5),
      'sub_projects': const Duration(minutes: 5),
      'blocks': const Duration(minutes: 3),
      'categories': const Duration(minutes: 10),
      'modes': const Duration(minutes: 15),
      'routine_v2': const Duration(minutes: 5),
    };
    
    for (final entry in defaultIntervals.entries) {
      updateSyncInterval(entry.key, entry.value);
    }
  }

  /// 1日あたりの同期回数を計算
  static int _calculateDailySyncCount() {
    int totalSyncs = 0;
    const secondsPerDay = 24 * 60 * 60;
    
    for (final interval in _syncIntervals.values) {
      totalSyncs += (secondsPerDay / interval.inSeconds).round();
    }
    
    return totalSyncs;
  }

  /// 最終同期時刻を取得
  static DateTime? getLastSyncTime(String dataType) {
    return _lastSyncTimes[dataType];
  }

  /// 全データ型の最終同期時刻を取得
  static Map<String, DateTime> getAllLastSyncTimes() {
    return Map.unmodifiable(_lastSyncTimes);
  }

  /// スケジューラーを停止
  static void dispose() {
    for (final timer in _timers.values) {
      timer?.cancel();
    }
    _timers.clear();
    _lastSyncTimes.clear();
    _isInitialized = false;
  }

  /// 現在の設定状態を取得
  static Map<String, dynamic> getStatus() {
    return {
      'initialized': _isInitialized,
      'active_timers': _timers.length,
      'sync_intervals': _syncIntervals,
      'last_sync_times': _lastSyncTimes,
      'estimated_daily_syncs': _calculateDailySyncCount(),
    };
  }
}