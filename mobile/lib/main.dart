import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app/app.dart';
import 'core/api/api_client.dart';
import 'core/api/api_providers.dart';
import 'core/auth/auth_controller.dart';
import 'core/push/firebase_push_messaging.dart';
import 'core/push/push_messaging.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('tr_TR');

  final apiClient = await ApiClient.create();
  // Telefona bildirim; Firebase başlatılamazsa uygulama bildirimsiz açılır.
  final push = await FirebasePushMessaging.create();

  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(apiClient),
      if (push != null) pushMessagingProvider.overrideWithValue(push),
    ],
  );

  // Tek uçuş refresh başarısız olduğunda (sınıflandırılamayan bir 401/403)
  // oturumu senkron biçimde temizle - go_router'ın redirect'i
  // authControllerProvider'ı dinlediği için kullanıcı otomatik olarak
  // /giris'e döner.
  apiClient.onSessionExpired = () {
    container.read(authControllerProvider.notifier).sessionExpired();
  };

  // Organizasyon/kullanıcı engeli (ya da super_admin'in bir kiracı ucuna
  // isabet etmesi -- normalde yaşanmamalı) -- sebep ÖNCE yazılır ki
  // go_router'ın redirect'i AYNI karar turunda doğru hedefi (hesap-engeli
  // ekranı / bilgilendirilmiş giriş ekranı) seçebilsin, SONRA aynı tek
  // yetkili sessionExpired() yoluyla oturum temizlenir.
  apiClient.onAccountAccessBlocked = (issue) {
    container.read(accountAccessIssueProvider.notifier).state = issue;
    container.read(authControllerProvider.notifier).sessionExpired();
  };

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const ArvendApp(),
    ),
  );
}
