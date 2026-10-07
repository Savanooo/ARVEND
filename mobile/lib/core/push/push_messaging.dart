import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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
