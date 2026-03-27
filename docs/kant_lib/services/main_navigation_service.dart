import 'package:flutter/foundation.dart';

/// Main（タブ）画面へ「行き先」を要求するための簡易サービス。
///
/// - Drawer など、Main の State を直接参照できない場所から使う。
/// - Main 側がリスナーで受け取り、該当タブへ切り替える。
enum MainDestination {
  timeline,
  inbox,
  calendar,
  routine,
  project,
  report,
  db,
}

class MainNavigationService {
  static final ValueNotifier<MainDestination?> request =
      ValueNotifier<MainDestination?>(null);

  static void navigate(MainDestination dest) {
    request.value = dest;
  }

  static void clear() {
    request.value = null;
  }
}

