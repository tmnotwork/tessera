import 'package:hive_flutter/hive_flutter.dart';

import '../models/mode.dart';
import '../utils/hive_open_with_retry.dart';
import '../services/auth_service.dart';

class ModeService {
  static const String _boxName = 'modes';
  static Box<Mode>? _box;
  static bool _opening = false;

  static Future<void> _ensureBoxOpen() async {
    if (_box != null && _box!.isOpen) return;
    if (_opening) {
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 30));
        if (_box != null && _box!.isOpen) return;
      }
    }
    _opening = true;
    try {
      _box = await openBoxWithRetry<Mode>(_boxName);
    } finally {
      _opening = false;
    }
  }

  static Future<T> _retryOnIdbClosing<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('database connection is closing') ||
          msg.contains('InvalidStateError') ||
          msg.contains('Failed to execute "transaction"')) {
        await _ensureBoxOpen();
        return await action();
      }
      rethrow;
    }
  }

  // 初期化
  static Future<void> initialize() async {
    await _ensureBoxOpen();
  }

  /// 同期等で getLocalItems の前に呼ぶ。未初期化でもボックスを開いてから取得できるようにする。
  static Future<void> ensureOpen() async => _ensureBoxOpen();

  /// タイムライン等で名前解決する前に参照。未初期化時は行を出さない判定に使う。
  static bool get isReady => _box != null && _box!.isOpen;

  // ボックスを取得（内部・書き込み用。未初期化時は throw）
  static Box<Mode> get box {
    if (_box == null) {
      throw Exception('ModeServiceが初期化されていません');
    }
    return _box!;
  }

  // 全モードを取得（未初期化時は空リスト）
  static List<Mode> getAllModes() {
    if (_box == null || !_box!.isOpen) return [];
    final currentUser = AuthService.getCurrentUser();
    if (currentUser == null) return [];

    final modes =
        _box!.values
            .where((mode) => mode.userId == currentUser.id && mode.isActive)
            .toList();

    // 「集中」を一番上に、その他は名前順でソート
    modes.sort((a, b) {
      if (a.name == '集中' && b.name != '集中') return -1;
      if (a.name != '集中' && b.name == '集中') return 1;
      return a.name.compareTo(b.name);
    });

    return modes;
  }

  // モードをIDで取得（現在ユーザー所有のみ返す）
  static Mode? getModeById(String id) {
    if (_box == null || !_box!.isOpen) return null;
    final uid = AuthService.getCurrentUserId();
    if (uid == null || uid.isEmpty) return null;
    final mode = _box!.get(id);
    if (mode == null || mode.userId != uid) return null;
    return mode;
  }

  // モードを追加
  static Future<void> addMode(Mode mode) async {
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async => box.put(mode.id, mode));
  }

  // モードを更新
  static Future<void> updateMode(
    Mode mode, {
    bool touchLastModified = true,
  }) async {
    final updatedMode = touchLastModified
        ? mode.copyWith(lastModified: DateTime.now())
        : mode;
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async => box.put(updatedMode.id, updatedMode));
  }

  // モードを削除（論理削除）
  static Future<void> deleteMode(
    String id, {
    bool touchLastModified = true,
  }) async {
    final mode = box.get(id);
    if (mode != null) {
      final DateTime nextLastModified =
          touchLastModified ? DateTime.now() : mode.lastModified;
      final deletedMode = mode.copyWith(
        isActive: false,
        lastModified: nextLastModified,
      );
      await _ensureBoxOpen();
      await _retryOnIdbClosing(() async => box.put(id, deletedMode));
    }
  }

  // モードを物理削除
  static Future<void> permanentlyDeleteMode(String id) async {
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async => box.delete(id));
  }

  // デフォルトモードを作成
  static Future<void> createDefaultModes() async {
    final currentUser = AuthService.getCurrentUser();
    if (currentUser == null) return;

    // 注意: このメソッドを直接呼ぶのではなく、
    // createDefaultModesWithSync() を使用することを推奨
    
    final now = DateTime.now();
    final defaultModes = [
      Mode(
        id: 'mode_focus',
        name: '集中',
        description: '集中して取り組むタスク',
        userId: currentUser.id,
        createdAt: now,
        lastModified: now,
      ),
      Mode(
        id: 'mode_gap',
        name: 'スキマ時間',
        description: '短時間でできるタスク',
        userId: currentUser.id,
        createdAt: now,
        lastModified: now,
      ),
      Mode(
        id: 'mode_audio',
        name: '耳だけ',
        description: '音声のみでできるタスク',
        userId: currentUser.id,
        createdAt: now,
        lastModified: now,
      ),
    ];

    for (final mode in defaultModes) {
      if (getModeById(mode.id) == null) {
        await addMode(mode);
      }
    }
  }

  // ボックスを閉じる
  static Future<void> close() async {
    await _box?.close();
  }

  // すべてのモードをクリア
  static Future<void> clearAll() async {
    await _ensureBoxOpen();
    await _box?.clear();
  }
}
