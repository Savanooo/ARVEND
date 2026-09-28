import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/app/app.dart';
import 'package:arvend/app/app_router.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/dashboard/domain/dashboard.dart';
import 'package:arvend/features/dashboard/domain/dashboard_registry.dart';
import 'package:arvend/features/dashboard/domain/mobile_routes.dart';

import '../../test_utils/fake_api_client.dart';
import 'fixtures.dart';

/// Ana sayfanın GERÇEK uygulama kablolamasıyla testleri (ArvendApp +
/// routerProvider): sekme çubuğundaki "Ana Sayfa"ya tekrar dokunma kancası
/// (AppShell) ve mobileRouteFor çıktılarının gerçek yönlendiricide
/// eşleşmesi -- elle yazılmış küçük GoRouter'larla yakalanamayan kırılmalar.
class _FakeAuth extends AuthController {
  _FakeAuth(this._user);
  final User _user;

  @override
  Future<User?> build() async => _user;
}

Map<String, dynamic> _meBody() => {
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

/// Fixture'lardaki her `ref` (Dikkat kayıtları, yaklaşanlar, proje ve görev
/// satırları, aşım en kötüsü, Son Hareketler).
Iterable<DashRef> _fixtureRefs(Dashboard d) sync* {
  for (final g in d.agenda.groups) {
    for (final r in g.items) {
      yield r.ref;
    }
  }
  for (final u in d.agenda.upcoming) {
    yield u.ref;
  }
  final s = d.sections;
  for (final p in s.projects?.top ?? const <DashProjectRow>[]) {
    yield p.ref;
  }
  for (final t in s.tasks?.mine.items ?? const <DashMyTask>[]) {
    yield t.ref;
  }
  final worst = s.costControl?.overBudget?.worst;
  if (worst != null) yield worst.ref;
  for (final a in s.activity?.items ?? const <DashActivityItem>[]) {
    yield a.ref;
  }
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  testWidgets('açıkken "Ana Sayfa" sekmesine tekrar dokunmak özeti yeniden ister (AppShell kancası)', (tester) async {
    final adapter = FakeHttpClientAdapter(
      script: {
        '/auth/me': [(status: 200, body: _meBody())],
        '/dashboard': [(status: 200, body: fixtureJson('owner')), (status: 200, body: fixtureJson('owner'))],
        '/offers/': [
          (status: 200, body: {'offers': <dynamic>[], 'total': 0}),
        ],
        '/notifications/unread-count': [
          (status: 200, body: {'unread_count': 0}),
          (status: 200, body: {'unread_count': 0}),
        ],
      },
    );
    final client = await buildFakeApiClient(adapter);
    await tester.pumpWidget(
      ProviderScope(overrides: [apiClientProvider.overrideWithValue(client)], child: const ArvendApp()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Dikkat Gerektirenler'), findsOneWidget);
    expect(adapter.calls.where((c) => c == '/dashboard').length, 1);

    await tester.tap(find.descendant(of: find.byType(BottomNavigationBar), matching: find.text('Ana Sayfa')));
    await tester.pumpAndSettle();
    expect(adapter.calls.where((c) => c == '/dashboard').length, 2);
  });

  testWidgets('mobileRouteFor ve modül rotaları gerçek yönlendiricide bir ekrana eşleşir', (tester) async {
    final container = ProviderContainer(overrides: [authControllerProvider.overrideWith(() => _FakeAuth(ownerUser))]);
    addTearDown(container.dispose);
    final configuration = container.read(routerProvider).configuration;

    DashRef ref(String kind, {String? project = 'p1', String? parent, String action = 'open'}) =>
        DashRef(kind: kind, id: 'r1', projectId: project, parentId: parent, action: action);

    // spec §6.6'daki her tür (fixture'da olmayanlar dahil) + fixture kayıtları.
    final refs = <DashRef>[
      ref('project', project: null),
      ref('project_finance', project: null),
      ref('project_cost', project: null),
      ref('project_operations', project: null),
      ref('offer', project: null),
      ref('offer', project: null, action: 'convert'),
      ref('task'),
      ref('milestone'),
      ref('purchase_request'),
      ref('rfq'),
      ref('rfq', action: 'award'),
      ref('purchase_order'),
      ref('subcontract'),
      ref('progress_claim', parent: 's1'),
      ref('progress_claim'),
      ref('subcontract_change_order', parent: 's1'),
      ref('subcontract_change_order'),
      ref('change_order'),
      ref('budget_adjustment'),
      ref('contract'),
      ref('payment_plan_item'),
      ref('invoice'),
      ref('customer', project: null),
      ref('product', project: null),
      ref('user', project: null),
      ref('price_source', project: null),
      for (final persona in kDashboardPersonas) ..._fixtureRefs(Dashboard.fromJson(fixtureJson(persona))),
    ];
    final paths = <String>{
      for (final r in refs) ?mobileRouteFor(r),
      for (final def in kModules.values) ?def.route?.path,
      for (final a in QuickActionKey.values)
        ...switch (a) {
          QuickActionKey.offer => ['/teklifler/yeni'],
          QuickActionKey.attendance => ['/diger/mesai'],
          QuickActionKey.calc => ['/diger/metraj'],
          QuickActionKey.purchaseRequest => ['/projeler/p1/satin-alma/talepler/yeni'],
          QuickActionKey.task => ['/projeler/p1/gorevler/yeni'],
          _ => const <String>[],
        },
      for (final cta in [kCtaProducts, kCtaAddEmployee, kCtaAddUser]) cta.route,
      '/ana-sayfa/dikkat?kod=plan_item_overdue',
      '/projeler?status=completed',
      '/gorevler',
      '/diger/bildirimler',
      '/diger/firma-ayarlari',
    };
    expect(paths.length, greaterThan(20));
    for (final path in paths) {
      final match = configuration.findMatch(Uri.parse(path));
      expect(match.isError, isFalse, reason: 'eşleşmeyen rota: $path');
      expect(match.matches, isNotEmpty, reason: path);
    }

    // Statik alt yollar `:id` tarafından yutulmamalı -- ör. "yeni" bir
    // personel kimliği, "kaynaklar" bir ürün kimliği sanılmamalı.
    final templates = <String, String>{
      '/diger/urunler/kaynaklar': '/diger/urunler/kaynaklar',
      '/diger/urunler/zamlar?period=30': '/diger/urunler/zamlar',
      '/diger/urunler/r1': '/diger/urunler/:id',
      '/diger/personel/yeni': '/diger/personel/yeni',
      '/diger/kullanicilar/yeni': '/diger/kullanicilar/yeni',
      '/diger/kullanicilar/r1': '/diger/kullanicilar/:id',
    };
    templates.forEach((location, template) {
      expect(configuration.findMatch(Uri.parse(location)).fullPath, template, reason: location);
    });
  });
}
