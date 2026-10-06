import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:arvend/app/app.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/profile/presentation/about_screen.dart';
import 'package:arvend/features/profile/presentation/other_menu_screen.dart';
import 'package:arvend/features/profile/presentation/profile_screen.dart';

import 'test_utils/fake_api_client.dart';

Map<String, dynamic> _meJson({
  String role = 'kullanici',
  String organizationName = 'İnce İnşaat A.Ş.',
  String organizationRoleName = '',
}) =>
    {
      'id': 'u1',
      'organization_id': 'org-1',
      'username': 'ahmet.yilmaz',
      'full_name': 'Ahmet Yılmaz',
      'role': role,
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'organization_name': organizationName,
      'organization_role_name': organizationRoleName,
      'organization_role_code': organizationRoleName.isEmpty ? '' : 'finance',
      'permissions': <String>[],
    };

void main() {
  group('User.fromJson', () {
    test('organization_name backend alanı okunur', () {
      final user = User.fromJson(_meJson(organizationName: 'ABC Yapı Ltd.'));
      expect(user.organizationName, 'ABC Yapı Ltd.');
    });

    test('organization_name eksikse boş string\'e düşer (super_admin senaryosu)', () {
      final json = _meJson()..remove('organization_name');
      final user = User.fromJson(json);
      expect(user.organizationName, '');
    });
  });

  group('AuthController.logout', () {
    test('sunucu çağrısı başarılı olursa state null olur ve çerezler temizlenir', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/auth/logout': [(status: 200, body: {'ok': true})],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final user = await container.read(authControllerProvider.future);
      expect(user, isNotNull);

      await container.read(authControllerProvider.notifier).logout();

      expect(container.read(authControllerProvider).valueOrNull, isNull);
      expect(adapter.calls, contains('/auth/logout'));
    });

    test('sunucu çağrısı başarısız olsa bile yerel oturum temizlenir (ağ hatası)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/auth/logout': [(status: 500, body: {'error': 'sunucu hatası'})],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final user = await container.read(authControllerProvider.future);
      expect(user, isNotNull);

      // logout() ApiException'ı yutar -- sunucu hatası local temizliği engellemez.
      await container.read(authControllerProvider.notifier).logout();

      expect(container.read(authControllerProvider).valueOrNull, isNull);
    });

    test('sessionExpired() de state\'i null\'a çeker (tek uçuş refresh 401 senaryosu)', () async {
      final adapter = FakeHttpClientAdapter(script: {'/auth/me': [(status: 200, body: _meJson())]});
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      await container.read(authControllerProvider.future);
      container.read(authControllerProvider.notifier).sessionExpired();

      expect(container.read(authControllerProvider).valueOrNull, isNull);
    });
  });

  group('ProfileScreen', () {
    Future<void> pumpProfile(WidgetTester tester, Map<String, dynamic> meJson) async {
      final adapter = FakeHttpClientAdapter(script: {'/auth/me': [(status: 200, body: meJson)]});
      final client = await buildFakeApiClient(adapter);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: const MaterialApp(home: ProfileScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('ad, kullanıcı adı, firma adı ve ince-taneli rol gösterilir', (tester) async {
      await pumpProfile(tester, _meJson(organizationName: 'İnce İnşaat A.Ş.', organizationRoleName: 'Finans'));

      expect(find.text('Ahmet Yılmaz'), findsOneWidget);
      expect(find.text('@ahmet.yilmaz'), findsOneWidget);
      expect(find.text('İnce İnşaat A.Ş.'), findsOneWidget);
      expect(find.text('Finans'), findsOneWidget);
    });

    testWidgets('ince-taneli rol boşsa kaba role\'e düşülür (kullanici -> Kullanıcı)', (tester) async {
      await pumpProfile(tester, _meJson(role: 'kullanici', organizationRoleName: ''));

      expect(find.text('Kullanıcı'), findsOneWidget);
    });

    testWidgets('admin -> Yönetici etiketine düşer', (tester) async {
      await pumpProfile(tester, _meJson(role: 'admin', organizationRoleName: ''));

      expect(find.text('Yönetici'), findsOneWidget);
    });

    testWidgets('organization_name boşsa (super_admin) firma satırı hiç gösterilmez', (tester) async {
      final json = _meJson(role: 'super_admin')..['organization_name'] = '';
      await pumpProfile(tester, json);

      expect(find.byIcon(Icons.apartment_outlined), findsNothing);
    });

    testWidgets('Şifre Değiştir ve Çıkış Yap hâlâ mevcut (regresyon)', (tester) async {
      await pumpProfile(tester, _meJson());

      expect(find.text('Şifre Değiştir'), findsOneWidget);
      expect(find.text('Çıkış Yap'), findsOneWidget);
    });
  });

  group('OtherMenuScreen', () {
    testWidgets('Hakkında sekmesi her zaman görünür', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {'/auth/me': [(status: 200, body: _meJson())]});
      final client = await buildFakeApiClient(adapter);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: const MaterialApp(home: OtherMenuScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Hakkında'), findsOneWidget);
    });
  });

  group('AboutScreen', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'ArvenYapı',
        packageName: 'com.arvend.mobile',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
    });

    testWidgets('marka adı, package_info\'dan sürüm/derleme ve gizlilik bağlantısı gösterilir', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: AboutScreen())),
      );
      await tester.pumpAndSettle();

      expect(find.text('ARVEND Yapı'), findsOneWidget);
      expect(find.text('Sürüm 1.0.0 (1)'), findsOneWidget);
      // Play ve App Store gizlilik politikasına uygulama içinden de bağlantı ister.
      expect(find.text('Gizlilik Politikası ve KVKK'), findsOneWidget);
    });
  });

  group('Diğer > Hakkında uçtan uca gezinme', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'ArvenYapı',
        packageName: 'com.arvend.mobile',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
    });

    testWidgets('Diğer > Hakkında dokunuşu sürüm bilgisini gösteren ekrana götürür', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/projects': [(status: 200, body: {'projects': <dynamic>[], 'total': 0})],
        '/offers/': [(status: 200, body: {'offers': <dynamic>[], 'total': 0})],
        '/notifications/unread-count': [(status: 200, body: {'unread_count': 0})],
      });
      final client = await buildFakeApiClient(adapter);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: const ArvendApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Alt gezinmede 'Diğer' sekmesine geç.
      await tester.tap(find.text('Diğer'));
      await tester.pumpAndSettle();
      expect(find.text('Hakkında'), findsOneWidget);

      await tester.tap(find.text('Hakkında'));
      await tester.pumpAndSettle();

      expect(find.text('Sürüm 1.0.0 (1)'), findsOneWidget);
    });
  });
}
