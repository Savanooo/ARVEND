import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/app/app.dart';
import 'package:arvend/core/api/api_providers.dart';

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

  testWidgets('super_admin: organizasyonu olmadığı için onboarding kontrolünden muaftır', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [
        (status: 200, body: _meBody(role: 'super_admin', onboardingCompleted: false, onboardingStep: 'company')),
      ],
      '/projects': [(status: 200, body: {'projects': <dynamic>[], 'total': 0})],
      '/offers/': [(status: 200, body: {'offers': <dynamic>[], 'total': 0})],
    });
    await _pumpApp(tester, adapter);

    // 'Ana Sayfa' hem AppBar başlığında hem alt gezinme etiketinde
    // göründüğü için ekranın kendine özgü içeriğiyle (Dashboard'un statik
    // "Son Projeler" başlığı) doğrulanır.
    expect(find.text('Son Projeler'), findsOneWidget);
    expect(find.text('Firma Kurulumu'), findsNothing);
    expect(find.text('Yeni Şifre Belirleyin'), findsNothing);
  });

  testWidgets('normal, zaten onboarding tamamlamış kullanıcı: hiçbir zorunlu ekranla karşılaşmadan ana sayfaya gider',
      (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 200, body: _meBody(role: 'kullanici'))],
      '/projects': [(status: 200, body: {'projects': <dynamic>[], 'total': 0})],
      '/offers/': [(status: 200, body: {'offers': <dynamic>[], 'total': 0})],
    });
    await _pumpApp(tester, adapter);

    expect(find.text('Son Projeler'), findsOneWidget);
    expect(find.text('Firma Kurulumu'), findsNothing);
    expect(find.text('Yeni Şifre Belirleyin'), findsNothing);
  });

  testWidgets('logout: Diğer > Profil > Çıkış Yap ile oturum kapanır, giriş ekranına dönülür', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 200, body: _meBody())],
      '/projects': [(status: 200, body: {'projects': <dynamic>[], 'total': 0})],
      '/offers/': [(status: 200, body: {'offers': <dynamic>[], 'total': 0})],
      '/auth/logout': [(status: 200, body: null)],
    });
    await _pumpApp(tester, adapter);
    expect(find.text('Son Projeler'), findsOneWidget);

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
    expect(find.text('Son Projeler'), findsNothing);
  });
}
