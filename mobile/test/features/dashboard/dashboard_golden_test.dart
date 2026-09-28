@Tags(['golden'])
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/dashboard/data/dashboard_providers.dart';
import 'package:arvend/features/dashboard/domain/dashboard.dart';
import 'package:arvend/features/dashboard/presentation/attention_screen.dart';
import 'package:arvend/features/dashboard/presentation/dashboard_screen.dart';
import 'package:arvend/features/notifications/data/notifications_providers.dart';

import '../../test_utils/fake_api_client.dart';
import 'fixtures.dart';

/// Ana sayfa ekran görüntüleri (spec §6.8) -- 4 persona x (360x800,
/// 412x915, 360 tam sayfa) = 12 PNG, `goldens/` altında. Üretmek/görmek:
///   flutter test --tags golden --update-goldens test/features/dashboard/dashboard_golden_test.dart
/// Uygulama fontları (Inter + MaterialIcons) yüklenir; aksi halde metinler
/// Ahem kutuları olarak çizilirdi. Veri tamamen deterministiktir: tarih ve
/// saatler fixture'ın `today`/`generated_at` alanlarından gelir.
Future<void> _loadAppFonts() async {
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

/// Uygulama teması; yalnızca AppBar başlığına aile adı verilir. Temanın
/// `appBarTheme.titleTextStyle`'ı fontFamily taşımadığı için cihazda
/// platform yazı tipiyle çizilir, test motorunda ise kutu glifine düşer --
/// ekran görüntüsünde başlık okunabilsin diye burada Inter verilir.
ThemeData _goldenTheme() {
  final theme = AppTheme.light();
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Inter'),
    ),
  );
}

class _FakeAuth extends AuthController {
  _FakeAuth(this._user);
  final User _user;

  @override
  Future<User?> build() async => _user;
}

const _sizes = <String, Size>{'360x800': Size(360, 800), '412x915': Size(412, 915)};

void main() {
  late Map<String, Map<String, dynamic>> fixtures;
  late ApiClient client;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await _loadAppFonts();
    SharedPreferences.setMockInitialValues({});
    // Betiksiz sahte istemci: beklenmeyen herhangi bir istek testi düşürür.
    client = await buildFakeApiClient(FakeHttpClientAdapter(script: {}));
    fixtures = {for (final p in kDashboardPersonas) p: fixtureJson(p)};
  });

  Widget harness(String persona) {
    final router = GoRouter(
      initialLocation: '/ana-sayfa',
      routes: [
        GoRoute(
          path: '/ana-sayfa',
          builder: (_, _) => const DashboardScreen(),
          routes: [GoRoute(path: 'dikkat', builder: (_, _) => const AttentionScreen())],
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => _FakeAuth(userFor(persona))),
        dashboardProvider.overrideWith((ref) async => Dashboard.fromJson(fixtures[persona]!)),
        unreadNotificationCountProvider.overrideWith((ref) async => 4),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: _goldenTheme(),
        locale: const Locale('tr', 'TR'),
        supportedLocales: const [Locale('tr', 'TR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        routerConfig: router,
      ),
    );
  }

  for (final persona in kDashboardPersonas) {
    for (final entry in _sizes.entries) {
      testWidgets('dashboard $persona ${entry.key}', (tester) async {
        tester.view.devicePixelRatio = 2.0;
        tester.view.physicalSize = entry.value * 2.0; // PNG 720x1600 / 824x1830
        addTearDown(tester.view.reset);
        await tester.pumpWidget(harness(persona));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dashboard_${persona}_${entry.key}.png'));
      });
    }

    testWidgets('dashboard $persona full page 360', (tester) async {
      // Tüm kaydırma içeriği tek görüntüde (inceleme için): önce 360x800
      // çizilir, içerik yüksekliği ölçülür, pencere o boya büyütülür.
      tester.view.devicePixelRatio = 2.0;
      tester.view.physicalSize = const Size(360, 800) * 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(harness(persona));
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first,
      );
      final fullHeight = (800 + scrollable.position.maxScrollExtent).ceilToDouble();
      tester.view.physicalSize = Size(360, fullHeight) * 2.0;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/dashboard_${persona}_360_full.png'));
    });
  }
}
