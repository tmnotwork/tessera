import 'package:yomiage/services/hive_service.dart';
import 'package:yomiage/webapp/web_study_mode_screen.dart';

class WebSettingsManager {
  // 保存された展開状態とフィルタ状態を読み込む
  static void loadSettings({
    required Function(bool) setStudyExpanded,
    required Function(bool) setSortingExpanded,
    required Function(bool) setReadingExpanded,
    required Function(StudyModeFilter) setStudyModeFilter,
  }) {
    final settingsBox = HiveService.getSettingsBox();

    final studyExpanded = settingsBox.get('studyExpanded', defaultValue: true);
    final sortingExpanded =
        settingsBox.get('sortingExpanded', defaultValue: true);
    final readingExpanded =
        settingsBox.get('readingExpanded', defaultValue: true);

    // フィルタ状態の読み込み
    final filterString = settingsBox.get('studyModeFilter');
    StudyModeFilter studyModeFilter;
    if (filterString == 'allCards') {
      studyModeFilter = StudyModeFilter.allCards;
    } else {
      studyModeFilter = StudyModeFilter.dueToday; // デフォルトまたは不明な値の場合
    }

    // 状態を更新
    setStudyExpanded(studyExpanded);
    setSortingExpanded(sortingExpanded);
    setReadingExpanded(readingExpanded);
    setStudyModeFilter(studyModeFilter);
  }

  // 展開状態とフィルタ状態を保存する
  static void saveSettings({
    required bool studyExpanded,
    required bool sortingExpanded,
    required bool readingExpanded,
    required StudyModeFilter studyModeFilter,
  }) {
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('studyExpanded', studyExpanded);
    settingsBox.put('sortingExpanded', sortingExpanded);
    settingsBox.put('readingExpanded', readingExpanded);
    // フィルタ状態の保存
    settingsBox.put('studyModeFilter',
        studyModeFilter == StudyModeFilter.allCards ? 'allCards' : 'dueToday');
  }

  // 特定の設定のみを保存する
  static void saveStudyModeFilter(StudyModeFilter studyModeFilter) {
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('studyModeFilter',
        studyModeFilter == StudyModeFilter.allCards ? 'allCards' : 'dueToday');
  }

  // 展開状態のみを保存する
  static void saveExpansionStates({
    required bool studyExpanded,
    required bool sortingExpanded,
    required bool readingExpanded,
  }) {
    final settingsBox = HiveService.getSettingsBox();
    settingsBox.put('studyExpanded', studyExpanded);
    settingsBox.put('sortingExpanded', sortingExpanded);
    settingsBox.put('readingExpanded', readingExpanded);
  }
}
