import 'package:hive/hive.dart';
import 'dart:async';
import '../models/routine_task_v2.dart';
import 'auth_service.dart';

class RoutineTaskV2Service {
  static const String _canonicalShortcutTemplateId = 'shortcut';
  static const String _canonicalShortcutBlockId = 'v2blk_shortcut_0';

  /// 正規ショートカットブロック上のタスクは常に templateId [shortcut]（編集画面・FAB・クエリの一致用）
  static void applyCanonicalShortcutBundleTaskIds(RoutineTaskV2 task) {
    if (task.routineBlockId == _canonicalShortcutBlockId &&
        task.routineTemplateId != _canonicalShortcutTemplateId) {
      task.routineTemplateId = _canonicalShortcutTemplateId;
    }
  }

  static Box<RoutineTaskV2>? _box;
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
    _box = await Hive.openBox<RoutineTaskV2>('routine_tasks_v2');
  }

  static void _ensureAdapterRegistered() {
    try {
      // V2 box がオンデマンドで開かれるケースでも壊れないよう、ここでも登録を担保する。
      // main.dart で登録済みなら何もしない。
      if (!Hive.isAdapterRegistered(28)) {
        Hive.registerAdapter(RoutineTaskV2Adapter());
      }
    } catch (e, st) {
      try {
        print('❌ Hive adapter registration failed (RoutineTaskV2): $e');
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
      _box = await Hive.openBox<RoutineTaskV2>('routine_tasks_v2');
    } finally {
      _opening = false;
    }
  }

  /// 同期実行前にボックスが開いていることを保証する（Web等で post-auth が deferred より先に走る対策）
  static Future<void> ensureOpen() => _ensureOpen();

  static Box<RoutineTaskV2> get _safeBox {
    if (_box == null) {
      throw StateError('RoutineTaskV2Service not initialized');
    }
    return _box!;
  }

  static Future<void> add(RoutineTaskV2 task) async {
    await _ensureOpen();
    applyCanonicalShortcutBundleTaskIds(task);
    await _safeBox.put(task.id, task);
    await _safeBox.flush();
    _notify();
  }

  static Future<void> update(RoutineTaskV2 task) async {
    await _ensureOpen();
    applyCanonicalShortcutBundleTaskIds(task);
    await _safeBox.put(task.id, task);
    await _safeBox.flush();
    _notify();
  }

  static Future<void> delete(String id) async {
    await _ensureOpen();
    await _safeBox.delete(id);
    await _safeBox.flush();
    _notify();
  }

  static Future<void> deleteByTemplate(String templateId) async {
    await _ensureOpen();
    final keys = _safeBox.values
        .where((task) => task.routineTemplateId == templateId)
        .map((task) => task.id)
        .toList();
    if (keys.isEmpty) return;
    await _safeBox.deleteAll(keys);
    await _safeBox.flush();
    _notify();
  }

  static RoutineTaskV2? getById(String id) {
    try {
      final uid = AuthService.getCurrentUserId();
      if (uid == null || uid.isEmpty) return null;
      final t = _safeBox.get(id);
      if (t == null || t.userId != uid) return null;
      return t;
    } catch (_) {
      return null;
    }
  }

  static List<RoutineTaskV2> getByBlock(String blockId) {
    try {
      final uid = AuthService.getCurrentUserId();
      if (uid == null || uid.isEmpty) return [];
      return _safeBox.values
          .where((t) {
            if (t.isDeleted || t.routineBlockId != blockId) return false;
            return t.userId == uid;
          })
          .toList()
        ..sort((a, b) => a.order.compareTo(b.order));
    } catch (_) {
      return [];
    }
  }

  /// ショートカット編集/FABで共通利用する正規クエリ。
  /// blockId と templateId の両方を固定し、現在ユーザーの未削除タスクのみ返す。
  static List<RoutineTaskV2> getCanonicalShortcutTasksForCurrentUser() {
    try {
      final uid = AuthService.getCurrentUserId();
      if (uid == null || uid.isEmpty) return [];
      return _safeBox.values
          .where((t) {
            if (t.isDeleted) return false;
            if (t.userId != uid) return false;
            if (t.routineBlockId != _canonicalShortcutBlockId) return false;
            return t.routineTemplateId == _canonicalShortcutTemplateId;
          })
          .toList()
        ..sort((a, b) => a.order.compareTo(b.order));
    } catch (_) {
      return [];
    }
  }

  /// Hiveボックス更新イベント（UIの再描画トリガー用途）
  static Stream<BoxEvent> watchAll() {
    return _safeBox.watch();
  }

  static List<RoutineTaskV2> getByTemplate(String templateId) {
    try {
      final uid = AuthService.getCurrentUserId();
      if (uid == null || uid.isEmpty) return [];
      return _safeBox.values
          .where((t) {
            if (t.isDeleted || t.routineTemplateId != templateId) return false;
            return t.userId == uid;
          })
          .toList()
        ..sort((a, b) {
          final byBlock = tiebreakBlock(a.routineBlockId).compareTo(tiebreakBlock(b.routineBlockId));
          if (byBlock != 0) return byBlock;
          return a.order.compareTo(b.order);
        });
    } catch (_) {
      return [];
    }
  }

  // 簡易のタイブレークキー（安定ソート用）
  static String tiebreakBlock(String id) => id;

  /// デバッグ用途：ユーザーIDのフィルタを掛けずに全件取得
  static List<RoutineTaskV2> debugGetAllRaw() {
    try {
      return _safeBox.values.toList();
    } catch (_) {
      return [];
    }
  }

  /// 開発者メニュー用：ローカルHive内で userId が空（または空白のみ）のルーティンタスクを現在ユーザーで上書きする。
  /// getByBlock/getByTemplate は userId でフィルタするため、未付与タスクはショートカット一覧等に出ない。救済用。
  static Future<int> runUserIdBackfillForAdmin() async {
    final uid = AuthService.getCurrentUserId();
    if (uid == null || uid.isEmpty) return 0;
    await _ensureOpen();
    int count = 0;
    for (final t in _safeBox.values.toList()) {
      if (t.userId.trim().isEmpty) {
        final updated = t.copyWith(userId: uid);
        await update(updated);
        count++;
      }
    }
    return count;
  }

  /// 開発者メニュー用：ショートカット正規ID（templateId='shortcut', blockId='v2blk_shortcut_0'）の
  /// タスクを対象に、userId が現在ユーザーと異なる場合も含めて強制的に上書きする。
  /// userId が空でなく「別ユーザーのID」が入っているためショートカットが表示されない場合の救済用。
  static Future<int> runShortcutUserIdForceFixForAdmin() async {
    const shortcutTemplateId = 'shortcut';
    const shortcutBlockId = 'v2blk_shortcut_0';
    final uid = AuthService.getCurrentUserId();
    if (uid == null || uid.isEmpty) return 0;
    await _ensureOpen();
    int count = 0;
    for (final t in _safeBox.values.toList()) {
      if (t.isDeleted) continue;
      if (t.routineTemplateId != shortcutTemplateId ||
          t.routineBlockId != shortcutBlockId) continue;
      if (t.userId == uid) continue;
      final updated = t.copyWith(userId: uid);
      await update(updated);
      count++;
    }
    return count;
  }

  // すべてのルーティンタスクをクリア
  static Future<void> clearAll() async {
    await initialize();
    await _box?.clear();
  }
}
