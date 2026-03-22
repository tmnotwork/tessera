import 'package:flutter/material.dart';

import 'english_example_progress_screen.dart';
import 'four_choice_progress_screen.dart';

/// 学習者向け：例文・四択など学習状況確認画面への入口。
class LearnerLearningStatusMenuScreen extends StatelessWidget {
  const LearnerLearningStatusMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('学習状況の確認'),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.translate),
            title: const Text('英語例文'),
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
