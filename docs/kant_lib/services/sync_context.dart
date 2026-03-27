import 'dart:async';

/// 同期の「起動元（トリガー）」を async の呼び出し連鎖に載せて伝播させる。
///
/// 目的:
/// - 履歴上で「なぜ同じ collection の diffFetch が二重に走ったか」を確定できるようにする。
/// - SyncManager 経由/直呼び（Widget/Tab切替/強制同期）を区別する。
class SyncContext {
  SyncContext._();

  static const Symbol _kOrigin = #syncOrigin;

  static String? get origin {
    final v = Zone.current[_kOrigin];
    return v is String && v.isNotEmpty ? v : null;
  }

  static Future<T> runWithOrigin<T>(
    String origin,
    Future<T> Function() fn,
  ) {
    final tag = origin.trim();
    if (tag.isEmpty) return fn();
    return runZoned(fn, zoneValues: <Object?, Object?>{_kOrigin: tag});
  }

  /// 既に origin が付いている場合は上書きしない（内側の処理が外側の原因を潰さないようにする）。
  static Future<T> runWithOriginIfAbsent<T>(
    String origin,
    Future<T> Function() fn,
  ) {
    if (SyncContext.origin != null) return fn();
    return runWithOrigin(origin, fn);
  }
}

