import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/push/push_watcher.dart';
import '../core/theme/app_theme.dart';
import '../core/update/app_update_watcher.dart';
import '../core/update/play_update.dart';
import 'app_router.dart';

class ArvendApp extends ConsumerWidget {
  const ArvendApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'ARVEND',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      routerConfig: router,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      // Uzaktan güncelleme denetimi (yalnızca Android) -- Navigator'ın
      // üstünde durur, istemleri router'ın kök Navigator'ına açar. Sideload
      // yapısında kendi güncelleyicimiz, Play yapısında Play'in uygulama içi
      // güncellemesi çalışır; diğeri no-op'tur.
      builder: (context, child) => AppUpdateWatcher(
        navigatorKey: router.routerDelegate.navigatorKey,
        child: PlayUpdateWatcher(
          // Telefona bildirim: kayıt, açıkken gelen bildirim, dokununca
          // hedef ekran (bkz. core/push/).
          child: PushWatcher(router: router, child: child ?? const SizedBox.shrink()),
        ),
      ),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
