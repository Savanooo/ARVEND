import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../firebase/firebase_setup.dart';
import 'push_messaging.dart';

/// Telefona bildirim (FCM) -- Firebase Messaging'in uygulamaya bakan yüzü.
class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging._(this._fm);
  final FirebaseMessaging _fm;

  /// Firebase başlatılamazsa (iOS henüz kurulmadı vb.) null -- uygulama
  /// bildirimsiz çalışmaya devam eder (bkz. core/firebase/firebase_setup.dart).
  static Future<PushMessaging?> create() async {
    if (!await initFirebase()) return null;
    try {
      return FirebasePushMessaging._(FirebaseMessaging.instance);
    } catch (e) {
      debugPrint('Bildirim: Firebase Messaging başlatılamadı: $e');
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
