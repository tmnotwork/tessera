import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hive/hive.dart';

/// Web で IndexedDB が他タブと競合した場合に備え、失敗時に指数バックオフでリトライする。
/// ネイティブでは [Hive.openBox] を 1 回だけ呼ぶ。
Future<Box<T>> openBoxWithRetry<T>(String name) async {
  if (!kIsWeb) {
    return Hive.openBox<T>(name);
  }
  const delaysMs = [500, 1000, 2000, 4000];
  for (var i = 0; i <= delaysMs.length; i++) {
    try {
      return await Hive.openBox<T>(name);
    } catch (e) {
      if (i == delaysMs.length) rethrow;
      await Future<void>.delayed(Duration(milliseconds: delaysMs[i]));
    }
  }
  throw StateError('unreachable');
}
