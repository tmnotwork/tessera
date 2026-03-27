import '../models/inbox_task.dart';
import 'project_service.dart';
import 'sub_project_service.dart';
import 'mode_service.dart';

/// CSV import/export service for InboxTask.
class InboxCsvService {
  /// Template CSV headers (simplified for user input).
  static const List<String> templateHeaders = [
    'title',
    'estimatedDuration',
    'executionDate',
    'startHour',
    'startMinute',
    'projectName',
    'subProjectName',
    'modeName',
    'memo',
    'isSomeday',
    'isImportant',
  ];

  /// Full CSV headers for export (includes all fields).
  static const List<String> fullHeaders = [
    'id',
    'title',
    'projectId',
    'subProjectId',
    'dueDate',
    'executionDate',
    'startHour',
    'startMinute',
    'estimatedDuration',
    'memo',
    'modeId',
    'isSomeday',
    'excludeFromReport',
    'isImportant',
    'isCompleted',
    'createdAt',
    'lastModified',
    'userId',
    'cloudId',
    'isDeleted',
    'deviceId',
    'version',
  ];

  /// Generate a template CSV string for users to fill in.
  static String generateTemplateCsv() {
    final buffer = StringBuffer();
    buffer.writeln(_join(templateHeaders));
    // Add a sample row as reference
    buffer.writeln(_join([
      'サンプルタスク',
      '30',
      '2025-01-20',
      '9',
      '0',
      '',
      '',
      '',
      'メモ欄（任意）',
      'false',
      'false',
    ]));
    return buffer.toString();
  }

  /// Export tasks to CSV string (UTF-8). Fields are RFC4180-quoted.
  static String exportCsv(List<InboxTask> tasks) {
    final buffer = StringBuffer();
    buffer.writeln(_join(fullHeaders));
    for (final t in tasks) {
      buffer.writeln(_join([
        t.id,
        t.title,
        t.projectId ?? '',
        t.subProjectId ?? '',
        t.dueDate?.toIso8601String() ?? '',
        t.executionDate.toIso8601String(),
        t.startHour?.toString() ?? '',
        t.startMinute?.toString() ?? '',
        t.estimatedDuration.toString(),
        t.memo ?? '',
        t.modeId ?? '',
        t.isSomeday.toString(),
        t.excludeFromReport.toString(),
        t.isImportant.toString(),
        t.isCompleted.toString(),
        t.createdAt.toIso8601String(),
        t.lastModified.toIso8601String(),
        t.userId,
        t.cloudId ?? '',
        t.isDeleted.toString(),
        t.deviceId,
        t.version.toString(),
      ]));
    }
    return buffer.toString();
  }

  /// Parse CSV and return list of maps for rows.
  static List<Map<String, String>> parseCsv(String csv) {
    final lines = csv.replaceAll('\r\n', '\n').split('\n');
    final records = <Map<String, String>>[];
    if (lines.isEmpty) return records;

    int idx = 0;
    List<String>? header;
    while (idx < lines.length) {
      final parsed = _readCsvRecord(lines, idx);
      if (parsed == null) break;
      final (fieldsRaw, nextIdx) = parsed;
      idx = nextIdx;

      if (fieldsRaw.isEmpty) continue;

      // Skip Excel's sep directive
      if (header == null &&
          fieldsRaw.length == 1 &&
          fieldsRaw[0].trim().toLowerCase().startsWith('sep=')) {
        continue;
      }

      if (header == null) {
        // Remove BOM if present
        final fields = List<String>.from(fieldsRaw);
        if (fields.isNotEmpty &&
            fields[0].isNotEmpty &&
            fields[0][0] == '\u{FEFF}') {
          fields[0] = fields[0].substring(1);
        }
        header = fields;
        continue;
      }

      // Build map from row
      final map = <String, String>{};
      final len =
          fieldsRaw.length < header.length ? fieldsRaw.length : header.length;
      for (int i = 0; i < len; i++) {
        map[header[i]] = fieldsRaw[i];
      }
      // Skip completely empty rows
      final allEmpty = map.values.every((v) => v.trim().isEmpty);
      if (!allEmpty) {
        records.add(map);
      }
    }
    return records;
  }

  /// Resolve project name to project ID.
  /// Throws if name is provided but not found.
  static String? resolveProjectId(Map<String, String> row) {
    // First check if projectId is directly provided
    final directId = (row['projectId'] ?? '').trim();
    if (directId.isNotEmpty) return directId;

    // Then check projectName
    final name = (row['projectName'] ?? '').trim();
    if (name.isEmpty) return null;

    final projects = ProjectService.getAllProjects();
    final match = projects.where((p) => p.name == name).toList();
    if (match.isEmpty) {
      throw Exception('プロジェクト「$name」が見つかりません');
    }
    return match.first.id;
  }

