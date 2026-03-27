import 'dart:convert';

import '../models/synced_day.dart';
import 'app_settings_service.dart';

class VersionCursor {
  const VersionCursor({
    required this.lastSeenWriteAt,
    required this.lastSeenDocId,
  });

  final DateTime lastSeenWriteAt;
  final String lastSeenDocId;

  VersionCursor copyWith({
    DateTime? lastSeenWriteAt,
    String? lastSeenDocId,
  }) {
    return VersionCursor(
      lastSeenWriteAt: lastSeenWriteAt ?? this.lastSeenWriteAt,
      lastSeenDocId: lastSeenDocId ?? this.lastSeenDocId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'lastSeenWriteAt': lastSeenWriteAt.toUtc().toIso8601String(),
      'lastSeenDocId': lastSeenDocId,
    };
  }

  static VersionCursor fromJson(Map<String, dynamic> json) {
    final writeAt = DateTime.tryParse(json['lastSeenWriteAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0).toUtc();
    final docId = (json['lastSeenDocId'] as String?) ?? '';
    return VersionCursor(lastSeenWriteAt: writeAt.toUtc(), lastSeenDocId: docId);
  }

  static VersionCursor initial() => VersionCursor(
        lastSeenWriteAt: DateTime.fromMillisecondsSinceEpoch(0).toUtc(),
        lastSeenDocId: '',
      );
}

class VersionCursorService {
  VersionCursorService._();

  static const _storagePrefix = 'sync.versionCursor.';

  static String _key(SyncedDayKind kind) => '$_storagePrefix${kind.name}';

  static VersionCursor _parse(String? raw) {
    if (raw == null || raw.isEmpty) {
      return VersionCursor.initial();
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return VersionCursor.fromJson(map);
    } catch (_) {
      return VersionCursor.initial();
    }
  }

  static Future<VersionCursor> load(SyncedDayKind kind) async {
    await AppSettingsService.initialize();
    final raw = AppSettingsService.getString(_key(kind));
    return _parse(raw);
  }

  static Future<void> save(SyncedDayKind kind, VersionCursor cursor) async {
    await AppSettingsService.setString(
      _key(kind),
      jsonEncode(cursor.toJson()),
    );
  }

  static Future<void> reset(SyncedDayKind kind) async {
    await AppSettingsService.setString(
      _key(kind),
      jsonEncode(VersionCursor.initial().toJson()),
    );
  }
}
