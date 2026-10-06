import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/app/app.dart';
import 'package:arvend/core/api/api_providers.dart';

import '../../test_utils/fake_api_client.dart';
import '../dashboard/fixtures.dart';

/// Uçtan uca (ArvendApp + gerçek routerProvider + AppShell): Diğer
/// sekmesinden her yönetim ekranı açılır, alt gezinme yerinde kalır ve
/// backend 403 dönse bile ekran çökmeden anlaşılır bir yetki mesajı
/// gösterir; geri tuşu menüye döner.
Map<String, dynamic> _meBody() => {
  'id': 'user-1',
  'organization_id': 'org-1',
  'username': 'sahip',
  'full_name': 'Test Sahip',
  'role': 'admin',
  'is_active': true,
  'must_change_password': false,
  'onboarding_completed': true,
  'onboarding_step': 'completed',
  'organization_name': 'Arvend Yapı',
  'organization_role_code': 'owner',
  'organization_role_name': 'Sahip',
  'permissions': kAllPermissions,
};

// Backend RequirePermission'ın gerçek 403 gövdesi.
const ScriptedResponse _denied = (status: 403, body: {'error': 'bu işlem için yetkiniz yok', 'code': 'permission_denied'});

// Büyüyebilir liste: sahte adaptör kuyruğu removeAt ile tüketir (List.filled
// sabit uzunlukludur, removeAt fırlatır).
List<ScriptedResponse> _many(ScriptedResponse r) => List.generate(8, (_) => r);

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Diğer > Yönetim: her ekran kabukta açılır, 403\'te yetki mesajı gösterir, geri menüye döner', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final adapter = FakeHttpClientAdapter(
      script: {
        '/auth/me': [(status: 200, body: _meBody())],
        '/dashboard': _many((status: 200, body: fixtureJson('owner'))),
        '/notifications/unread-count': _many((status: 200, body: {'unread_count': 0})),
        '/offers/': _many((status: 200, body: {'offers': <dynamic>[], 'total': 0})),
        for (final path in [
          '/products',
          '/products/price-sources',
          '/products/price-changes',
          '/products/price-changes/summary',
          '/employees',
          '/users',
          '/organization/roles',
          '/organization/permissions',
          '/organization/suppliers',
          '/organization/cost-codes',
          '/calculations/groups',
          '/settings/smtp',
        ])
          path: _many(_denied),
      },
    );
    final client = await buildFakeApiClient(adapter);
    await tester.pumpWidget(
      ProviderScope(overrides: [apiClientProvider.overrideWithValue(client)], child: const ArvendApp()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: find.byType(BottomNavigationBar), matching: find.text('Diğer')));
    await tester.pumpAndSettle();

    const entries = {
      'Ürünler': '/products',
      'Personel': '/employees',
      'Kullanıcılar': '/users',
      'Roller & Yetkiler': '/organization/roles',
      'Tedarikçiler': '/organization/suppliers',
      'Maliyet Kodları': '/organization/cost-codes',
      'Metraj Reçeteleri': '/calculations/groups',
      'E-posta Ayarları': '/settings/smtp',
    };
    final menuList = find.byType(Scrollable).last;
    for (final entry in entries.entries) {
      final tile = find.text(entry.key);
      await tester.scrollUntilVisible(tile, 200, scrollable: menuList);
      await tester.pumpAndSettle();
      final before = adapter.calls.where((c) => c == entry.value).length;
      await tester.tap(tile);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: entry.key);
      expect(adapter.calls.where((c) => c == entry.value).length, greaterThan(before), reason: entry.key);
      // Her modül kendi açıklamasını yazar ("… yetkin yok" / "… izni olmalı").
      expect(find.textContaining(RegExp('yetki|izni')), findsWidgets, reason: '${entry.key}: 403 mesajı yok');
      // Ekran Diğer dalında açıldı -- alt gezinme kaybolmadı.
      expect(find.byType(BottomNavigationBar), findsOneWidget, reason: entry.key);

      // pageBack() İngilizce "Back" ipucunu arar; uygulama Türkçe ("Geri").
      expect(find.byType(BackButton), findsOneWidget, reason: entry.key);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      // Başlık ("Yönetim") değil öğenin kendisi: scrollUntilVisible öğeyi en
      // üste hizalar, menü uzayınca başlık görünür alanın üstünde kalır.
      expect(find.text(entry.key), findsOneWidget, reason: '${entry.key}: geri menüye dönmedi');
      expect(find.text('Hesap'), findsOneWidget, reason: '${entry.key}: Diğer menüsünde değil');
    }
  });
}
