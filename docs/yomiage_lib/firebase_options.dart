import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBfEwq9YvACCu5mSSSfwH613xSoPOjqJlw',
    appId: '1:938729438669:web:60366658e8249f67035884',
    messagingSenderId: '938729438669',
    projectId: 'yomiage-1f7fd',
    authDomain: 'yomiage-1f7fd.firebaseapp.com',
    storageBucket: 'yomiage-1f7fd.firebasestorage.app',
    measurementId: 'G-7K5S67257N',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyARDXWmD-Vz2F9_qzc4jsPu--PqOm6Mk9w',
    appId: '1:938729438669:android:e80cfb26a12de649035884',
    messagingSenderId: '938729438669',
    projectId: 'yomiage-1f7fd',
    storageBucket: 'yomiage-1f7fd.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyBrEYREvm7uFIMCNE-LNAH82rUmNTs4RxA',
    appId: '1:938729438669:ios:f384c534c58d69c8035884',
    messagingSenderId: '938729438669',
    projectId: 'yomiage-1f7fd',
    storageBucket: 'yomiage-1f7fd.firebasestorage.app',
    iosBundleId: 'com.example.yomiageApp2',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyBrEYREvm7uFIMCNE-LNAH82rUmNTs4RxA',
    appId: '1:938729438669:ios:f384c534c58d69c8035884',
    messagingSenderId: '938729438669',
    projectId: 'yomiage-1f7fd',
    storageBucket: 'yomiage-1f7fd.firebasestorage.app',
    iosBundleId: 'com.example.yomiageApp2',
  );

  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyBfEwq9YvACCu5mSSSfwH613xSoPOjqJlw',
    appId: '1:938729438669:web:2bc328f96f928fd8035884',
    messagingSenderId: '938729438669',
    projectId: 'yomiage-1f7fd',
    authDomain: 'yomiage-1f7fd.firebaseapp.com',
    storageBucket: 'yomiage-1f7fd.firebasestorage.app',
    measurementId: 'G-CRENJ843CL',
  );
}
