import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../models/inbox_task.dart';
import '../../providers/task_provider.dart';
import '../../services/auth_service.dart';
import '../../services/device_info_service.dart';
import '../../services/inbox_csv_service.dart';
import '../../utils/web_download_stub.dart'
    if (dart.library.html) '../../utils/web_download_web.dart' as web_dl;

class InboxCsvImportDialog extends StatefulWidget {
  const InboxCsvImportDialog({super.key});

  @override
  State<InboxCsvImportDialog> createState() => _InboxCsvImportDialogState();
}

class _InboxCsvImportDialogState extends State<InboxCsvImportDialog> {
  bool _isImporting = false;
  String? _statusMessage;

  Future<void> _downloadTemplate() async {
    try {
      final csv = InboxCsvService.generateTemplateCsv();
      final filename =
          'inbox_template_${DateTime.now().millisecondsSinceEpoch}.csv';
      final content = '\uFEFF${csv.replaceAll('\n', '\r\n')}';
      final bytes = utf8.encode(content);

      if (kIsWeb) {
        web_dl.triggerDownload(filename, bytes);
        setState(() {
          _statusMessage = 'テンプレートをダウンロードしました';
        });
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/$filename');
        await file.writeAsBytes(bytes, flush: true);
        setState(() {
          _statusMessage = 'テンプレートを保存しました: ${file.path}';
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'テンプレートのダウンロードに失敗しました: $e';
      });
    }
  }

  Future<void> _importCsv() async {
    if (_isImporting) return;
    setState(() {
      _isImporting = true;
      _statusMessage = null;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        allowMultiple: false,
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) {
        setState(() {
          _isImporting = false;
        });
        return;
      }

      String csvContent;
      final picked = result.files.first;
      if (kIsWeb) {
        final bytes = picked.bytes;
        if (bytes == null) throw Exception('ファイルの読み込みに失敗しました');
        csvContent =
            utf8.decode(bytes, allowMalformed: true).replaceAll('\uFEFF', '');
      } else {
        final path = picked.path;
        if (path == null) throw Exception('ファイルパスが取得できません');
        final file = File(path);
        csvContent = (await file.readAsString()).replaceAll('\uFEFF', '');
      }

      final rows = InboxCsvService.parseCsv(csvContent);
      if (rows.isEmpty) {
        setState(() {
          _isImporting = false;
          _statusMessage = 'CSVにデータがありません';
        });
        return;
      }

      final deviceId = await DeviceInfoService.getDeviceId();
      final uid = AuthService.getCurrentUserId() ?? '';

      final tasks = <InboxTask>[];
      for (final row in rows) {
        final title = (row['title'] ?? '').trim();
        if (title.isEmpty) continue;
        final task = InboxCsvService.toInboxTask(
          row,
          userId: uid,
          deviceId: deviceId,
        );
        tasks.add(task);
      }

      if (tasks.isEmpty) {
        setState(() {
          _isImporting = false;
          _statusMessage = 'インポート可能なタスクがありません（titleが必須です）';
        });
        return;
      }

      // Add tasks via provider
      if (!mounted) return;
      final provider = context.read<TaskProvider>();
      int imported = 0;
      for (final task in tasks) {
        await provider.addInboxTask(task);
        imported++;
      }

      setState(() {
        _isImporting = false;
        _statusMessage = '$imported 件のタスクをインポートしました';
      });

      // Refresh tasks
      await provider.refreshTasks(showLoading: false);

      // Close dialog after short delay
      await Future.delayed(const Duration(milliseconds: 1500));
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      setState(() {
        _isImporting = false;
        _statusMessage = 'インポートエラー: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('CSVインポート'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Template download section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.description, color: scheme.primary),
                        const SizedBox(width: 8),
                        const Text(
                          '1. テンプレートをダウンロード',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'CSVテンプレートをダウンロードして、タスクを入力してください。',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _downloadTemplate,
                      icon: const Icon(Icons.download),
                      label: const Text('テンプレートをダウンロード'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Import section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.upload_file, color: scheme.primary),
                        const SizedBox(width: 8),
                        const Text(
                          '2. CSVをアップロード',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '入力済みのCSVファイルをアップロードしてインポートします。',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _isImporting ? null : _importCsv,
                      icon: _isImporting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.upload),
                      label: Text(_isImporting ? 'インポート中...' : 'CSVをアップロード'),
                    ),
                  ],
                ),
              ),
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _statusMessage!,
                  style: TextStyle(
                    fontSize: 12,
                    color: _statusMessage!.contains('エラー') ||
                            _statusMessage!.contains('失敗')
                        ? scheme.error
                        : scheme.onSurface,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            // Field description
            ExpansionTile(
              title: const Text(
                'CSVフィールド説明',
                style: TextStyle(fontSize: 12),
              ),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: [
                _buildFieldDesc('title', 'タスク名（必須）'),
                _buildFieldDesc('estimatedDuration', '見積時間（分）デフォルト30'),
                _buildFieldDesc('projectId', 'プロジェクトID（任意）'),
                _buildFieldDesc('subProjectId', 'サブプロジェクトID（任意）'),
                _buildFieldDesc('memo', 'メモ（任意）'),
                _buildFieldDesc('isSomeday', 'いつかフラグ（true/false）'),
                _buildFieldDesc('isImportant', '重要フラグ（true/false）'),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('閉じる'),
        ),
      ],
    );
  }

  Widget _buildFieldDesc(String field, String desc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              field,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text(
              desc,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}
