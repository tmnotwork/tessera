import 'package:flutter/material.dart';

import '../models/routine_template_v2.dart';
import '../services/routine_template_v2_service.dart';
import '../services/routine_mutation_facade.dart';
import 'routine_detail_screen_v2_table.dart';

class RoutineTemplateV2DbScreen extends StatefulWidget {
  const RoutineTemplateV2DbScreen({super.key});

  @override
  State<RoutineTemplateV2DbScreen> createState() =>
      _RoutineTemplateV2DbScreenState();
}

class _RoutineTemplateV2DbScreenState extends State<RoutineTemplateV2DbScreen> {
  List<RoutineTemplateV2> _loadLocal() {
    final list = RoutineTemplateV2Service.getAll(includeDeleted: true);
    list.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    return list;
  }

  static const double _colTitleWidth = 200;
  static const double _colApplyWidth = 100;
  static const double _colActiveWidth = 56;
  static const double _colEditWidth = 48;
  static const double _colDeleteWidth = 48;
  static const double _minTableWidth = 520;

  String _applyDayTypeLabel(String applyDayType) {
    switch (applyDayType) {
      case 'weekday':
        return '平日';
      case 'holiday':
        return '休日';
      case 'both':
        return '毎日';
      default:
        if (applyDayType.startsWith('dow:')) return '曜日指定';
        return applyDayType;
    }
  }

  Future<void> _openEdit(RoutineTemplateV2 t) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RoutineDetailScreenV2Table(
          routine: t,
          embedded: false,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _deleteTemplate(RoutineTemplateV2 t) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('テンプレートを削除'),
        content: Text(
          '「${t.title.isEmpty ? "（名称なし）" : t.title}」を削除しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await RoutineMutationFacade.instance.deleteTemplate(t.id);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('削除に失敗しました: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final templates = _loadLocal();
    final theme = Theme.of(context);
    final borderColor = theme.dividerColor;
    final headerStyle = theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: theme.textTheme.bodySmall?.color,
        ) ??
        const TextStyle(fontSize: 12, fontWeight: FontWeight.bold);

    Widget headerCell(String label, double width, {bool center = false}) {
      return SizedBox(
        width: width,
        height: 40,
        child: Container(
          alignment: center ? Alignment.center : Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withOpacity(
                theme.brightness == Brightness.light ? 1 : 0.2),
            border: Border(
              right: BorderSide(color: borderColor),
              bottom: BorderSide(color: borderColor),
            ),
          ),
          child: Text(label, style: headerStyle),
        ),
      );
    }

    Widget dataCell(Widget child, double width, {bool center = false}) {
      return SizedBox(
        width: width,
        height: 48,
        child: Container(
          alignment: center ? Alignment.center : Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(color: borderColor),
              bottom: BorderSide(color: borderColor),
            ),
          ),
          child: child,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('ルーティンテンプレート（V2） ${templates.length}件'),
      ),
      body: Scrollbar(
        thumbVisibility: true,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: _minTableWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ヘッダー行
                Row(
                  children: [
                    headerCell('テンプレート名', _colTitleWidth),
                    headerCell('適用', _colApplyWidth, center: true),
                    headerCell('有効', _colActiveWidth, center: true),
                    headerCell('編集', _colEditWidth, center: true),
                    headerCell('削除', _colDeleteWidth, center: true),
                  ],
                ),
                // データ行
                if (templates.isEmpty)
                  Row(
                    children: [
                      dataCell(
                        Text(
                          'テンプレートがありません',
                          style: theme.textTheme.bodySmall,
                        ),
                        _colTitleWidth + _colApplyWidth + _colActiveWidth,
                      ),
                      dataCell(const SizedBox.shrink(), _colEditWidth,
                          center: true),
                      dataCell(const SizedBox.shrink(), _colDeleteWidth,
                          center: true),
                    ],
                  )
                else
                  ...templates.map((t) {
                    return Row(
                      children: [
                        dataCell(
                          Text(
                            t.title.isEmpty ? '（名称なし）' : t.title,
                            style: theme.textTheme.bodyMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                          _colTitleWidth,
                        ),
                        dataCell(
                          Text(
                            _applyDayTypeLabel(t.applyDayType),
                            style: theme.textTheme.bodySmall,
                          ),
                          _colApplyWidth,
                        ),
                        dataCell(
                          Icon(
                            t.isActive ? Icons.check_circle : Icons.cancel,
                            size: 20,
                            color: t.isActive
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outline,
                          ),
                          _colActiveWidth,
                          center: true,
                        ),
                        dataCell(
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            tooltip: '編集',
                            onPressed: () => _openEdit(t),
                          ),
                          _colEditWidth,
                          center: true,
                        ),
                        dataCell(
                          IconButton(
                            icon: Icon(
                              Icons.delete_outline,
                              size: 20,
                              color: theme.colorScheme.error,
                            ),
                            tooltip: '削除',
                            onPressed: () => _deleteTemplate(t),
                          ),
                          _colDeleteWidth,
                          center: true,
                        ),
                      ],
                    );
                  }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
