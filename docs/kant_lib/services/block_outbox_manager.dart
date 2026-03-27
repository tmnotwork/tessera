import 'dart:async';
import 'package:hive/hive.dart';

import '../models/block.dart';
import 'block_service.dart';
import 'block_sync_service.dart';
import 'network_manager.dart';

/// Persistent outbox manager for Block operations
/// Stores queued operations in Hive to guarantee delivery after offline periods
class BlockOutboxManager {
  static const String _boxName = 'block_outbox';
  static Box? _box;
  static bool _initialized = false;
  static bool _isFlushing = false;

  /// Initialize outbox and start connectivity listener
  static Future<void> initialize() async {
    if (_initialized) return;
    _box = await Hive.openBox(_boxName);

    // Flush immediately if already online
    if (NetworkManager.isOnline) {
      unawaited(flush());
    }

    // Flush on connectivity restore
    NetworkManager.connectivityStream.listen((isOnline) {
      if (isOnline) {
        unawaited(flush());
      }
    });

    _initialized = true;
  }

  /// Enqueue a block operation. operation: 'create' | 'update' | 'delete'
  static Future<void> enqueue(Block block, String operation) async {
    _box ??= await Hive.openBox(_boxName);

    // Ensure the block has a cloudId so we can upsert to a fixed doc
    final cloudId = (block.cloudId == null || block.cloudId!.isEmpty)
        ? null
        : block.cloudId;

    final key = cloudId ?? block.id; // fallback to local id if needed

    final entry = <String, dynamic>{
      'cloudId': cloudId,
      'localId': block.id,
      'operation': operation,
      'data': block.toCloudJson(),
      'timestamp': DateTime.now().toIso8601String(),
      'attempts': 0,
    };

    await _box!.put(key, entry);
    await _box!.flush();
    try {
      print(
          '📮 BlockOutbox: queued $operation for $key localId=${block.id} cloudId=${block.cloudId ?? 'null'} v=${block.version} lm=${block.lastModified.toIso8601String()} exec=${block.executionDate.toIso8601String()} start=${block.startHour.toString().padLeft(2, '0')}:${block.startMinute.toString().padLeft(2, '0')} dur=${block.estimatedDuration}');
    } catch (_) {
      print('📮 BlockOutbox: queued $operation for $key');
    }
  }

  /// Flush queued operations (best-effort)
  static Future<void> flush() async {
    if (_isFlushing) return;
    _box ??= await Hive.openBox(_boxName);
    if (_box!.isEmpty) return;
    if (!NetworkManager.isOnline) return;

    _isFlushing = true;
    print('📤 BlockOutbox: flushing ${_box!.length} operation(s)');

    try {
      final syncService = BlockSyncService();

      // Iterate over a snapshot of keys to avoid concurrent modification issues
      final keys = List.from(_box!.keys);
      for (final key in keys) {
        final raw = _box!.get(key);
        if (raw is! Map) {
          await _box!.delete(key);
          continue;
        }

        try {
          final operation = (raw['operation'] ?? 'update') as String;
          final data = Map<String, dynamic>.from(raw['data'] as Map);
          final block = Block.fromJson(data);

          switch (operation) {
            case 'create':
            case 'update':
              await syncService.uploadToFirebase(block);
              await BlockService.updateBlock(
                  block); // persist lastSynced/cloudId
              break;
            case 'delete':
              // For delete, prefer logical deletion
              final cid = (raw['cloudId'] as String?) ?? block.cloudId;
              if (cid != null && cid.isNotEmpty) {
                await syncService.deleteFromFirebase(cid);
              } else {
                // If we do not have a cloud id, ensure local delete only
                await BlockService.deleteBlock(block.id);
              }
              break;
            default:
              await syncService.uploadToFirebase(block);
              await BlockService.updateBlock(block);
          }

          // Success -> remove from outbox
          await _box!.delete(key);
        } catch (e) {
          // Increment attempts and keep it for retry
          try {
            final attempts = (raw['attempts'] as int? ?? 0) + 1;
            raw['attempts'] = attempts;
            await _box!.put(key, raw);
          } catch (_) {}
          print('❌ BlockOutbox: failed to process $key, will retry later: $e');
        }
      }

      await _box!.flush();
      print('✅ BlockOutbox: flush completed');
    } finally {
      _isFlushing = false;
    }
  }

  /// 未送信の outbox 件数を取得（best-effort）
  static Future<int> pendingCount() async {
    try {
      _box ??= await Hive.openBox(_boxName);
      return _box?.length ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Manual clear for debugging
  static Future<void> clear() async {
    _box ??= await Hive.openBox(_boxName);
    await _box!.clear();
    print('🗑️ BlockOutbox: cleared');
  }
}
