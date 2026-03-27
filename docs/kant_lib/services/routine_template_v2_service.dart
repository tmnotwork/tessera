import 'dart:async';

import 'package:hive/hive.dart';

import '../models/routine_template_v2.dart';
import 'auth_service.dart';

class RoutineTemplateV2Service {
  static Box<RoutineTemplateV2>? _box;
  static bool _opening = false;
  static bool _deferNotify = false;
  static final StreamController<void> _updateController =
      StreamController<void>.broadcast();

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
    _box = await Hive.openBox<RoutineTemplateV2>('routine_templates_v2');
  }

  static void _ensureAdapterRegistered() {
    try {
      // main.dart での登録が失敗/未実行でも、V2テンプレの永続化が動くようにする。
      if (!Hive.isAdapterRegistered(29)) {
        Hive.registerAdapter(RoutineTemplateV2Adapter());
      }
    } catch (e, st) {
      // 既に登録済み/並行初期化等は無視
      try {
        print('❌ Hive adapter registration failed (RoutineTemplateV2): $e');
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
      _box = await Hive.openBox<RoutineTemplateV2>('routine_templates_v2');
    } finally {
      _opening = false;
    }
  }

  /// 同期実行前にボックスが開いていることを保証する（Web等で post-auth が deferred より先に走る対策）
  static Future<void> ensureOpen() => _ensureOpen();

  static Box<RoutineTemplateV2> get _safeBox {
    if (_box == null) {
      throw StateError('RoutineTemplateV2Service not initialized');
    }
    return _box!;
  }

  /// 予約ドキュメント `shortcut` は常にショートカット扱い（新規ユーザー・同期の取りこぼしを永続化層で防ぐ）
  static void applyCanonicalShortcutTemplateFlags(RoutineTemplateV2 template) {
    if (template.id == 'shortcut' || template.cloudId == 'shortcut') {
      template.isShortcut = true;
    }
  }

  static Future<void> add(RoutineTemplateV2 template) async {
    await _ensureOpen();
    applyCanonicalShortcutTemplateFlags(template);
    await _safeBox.put(template.id, template);
    await _safeBox.flush();
    _notify();
  }

  static Future<void> update(RoutineTemplateV2 template) async {
    await _ensureOpen();
    applyCanonicalShortcutTemplateFlags(template);
    await _safeBox.put(template.id, template);
    await _safeBox.flush();
    _notify();
  }

  static RoutineTemplateV2? getById(String id) {
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

  static List<RoutineTemplateV2> getAll({bool includeDeleted = false}) {
    try {
      final uid = AuthService.getCurrentUserId();
      if (uid == null || uid.isEmpty) return [];
      final list = _safeBox.values
          .where((t) {
            if (!includeDeleted && t.isDeleted == true) return false;
            return t.userId == uid;
          })
          .toList();
      list.sort((a, b) => a.title.compareTo(b.title));
      return list;
    } catch (_) {
      return [];
    }
  }

  static List<RoutineTemplateV2> debugGetAllRaw() {
    try {
      return _safeBox.values.toList();
    } catch (_) {
      return [];
    }
  }

  /// 開発者メニュー用：userId が空（または空白のみ）のテンプレを現在ユーザーで上書き。
  /// getById/getAll は userId でフィルタするため、未付与だとルーティン・ショートカットが見えない要因になる。
  static Future<int> runUserIdBackfillForAdmin() async {
    final uid = AuthService.getCurrentUserId();
    if (uid == null || uid.isEmpty) return 0;
    await _ensureOpen();
    int count = 0;
    for (final t in _safeBox.values.toList()) {
      if (t.userId.trim().isNotEmpty) continue;
      final now = DateTime.now().toUtc();
      final updated = RoutineTemplateV2(
        id: t.id,
        title: t.title,
        memo: t.memo,
        workType: t.workType,
        color: t.color,
        applyDayType: t.applyDayType,
        isActive: t.isActive,
        cloudId: t.cloudId,
        lastSynced: t.lastSynced,
        isDeleted: t.isDeleted,
        deviceId: t.deviceId,
        version: t.version + 1,
        userId: uid,
        createdAt: t.createdAt,
        lastModified: now,
        isShortcut: t.isShortcut,
      );
      await update(updated);
      count++;
    }
    return count;
  }

  // すべてのルーティンテンプレートをクリア
  static Future<void> clearAll() async {
    await initialize();
    await _box?.clear();
  }
}

