import 'package:hive/hive.dart';
import 'dart:async';
import '../models/routine_block_v2.dart';
import 'auth_service.dart';

class RoutineBlockV2Service {
  static const String _canonicalShortcutTemplateId = 'shortcut';
  static const String _canonicalShortcutBlockId = 'v2blk_shortcut_0';

  static void applyCanonicalShortcutBlockTemplateId(RoutineBlockV2 block) {
    if (block.id == _canonicalShortcutBlockId &&
        block.routineTemplateId != _canonicalShortcutTemplateId) {
      block.routineTemplateId = _canonicalShortcutTemplateId;
    }
  }

  static Box<RoutineBlockV2>? _box;
  static bool _opening = false;
  static bool _deferNotify = false;
  static final StreamController<void> _updateController = StreamController<void>.broadcast();
  static Stream<void> get updateStream => _updateController.stream;
  static void _notify() {
    if (_deferNotify) return;
    try {
      _updateController.add(null);
    } catch (_) {}
  }

  /// 一括追加時にUIの都度更新を避けるため。true の間は notify を抑止し、false で1回だけ通知する。
  static void deferNotifications(bool defer) {
    _deferNotify = defer;
    if (!defer) {
      try {
        _updateController.add(null);
      } catch (_) {}
    }
  }

  static Future<void> initialize() async {
    _ensureAdapterRegistered();
    _box = await Hive.openBox<RoutineBlockV2>('routine_blocks_v2');
  }

  static void _ensureAdapterRegistered() {
    try {
      // main.dart での一括登録に失敗/スキップされたケースでも V2 box が開けるようにする。
      if (!Hive.isAdapterRegistered(27)) {
        Hive.registerAdapter(RoutineBlockV2Adapter());
      }
    } catch (e, st) {
      try {
        print('❌ Hive adapter registration failed (RoutineBlockV2): $e');
        print(st);
      } catch (_) {}
    }
  }

  static Future<void> _ensureOpen() async {
    if (_box != null && _box!.isOpen) return;
    if (_opening) {
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 30));
        if (_box != null && _box!.isOpen) return;
      }
    }
    _opening = true;
    try {
      _ensureAdapterRegistered();
      _box = await Hive.openBox<RoutineBlockV2>('routine_blocks_v2');
    } finally {
      _opening = false;
    }
  }

  /// 同期実行前にボックスが開いていることを保証する（Web等で post-auth が deferred より先に走る対策）
  static Future<void> ensureOpen() => _ensureOpen();

  static Box<RoutineBlockV2> get _safeBox {
    if (_box == null) {
      throw StateError('RoutineBlockV2Service not initialized');
    }
    return _box!;
  }

  static Future<void> add(RoutineBlockV2 block) async {
    await _ensureOpen();
    applyCanonicalShortcutBlockTemplateId(block);
    await _safeBox.put(block.id, block);
    await _safeBox.flush();
    _notify();
  }

  static Future<void> update(RoutineBlockV2 block) async {
    await _ensureOpen();
    applyCanonicalShortcutBlockTemplateId(block);
    await _safeBox.put(block.id, block);
    await _safeBox.flush();
    _notify();
  }

  static Future<void> delete(String id) async {
    await _ensureOpen();
    await _safeBox.delete(id);
    await _safeBox.flush();
    _notify();
  }

  static RoutineBlockV2? getById(String id) {
    try {
      final uid = AuthService.getCurrentUserId();
      if (uid == null || uid.isEmpty) return null;
      final b = _safeBox.get(id);
      if (b == null || b.userId != uid) return null;
      return b;
    } catch (_) {
      return null;
    }
  }

  static List<RoutineBlockV2> getAllByTemplate(String templateId) {
    try {
      final uid = AuthService.getCurrentUserId();
      if (uid == null || uid.isEmpty) return [];
      return _safeBox.values
          .where((b) {
            if (b.isDeleted || b.routineTemplateId != templateId) return false;
            return b.userId == uid;
          })
          .toList()
        ..sort((a, b) {
          final t1 = a.startTime.hour * 60 + a.startTime.minute;
          final t2 = b.startTime.hour * 60 + b.startTime.minute;
          if (t1 != t2) return t1.compareTo(t2);
          return a.order.compareTo(b.order);
        });
    } catch (_) {
      return [];
    }
  }

  static List<RoutineBlockV2> getAll() {
    try {
      final uid = AuthService.getCurrentUserId();
      if (uid == null || uid.isEmpty) return [];
      return _safeBox.values
          .where((b) => !b.isDeleted && b.userId == uid)
          .toList()
        ..sort((a, b) => a.lastModified.compareTo(b.lastModified));
    } catch (_) {
      return [];
    }
  }

  /// デバッグ用途：ユーザーIDのフィルタを掛けずに全件取得
  static List<RoutineBlockV2> debugGetAllRaw() {
    try {
      return _safeBox.values.toList();
    } catch (_) {
      return [];
    }
  }

  /// 開発者メニュー用：userId が空（または空白のみ）のブロックを現在ユーザーで上書き。
  static Future<int> runUserIdBackfillForAdmin() async {
    final uid = AuthService.getCurrentUserId();
    if (uid == null || uid.isEmpty) return 0;
    await _ensureOpen();
    int count = 0;
    for (final b in _safeBox.values.toList()) {
      if (b.userId.trim().isNotEmpty) continue;
      final updated = b.copyWith(
        userId: uid,
        lastModified: DateTime.now().toUtc(),
        version: b.version + 1,
      );
      await update(updated);
      count++;
    }
    return count;
  }

  // すべてのルーティンブロックをクリア
  static Future<void> clearAll() async {
    await initialize();
    await _box?.clear();
  }
}
