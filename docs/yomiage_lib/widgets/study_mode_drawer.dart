import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:yomiage/screens/study_mode_filter.dart';
import 'package:yomiage/services/tts_service.dart';

class StudyModeDrawer extends StatelessWidget {
  final StudyModeFilter studyModeFilter;
  final ValueChanged<StudyModeFilter> onStudyModeFilterChanged;
  final VoidCallback onSaveSettings;

  const StudyModeDrawer({
    Key? key,
    required this.studyModeFilter,
    required this.onStudyModeFilterChanged,
    required this.onSaveSettings,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Web ではドロワーを表示しない
    if (kIsWeb) return const SizedBox.shrink();

    return FractionallySizedBox(
      widthFactor: 0.75, // 画面幅の 3/4
      child: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: Theme.of(context).primaryColor),
              child: const Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  '出題モード',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ),
            _buildDrawerToggle(
              title: '全問出題',
              subtitle: '既に覚えた問題も含めて、全問を出題します。',
              value: studyModeFilter == StudyModeFilter.allCards,
              onChanged: (value) {
                onStudyModeFilterChanged(
                  value ? StudyModeFilter.allCards : StudyModeFilter.dueToday,
                );
                onSaveSettings();
              },
            ),
            _buildDrawerToggle(
              title: 'ランダム出題',
              subtitle: 'ランダムに出題します。',
              value: TtsService.randomPlayback,
              onChanged: (v) {
                TtsService.setRandomPlayback(v);
              },
            ),
            _buildDrawerToggle(
              title: '逆出題',
              subtitle: '回答→質問の順番で出題します。',
              value: TtsService.reversePlayback,
              onChanged: (v) {
                TtsService.setReversePlayback(v);
              },
            ),
            _buildDrawerToggle(
              title: '集中暗記',
              subtitle: '連続正解回数が0～1の問題のみを出題します。',
              value: TtsService.focusedMemorization,
              onChanged: (v) {
                TtsService.setFocusedMemorization(v);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawerToggle({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile.adaptive(
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}
