import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/app/app.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';

import '../features/dashboard/fixtures.dart';
import '../test_utils/fake_api_client.dart';

/// ARVEND — SUPER ADMIN + FİRMA/MAĞAZA YÖNETİMİ + MOBİL FIRST-LOGIN
/// ONBOARDING fazının go_router redirect zincirini (app/app_router.dart)
/// doğrular: must_change_password -> onboarding_completed -> normal akış
/// sırası, VE super_admin'in onboarding'den muaf tutulması.

Map<String, dynamic> _meBody({
  bool mustChangePassword = false,
  bool onboardingCompleted = true,
  String onboardingStep = 'completed',
  String role = 'admin',
}) {
  return {
    'id': 'user-1',
    'organization_id': role == 'super_admin' ? null : 'org-1',
    'username': 'test_kullanici',
    'full_name': 'Test Kullanıcı',
    'role': role,
    'is_active': true,
    'must_change_password': mustChangePassword,
    'onboarding_completed': onboardingCompleted,
    'onboarding_step': onboardingStep,
  };
}

final _emptyOnboardingState = {
  'onboarding_completed': false,
  'onboarding_step': 'company',
  'profile': <String, dynamic>{},
  'commercial': <String, dynamic>{},
};

Future<void> _pumpApp(WidgetTester tester, FakeHttpClientAdapter adapter) async {
  final client = await buildFakeApiClient(adapter);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: const ArvendApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('must_change_password=true: hiçbir yere değil, şifre belirleme ekranına yönlendirilir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 200, body: _meBody(mustChangePassword: true, onboardingCompleted: false))],
    });
    await _pumpApp(tester, adapter);

    expect(find.text('Yeni Şifre Belirleyin'), findsOneWidget);
    expect(find.text('Ana Sayfa'), findsNothing);
  });

  testWidgets('onboarding tamamlanmamış admin: onboarding sihirbazına yönlendirilir (kaldığı adımdan)',
      (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [
        (status: 200, body: _meBody(onboardingCompleted: false, onboardingStep: 'offers')),
      ],
      '/onboarding': [
        (status: 200, body: {..._emptyOnboardingState, 'onboarding_step': 'offers'}),
      ],
    });
    await _pumpApp(tester, adapter);

    expect(find.text('Firma Kurulumu'), findsOneWidget);
    // 'offers' 3. adım (index 2) -- sihirbaz kaldığı adımdan devam etmeli.
    expect(find.text('Adım 3 / 5'), findsOneWidget);
    expect(find.text('Teklif'), findsOneWidget);
  });

  testWidgets(
      'super_admin: kiracı akışlarının (onboarding/dashboard) TAMAMINDAN muaftır, '
      'web-only hesap ekranına yönlendirilir ve HİÇBİR kiracı ucu çağrılmaz', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [
        (status: 200, body: _meBody(role: 'super_admin', onboardingCompleted: false, onboardingStep: 'company')),
      ],
      // ARVEND Mobile TAMAMEN bir kiracı uygulamasıdır -- super_admin
      // giriş yapar yapmaz web-only ekrana düşmeli, /dashboard, /offers/,
      // /notifications/unread-count gibi HİÇBİR kiracı ucu
      // ÇAĞRILMAMALI (bkz. app_router.dart _forcedRouteFor). Script'te bu
      // yollar KASITLI OLARAK tanımsız bırakıldı -- adapter, script'te
      // olmayan bir yola istek gelirse StateError fırlatır, bu yüzden
      // testin kendisi "hiç çağrılmadı" iddiasını doğal olarak da kanıtlar.
    });
    await _pumpApp(tester, adapter);

    expect(find.text('Bu hesap platform yönetimi içindir. Yönetim panelini web üzerinden kullanın.'),
        findsOneWidget);
    expect(find.text('Hesap: test_kullanici'), findsOneWidget);
    expect(find.text('Dikkat Gerektirenler'), findsNothing);
    expect(find.text('Firma Kurulumu'), findsNothing);
    expect(find.text('Yeni Şifre Belirleyin'), findsNothing);
    expect(adapter.calls, ['/auth/me']);
  });

  testWidgets('super_admin: web-only ekrandan çıkış yapınca giriş ekranına döner', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 200, body: _meBody(role: 'super_admin'))],
      '/auth/logout': [(status: 200, body: null)],
    });
    await _pumpApp(tester, adapter);
    expect(find.text('Bu hesap platform yönetimi içindir. Yönetim panelini web üzerinden kullanın.'),
        findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Çıkış Yap'));
    await tester.pumpAndSettle();

    expect(adapter.calls, contains('/auth/logout'));
    expect(find.byType(TextFormField), findsWidgets);
  });

  testWidgets('normal, zaten onboarding tamamlamış kullanıcı: hiçbir zorunlu ekranla karşılaşmadan ana sayfaya gider',
      (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 200, body: _meBody(role: 'kullanici'))],
      // Ana sayfa TEK uçtan (/dashboard) beslenir -- eski /projects ve
      // /tasks/mine çağrıları yok.
      '/dashboard': [(status: 200, body: fixtureJson('owner'))],
      '/offers/': [(status: 200, body: {'offers': <dynamic>[], 'total': 0})],
      '/notifications/unread-count': [(status: 200, body: {'unread_count': 0})],
    });
    await _pumpApp(tester, adapter);

    expect(find.text('Dikkat Gerektirenler'), findsOneWidget);
    expect(find.text('Firma Kurulumu'), findsNothing);
    expect(find.text('Yeni Şifre Belirleyin'), findsNothing);
  });

  testWidgets('logout: Diğer > Profil > Çıkış Yap ile oturum kapanır, giriş ekranına dönülür', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 200, body: _meBody())],
      // Ana sayfa TEK uçtan (/dashboard) beslenir -- eski /projects ve
      // /tasks/mine çağrıları yok.
      '/dashboard': [(status: 200, body: fixtureJson('owner'))],
      '/offers/': [(status: 200, body: {'offers': <dynamic>[], 'total': 0})],
      '/notifications/unread-count': [(status: 200, body: {'unread_count': 0})],
      '/auth/logout': [(status: 200, body: null)],
    });
    await _pumpApp(tester, adapter);
    expect(find.text('Dikkat Gerektirenler'), findsOneWidget);

    await tester.tap(find.text('Diğer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profil'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Çıkış Yap'));
    await tester.pumpAndSettle();
    // Onay diyaloğu: "Çıkış Yap" metni artık HEM tetikleyici butonda HEM
    // diyalog içindeki TextButton'da var -- diyalogdakini hedefle.
    await tester.tap(find.widgetWithText(TextButton, 'Çıkış Yap'));
    await tester.pumpAndSettle();

    expect(adapter.calls, contains('/auth/logout'));
    expect(find.byType(TextFormField), findsWidgets); // Giriş ekranındaki kullanıcı adı/şifre alanları
    expect(find.text('Dikkat Gerektirenler'), findsNothing);
  });

  group('oturum-içi organizasyon/kullanıcı engeli (FINAL entegrasyon fazı)', () {
    // main.dart'ın `apiClient.onSessionExpired`/`onAccountAccessBlocked`
    // kablosunu BİREBİR tekrarlar -- `_pumpApp`'ın aksine, ArvendApp
    // KENDİSİ bu kabloyu kurmaz (bkz. app/app.dart), yalnızca main() kurar.
    Future<void> pumpWithHooks(WidgetTester tester, FakeHttpClientAdapter adapter) async {
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);
      client.onSessionExpired = () => container.read(authControllerProvider.notifier).sessionExpired();
      client.onAccountAccessBlocked = (issue) {
        container.read(accountAccessIssueProvider.notifier).state = issue;
        container.read(authControllerProvider.notifier).sessionExpired();
      };
      client.onAccountSetupRequired = () => container.read(authControllerProvider.notifier).recheckAccountSetup();
      await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const ArvendApp()));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'organizasyon askıya alınmış/iptal edilmiş/silinmiş: oturum-içi bir kiracı isteği 403 alınca '
        'özel hesap-engeli ekranına düşülür, istek TEKRARLANMAZ', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meBody(role: 'kullanici'))],
        '/dashboard': [(status: 403, body: {'error': 'firma askıya alınmış veya erişilemiyor'})],
        '/offers/': [(status: 200, body: {'offers': <dynamic>[], 'total': 0})],
        '/notifications/unread-count': [(status: 200, body: {'unread_count': 0})],
      });
      await pumpWithHooks(tester, adapter);

      expect(find.text('Firmanızın platform erişimi şu anda kapalı.'), findsOneWidget);
      expect(find.text('Dikkat Gerektirenler'), findsNothing);
      expect(adapter.calls.where((p) => p == '/dashboard').length, 1);
    });

    testWidgets('organizasyon engeli ekranından çıkış yapınca düz giriş ekranına dönülür (döngüye girmez)',
        (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meBody(role: 'kullanici'))],
        '/dashboard': [(status: 403, body: {'error': 'firma askıya alınmış veya erişilemiyor'})],
        '/offers/': [(status: 200, body: {'offers': <dynamic>[], 'total': 0})],
        '/notifications/unread-count': [(status: 200, body: {'unread_count': 0})],
        '/auth/logout': [(status: 200, body: null)],
      });
      await pumpWithHooks(tester, adapter);
      expect(find.text('Firmanızın platform erişimi şu anda kapalı.'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Çıkış Yap'));
      await tester.pumpAndSettle();

      expect(find.byType(TextFormField), findsWidgets);
      expect(find.text('Firmanızın platform erişimi şu anda kapalı.'), findsNothing);
    });

    testWidgets(
        'kullanıcı pasif/silinmiş: oturum-içi bir kiracı isteği 403 alınca giriş ekranına döner VE '
        'bilgilendirici mesaj gösterilir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meBody(role: 'kullanici'))],
        '/dashboard': [(status: 403, body: {'error': 'kullanıcı pasif durumda'})],
        '/offers/': [(status: 200, body: {'offers': <dynamic>[], 'total': 0})],
        '/notifications/unread-count': [(status: 200, body: {'unread_count': 0})],
      });
      await pumpWithHooks(tester, adapter);

      expect(find.byType(TextFormField), findsWidgets);
      expect(find.text('Hesabınıza erişiminiz kapatılmıştır. Bilgi için yöneticinizle görüşün.'), findsOneWidget);
      expect(find.text('Dikkat Gerektirenler'), findsNothing);
    });

    testWidgets(
        'oturum sürerken geçici şifre zorunlu kılındı: iş ucu 403 "önce şifrenizi değiştirin" deyince '
        'kullanıcı tazelenir ve şifre belirleme ekranına gidilir (oturum düşmez)', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [
          (status: 200, body: _meBody(role: 'kullanici')),
          (status: 200, body: _meBody(role: 'kullanici', mustChangePassword: true)),
        ],
        '/dashboard': [
          (status: 403, body: {'error': 'devam etmeden önce şifrenizi değiştirmeniz gerekiyor'}),
        ],
        '/offers/': [(status: 200, body: {'offers': <dynamic>[], 'total': 0})],
        '/notifications/unread-count': [(status: 200, body: {'unread_count': 0})],
      });
      await pumpWithHooks(tester, adapter);

      expect(find.text('Yeni Şifre Belirleyin'), findsOneWidget);
      expect(adapter.calls.where((p) => p == '/auth/me').length, 2);
      expect(adapter.calls, isNot(contains('/auth/refresh')));
    });
  });

  testWidgets('kurulumu bitmemiş firmanın yönetici OLMAYAN kullanıcısı: sihirbaz yerine bekleme ekranı, çıkış yapabilir',
      (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 200, body: _meBody(role: 'kullanici', onboardingCompleted: false, onboardingStep: 'company'))],
      // /onboarding KASITLI olarak betiklenmedi: yalnızca admin'e açık.
      '/auth/logout': [(status: 200, body: null)],
    });
    await _pumpApp(tester, adapter);

    expect(
      find.text('Firma kurulumu henüz tamamlanmadı; firma sahibinin kurulumu bitirmesi gerekiyor.'),
      findsOneWidget,
    );
    expect(find.text('Firma Kurulumu'), findsNothing);
    expect(adapter.calls, isNot(contains('/onboarding')));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Çıkış Yap'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsWidgets);
  });

  testWidgets('bekleme ekranında "Tekrar Kontrol Et": sahip kurulumu bitirdiyse ana sayfaya çıkılır', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [
        (status: 200, body: _meBody(role: 'kullanici', onboardingCompleted: false, onboardingStep: 'company')),
        (status: 200, body: _meBody(role: 'kullanici')),
      ],
      '/dashboard': [(status: 200, body: fixtureJson('owner'))],
      '/offers/': [(status: 200, body: {'offers': <dynamic>[], 'total': 0})],
      '/notifications/unread-count': [(status: 200, body: {'unread_count': 0})],
    });
    await _pumpApp(tester, adapter);

    await tester.tap(find.text('Tekrar Kontrol Et'));
    await tester.pumpAndSettle();

    expect(find.text('Dikkat Gerektirenler'), findsOneWidget);
  });
}
