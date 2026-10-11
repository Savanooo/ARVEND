import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Firebase projesi `arvend-8bc93` (Firebase konsolundaki
/// google-services.json / GoogleService-Info.plist değerleri). Bunlar gizli değildir: istemci
/// kimliğidir, uygulamanın paket adı ve imzasıyla sınırlıdır. Telefona
/// bildirim GÖNDERMEK sunucudaki hizmet hesabı anahtarını ister, o
/// uygulamada YOKTUR.
///
/// google-services gradle eklentisi bilinçli olarak kullanılmadı: AGP 9 ile
/// derleme düzenine dokunmadan, Dart'ta açık seçeneklerle başlatılıyor.
/// Aynı nedenle Crashlytics gradle eklentisi de yok (bkz.
/// core/crash/firebase_crash_reporter.dart).
const _androidOptions = FirebaseOptions(
  apiKey: 'AIzaSyCAsnBvRRPZkVhCSHJd2a1m_6A5-cq9KFY',
  appId: '1:955862124222:android:1c6409b1aef647838580ef',
  messagingSenderId: '955862124222',
  projectId: 'arvend-8bc93',
  storageBucket: 'arvend-8bc93.firebasestorage.app',
);

/// iOS uygulaması (bundle com.arvendyapi.arvend). Bildirimler APNs
/// anahtarıyla (Firebase > Cloud Messaging) iPhone'a iletilir;
/// GoogleService-Info.plist'in Xcode projesine eklenmesine gerek kalmasın
/// diye Android'deki gibi Dart'ta açık seçeneklerle başlatılıyor.
const _iosOptions = FirebaseOptions(
  apiKey: 'AIzaSyDDMer-1r9FMJXj-kZXcwAtJkJB7vlDhPU',
  appId: '1:955862124222:ios:16d9c7f988f2bfff8580ef',
  messagingSenderId: '955862124222',
  projectId: 'arvend-8bc93',
  storageBucket: 'arvend-8bc93.firebasestorage.app',
  iosBundleId: 'com.arvendyapi.arvend',
);

Future<bool>? _initialized;

/// Firebase'i BİR KEZ başlatır (bildirim ve çökme raporlama ortak kullanır).
/// Android ve iOS dışında ya da başlatılamazsa false -- uygulama bildirimsiz
/// ve raporsuz çalışmaya devam eder.
Future<bool> initFirebase() => _initialized ??= _initialize();

Future<bool> _initialize() async {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return false;
  try {
    await Firebase.initializeApp(options: Platform.isIOS ? _iosOptions : _androidOptions);
    return true;
  } catch (e) {
    debugPrint('Firebase başlatılamadı: $e');
    return false;
  }
}
