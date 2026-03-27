import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> enableFirestoreWebPersistence(
  FirebaseFirestore firestore,
  PersistenceSettings settings,
) async {
  // cloud_firestore 6.x では enablePersistence が削除されたため、
  // Webでも settings 経由で永続化を有効化する。
  // NOTE（複数タブ）:
  // - cloud_firestore 6.1 / cloud_firestore_platform_interface 7.0.7 時点でも Settings に
  //   webPersistentTabManager は公開 API に含まれていない。2 タブ目は永続層の排他で
  //   「memory cache にフォールバック」する可能性あり。FlutterFire で該当 API がリリースされれば
  //   persistenceEnabled: true と合わせて webPersistentTabManager を設定すること
  //   （docs/firestore_web_多タブ排他_状況整理.md / docs/old/マルチタブ対応_修正方針.md）。
  // - 複数タブでの安定化は、Auth 側の hold と Hive のリトライ・Web タイムアウト延長で緩和している。
  // ignore: unused_local_variable
  final _ = settings;
  firestore.settings = firestore.settings.copyWith(persistenceEnabled: true);
}
