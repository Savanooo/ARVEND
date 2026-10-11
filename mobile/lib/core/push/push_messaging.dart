import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../api/api_providers.dart';

/// Telefona bildirim (FCM) -- Firebase'e doğrudan bağlı olmayan yüz.
/// Gerçek uygulama main.dart'ta `FirebasePushMessaging` ile ezilir;
/// testlerde ve Firebase'in kurulmadığı platformlarda (iOS) varsayılan
/// `NoopPushMessaging` çalışır, hiçbir şey yapmaz.
abstract class PushMessaging {
  /// Bildirim izni (Android 13+ sistem penceresi). Reddedilirse false.
  Future<bool> requestPermission();

  /// Bu telefonun kayıt anahtarı; alınamazsa null.
  Future<String?> token();
  Stream<String> get onTokenRefresh;

  /// Uygulama açıkken gelen bildirim (sistem bunu kendisi göstermez).
  Stream<PushMessage> get onForegroundMessage;

  /// Arka plandayken dokunulan bildirim.
  Stream<PushMessage> get onMessageOpenedApp;

  /// Uygulama kapalıyken bildirime dokunularak açıldıysa o bildirim.
  Future<PushMessage?> initialMessage();

  /// Çıkışta: bu telefona bir sonraki oturumda yeni anahtar verilsin.
  Future<void> deleteToken();
}

/// Bildirimin uygulamanın ilgilendiği kısmı (backend PushService.pushMessage).
class PushMessage {
  const PushMessage({
    this.title = '',
    this.body = '',
    this.actionTarget = '',
    this.type = '',
    this.notificationId = '',
  });

  factory PushMessage.fromData({String? title, String? body, required Map<String, dynamic> data}) => PushMessage(
        title: title ?? '',
        body: body ?? '',
        actionTarget: data['action_target'] as String? ?? '',
        type: data['type'] as String? ?? '',
        notificationId: data['notification_id'] as String? ?? '',
      );

  final String title;
  final String body;

  /// Zildeki bildirimin kimliği -- dokununca okundu işaretlemek için.
  final String notificationId;

  /// Uygulama içi rota (ör. `/projeler/<id>/gorevler/<id>`); boş olabilir.
  final String actionTarget;
  final String type;
}

class NoopPushMessaging implements PushMessaging {
  const NoopPushMessaging();

  @override
  Future<bool> requestPermission() async => false;
  @override
  Future<String?> token() async => null;
  @override
  Stream<String> get onTokenRefresh => const Stream.empty();
  @override
  Stream<PushMessage> get onForegroundMessage => const Stream.empty();
  @override
  Stream<PushMessage> get onMessageOpenedApp => const Stream.empty();
  @override
  Future<PushMessage?> initialMessage() async => null;
  @override
  Future<void> deleteToken() async {}
}

final pushMessagingProvider = Provider<PushMessaging>((ref) => const NoopPushMessaging());

/// POST /push/devices[/unregister] -- yalnızca oturumdaki kullanıcının
/// kendi telefonu.
class PushRepository {
  PushRepository(this._client);
  final ApiClient _client;

  Future<void> register(String token, {String platform = 'android', String appVersion = ''}) async {
    await _client.post<Map<String, dynamic>>('/push/devices', data: {
      'token': token,
      'platform': platform,
      'app_version': appVersion,
    });
  }

  Future<void> unregister(String token) async {
    await _client.post<Map<String, dynamic>>('/push/devices/unregister', data: {'token': token});
  }
}

final pushRepositoryProvider = Provider<PushRepository>((ref) => PushRepository(ref.watch(apiClientProvider)));

/// Çıkışta silinemeyen (ör. ağ yoktu) bildirim anahtarının kaydı
/// (SharedPreferences). Anahtar silinene kadar telefon eski kullanıcının
/// bildirimlerini almaya devam ederdi; kayıt varsa bir sonraki açılışta ve
/// öne gelişte (oturum yokken) silme yeniden denenir (bkz.
/// AuthController.retryPendingPushCleanup).
class PushCleanupStore {
  PushCleanupStore({Future<SharedPreferences> Function()? prefs}) : _prefs = prefs ?? SharedPreferences.getInstance;

  static const key = 'arvend.push.token_delete_pending';

  final Future<SharedPreferences> Function() _prefs;

  /// Okunamazsa (test ortamı) bekleyen silme yok sayılır.
  Future<bool> isPending() async {
    try {
      return (await _prefs()).getBool(key) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> markPending() async {
    try {
      await (await _prefs()).setBool(key, true);
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      await (await _prefs()).remove(key);
    } catch (_) {}
  }
}

final pushCleanupStoreProvider = Provider<PushCleanupStore>((ref) => PushCleanupStore());
