import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/study_timer_service.dart';

/// アプリ直下に置き、タップ・スクロール・キー入力で [StudyTimerService.onUserInteraction] を送る。
///
/// 無操作が [StudyTimerService.idleTimeout] 続くと勉強時間の集計が止まる（TTS 中は除く）。
class StudyTimeUserActivityScope extends StatefulWidget {
  const StudyTimeUserActivityScope({super.key, required this.child});

  final Widget child;

  @override
  State<StudyTimeUserActivityScope> createState() => _StudyTimeUserActivityScopeState();
}

class _StudyTimeUserActivityScopeState extends State<StudyTimeUserActivityScope> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      StudyTimerService.instance.onUserInteraction();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification n) {
        if (n is ScrollStartNotification || n is ScrollUpdateNotification) {
          StudyTimerService.instance.onUserInteraction();
        }
        return false;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => StudyTimerService.instance.onUserInteraction(),
        child: widget.child,
      ),
    );
  }
}
