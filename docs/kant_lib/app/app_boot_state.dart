import 'package:flutter/foundation.dart';

/// タイムラインのギャップ実績行を「データが揃ってから」表示するため。
/// Project/Mode/SubProject が ready になったら true。MainScreen が購読して refresh 1回かける。
final ValueNotifier<bool> displayServicesReady = ValueNotifier<bool>(false);
