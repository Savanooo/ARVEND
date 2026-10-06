import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'push_messaging.dart';

/// Firebase projesi `arvend-8bc93` (Firebase konsolundaki
/// google-services.json'un değerleri). Bunlar gizli değildir: istemci
/// kimliğidir, uygulamanın paket adı ve imzasıyla sınırlıdır. Telefona
/// bildirim GÖNDERMEK sunucudaki hizmet hesabı anahtarını ister, o
/// uygulamada YOKTUR.
///
/// google-services gradle eklentisi bilinçli olarak kullanılmadı: AGP 9 ile
/// derleme düzenine dokunmadan, Dart'ta açık seçeneklerle başlatılıyor.
const _androidOptions = FirebaseOptions(
  apiKey: 'AIzaSyCAsnBvRRPZkVhCSHJd2a1m_6A5-cq9KFY',
  appId: '1:955862124222:android:1c6409b1aef647838580ef',
  messagingSenderId: '955862124222',
  projectId: 'arvend-8bc93',
  storageBucket: 'arvend-8bc93.firebasestorage.app',
);

class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging._(this._fm);
  final FirebaseMessaging _fm;

  /// Firebase'i başlatır; başlatılamazsa (iOS henüz kurulmadı, ağ yok vb.)
  /// null -- uygulama bildirimsiz çalışmaya devam eder.
  static Future<PushMessaging?> create() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      await Firebase.initializeApp(options: _androidOptions);
      return FirebasePushMessaging._(FirebaseMessaging.instance);
    } catch (e) {
      debugPrint('Bildirim: Firebase başlatılamadı: $e');
      return null;
    }
  }

  static PushMessage _from(RemoteMessage m) =>
      PushMessage.fromData(title: m.notification?.title, body: m.notification?.body, data: m.data);

  @override
  Future<bool> requestPermission() async {
    final s = await _fm.requestPermission();
    return s.authorizationStatus == AuthorizationStatus.authorized ||
        s.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<String?> token() async {
    try {
      return await _fm.getToken();
    } catch (e) {
      // Google Play Hizmetleri olmayan cihaz / ağ hatası.
      debugPrint('Bildirim: kayıt anahtarı alınamadı: $e');
      return null;
    }
  }

  @override
  Stream<String> get onTokenRefresh => _fm.onTokenRefresh;

  @override
  Stream<PushMessage> get onForegroundMessage => FirebaseMessaging.onMessage.map(_from);

  @override
  Stream<PushMessage> get onMessageOpenedApp => FirebaseMessaging.onMessageOpenedApp.map(_from);

  @override
  Future<PushMessage?> initialMessage() async {
    final m = await _fm.getInitialMessage();
    return m == null ? null : _from(m);
  }

  @override
  Future<void> deleteToken() => _fm.deleteToken();
}
