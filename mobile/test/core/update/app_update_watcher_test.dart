import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/app/app.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/update/app_release.dart';
import 'package:arvend/core/update/update_controller.dart';
import 'package:arvend/core/update/update_postpone_store.dart';
import 'package:arvend/core/update/update_presenter.dart';

import '../../features/dashboard/fixtures.dart';
import '../../test_utils/fake_api_client.dart';
import 'update_fakes.dart';

Map<String, dynamic> _userJson() => {
      'id': 'user-1',
      'organization_id': 'org-1',
      'username': 'test_kullanici',
      'full_name': 'Test Kullanıcı',
      'role': 'admin',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
    };

/// Uygulamanın GERÇEK kablolamasıyla (ArvendApp + router + AppUpdateWatcher)
/// açılış denetimi: oturum yokken giriş ekranında da sorulur.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  late FakeHttpClientAdapter adapter;
  late FakeInstallService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = FakeInstallService();
  });

  Future<void> pumpApp(
    WidgetTester tester,
    Map<String, dynamic> versionBody, {
    List<Map<String, dynamic>> laterVersionBodies = const [],
    DateTime Function()? clock,
  }) async {
    adapter = FakeHttpClientAdapter(script: {
      // Oturum yok: /auth/me 401 -> refresh de 401 -> giriş ekranı.
      '/auth/me': [
        (status: 401, body: {'error': 'yetkisiz'}),
      ],
      '/auth/refresh': [
        (status: 401, body: {'error': 'oturum yok'}),
      ],
      '/mobile/app-version': [
        (status: 200, body: versionBody),
        for (final body in laterVersionBodies) (status: 200, body: body),
      ],
      '/auth/login': [(status: 200, body: _userJson())],
      '/dashboard': [(status: 200, body: fixtureJson('owner'))],
      '/offers/': [
        (status: 200, body: {'offers': <dynamic>[], 'total': 0}),
      ],
      '/notifications/unread-count': [
        (status: 200, body: {'unread_count': 0}),
      ],
    });
    final client = await buildFakeApiClient(adapter);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(client),
          updateSupportedProvider.overrideWithValue(true),
          installedVersionProvider.overrideWith((ref) async => const InstalledVersion(version: '1.1.0', build: 2)),
          updateInstallServiceProvider.overrideWithValue(service),
          if (clock != null) updateClockProvider.overrideWithValue(clock),
        ],
        child: const ArvendApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> login(WidgetTester tester) async {
    await tester.enterText(find.widgetWithText(TextFormField, 'Kullanıcı Adı'), 'test_kullanici');
    await tester.enterText(find.widgetWithText(TextFormField, 'Şifre'), 'gizli-sifre');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş Yap'));
    await tester.pumpAndSettle();
  }

  void resume(WidgetTester tester) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  testWidgets('öne gelişte: son denetim 6 saatten yeni ise sorulmaz, eskiyse yeniden sorulur', (tester) async {
    var now = DateTime(2026, 9, 28, 10);
    await pumpApp(
      tester,
      {'platform': 'android', 'build': 0},
      laterVersionBodies: [releaseJson(build: 3)],
      clock: () => now,
    );
    int versionCalls() => adapter.calls.where((c) => c == '/mobile/app-version').length;
    expect(versionCalls(), 1);

    now = now.add(const Duration(hours: 5));
    resume(tester);
    await tester.pumpAndSettle();
    expect(versionCalls(), 1);

    now = now.add(const Duration(hours: 1));
    resume(tester);
    await tester.pumpAndSettle();
    expect(versionCalls(), 2);
    expect(find.text('Yeni sürüm hazır'), findsOneWidget);
  });

  testWidgets('güncel sürümde açılışta hiçbir şey gösterilmez', (tester) async {
    await pumpApp(tester, {'platform': 'android', 'build': 0});
    expect(find.text('Yönetim Sistemine Giriş'), findsOneWidget);
    expect(find.text('Yeni sürüm hazır'), findsNothing);
    expect(adapter.calls.where((c) => c == '/mobile/app-version').length, 1);
  });

  testWidgets('açılışta giriş ekranında da sorulur; "Sonra" o build\'i erteler', (tester) async {
    await pumpApp(tester, releaseJson(build: 3));
    expect(find.text('Yeni sürüm hazır'), findsOneWidget);

    await tester.tap(find.text('Sonra'));
    await tester.pumpAndSettle();
    expect(find.text('Yeni sürüm hazır'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(UpdatePostponeStore.buildKey), 3);
  });

  testWidgets('oturumsuzken "Güncelle": önce giriş istenir, girişten sonra istem yeniden açılır', (tester) async {
    await pumpApp(tester, releaseJson(build: 3));
    await tester.tap(find.text('Güncelle'));
    await tester.pumpAndSettle();

    expect(find.text(kUpdateLoginRequiredMessage), findsOneWidget);
    expect(find.text('Yeni sürüm hazır'), findsNothing);
    expect(service.prepareCalls, 0, reason: 'oturum yokken indirme denenmez');

    await login(tester);

    expect(find.text('Yeni sürüm hazır'), findsOneWidget);
    await tester.tap(find.text('Güncelle'));
    await tester.pumpAndSettle();

    expect(service.prepareCalls, 1);
    expect(service.installCalls, 1);
    expect(find.text('Yeni sürüm hazır'), findsNothing);
  });

  testWidgets('zorunlu güncelleme giriş ekranında kapatılamaz ama girişe izin verir, girişten sonra yine açılır',
      (tester) async {
    await pumpApp(tester, releaseJson(build: 3, minBuild: 3));
    expect(find.textContaining('Bu güncelleme zorunlu'), findsOneWidget);
    expect(find.text('Sonra'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.textContaining('Bu güncelleme zorunlu'), findsOneWidget);

    await tester.tap(find.text('Güncelle'));
    await tester.pumpAndSettle();
    expect(find.text(kUpdateLoginRequiredMessage), findsOneWidget);

    await login(tester);
    expect(find.textContaining('Bu güncelleme zorunlu'), findsOneWidget);
  });

  group('eski bilgiyle istem açılmaz (bu arada yeni sürüm yayınlanmış olabilir)', () {
    int versionCalls() => adapter.calls.where((c) => c == '/mobile/app-version').length;

    testWidgets('girişte bilgi 6 saatten eskiyse istem göstermeden önce yeniden sorulur', (tester) async {
      var now = DateTime(2026, 9, 28, 10);
      await pumpApp(
        tester,
        releaseJson(build: 3),
        laterVersionBodies: [releaseJson(build: 4, version: '1.3.0', sha256: 'b' * 64)],
        clock: () => now,
      );
      await tester.tap(find.text('Güncelle'));
      await tester.pumpAndSettle();
      expect(find.text(kUpdateLoginRequiredMessage), findsOneWidget);

      now = now.add(const Duration(hours: 7));
      await login(tester);

      expect(versionCalls(), 2);
      expect(find.text('Yeni sürüm hazır'), findsOneWidget);
      expect(find.text('Sürüm 1.3.0'), findsOneWidget, reason: 'build 3 değil, güncel build 4 gösterilmeli');
    });

    testWidgets('girişte yeniden sorulunca güncelleme artık yoksa istem açılmaz', (tester) async {
      var now = DateTime(2026, 9, 28, 10);
      late ProviderContainer container;
      await pumpApp(
        tester,
        releaseJson(build: 3),
        laterVersionBodies: [
          {'platform': 'android', 'build': 0},
        ],
        clock: () => now,
      );
      container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
      await tester.tap(find.text('Güncelle'));
      await tester.pumpAndSettle();

      now = now.add(const Duration(hours: 7));
      await login(tester);

      expect(versionCalls(), 2);
      expect(find.text('Yeni sürüm hazır'), findsNothing);
      expect(container.read(updateControllerProvider).awaitingLogin, isFalse);
    });

    testWidgets('zorunlu istem açıkken öne gelişte bilgi yine tazelenir; istem güncel sürümle geri gelir',
        (tester) async {
      var now = DateTime(2026, 9, 28, 10);
      await pumpApp(
        tester,
        releaseJson(build: 3, minBuild: 3),
        laterVersionBodies: [releaseJson(build: 4, version: '1.3.0', sha256: 'b' * 64, minBuild: 3)],
        clock: () => now,
      );
      expect(find.textContaining('Bu güncelleme zorunlu'), findsOneWidget);

      now = now.add(const Duration(hours: 7));
      resume(tester);
      await tester.pumpAndSettle();
      expect(versionCalls(), 2, reason: 'istem açıkken de 6 saatlik denetim yapılmalı');
      expect(find.textContaining('Bu güncelleme zorunlu'), findsOneWidget);

      await tester.tap(find.text('Güncelle'));
      await tester.pumpAndSettle();
      await login(tester);

      expect(find.textContaining('Bu güncelleme zorunlu'), findsOneWidget);
      expect(find.text('Sürüm 1.3.0'), findsOneWidget);
      expect(versionCalls(), 2);
    });
  });
}
