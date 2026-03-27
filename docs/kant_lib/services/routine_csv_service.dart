import 'package:flutter/material.dart';
import '../models/routine_shortcut_task_row.dart';

class RoutineCsvService {
  static const List<String> headers = [
    'id',
    'name',
    'routineTemplateName',
    'projectId',
    'date',
    'startTime',
    'endTime',
    'details',
    'memo',
    'subProjectId',
    'subProject',
    'modeId',
    'blockName',
    'location',
    'routineTemplateId',
    'timeZoneId',
    'createdAt',
    'lastModified',
    'userId',
    'cloudId',
    'lastSynced',
    'isDeleted',
    'deviceId',
    'version',
  ];

  /// Export tasks to CSV string (UTF-8). Fields are RFC4180-quoted.
  static String exportCsv(List<RoutineShortcutTaskRow> tasks) {
    final buffer = StringBuffer();
    buffer.writeln(_join(headers));
    for (final t in tasks) {
      buffer.writeln(_join([
        t.id,
        t.name,
        '', // routineTemplateName (will be populated during export)
        t.projectId ?? '',
        '', // date (will be populated during export)
        _fmtTime(t.startTime),
        _fmtTime(t.endTime),
        t.details ?? '',
        t.memo ?? '',
        t.subProjectId ?? '',
        t.subProject ?? '',
        t.modeId ?? '',
        t.blockName ?? '',
        t.location ?? '',
        t.routineTemplateId,
        t.timeZoneId,
        t.createdAt.toIso8601String(),
        t.lastModified.toIso8601String(),
        t.userId,
        t.cloudId ?? '',
        t.lastSynced?.toIso8601String() ?? '',
        t.isDeleted.toString(),
        t.deviceId,
        t.version.toString(),
      ]));
    }
    return buffer.toString();
  }

  /// Parse CSV produced by exportCsv and return list of maps for rows.
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

      // Excel の先頭行ディレクティブ "sep=," をスキップ
      if (header == null &&
          fieldsRaw.length == 1 &&
          fieldsRaw[0].trim().toLowerCase().startsWith('sep=')) {
        continue;
      }

      if (header == null) {
        // ヘッダーを確定（BOM除去）
        final fields = List<String>.from(fieldsRaw);
        if (fields.isNotEmpty &&
            fields[0].isNotEmpty &&
            fields[0][0] == '\u{FEFF}') {
          fields[0] = fields[0].substring(1);
        }
        header = fields;
        continue;
      }

      // データ行をマップ化
      final map = <String, String>{};
      final len =
          fieldsRaw.length < header.length ? fieldsRaw.length : header.length;
      for (int i = 0; i < len; i++) {
        map[header[i]] = fieldsRaw[i];
      }
      // 完全空行はスキップ
      final allEmpty = map.values.every((v) => v.trim().isEmpty);
      if (!allEmpty) {
        records.add(map);
      }
    }
    return records;
  }

  /// CSV 1 行を **非永続**の表示行 DTO に変換。監査系フィールドは呼び出し側で上書きする。
  static RoutineShortcutTaskRow fromCsvRow(Map<String, String> row) {
    TimeOfDay parseTime(String s) {
      final parts = s.split(':');
      int h = 0, m = 0;
      if (parts.isNotEmpty) h = int.tryParse(parts[0]) ?? 0;
      if (parts.length > 1) m = int.tryParse(parts[1]) ?? 0;
      return TimeOfDay(hour: h.clamp(0, 23), minute: m.clamp(0, 59));
    }

    final id = (row['id'] ?? '').isNotEmpty
        ? row['id']!
        : 'routine_task_${DateTime.now().millisecondsSinceEpoch}';

    return RoutineShortcutTaskRow(
      id: id,
      name: row['name'] ?? '',
      projectId: _emptyToNull(row['projectId']),
      startTime: parseTime(row['startTime'] ?? '00:00'),
      endTime: parseTime(row['endTime'] ?? '00:00'),
      details: _emptyToNull(row['details']),
      memo: _emptyToNull(row['memo']),
      subProjectId: _emptyToNull(row['subProjectId']),
      subProject: _emptyToNull(row['subProject']),
      modeId: _emptyToNull(row['modeId']),
      blockName: _emptyToNull(row['blockName']),
      location: _emptyToNull(row['location']),
      routineTemplateId: row['routineTemplateId'] ?? '',
      timeZoneId: row['timeZoneId'] ?? '',
      createdAt: DateTime.tryParse(row['createdAt'] ?? '') ?? DateTime.now(),
      lastModified:
          DateTime.tryParse(row['lastModified'] ?? '') ?? DateTime.now(),
      userId: row['userId'] ?? '',
      cloudId: _emptyToNull(row['cloudId']),
      lastSynced: row['lastSynced'] != null && row['lastSynced']!.isNotEmpty
          ? DateTime.tryParse(row['lastSynced']!)
          : null,
      isDeleted: (row['isDeleted'] ?? 'false').toLowerCase() == 'true',
      deviceId: row['deviceId'] ?? '',
      version: int.tryParse(row['version'] ?? '1') ?? 1,
    );
  }

  // --- helpers ---
  static String? _emptyToNull(String? v) => (v == null || v.isEmpty) ? null : v;

  static String _fmtTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

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
      // Count quotes to detect closure (odd number of quotes -> toggles)
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
