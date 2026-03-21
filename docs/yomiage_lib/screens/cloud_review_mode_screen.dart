import 'package:yomiage/models/deck.dart';

import 'study_mode_filter.dart';
import 'review_mode_screen.dart';
import 'package:yomiage/services/tts_playback_controller.dart';

class CloudReviewModeScreen extends ReviewModeScreen {
  const CloudReviewModeScreen({
    super.key,
    required Deck deck,
    String? chapterName,
    StudyModeFilter? filter,
  }) : super(
          deck: deck,
          chapterName: chapterName,
          filter: filter,
          ttsController: const CloudTtsPlaybackController(),
        );
}
