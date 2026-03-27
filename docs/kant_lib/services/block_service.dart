// ignore_for_file: unused_local_variable

import 'dart:async';

import 'package:hive/hive.dart';

import '../models/block.dart';
import '../utils/hive_open_with_retry.dart';
import 'auth_service.dart';
import 'notification_service.dart';

class BlockService {
  static const String _boxName = 'blocks';
  static late Box<Block> _blockBox;
  static bool _opening = false;

  /// Hive box (must be opened/initialized).
  static Box<Block> get blockBox {
    if (Hive.isBoxOpen(_boxName)) {
      // Always get from Hive to avoid stale reference.
      return Hive.box<Block>(_boxName);
    }
    throw Exception('BlockService not initialized');
  }

  /// Block changes stream (add/update/delete).
  static Stream<BoxEvent> watchChanges() {
    if (!Hive.isBoxOpen(_boxName)) return const Stream<BoxEvent>.empty();
    return blockBox.watch();
  }

  static Future<void> _ensureBoxOpen() async {
    if (Hive.isBoxOpen(_boxName)) {
      return;
    }
    if (_opening) {
      // wait briefly if another open is in progress
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 30));
        if (Hive.isBoxOpen(_boxName)) return;
      }
    }
    _opening = true;
    try {
      _blockBox = await openBoxWithRetry<Block>(_boxName);
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
        // Reopen and retry once
        await _ensureBoxOpen();
        return await action();
      }
      rethrow;
    }
  }

  // TaskProviderへの通知用StreamController
  static final StreamController<void> _updateController =
      StreamController<void>.broadcast();

  // TaskProviderが購読可能な更新通知Stream
  static Stream<void> get updateStream => _updateController.stream;

  // TaskProviderに更新を通知
  static void _notifyTaskProviderUpdate() {
    _updateController.add(null);
  }

  // 初期化（boxが開かれていなければ開く）
  static Future<void> initialize() async {
    if (!Hive.isBoxOpen(_boxName)) {
      _blockBox = await openBoxWithRetry<Block>(_boxName);
    } else {
      _blockBox = Hive.box<Block>(_boxName);
    }
  }

  // ブロックを追加
  static Future<void> addBlock(Block block) async {
    try {
      await _ensureBoxOpen();
      // creationMethodの安全性チェック
      try {
        final _ = block.creationMethod.index;
      } catch (e) {
        block.creationMethod = TaskCreationMethod.manual;
      }
      await _retryOnIdbClosing(() async {
        await _blockBox.put(block.id, block);
        await _blockBox.flush(); // 確実にディスクに書き込み
      });

      // 保存確認
      final savedBlock =
          await _retryOnIdbClosing(() async => _blockBox.get(block.id));
      if (savedBlock == null) {
        throw Exception('ブロックの保存に失敗しました');
      }

      // TaskProviderに通知（ブロック追加後）
      _notifyTaskProviderUpdate();
    } catch (e) {
      rethrow;
    }
  }

  // ブロックを更新
  static Future<void> updateBlock(Block block) async {
    try {
      await _ensureBoxOpen();
      Block? prev;
      try {
        prev = await _retryOnIdbClosing(() async => _blockBox.get(block.id));
      } catch (_) {}
      await _retryOnIdbClosing(() async {
        await _blockBox.put(block.id, block);
        await _blockBox.flush();
      });
      // TaskProviderに通知（ブロック更新後）
      _notifyTaskProviderUpdate();
    } catch (e) {
      rethrow;
    }
  }

  // ブロックを削除
  static Future<void> deleteBlock(String id) async {
    try {
      await _ensureBoxOpen();
      // 削除前にブロックの存在確認
      final existingBlock =
          await _retryOnIdbClosing(() async => _blockBox.get(id));
      if (existingBlock == null) {
        return;
      }

      // 予定通知がスケジュールされていれば取り消す（手動・ルーティン反映問わず全削除経路で確実に解除）
      if (existingBlock.isEvent == true) {
        try {
          await NotificationService().cancelEventReminder(existingBlock);
        } catch (_) {}
      }

      // Hiveから削除
      await _retryOnIdbClosing(() async {
        await _blockBox.delete(id);
        await _blockBox.flush(); // 確実にディスクに書き込み
      });

      // 削除確認
      final deletedBlock =
          await _retryOnIdbClosing(() async => _blockBox.get(id));
      if (deletedBlock == null) {
        _notifyTaskProviderUpdate(); // TaskProviderに更新を通知
      } else {
        print(
            '❌ ERROR: Block deletion failed - block still exists: "${existingBlock.title}" (ID: $id)');
        throw Exception('Block deletion failed for ID: $id');
      }
    } catch (e) {
      print('❌ ERROR: Failed to delete block with ID $id: $e');
      rethrow;
    }
  }

  /// バッチでブロックを追加・更新・削除（flush は最後に1回のみ。通知は呼び元で1回行う）
  static Future<void> batchPutBlocks({
    required List<Block> toAdd,
    required List<Block> toUpdate,
    List<String> toDelete = const [],
  }) async {
    if (toAdd.isEmpty && toUpdate.isEmpty && toDelete.isEmpty) return;
    try {
      await _ensureBoxOpen();
      // 削除対象のうち isEvent のブロックは予定通知を先に取り消す
      for (final id in toDelete) {
        final b = await _retryOnIdbClosing(() async => _blockBox.get(id));
        if (b != null && b.isEvent == true) {
          try {
            await NotificationService().cancelEventReminder(b);
          } catch (_) {}
        }
      }
      await _retryOnIdbClosing(() async {
        for (final id in toDelete) {
          await _blockBox.delete(id);
        }
        for (final block in toAdd) {
          try {
            final _ = block.creationMethod.index;
          } catch (e) {
            block.creationMethod = TaskCreationMethod.manual;
          }
          await _blockBox.put(block.id, block);
        }
        for (final block in toUpdate) {
          await _blockBox.put(block.id, block);
        }
        await _blockBox.flush();
      });
      _notifyTaskProviderUpdate();
    } catch (e) {
      rethrow;
    }
  }

  // 複数ブロックを一括削除
  static Future<void> deleteBlocks(List<String> ids) async {
    try {
      int deletedCount = 0;
      int failedCount = 0;

      for (final id in ids) {
        try {
          await deleteBlock(id);
          deletedCount++;
        } catch (e) {
          print('❌ Failed to delete block $id: $e');
          failedCount++;
        }
      }

      if (deletedCount > 0) {
        _notifyTaskProviderUpdate(); // 一括更新通知
      }
    } catch (e) {
      print('❌ ERROR: Failed bulk block deletion: $e');
      rethrow;
    }
  }

  static String? get _currentUserId => AuthService.getCurrentUserId();

  // すべてのブロックを取得（現在ユーザー分のみ・厳格）
  static List<Block> getAllBlocks() {
    try {
      if (!Hive.isBoxOpen(_boxName)) return [];
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      final validBlocks = <Block>[];
      final allBlocksCount = _blockBox.length;

      for (int i = 0; i < allBlocksCount; i++) {
        try {
          final key = _blockBox.keyAt(i);
          final block = _blockBox.get(key);
          if (block == null || block.userId != uid) continue;

          try {
            final _ = block.creationMethod.index;
            validBlocks.add(block);
          } catch (rangeError) {
            if (rangeError.toString().contains('RangeError')) {
              print(
                  '⚠️ Corrupted block detected, attempting to fix: ${block.id}');
              try {
                block.creationMethod = TaskCreationMethod.manual;
                validBlocks.add(block);
              } catch (fixError) {
                print(
                    '❌ Cannot fix corrupted block ${block.id}: $fixError, deleting...');
                _blockBox.delete(key);
              }
            } else {
              rethrow;
            }
          }
        } catch (e) {
          print('❌ Error reading block at index $i: $e');
        }
      }
      return validBlocks;
    } catch (e) {
      print('❌ Error in getAllBlocks: $e');
      return [];
    }
  }

  // IDでブロックを取得（現在ユーザー所有のみ返す）
  static Block? getBlockById(String id) {
    try {
      if (!Hive.isBoxOpen(_boxName)) return null;
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return null;
      final block = _blockBox.get(id);
      if (block == null || block.userId != uid) return null;
      return block;
    } catch (e) {
      return null;
    }
  }

  // 指定日付のブロック一覧を取得（現在ユーザー分のみ）
  static List<Block> getBlocksForDate(DateTime date) {
    try {
      if (!Hive.isBoxOpen(_boxName)) return [];
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return [];
      return _blockBox.values
          .where(
            (block) =>
                block.userId == uid &&
                block.executionDate.year == date.year &&
                block.executionDate.month == date.month &&
                block.executionDate.day == date.day,
          )
          .toList();
    } catch (e) {
      return [];
    }
  }

  // ルーティン由来のブロックを全削除（現在ユーザー分のみ）
  static Future<void> deleteRoutineBlocks() async {
    try {
      final uid = _currentUserId;
      if (uid == null || uid.isEmpty) return;
      final routineBlocks = _blockBox.values
          .where(
            (block) =>
                block.userId == uid &&
                block.creationMethod == TaskCreationMethod.routine,
          )
          .toList();
      for (final block in routineBlocks) {
        await _blockBox.delete(block.id);
      }
    } catch (e) {
      rethrow;
    }
  }

  // 全ブロックをクリア（破損データ対策）
  static Future<void> clearAllBlocks() async {
    try {
      await _blockBox.clear();
    } catch (e) {
      print('❌ Failed to clear blocks: $e');
      rethrow;
    }
  }
}
