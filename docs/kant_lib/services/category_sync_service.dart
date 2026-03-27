import '../models/category.dart';
import '../models/syncable_model.dart';
import 'data_sync_service.dart';
import 'category_service.dart';
import 'device_info_service.dart';
import 'auth_service.dart';
import 'app_settings_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';


/// Category同期サービス
class CategorySyncService extends DataSyncService<Category> {
  static final CategorySyncService _instance = CategorySyncService._internal();
  factory CategorySyncService() => _instance;
  CategorySyncService._internal() : super('categories');

  @override
  String? get diffCursorKey => AppSettingsService.keyCursorCategories;

  @override
  Category createFromCloudJson(Map<String, dynamic> json) {
    return Category.fromJson(json);
  }

  @override
  Future<List<Category>> getLocalItems() async {
    try {
      await CategoryService.ensureOpen();
      return CategoryService.getAllCategories();
    } catch (e) {
      print('❌ Failed to get local categories: $e');
      return [];
    }
  }

  @override
  Future<Category?> getLocalItemByCloudId(String cloudId) async {
    try {
      final categories = CategoryService.getAllCategories();
      return categories.where((c) => c.cloudId == cloudId).firstOrNull;
    } catch (e) {
      print('❌ Failed to get local category by cloudId: $e');
      return null;
    }
  }

  @override
  Future<void> saveToLocal(Category category) async {
    try {
      // 1) cloudId で既存検索
      Category? existingCategory;
      if (category.cloudId != null && category.cloudId!.isNotEmpty) {
        existingCategory = await getLocalItemByCloudId(category.cloudId!);
      }
      // 2) id で検索
      existingCategory ??=
          CategoryService.getCategoryById(category.id);
      // 3) userId + 正規化name で検索
      if (existingCategory == null) {
        final norm = category.name.trim().toLowerCase();
        final sameUser = CategoryService
            .getCategoriesByUserId(category.userId)
            .where((c) => c.name.trim().toLowerCase() == norm)
            .toList();
        if (sameUser.isNotEmpty) {
          existingCategory = sameUser.first;
        }
      }

      if (existingCategory != null) {
        // 既存カテゴリにリモート内容を適用（欠落のみ上書き）
        existingCategory.fromCloudJson(category.toCloudJson());
        // cloudId を引き継ぎ（どちらかが持っていれば統一）
        existingCategory.cloudId =
            (existingCategory.cloudId?.isNotEmpty == true)
                ? existingCategory.cloudId
                : category.cloudId;
        await CategoryService.updateCategory(existingCategory);
      } else {
        // 新規カテゴリを作成
        await CategoryService.addCategory(category);
      }
    } catch (e) {
      print('❌ Failed to save category locally: $e');
      rethrow;
    }
  }

  @override
  Future<Category> handleManualConflict(Category local, Category remote) async {
    // Last-Write-Wins戦略：設定データは最新を優先
    print(
        '⚠️ Category conflict resolved automatically (Last-Write-Wins): ${local.name}');
    print('  Local: ${local.lastModified} (v${local.version})');
    print('  Remote: ${remote.lastModified} (v${remote.version})');

    if (remote.lastModified.isAfter(local.lastModified)) {
      await saveToLocal(remote);
      return remote;
    } else {
      return local;
    }
  }

  /// カテゴリ作成時の同期対応
  Future<Category> createCategoryWithSync({
    required String name,
  }) async {
    try {
      final deviceId = await DeviceInfoService.getDeviceId();
      final userId = AuthService.getCurrentUserId() ?? '';

      // ローカルでカテゴリ作成
      final now = DateTime.now();
      final category = Category(
        id: 'category_${now.millisecondsSinceEpoch}_${now.microsecond}',
        name: name,
        createdAt: now,
        lastModified: now,
        userId: userId,
        deviceId: deviceId,
        version: 1,
      );

      // ローカル保存
      await CategoryService.addCategory(category);

      // 同期メタデータを設定
      category.markAsModified(deviceId);

      // Firebaseに同期（ネットワークがあれば）
      try {
        await uploadToFirebase(category);
      } catch (e) {
        print('⚠️ Failed to sync new category to Firebase: $e');
        // ネットワークエラーでもローカル作成は成功とする
      }

      return category;
    } catch (e) {
      print('❌ Failed to create category with sync: $e');
      rethrow;
    }
  }

