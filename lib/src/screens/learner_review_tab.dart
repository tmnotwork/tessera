import 'package:flutter/material.dart';

import 'review_mode_screen.dart';

/// ボトムナビの「復習」タブ: [ReviewModeScreen] を表示する。
class LearnerReviewTab extends StatelessWidget {
  const LearnerReviewTab({super.key, this.displayId});

  final String? displayId;

  @override
  Widget build(BuildContext context) {
    return ReviewModeScreen(
      learnerDisplayId: displayId,
      showLearnerShellContext: true,
    );
  }
}
