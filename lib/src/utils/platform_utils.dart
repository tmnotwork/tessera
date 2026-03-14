import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

bool get isDesktop =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.linux;

bool get isAndroid => defaultTargetPlatform == TargetPlatform.android;

bool get isMobile => !isDesktop;
