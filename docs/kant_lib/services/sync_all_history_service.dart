import 'dart:convert';

import 'app_settings_service.dart';
import 'block_outbox_manager.dart';
import 'sync_kpi.dart';
import 'task_batch_sync_manager.dart';
import 'task_outbox_manager.dart';

/// 同期/読取の起動理由（トリガー）をアプリ内に履歴保存する。
///
/// 目的:
/// - ログではなく、設定画面の管理メニューから「なぜ read が発生したか」を後から確認できるようにする。
///
/// 方針:
/// - Hive の型互換で事故らないよう、履歴は JSON 文字列として AppSettings に保存する。
/// - 履歴件数は上限を設け、古いものから削除する。
class SyncAllHistoryService {
  static const String _key = 'debug.syncAll.history.v1';
  // 調査用ログは burst しやすい（cursorRead/localBoxState等）。
  // 原因特定が終わるまで保持件数を増やし、重要イベントが押し出されないようにする。
  static const int _maxEntries = 2000;

  static Future<List<Map<String, dynamic>>> load() async {
    try {
      await AppSettingsService.initialize();
      final raw = AppSettingsService.getString(_key);
      if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> clear() async {
    try {
      await AppSettingsService.initialize();
      await AppSettingsService.setString(_key, '[]');
    } catch (_) {}
  }

  static Map<String, dynamic> _kpiSnapshot() {
    // 数値は “概算” だが、原因切り分けに有用。
    // ignore: avoid_print
    try {
      // late import回避のため動的参照にしない。ここは同期系のみで使用される想定。
      // 直接参照できない環境でも落とさない。
      // ignore: undefined_identifier
      return {
        // ignore: undefined_identifier
        'queryReads': SyncKpi.queryReads,
        // ignore: undefined_identifier
        'docGets': SyncKpi.docGets,
        // ignore: undefined_identifier
        'preWriteChecks': SyncKpi.preWriteChecks,
        // ignore: undefined_identifier
        'writes': SyncKpi.writes,
        // ignore: undefined_identifier
        'batchCommits': SyncKpi.batchCommits,
        // ignore: undefined_identifier
        'watchStarts': SyncKpi.watchStarts,
        // ignore: undefined_identifier
        'watchInitialReads': SyncKpi.watchInitialReads,
        // ignore: undefined_identifier
        'watchChangeReads': SyncKpi.watchChangeReads,
        // ignore: undefined_identifier
        'onDemandFetches': SyncKpi.onDemandFetches,
        // ignore: undefined_identifier
        'versionFeedEvents': SyncKpi.versionFeedEvents,
      };
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Map<String, dynamic> _kpiDelta(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) {
    int d(String k) {
      final b = before[k];
      final a = after[k];
      if (b is int && a is int) return a - b;
      return 0;
    }

    return <String, dynamic>{
      'queryReads': d('queryReads'),
      'docGets': d('docGets'),
      'preWriteChecks': d('preWriteChecks'),
      'writes': d('writes'),
      'batchCommits': d('batchCommits'),
      'watchStarts': d('watchStarts'),
      'watchInitialReads': d('watchInitialReads'),
      'watchChangeReads': d('watchChangeReads'),
      'onDemandFetches': d('onDemandFetches'),
      'versionFeedEvents': d('versionFeedEvents'),
    };
  }

  /// 未送信（outbox / batch）の滞留状況を履歴へ残すためのスナップショット。
  ///
  /// 目的:
  /// - 「未送信が残っているか？」を“履歴画面”だけで判定できるようにする。
  /// - ネットワーク/エラーで送信が詰まっている場合、read/write多発の根因になりやすい。
  ///
  /// NOTE:
  /// - 依存サービスの初期化タイミングに左右されるため best-effort（失敗しても落とさない）。
  static Future<Map<String, int>> _pendingSnapshot() async {
    final out = <String, int>{};
    try {
      // TaskOutbox は "送信すべきタスク操作" の永続キュー。
      final list = await TaskOutboxManager.snapshot();
      out['taskOutbox'] = list.length;
    } catch (_) {}
    try {
      // BlockOutbox は "送信すべきブロック操作" の永続キュー。
      out['blockOutbox'] = await BlockOutboxManager.pendingCount();
    } catch (_) {}
    try {
      // TaskBatch はメモリ上の pending（永続ストアからの復元を含む）。
      final stats = TaskBatchSyncManager.getBatchStatistics();
      final v = stats['pending_operations'];
      if (v is int) {
        out['taskBatch'] = v;
      }
    } catch (_) {}
    return out;
  }

  static Future<String> recordStart({
    required String reason,
    String? origin,
    String? userId,
    Map<String, dynamic>? extra,
  }) async {
    return recordEventStart(
      type: 'syncAll',
      reason: reason,
      origin: origin,
      userId: userId,
      extra: extra,
    );
  }

  static Future<String> recordEventStart({
    required String type,
    required String reason,
    String? origin,
    String? userId,
    Map<String, dynamic>? extra,
    bool includeKpiSnapshot = true,
  }) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final now = DateTime.now().toUtc().toIso8601String();
    final kpiBefore = includeKpiSnapshot ? _kpiSnapshot() : null;
    Map<String, int> pendingStart = const <String, int>{};
    try {
      pendingStart = await _pendingSnapshot();
    } catch (_) {}
    final mergedExtra = <String, dynamic>{
      if (extra != null && extra.isNotEmpty) ...extra,
      if (pendingStart.isNotEmpty) 'pendingStart': pendingStart,
    };
    final entry = <String, dynamic>{
      'id': id,
      'type': type, // syncAll | widgetSync | versionFeed | watchStart | fullFetch | ...
      'startedAtUtc': now,
      'endedAtUtc': null,
      'reason': reason,
      'origin': origin,
      'userId': userId,
      'status': 'started', // started | finished | skipped | failed
      'success': null,
      'syncedCount': null,
      'failedCount': null,
      'error': null,
      if (mergedExtra.isNotEmpty) 'extra': mergedExtra,
      if (kpiBefore != null && kpiBefore.isNotEmpty) 'kpiBefore': kpiBefore,
    };

    try {
      final items = await load();
      items.insert(0, entry);
      if (items.length > _maxEntries) {
        items.removeRange(_maxEntries, items.length);
      }
      await _save(items);
    } catch (_) {}

    return id;
  }

  static Future<void> recordFinish({
    required String id,
    required bool success,
    int? syncedCount,
    int? failedCount,
    String? error,
    Map<String, dynamic>? extra,
    bool includeKpiDelta = true,
  }) async {
    Map<String, dynamic>? kpiDelta;
    if (includeKpiDelta) {
      try {
        final items = await load();
        final idx = items.indexWhere((e) => e['id'] == id);
        if (idx >= 0) {
          final before = items[idx]['kpiBefore'];
          if (before is Map) {
            final after = _kpiSnapshot();
            kpiDelta = _kpiDelta(Map<String, dynamic>.from(before), after);
          }
        }
      } catch (_) {}
    }
    await _update(
      id: id,
      patch: <String, dynamic>{
        'endedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'status': 'finished',
        'success': success,
        'syncedCount': syncedCount,
        'failedCount': failedCount,
        'error': error,
        if (extra != null && extra.isNotEmpty) 'extra': extra,
        if (kpiDelta != null && kpiDelta.isNotEmpty) 'kpiDelta': kpiDelta,
      },
    );
    // finish 時点の未送信状況を extra に追記（_update が extra をマージする）
    try {
      final pendingEnd = await _pendingSnapshot();
      if (pendingEnd.isNotEmpty) {
        await _update(
          id: id,
          patch: <String, dynamic>{
            'extra': <String, dynamic>{'pendingEnd': pendingEnd},
          },
        );
      }
    } catch (_) {}
  }

  static Future<void> recordSkipped({
    required String id,
    required String reason,
    Map<String, dynamic>? extra,
  }) async {
    await _update(
      id: id,
      patch: <String, dynamic>{
        'endedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'status': 'skipped',
        'success': false,
        'error': reason,
        if (extra != null && extra.isNotEmpty) 'extra': extra,
      },
    );
  }

  static Future<void> recordFailed({
    required String id,
    required String error,
    Map<String, dynamic>? extra,
  }) async {
    await _update(
      id: id,
      patch: <String, dynamic>{
        'endedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'status': 'failed',
        'success': false,
        'error': error,
        if (extra != null && extra.isNotEmpty) 'extra': extra,
      },
    );
  }

  /// 一回完結の軽量イベント（start+finish）を記録する。
  static Future<void> recordSimpleEvent({
    required String type,
    required String reason,
    String? origin,
    String? userId,
    Map<String, dynamic>? extra,
  }) async {
    final id = await recordEventStart(
      type: type,
      reason: reason,
      origin: origin,
      userId: userId,
      extra: extra,
    );
    await recordFinish(id: id, success: true);
  }

  static Future<void> _update({
    required String id,
    required Map<String, dynamic> patch,
  }) async {
    try {
      final items = await load();
      final idx = items.indexWhere((e) => e['id'] == id);
      if (idx < 0) return;
      final next = <String, dynamic>{...items[idx], ...patch};
      // extra は追記型でマージする（上書きで情報が消えないように）
      try {
        final prevExtra = items[idx]['extra'];
        final patchExtra = patch['extra'];
        if (prevExtra is Map && patchExtra is Map) {
          next['extra'] = <String, dynamic>{
            ...Map<String, dynamic>.from(prevExtra),
            ...Map<String, dynamic>.from(patchExtra),
          };
        }
      } catch (_) {}
      items[idx] = next;
      await _save(items);
    } catch (_) {}
  }

  static Future<void> _save(List<Map<String, dynamic>> items) async {
    try {
      await AppSettingsService.initialize();
      await AppSettingsService.setString(_key, jsonEncode(items));
    } catch (_) {}
  }
}

