/// アウトボックスに積まれるタスク操作のスナップショット。
class TaskOutboxEntry {
  TaskOutboxEntry({
    required this.entryId,
    required this.taskType,
    required this.localTaskId,
    required this.operation,
    required this.payload,
    required this.timestamp,
    required this.priority,
    required this.orderKey,
    required this.dependencyKey,
    this.version = 1,
    this.cloudId,
    this.attempts = 0,
    this.nextRetryAt,
    this.lastError,
    this.dedupeKey,
    this.lifecycleToken,
    this.origin,
  });

  factory TaskOutboxEntry.fromMap(Map<dynamic, dynamic> raw) {
    final payloadRaw = raw['payload'];
    Map<String, dynamic> payload = const <String, dynamic>{};
    if (payloadRaw is Map) {
      payload = payloadRaw.map((key, value) => MapEntry(key.toString(), value));
    }

    return TaskOutboxEntry(
      version: (raw['version'] as int?) ?? 1,
      entryId: raw['entryId'] as String,
      taskType: raw['taskType'] as String,
      localTaskId: raw['localTaskId'] as String,
      operation: raw['operation'] as String,
      payload: payload,
      timestamp: DateTime.tryParse(raw['timestamp'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(
            raw['timestampMillis'] as int? ??
                DateTime.now().millisecondsSinceEpoch,
          ),
      priority: TaskOutboxPriority.values.firstWhere(
        (p) => p.name == (raw['priority'] as String? ?? 'normal'),
        orElse: () => TaskOutboxPriority.normal,
      ),
      attempts: raw['attempts'] as int? ?? 0,
      cloudId: raw['cloudId'] as String?,
      nextRetryAt: _parseDateTime(raw['nextRetryAt']),
      lastError: raw['lastError'] as String?,
      dedupeKey: raw['dedupeKey'] as String?,
      lifecycleToken: raw['lifecycleToken'] as String?,
      origin: raw['origin'] as String?,
      orderKey: raw['orderKey'] as int? ?? 0,
      dependencyKey: raw['dependencyKey'] as String? ??
          '${raw['taskType']}:${raw['localTaskId']}',
    );
  }

  final int version;
  final String entryId;
  final String taskType;
  final String localTaskId;
  final String operation;
  final Map<String, dynamic> payload;
  final DateTime timestamp;
  final TaskOutboxPriority priority;
  final String? cloudId;
  final int attempts;
  final DateTime? nextRetryAt;
  final String? lastError;
  final String? dedupeKey;
  final String? lifecycleToken;
  final String? origin;
  final int orderKey;
  final String dependencyKey;

  TaskOutboxEntry copyWith({
    int? version,
    String? entryId,
    String? taskType,
    String? localTaskId,
    String? operation,
    Map<String, dynamic>? payload,
    DateTime? timestamp,
    TaskOutboxPriority? priority,
    String? cloudId,
    int? attempts,
    DateTime? nextRetryAt,
    String? lastError,
    String? dedupeKey,
    String? lifecycleToken,
    String? origin,
    int? orderKey,
    String? dependencyKey,
  }) {
    return TaskOutboxEntry(
      version: version ?? this.version,
      entryId: entryId ?? this.entryId,
      taskType: taskType ?? this.taskType,
      localTaskId: localTaskId ?? this.localTaskId,
      operation: operation ?? this.operation,
      payload: payload ?? Map<String, dynamic>.from(this.payload),
      timestamp: timestamp ?? this.timestamp,
      priority: priority ?? this.priority,
      cloudId: cloudId ?? this.cloudId,
      attempts: attempts ?? this.attempts,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      lastError: lastError ?? this.lastError,
      dedupeKey: dedupeKey ?? this.dedupeKey,
      lifecycleToken: lifecycleToken ?? this.lifecycleToken,
      origin: origin ?? this.origin,
      orderKey: orderKey ?? this.orderKey,
      dependencyKey: dependencyKey ?? this.dependencyKey,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'version': version,
      'entryId': entryId,
      'taskType': taskType,
      'localTaskId': localTaskId,
      'operation': operation,
      'payload': Map<String, dynamic>.from(payload),
      'timestamp': timestamp.toIso8601String(),
      'priority': priority.name,
      'cloudId': cloudId,
      'attempts': attempts,
      'nextRetryAt': nextRetryAt?.toIso8601String(),
      'lastError': lastError,
      'dedupeKey': dedupeKey,
      'lifecycleToken': lifecycleToken,
      'origin': origin,
      'orderKey': orderKey,
      'dependencyKey': dependencyKey,
    };
  }

  static DateTime? _parseDateTime(dynamic raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(raw);
    }
    if (raw is String) {
      return DateTime.tryParse(raw);
    }
    return null;
  }
}

enum TaskOutboxPriority { immediate, high, normal, background }
