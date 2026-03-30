import 'package:flutter/material.dart';

import '../database/local_database.dart';
import 'english_example_composition_progress_screen.dart';
import 'english_example_progress_screen.dart';
import 'four_choice_progress_screen.dart';
import 'study_report_screen.dart';

/// 学習者向け：例文・四択など学習状況確認画面への入口。
class LearnerLearningStatusMenuScreen extends StatelessWidget {
  const LearnerLearningStatusMenuScreen({super.key, this.localDatabase});

  final LocalDatabase? localDatabase;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('学習状況の確認'),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.bar_chart),
            title: const Text('学習時間レポート'),
            subtitle: const Text('日・週・月・年ごとの学習時間を確認'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => StudyReportScreen(
                    localDatabase: localDatabase,
                  ),
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.translate),
            title: const Text('例文読み上げ'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const EnglishExampleProgressScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.edit_note),
            title: const Text('英作文'),
            subtitle: const Text('答え合わせの記録を単元別に表示'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) =>
                      const EnglishExampleCompositionProgressScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.quiz_outlined),
            title: const Text('四択問題'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const FourChoiceProgressScreen(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
