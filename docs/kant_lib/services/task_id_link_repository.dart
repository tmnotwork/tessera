import 'dart:async';

import 'package:hive/hive.dart';

class TaskIdLinkUpdate {
  TaskIdLinkUpdate({required this.localTaskId, required this.cloudId});

  final String localTaskId;
  final String? cloudId;
}

/// ローカル ID とクラウド ID の対応を永続化して配信するリポジトリ。
class TaskIdLinkRepository {
  TaskIdLinkRepository._(this._box);

  static const _boxName = 'task_id_links';
  static TaskIdLinkRepository? _instance;

  final Box<dynamic> _box;
  final StreamController<TaskIdLinkUpdate> _updateController =
      StreamController<TaskIdLinkUpdate>.broadcast();

  Stream<TaskIdLinkUpdate> get updates => _updateController.stream;

  static Future<TaskIdLinkRepository> initialize() async {
    if (_instance != null) return _instance!;
    final box = await Hive.openBox<dynamic>(_boxName);
    _instance = TaskIdLinkRepository._(box);
    return _instance!;
  }

  static TaskIdLinkRepository get instance {
    final repo = _instance;
    if (repo == null) {
      throw StateError('TaskIdLinkRepository is not initialized');
    }
    return repo;
  }

  Future<String?> lookup(String localTaskId) async {
    final raw = _box.get(localTaskId);
    if (raw is Map) {
      final value = raw['cloudId'];
      return value?.toString();
    }
    if (raw is String) {
      return raw;
    }
    return null;
  }

  Future<void> updateLink(String localTaskId, String cloudId) async {
    await _box.put(localTaskId, <String, dynamic>{
      'cloudId': cloudId,
      'updatedAt': DateTime.now().toIso8601String(),
    });
    _updateController.add(
      TaskIdLinkUpdate(localTaskId: localTaskId, cloudId: cloudId),
    );
  }

  Future<void> registerLocalOnly(String localTaskId) async {
    final existing = await lookup(localTaskId);
    if (existing != null) {
      return;
    }
    await _box.put(localTaskId, <String, dynamic>{
      'cloudId': null,
      'updatedAt': DateTime.now().toIso8601String(),
    });
    _updateController.add(
      TaskIdLinkUpdate(localTaskId: localTaskId, cloudId: null),
    );
  }

  Future<void> remove(String localTaskId) async {
    await _box.delete(localTaskId);
  }

  Future<void> clear() async {
    await _box.clear();
  }

  static Future<void> clearAll() async {
    if (_instance != null) {
      await _instance!.clear();
    }
  }

  void dispose() {
    _updateController.close();
  }
}
