import 'package:flutter/foundation.dart';

abstract class InboxControllerInterface {
  ValueListenable<bool> get isSyncing;
  Future<void> requestSync();
  void dispose();
}
