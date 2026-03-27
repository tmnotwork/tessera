import 'app_settings_service.dart';

/// ルーティンV2用の Lamport clock（論理時計）
///
/// - 端末時計ズレに依存しない決定的な競合解決のために version を単調増加にする。
/// - ローカルで変更を作る前に next() を呼び、取得した値を doc.version に設定する。
/// - pull時に observe(remoteVersion) を呼び、カウンタを max に引き上げる。
class RoutineLamportClockService {
  RoutineLamportClockService._();

  static const String _key = 'routine.v2.lamport_counter';

  static Future<void> ensureInitialized() async {
    await AppSettingsService.initialize();
  }

  /// シングルアイソレート前提の簡易ミューテックス（逐次実行キュー）
  ///
  /// 重要: `Future<void>` を `Future<int>` 等に `as` キャストすると Web で実行時TypeErrorになるため、
  /// 戻り値は「この呼び出しのタスク（Future<T>）」をそのまま返す。
  static Future<void> _queue = Future<void>.value();

  static Future<T> _synchronized<T>(Future<T> Function() fn) {
    final task = _queue.then((_) => fn());
    // 失敗してもキューが詰まらないように、次のタスクへ進めるための“完了Future<void>”に潰す
    _queue = task.then((_) => null, onError: (_) => null);
    return task;
  }

  static Future<int> current() async {
    await ensureInitialized();
    return AppSettingsService.getInt(_key, defaultValue: 0);
  }

  /// 次の Lamport version を払い出す（永続化）
  static Future<int> next() async {
    return _synchronized(() async {
      await ensureInitialized();
      final cur = AppSettingsService.getInt(_key, defaultValue: 0);
      final next = cur + 1;
      await AppSettingsService.setInt(_key, next);
      return next;
    });
  }

  /// リモート取り込み時に呼び、ローカルカウンタを引き上げる
  static Future<void> observe(int? remoteVersion) async {
    if (remoteVersion == null) return;
    if (remoteVersion <= 0) return;
    return _synchronized(() async {
      await ensureInitialized();
      final cur = AppSettingsService.getInt(_key, defaultValue: 0);
      if (remoteVersion > cur) {
        await AppSettingsService.setInt(_key, remoteVersion);
      }
    });
  }
}

