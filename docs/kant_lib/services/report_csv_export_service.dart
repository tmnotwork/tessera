import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../app/main_screen/report_period.dart';
import '../app/reporting/report_data_repository.dart';
import '../models/actual_task.dart';
import '../models/block.dart';
import '../utils/web_download_stub.dart'
    if (dart.library.html) '../utils/web_download_web.dart' as web_dl;
import 'mode_service.dart';
import 'project_service.dart';

class ReportCsvExportResult {
  const ReportCsvExportResult({
    required this.filename,
    required this.filePath,
    required this.rowCount,
  });

  final String filename;
  final String? filePath;
  final int rowCount;
}

class ReportCsvExportService {
  static Future<ReportCsvExportResult> exportRange({
    required ReportPeriod period,
    required DateTime rangeStartInclusive,
    required DateTime rangeEndInclusive,
  }) async {
    final normalized = _normalizeRange(rangeStartInclusive, rangeEndInclusive);
    final start = normalized.$1;
    final end = normalized.$2;

    final repo = ReportDataRepository.instance;
    final actualTasks = repo.getActualTasksInRange(start, end);
    final blocks = repo.getBlocksInRange(start, end);

    final built = _buildCsv(
      repo: repo,
      actualTasks: actualTasks,
      blocks: blocks,
      rangeStartInclusive: start,
      rangeEndInclusive: end,
    );
    final csv = built.$1;
    final rowCount = built.$2;
    final filename = 'report_${period.name}_${DateTime.now().millisecondsSinceEpoch}.csv';
    final content = '\uFEFF${csv.replaceAll('\n', '\r\n')}';
    final bytes = utf8.encode(content);

    if (kIsWeb) {
      web_dl.triggerDownload(filename, bytes);
      return ReportCsvExportResult(
        filename: filename,
        filePath: null,
        rowCount: rowCount,
      );
    }

    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/$filename';
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return ReportCsvExportResult(
      filename: filename,
      filePath: path,
      rowCount: rowCount,
    );
  }

  static (DateTime, DateTime) _normalizeRange(DateTime a, DateTime b) {
    final start = _dateOnly(a);
    final end = _dateOnly(b);
    if (start.isAfter(end)) return (end, start);
    return (start, end);
  }

