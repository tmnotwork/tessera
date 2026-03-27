import 'package:flutter/material.dart';
import '../services/app_settings_service.dart';

class ProjectSettingsScreen extends StatefulWidget {
  final bool initialTwoColumn;
  final bool initialHideEmpty;

  const ProjectSettingsScreen({
    super.key,
    required this.initialTwoColumn,
    required this.initialHideEmpty,
  });

  @override
  State<ProjectSettingsScreen> createState() => _ProjectSettingsScreenState();
}

class _ProjectSettingsScreenState extends State<ProjectSettingsScreen> {
  bool _twoColumn = false;
  bool _hideEmpty = true;

  @override
  void initState() {
    super.initState();
    _twoColumn = widget.initialTwoColumn;
    _hideEmpty = widget.initialHideEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('プロジェクト設定'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: AppSettingsService.projectShowProjectsOnlyNotifier,
              builder: (context, value, _) {
                return SwitchListTile(
                  title: const Text('プロジェクトのみを表示'),
                  subtitle: const Text(
                    'プロジェクト一覧で未了タスクをカード下に表示しません',
                  ),
                  value: value,
                  onChanged: (v) async {
                    await AppSettingsService.setBool(
                      AppSettingsService.keyProjectShowProjectsOnly,
                      v,
                    );
                  },
                );
              },
            ),
            const Divider(),
            SwitchListTile(
              title: const Text('2列表示にする'),
              value: _twoColumn,
              onChanged: (v) {
                setState(() => _twoColumn = v);
                Navigator.of(context)
                    .pop({'twoColumn': v, 'hideEmpty': _hideEmpty});
              },
            ),
            const Divider(),
            SwitchListTile(
              title: const Text('未実施なしのプロジェクトを非表示'),
              value: _hideEmpty,
              onChanged: (v) {
                setState(() => _hideEmpty = v);
                Navigator.of(context)
                    .pop({'twoColumn': _twoColumn, 'hideEmpty': v});
              },
            ),
            const SizedBox(height: 12),
            Text(
              '設定は保存され、プロジェクト画面に反映されます。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
