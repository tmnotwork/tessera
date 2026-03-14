import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

/// SharedPreferences 用のデータフォルダパス保存キー
const dataFolderKey = 'data_folder_path';

/// テーマモード保存キー（'light' | 'dark' | 'system'）
const themeModeKey = 'theme_mode';

bool get isDesktop =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;

/// スマホ（Android / iOS）。PC と UI を分けるときの判定に使用
bool get isMobile => !isDesktop;