  static DateTime _dateOnly(DateTime d) {
    final local = d.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  static (String, int) _buildCsv({
    required ReportDataRepository repo,
    required List<ActualTask> actualTasks,
    required List<Block> blocks,
    required DateTime rangeStartInclusive,
    required DateTime rangeEndInclusive,
  }) {
    final rangeStart = _dateOnly(rangeStartInclusive);
    final rangeEnd = _dateOnly(rangeEndInclusive);

    final header = <String>[
      'type',
      'date',
      'startTime',
      'endTime',
      'durationMinutes',
      'projectId',
      'projectName',
      'subProjectId',
      'subProjectName',
      'modeId',
      'modeName',
      'title',
      'memo',
      'location',
    ];
    final buffer = StringBuffer()..writeln(_join(header));
    int rowCount = 0;

    final List<_DetailRow> rows = [];

    for (final task in actualTasks) {
      final allocation = repo.getActualTaskAllocatedMinutesByDay(task);
      final interval = _actualIntervalLocal(task);
      if (interval == null) continue;
      final startLocal = interval.$1;
      final endLocalExclusive = interval.$2;
      for (final entry in allocation.entries) {
        final day = _dateOnly(entry.key);
        final minutes = entry.value;
        if (minutes <= 0) continue;
        if (day.isBefore(rangeStart) || day.isAfter(rangeEnd)) continue;
        final daySegment = _intersectWithDay(
          startLocal: startLocal,
          endLocalExclusive: endLocalExclusive,
          day: day,
        );
        final segStart = daySegment?.$1;
        final segEnd = daySegment?.$2;
        rows.add(_DetailRow(
          type: '実績',
          date: _formatDate(day),
          startTime: segStart != null ? _formatTime(segStart) : '',
          endTime: segEnd != null ? _formatTime(segEnd) : '',
          durationMinutes: minutes,
          projectId: task.projectId ?? '',
          projectName: _projectDisplayName(task.projectId ?? ''),
          subProjectId: task.subProjectId ?? '',
          subProjectName: task.subProject ?? '',
          modeId: task.modeId ?? '',
          modeName: _modeDisplayName(task.modeId ?? ''),
          title: task.blockName ?? task.title,
          memo: task.memo ?? '',
          location: task.location ?? '',
          sortKey: segStart ?? day,
        ));
      }
    }

    for (final block in blocks) {
      final allocation = repo.getBlockAllocatedWorkingMinutesByDay(block);
      final interval = _blockIntervalLocal(block);
      if (interval == null) continue;
      final startLocal = interval.$1;
      final endLocalExclusive = interval.$2;
      for (final entry in allocation.entries) {
        final day = _dateOnly(entry.key);
        final minutes = entry.value;
        if (minutes <= 0) continue;
        if (day.isBefore(rangeStart) || day.isAfter(rangeEnd)) continue;
        final daySegment = _intersectWithDay(
          startLocal: startLocal,
          endLocalExclusive: endLocalExclusive,
          day: day,
        );
        final segStart = daySegment?.$1;
        final segEnd = daySegment?.$2;
        rows.add(_DetailRow(
          type: '予定',
          date: _formatDate(day),
          startTime: segStart != null ? _formatTime(segStart) : '',
          endTime: segEnd != null ? _formatTime(segEnd) : '',
          durationMinutes: minutes,
          projectId: block.projectId ?? '',
          projectName: _projectDisplayName(block.projectId ?? ''),
          subProjectId: block.subProjectId ?? '',
          subProjectName: block.subProject ?? '',
          modeId: block.modeId ?? '',
          modeName: _modeDisplayName(block.modeId ?? ''),
          title: block.blockName ?? block.title,
          memo: block.memo ?? '',
          location: block.location ?? '',
          sortKey: segStart ?? day,
        ));
      }
    }

    rows.sort((a, b) {
      final cmp = a.sortKey.compareTo(b.sortKey);
      if (cmp != 0) return cmp;
      final typeOrder = a.type == '予定' ? 0 : 1;
      final typeOrderB = b.type == '予定' ? 0 : 1;
      return typeOrder.compareTo(typeOrderB);
    });

    for (final row in rows) {
      buffer.writeln(_join([
        row.type,
        row.date,
        row.startTime,
        row.endTime,
        row.durationMinutes.toString(),
        row.projectId,
        row.projectName,
        row.subProjectId,
        row.subProjectName,
        row.modeId,
        row.modeName,
        row.title,
        row.memo,
        row.location,
      ]));
      rowCount++;
    }

    return (buffer.toString(), rowCount);
  }

  static String _projectDisplayName(String projectId) {
    return ProjectService.getProjectById(projectId)?.name ??
        (projectId.isEmpty ? '未分類' : projectId);
  }

  static String _modeDisplayName(String modeId) {
    if (modeId.isEmpty) return '';
    return ModeService.getModeById(modeId)?.name ?? modeId;
  }

  static (DateTime, DateTime)? _actualIntervalLocal(ActualTask task) {
    final startLocal = task.startAt?.toLocal() ?? task.startTime.toLocal();
    final endLocal = (() {
      final canonical = task.endAtExclusive?.toLocal();
      if (canonical != null) return canonical;
      final legacy = task.endTime?.toLocal();
      if (legacy != null) return legacy;
      if (task.actualDuration > 0) {
        return startLocal.add(Duration(minutes: task.actualDuration));
      }
      return DateTime.now();
    })();
    if (!endLocal.isAfter(startLocal)) return null;
    return (startLocal, endLocal);
  }

  static (DateTime, DateTime)? _blockIntervalLocal(Block block) {
    final startLocal = block.startAt?.toLocal() ??
        DateTime(
          block.executionDate.year,
          block.executionDate.month,
          block.executionDate.day,
          block.startHour,
          block.startMinute,
        );
    final endLocalExclusive = block.endAtExclusive?.toLocal() ??
        DateTime(
          block.executionDate.year,
          block.executionDate.month,
          block.executionDate.day,
          block.startHour,
          block.startMinute,
        ).add(Duration(minutes: block.estimatedDuration));
    if (!endLocalExclusive.isAfter(startLocal)) return null;
    return (startLocal, endLocalExclusive);
  }

  static (DateTime, DateTime)? _intersectWithDay({
    required DateTime startLocal,
    required DateTime endLocalExclusive,
    required DateTime day,
  }) {
    final dayStart = _dateOnly(day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final segStart = startLocal.isAfter(dayStart) ? startLocal : dayStart;
    final segEnd =
        endLocalExclusive.isBefore(dayEnd) ? endLocalExclusive : dayEnd;
    if (!segEnd.isAfter(segStart)) return null;
    return (segStart, segEnd);
  }

  static String _formatDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

  static String _formatTime(DateTime d) {
    final local = d.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  static String _quote(String field) {
    final needsQuote =
        field.contains(',') || field.contains('\n') || field.contains('"');
    if (!needsQuote) return field;
    final escaped = field.replaceAll('"', '""');
    return '"$escaped"';
  }

  static String _join(List<String> fields) => fields.map(_quote).join(',');
}

class _DetailRow {
  const _DetailRow({
    required this.type,
    required this.date,
    required this.startTime,
    required this.endTime,
    required this.durationMinutes,
    required this.projectId,
    required this.projectName,
    required this.subProjectId,
    required this.subProjectName,
    required this.modeId,
    required this.modeName,
    required this.title,
    required this.memo,
    required this.location,
    required this.sortKey,
  });

  final String type;
  final String date;
  final String startTime;
  final String endTime;
  final int durationMinutes;
  final String projectId;
  final String projectName;
  final String subProjectId;
  final String subProjectName;
  final String modeId;
  final String modeName;
  final String title;
  final String memo;
  final String location;
  final DateTime sortKey;
}
