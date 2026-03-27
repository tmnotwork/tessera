import 'package:hive_flutter/hive_flutter.dart';

import '../models/category.dart';
import '../utils/hive_open_with_retry.dart';
import 'auth_service.dart';
import 'category_sync_service.dart';

class CategoryService {
  static const String _boxName = 'categories';
  static Box<Category>? _box;
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
      _box = await openBoxWithRetry<Category>(_boxName);
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

  static Future<void> initialize() async {
    await _ensureBoxOpen();
  }

  /// 同期等で getLocalItems の前に呼ぶ。未初期化でもボックスを開いてから取得できるようにする。
  static Future<void> ensureOpen() async => _ensureBoxOpen();

  static Box<Category> get box => _box!;

  // カテゴリを追加
  static Future<void> addCategory(Category category) async {
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async => box.put(category.id, category));
  }

  // カテゴリを更新
  static Future<void> updateCategory(Category category) async {
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async => box.put(category.id, category));
  }

  // カテゴリを削除
  static Future<void> deleteCategory(String id) async {
    await _ensureBoxOpen();
    await _retryOnIdbClosing(() async => box.delete(id));
  }

  // カテゴリを取得（現在ユーザー所有のみ返す）
  static Category? getCategoryById(String id) {
    try {
      final userId = AuthService.getCurrentUserId();
      if (userId == null || userId.isEmpty) return null;
      final c = box.get(id);
      if (c == null || c.userId != userId) return null;
      return c;
    } catch (_) {
      return null;
    }
  }

  // 全カテゴリを取得（現在ユーザー分のみ）
  static List<Category> getAllCategories() {
    try {
      final userId = AuthService.getCurrentUserId();
      if (userId == null) return [];
      return getCategoriesByUserId(userId);
    } catch (_) {
      return [];
    }
  }

  // ユーザーのカテゴリを取得
  static List<Category> getCategoriesByUserId(String userId) {
    try {
      return box.values.where((category) => category.userId == userId).toList();
    } catch (_) {
      return [];
    }
  }

  // 現在のユーザーのカテゴリを取得
  static List<Category> getCurrentUserCategories() {
    final userId = AuthService.getCurrentUserId();
    if (userId == null) return [];
    return getCategoriesByUserId(userId);
  }

  // カテゴリ名で検索
  static List<Category> searchCategoriesByName(String name) {
    final userId = AuthService.getCurrentUserId();
    if (userId == null) return [];
    try {
      return box.values
          .where(
            (category) =>
                category.userId == userId &&
                category.name.toLowerCase().contains(name.toLowerCase()),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  // 初期カテゴリを作成
  static Future<void> createInitialCategories() async {
    final userId = AuthService.getCurrentUserId();
    if (userId == null) return;

    // 先に同期してリモート既存を取り込み（重複防止）
    try {
      await CategorySyncService.syncAllCategories();
    } catch (_) {}

    final existingCategories = getCategoriesByUserId(userId);

    final initialCategories = ['仕事', 'プライベート', '学習', '健康', '趣味', '家事', 'その他'];

    for (final name in initialCategories) {
      final norm = name.trim().toLowerCase();
      final exists =
          existingCategories.any((c) => c.name.trim().toLowerCase() == norm);
      if (exists) continue;
      final category = Category(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        createdAt: DateTime.now(),
        lastModified: DateTime.now(),
        userId: userId,
      );
      await addCategory(category);
    }
  }

  // Firebase同期（将来的に実装）
  static Future<void> syncFromCloud() async {
    // 同期ロジックは同期サービスへ委譲
    try {
      await CategorySyncService.syncAllCategories();
    } catch (_) {}
  }

  // すべてのカテゴリをクリア
  static Future<void> clearAll() async {
    await _ensureBoxOpen();
    await _box?.clear();
  }
}