  /// Resolve sub-project name to sub-project ID.
  /// Throws if name is provided but not found.
  static String? resolveSubProjectId(Map<String, String> row) {
    // First check if subProjectId is directly provided
    final directId = (row['subProjectId'] ?? '').trim();
    if (directId.isNotEmpty) return directId;

    // Then check subProjectName
    final name = (row['subProjectName'] ?? '').trim();
    if (name.isEmpty) return null;

    final subProjects = SubProjectService.getAllSubProjects();
    final match = subProjects.where((sp) => sp.name == name).toList();
    if (match.isEmpty) {
      throw Exception('サブプロジェクト「$name」が見つかりません');
    }
    return match.first.id;
  }

  /// Resolve mode name to mode ID.
  /// Throws if name is provided but not found.
  static String? resolveModeId(Map<String, String> row) {
    // First check if modeId is directly provided
    final directId = (row['modeId'] ?? '').trim();
    if (directId.isNotEmpty) return directId;

    // Then check modeName
    final name = (row['modeName'] ?? '').trim();
    if (name.isEmpty) return null;

    final modes = ModeService.getAllModes();
    final match = modes.where((m) => m.name == name).toList();
    if (match.isEmpty) {
      throw Exception('モード「$name」が見つかりません');
    }
    return match.first.id;
  }

  /// Convert parsed row to InboxTask. Caller should set userId/deviceId.
  /// Throws if referenced names (project, subProject, mode) are not found.
  static InboxTask toInboxTask(
    Map<String, String> row, {
    required String userId,
    required String deviceId,
  }) {
    final now = DateTime.now();
    final id = (row['id'] ?? '').isNotEmpty
        ? row['id']!
        : 'inbox_${now.millisecondsSinceEpoch}_${now.microsecond}';

    // Parse executionDate or use dummy inbox date
    DateTime executionDate;
    final execDateStr = (row['executionDate'] ?? '').trim();
    if (execDateStr.isNotEmpty) {
      final parsed = DateTime.tryParse(execDateStr);
      if (parsed == null) {
        throw Exception('実施日「$execDateStr」の形式が正しくありません（例: 2025-01-20）');
      }
      executionDate = parsed;
    } else {
      executionDate = DateTime(2100, 1, 1);
    }

    // Resolve names to IDs (throws if not found)
    final projectId = resolveProjectId(row);
    final subProjectId = resolveSubProjectId(row);
    final modeId = resolveModeId(row);

    return InboxTask(
      id: id,
      title: row['title'] ?? '',
      projectId: projectId,
      subProjectId: subProjectId,
      dueDate: (row['dueDate'] ?? '').isNotEmpty
          ? DateTime.tryParse(row['dueDate']!)
          : null,
      executionDate: executionDate,
      startHour: int.tryParse(row['startHour'] ?? ''),
      startMinute: int.tryParse(row['startMinute'] ?? ''),
      estimatedDuration: int.tryParse(row['estimatedDuration'] ?? '') ?? 30,
      memo: _emptyToNull(row['memo']),
      modeId: modeId,
      isSomeday: (row['isSomeday'] ?? 'false').toLowerCase() == 'true',
      excludeFromReport:
          (row['excludeFromReport'] ?? 'false').toLowerCase() == 'true',
      isImportant: (row['isImportant'] ?? 'false').toLowerCase() == 'true',
      isCompleted: (row['isCompleted'] ?? 'false').toLowerCase() == 'true',
      createdAt: DateTime.tryParse(row['createdAt'] ?? '') ?? now,
      lastModified: DateTime.tryParse(row['lastModified'] ?? '') ?? now,
      userId: userId,
      cloudId: _emptyToNull(row['cloudId']),
      isDeleted: (row['isDeleted'] ?? 'false').toLowerCase() == 'true',
      deviceId: deviceId,
      version: int.tryParse(row['version'] ?? '1') ?? 1,
    );
  }

  // --- helpers ---
  static String? _emptyToNull(String? v) =>
      (v == null || v.isEmpty) ? null : v;

  static String _quote(String field) {
    final needsQuote =
        field.contains(',') || field.contains('\n') || field.contains('"');
    if (!needsQuote) return field;
    final escaped = field.replaceAll('"', '""');
    return '"$escaped"';
  }

  static String _join(List<String> fields) => fields.map(_quote).join(',');

  // Reads one RFC4180 record possibly spanning multiple lines.
  static (List<String>, int)? _readCsvRecord(List<String> lines, int startIdx) {
    if (startIdx >= lines.length) return null;
    final record = StringBuffer();
    bool inQuotes = false;
    int idx = startIdx;
    while (idx < lines.length) {
      final line = lines[idx];
      record.write(line);
      int quoteCount = 0;
      for (int i = 0; i < line.length; i++) {
        if (line[i] == '"') quoteCount++;
      }
      if (quoteCount % 2 != 0) inQuotes = !inQuotes;
      if (!inQuotes) break;
      record.write('\n');
      idx++;
    }
    final parsed = _splitCsvLine(record.toString());
    return (parsed, idx + 1);
  }

  static List<String> _splitCsvLine(String line) {
    final result = <String>[];
    final sb = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          sb.write('"');
          i++; // skip escaped quote
        } else {
          inQuotes = !inQuotes;
        }
      } else if (c == ',' && !inQuotes) {
        result.add(sb.toString());
        sb.clear();
      } else {
        sb.write(c);
      }
    }
    result.add(sb.toString());
    return result;
  }
}