  /// カテゴリ更新時の同期対応
  Future<void> updateCategoryWithSync(Category category) async {
    try {
      final deviceId = await DeviceInfoService.getDeviceId();

      // 同期メタデータを更新
      category.markAsModified(deviceId);

      // ローカル更新
      await CategoryService.updateCategory(category);

      // Firebaseに同期（ネットワークがあれば）
      try {
        await uploadToFirebase(category);
      } catch (e) {
        print('⚠️ Failed to sync updated category to Firebase: $e');
        // ネットワークエラーでもローカル更新は成功とする
      }
    } catch (e) {
      print('❌ Failed to update category with sync: $e');
      rethrow;
    }
  }

  /// カテゴリ削除時の同期対応
  Future<void> deleteCategoryWithSync(String categoryId) async {
    try {
      final categories = CategoryService.getAllCategories();
      final category = categories.where((c) => c.id == categoryId).firstOrNull;
      if (category == null) return;

      final deviceId = await DeviceInfoService.getDeviceId();

      // 論理削除マークを設定
      category.isDeleted = true;
      category.markAsModified(deviceId);

      // ローカル削除
      await CategoryService.deleteCategory(categoryId);

      // Firebaseに削除を同期（ネットワークがあれば）
      try {
        if (category.cloudId != null) {
          await deleteFromFirebase(category.cloudId!);
        }
      } catch (e) {
        print('⚠️ Failed to sync category deletion to Firebase: $e');
        // ネットワークエラーでもローカル削除は成功とする
      }
    } catch (e) {
      print('❌ Failed to delete category with sync: $e');
      rethrow;
    }
  }

