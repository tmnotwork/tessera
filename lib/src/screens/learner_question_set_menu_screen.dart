import 'package:flutter/material.dart';

import 'english_example_list_screen.dart';
import 'learner_home_screen.dart';

/// 学習者向け：問題集タブの入口（四択 / 英作文）。
class LearnerQuestionSetMenuScreen extends StatelessWidget {
  const LearnerQuestionSetMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('問題集'),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.quiz_outlined),
            title: const Text('四択'),
            subtitle: const Text('四択問題に挑戦'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (context) => const LearnerFourChoiceSolveScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.edit_note),
            title: const Text('英作文'),
            subtitle: const Text('チャプターから英作文練習'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (context) => const EnglishExampleListScreen(
                    isLearnerMode: true,
                    compositionMenuOnly: true,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
