import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> enableFirestoreWebPersistence(
  FirebaseFirestore firestore,
  PersistenceSettings settings,
) async {
  // Web以外のビルドでは呼び出されないため、空実装でコンパイルを通す。
}