  /// カテゴリ名でフィルタ同期
  Future<SyncResult> syncCategoriesByName(String nameFilter) async {
    try {
      print('🔄 Syncing categories with name filter: $nameFilter');

      // 名前フィルタのFirestoreクエリ
      final querySnapshot = await userCollection
          .where('isDeleted', isEqualTo: false)
          .where('name', isGreaterThanOrEqualTo: nameFilter)
          .where('name', isLessThan: '$nameFilter\uf8ff')
          .get();

      final remoteCategories = <Category>[];
      for (final doc in querySnapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final category = createFromCloudJson(data);
          remoteCategories.add(category);
        } catch (e) {
          print('⚠️ Failed to parse category ${doc.id}: $e');
        }
      }

      // ローカルカテゴリとの競合解決
      int syncedCount = 0;
      int failedCount = 0;
      final conflicts = <ConflictResolution>[];

      for (final remoteCategory in remoteCategories) {
        try {
          final localCategory =
              await getLocalItemByCloudId(remoteCategory.cloudId!);

          if (localCategory == null) {
            await saveToLocal(remoteCategory);
            syncedCount++;
          } else if (localCategory.hasConflictWith(remoteCategory)) {
            await resolveConflict(localCategory, remoteCategory);
            conflicts.add(ConflictResolution.localNewer); // 簡易的な記録
            syncedCount++;
          }
        } catch (e) {
          print('❌ Failed to process remote category: $e');
          failedCount++;
        }
      }

      print(
          '✅ Filtered categories sync completed: $syncedCount synced, $failedCount failed');
      return SyncResult(
        success: failedCount == 0,
        syncedCount: syncedCount,
        failedCount: failedCount,
        conflicts: conflicts,
      );
    } catch (e) {
      print('❌ Filtered categories sync failed: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  /// すべてのCategoryを同期
  static Future<SyncResult> syncAllCategories() async {
    try {
      final syncService = CategorySyncService();
      return await syncService.performSync();
    } catch (e) {
      print('❌ Failed to sync all categories: $e');
      return SyncResult(
        success: false,
        error: e.toString(),
        failedCount: 1,
      );
    }
  }

  /// カテゴリの変更を監視
  Stream<List<Category>> watchCategoryChanges() {
    return watchFirebaseChanges();
  }

  /// 最近作成されたカテゴリを監視
  Stream<List<Category>> watchRecentlyCreatedCategories({int limit = 20}) {
    return userCollection
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
      final items = <Category>[];
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          items.add(createFromCloudJson(data));
        } catch (_) {}
      }
      return items;
    }).handleError((e, st) {
      // 監視エラーを握ってUI継続（ネットワーク一時障害/認証再水和対策）
      try {
        // ignore: avoid_print
        print('⚠️ Firestore watch error: $e');
      } catch (_) {}
    });
  }

  /// 差分同期: lastModified >= cursor のカテゴリ
  Future<SyncResult> syncCategoriesSince(DateTime cursorUtc) async {
    try {
      final from = cursorUtc.subtract(const Duration(seconds: 10));
      final snapshot = await userCollection
          .where('lastModified', isGreaterThanOrEqualTo: from.toIso8601String())
          .get();

      int synced = 0;
      int failed = 0;
      final conflicts = <ConflictResolution>[];
      DateTime? maxRemoteLastModifiedUtc;
      for (final doc in snapshot.docs) {
        try {
          final data = doc.data() as Map<String, dynamic>;
          data['cloudId'] = doc.id;
          final lmRaw = data['lastModified'];
          DateTime? lm;
          if (lmRaw is Timestamp) {
            lm = lmRaw.toDate().toUtc();
          } else if (lmRaw is DateTime) {
            lm = lmRaw.toUtc();
          } else if (lmRaw is String) {
            lm = DateTime.tryParse(lmRaw)?.toUtc();
          }
          if (lm != null) {
            final currentMax = maxRemoteLastModifiedUtc;
            if (currentMax == null || lm.isAfter(currentMax)) {
              maxRemoteLastModifiedUtc = lm;
            }
          }
          final remote = createFromCloudJson(data);
          final local = await getLocalItemByCloudId(remote.cloudId!);
          if (local == null) {
            await saveToLocal(remote);
            synced++;
          } else if (local.hasConflictWith(remote)) {
            await resolveConflict(local, remote);
            conflicts.add(ConflictResolution.remoteNewer);
            synced++;
          }
        } catch (_) {
          failed++;
        }
      }
      // IMPORTANT: 端末時刻でカーソル前進しない（取得結果由来の最大値のみ）
      final latest = maxRemoteLastModifiedUtc;
      if (latest != null) {
        final key = AppSettingsService.keyCursorCategories;
        final current = AppSettingsService.getCursor(key);
        var candidate = latest.subtract(const Duration(milliseconds: 1));
        if (candidate.millisecondsSinceEpoch < 0) {
          candidate = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        }
        if (current != null && candidate.isBefore(current)) {
          candidate = current;
        }
        await AppSettingsService.setCursor(key, candidate);
      }
      return SyncResult(success: failed == 0, syncedCount: synced, failedCount: failed, conflicts: conflicts);
    } catch (e) {
      return SyncResult(success: false, error: e.toString(), failedCount: 1);
    }
  }

  /// ローカルカテゴリを削除する（同期処理で使用）
  @override
  Future<void> deleteLocalItem(Category item) async {
    try {
      await CategoryService.deleteCategory(item.id);
      print('✅ Local category deleted during sync: ${item.name} (id: ${item.id})');
    } catch (e) {
      print('❌ Failed to delete local category: ${item.name}, error: $e');
      rethrow;
    }
  }
}
