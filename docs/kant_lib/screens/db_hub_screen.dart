import 'package:flutter/material.dart';

enum DbSubView {
  hub,
  inbox,
  blocks,
  actualBlocks,
  projects,
  routineTemplatesV2,
  routineTasksV2,
  categories,
}

class DbHubScreen extends StatelessWidget {
  final void Function(DbSubView view)? onSelect;
  const DbHubScreen({super.key, this.onSelect});

  @override
  Widget build(BuildContext context) {
    final entries = <_DbEntry>[
      _DbEntry(
        icon: Icons.inbox,
        title: 'インボックス',
        subtitle: '全レコード（デフォルト: 過去3ヶ月）',
        onTap: () => onSelect?.call(DbSubView.inbox),
      ),
      _DbEntry(
        icon: Icons.add_box_outlined,
        title: '予定ブロック',
        subtitle: '実行日範囲でフィルタ可',
        onTap: () => onSelect?.call(DbSubView.blocks),
      ),
      _DbEntry(
        icon: Icons.task_alt,
        title: '実績ブロック',
        subtitle: '最新30日分を表示（フィルタ可）',
        onTap: () => onSelect?.call(DbSubView.actualBlocks),
      ),
      _DbEntry(
        icon: Icons.folder,
        title: 'プロジェクト',
        subtitle: '全件表示・削除',
        onTap: () => onSelect?.call(DbSubView.projects),
      ),
      _DbEntry(
        icon: Icons.schedule,
        title: 'ルーティンテンプレート（V2）',
        subtitle: 'ローカルHive + 同期（routine_templates_v2）',
        onTap: () => onSelect?.call(DbSubView.routineTemplatesV2),
      ),
      _DbEntry(
        icon: Icons.repeat,
        title: 'ルーティンタスク（V2）',
        subtitle: 'ローカルHive + 同期（routine_tasks_v2）',
        onTap: () => onSelect?.call(DbSubView.routineTasksV2),
      ),
      _DbEntry(
        icon: Icons.category,
        title: 'カテゴリー',
        subtitle: '全件表示・追加・編集・削除',
        onTap: () => onSelect?.call(DbSubView.categories),
      ),
      const _DbEntry(icon: Icons.view_week, title: 'カレンダー', subtitle: '近日対応'),
    ];

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final e = entries[index];
        final bool available = e.onTap != null;
        return ListTile(
          leading: Icon(
            e.icon,
            color: Theme.of(context).iconTheme.color, // 明示色で「透明」見えを防ぐ
          ),
          title: Text(e.title),
          subtitle: e.subtitle != null ? Text(e.subtitle!) : null,
          trailing: available
              ? const Icon(Icons.chevron_right)
              : const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4.0),
                  child: Chip(label: Text('近日対応')),
                ),
          onTap: e.onTap,
          enabled: true,
        );
      },
    );
  }
}

class _DbEntry {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  const _DbEntry({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });
}
