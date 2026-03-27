import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/inbox_task.dart' as inbox;
import '../../models/block.dart' as block;
import '../../models/actual_task.dart' as actual;
import '../../screens/mobile_task_edit_screen.dart';
import '../../utils/unified_screen_dialog.dart';
import '../inbox/inbox_memo_dialog.dart';

class TaskDetailsDialog extends StatelessWidget {
  final dynamic task;

  const TaskDetailsDialog({super.key, required this.task});

  String _typeLabel() {
    if (task is actual.ActualTask) return '実績';
    if (task is block.Block) return '予定';
    if (task is inbox.InboxTask) return 'インボックス';
    return 'タスク';
  }

  @override
  Widget build(BuildContext context) {
    // showDialog 直出し（アンカー無し）だと内容量次第で極端に細くなるので、
    // ここで最低幅を明示して「文章幅だけ」になるのを防ぐ。
    final screenWidth = MediaQuery.of(context).size.width;
    final available = (screenWidth - 48).clamp(0.0, double.infinity);
    double targetWidth = screenWidth >= 1200 ? 600 : 520;
    if (targetWidth > available) targetWidth = available;
    if (targetWidth < 360) targetWidth = 360;

    return AlertDialog(
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color:
                  Theme.of(context).colorScheme.primary.withOpacity( 0.1),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withOpacity( 0.3),
              ),
            ),
            child: Text(
              _typeLabel(),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '詳細',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const Spacer(),
          if (_canShowMenu())
            PopupMenuButton<String>(
              tooltip: 'メニュー',
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (value) => _onMenuSelected(value, context),
              itemBuilder: (ctx) => _buildMenuItems(),
            ),
        ],
      ),
      content: SizedBox(
        width: targetWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _buildContentSections(context),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('閉じる'),
        ),
      ],
    );
  }

  List<Widget> _buildContentSections(BuildContext context) {
    final sections = <Widget>[];

    void addField(String label, String? value) {
      if (value == null || value.isEmpty) return;
      sections.add(Row(
        children: [
          Expanded(
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.bold))),
          IconButton(
            tooltip: 'コピー',
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('コピーしました: $label')),
              );
            },
          ),
        ],
      ));
      sections.add(SelectableText(value));
      sections.add(const SizedBox(height: 8));
    }

    void addFieldAll(String label, Object? value) {
      final String text;
      if (value == null) {
        text = '<null>';
      } else if (value is DateTime) {
        text = _fmtDT(value);
      } else if (value is bool) {
        text = value ? 'true' : 'false';
      } else if (value is List) {
        // List<String> 想定だが、型が混ざっていても落ちないようにする
        text = value.map((e) => e?.toString() ?? '<null>').join(', ');
      } else {
        text = value.toString();
      }
      // “すべての情報”を表示するため、空文字も含めて出す
      sections.add(Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          IconButton(
            tooltip: 'コピー',
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('コピーしました: $label')),
              );
            },
          ),
        ],
      ));
      sections.add(SelectableText(text));
      sections.add(const SizedBox(height: 8));
    }

    if (task is actual.ActualTask) {
      final t = task as actual.ActualTask;
      addField('タイトル', t.title);
      addField('ブロック名', t.blockName ?? '');
      addField('プロジェクト', t.projectId ?? '');
      addField('サブプロジェクト', t.subProject ?? '');
      addField('場所', t.location ?? '');
      addField('開始時刻', _fmtDT(t.startTime));
      addField('終了時刻', t.endTime != null ? _fmtDT(t.endTime!) : '');
      addField('実績時間(分)', t.durationInMinutes.toString());
      addField('メモ', t.memo ?? '');
      addField('作成日時', _fmtDT(t.createdAt));
      addField('最終更新', _fmtDT(t.lastModified));
      addField('cloudId', t.cloudId);
    } else if (task is block.Block) {
      final b = task as block.Block;
      // 「詳細を表示」では予定ブロックのすべての情報を表示する（null/空も含む）
      addFieldAll('id', b.id);
      addFieldAll('タイトル', b.title);
      addFieldAll('作成種別(creationMethod)', b.creationMethod.name);
      addFieldAll('プロジェクトID(projectId)', b.projectId);
      addFieldAll('期限(dueDate)', b.dueDate == null ? null : _fmtDate(b.dueDate!));
      addFieldAll('実行日(executionDate)', _fmtDate(b.executionDate));
      addFieldAll('開始時刻(startHour:startMinute)', _fmtHM(b.startHour, b.startMinute));
      addFieldAll('予定時間(分)(estimatedDuration)', b.estimatedDuration);
      addFieldAll('稼働(分)(workingMinutes)', b.workingMinutes);
      addFieldAll('休憩(分)(breakMinutes)', b.breakMinutes);

      // Canonical range（UTC）と、互換の壁時計表示（account wall clock）
      addFieldAll('startAt(UTC)', b.startAt == null ? null : _fmtDT(b.startAt!));
      addFieldAll(
        'endAtExclusive(UTC)',
        b.endAtExclusive == null ? null : _fmtDT(b.endAtExclusive!),
      );
      addFieldAll('終日(allDay)', b.allDay);
      addFieldAll('dayKeys', b.dayKeys ?? const <String>[]);
      addFieldAll('monthKeys', b.monthKeys ?? const <String>[]);

      addFieldAll('ブロック名(blockName)', b.blockName);
      addFieldAll('メモ(memo)', b.memo);
      addFieldAll('場所(location)', b.location);
      addFieldAll('モードID(modeId)', b.modeId);
      addFieldAll('サブプロジェクトID(subProjectId)', b.subProjectId);
      addFieldAll('サブプロジェクト名(subProject)', b.subProject);

      addFieldAll('完了(isCompleted)', b.isCompleted);
      addFieldAll('イベント(isEvent)', b.isEvent);
      addFieldAll('ルーティン由来(isRoutineDerived)', b.isRoutineDerived);
      addFieldAll('中断由来(isPauseDerived)', b.isPauseDerived);
      addFieldAll('紐づくタスクID(taskId)', b.taskId);

      addFieldAll('作成日時(createdAt)', _fmtDT(b.createdAt));
      addFieldAll('最終更新(lastModified)', _fmtDT(b.lastModified));
      addFieldAll('ユーザーID(userId)', b.userId);

      // 同期・メタ
      addFieldAll('cloudId', b.cloudId);
      addFieldAll('lastSynced', b.lastSynced == null ? null : _fmtDT(b.lastSynced!));
      addFieldAll('isDeleted', b.isDeleted);
      addFieldAll('deviceId', b.deviceId);
      addFieldAll('version', b.version);
    } else if (task is inbox.InboxTask) {
      final i = task as inbox.InboxTask;
      addField('id', i.id);
      addField('タイトル', i.title);
      addField('プロジェクト', i.projectId ?? '');
      addField('サブプロジェクトID', i.subProjectId ?? '');
      if (i.startHour != null && i.startMinute != null) {
        addField('開始時刻', _fmtHM(i.startHour!, i.startMinute!));
      }
      addField('予定時間(分)', i.estimatedDuration.toString());
      addField('メモ', i.memo ?? '');
      addField('作成日時', _fmtDT(i.createdAt));
      addField('最終更新', _fmtDT(i.lastModified));
      addField('cloudId', i.cloudId);
    }

    if (sections.isEmpty) {
      sections.add(const Text('詳細情報はありません'));
    }
    return sections;
  }

  bool _canShowMenu() =>
      task is inbox.InboxTask || task is actual.ActualTask || task is block.Block;

  List<PopupMenuEntry<String>> _buildMenuItems() {
    final items = <PopupMenuEntry<String>>[];
    if (task is actual.ActualTask || task is block.Block) {
      items.add(
        const PopupMenuItem<String>(
          value: 'edit',
          child: Text('編集'),
        ),
      );
    }
    if (task is inbox.InboxTask) {
      items.add(
        const PopupMenuItem<String>(
          value: 'memo',
          child: Text('コメント'),
        ),
      );
    }
    return items;
  }

  void _onMenuSelected(String value, BuildContext context) {
    if (value == 'edit' && (task is actual.ActualTask || task is block.Block)) {
      final navigator = Navigator.of(context, rootNavigator: true);
      // 詳細ダイアログを閉じてから編集画面を開く
      navigator.pop();
      Future.microtask(() {
        showUnifiedScreenDialog<void>(
          context: navigator.context,
          builder: (_) => MobileTaskEditScreen(task: task),
        );
      });
      return;
    }
    if (value == 'memo' && task is inbox.InboxTask) {
      showInboxMemoEditorDialog(context, task as inbox.InboxTask);
      return;
    }
  }

  String _fmtHM(int h, int m) =>
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String _fmtDT(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
