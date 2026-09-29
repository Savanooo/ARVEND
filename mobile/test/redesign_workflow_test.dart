import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/features/dashboard/presentation/dashboard_screen.dart';
import 'package:arvend/features/offers/presentation/offer_create_screen.dart';
import 'package:arvend/features/projects/activity/activity_routes.dart';
import 'package:arvend/features/projects/presentation/project_detail_screen.dart';

import 'features/dashboard/fixtures.dart';
import 'test_utils/fake_api_client.dart';

Map<String, dynamic> _meJson({List<String> permissions = const []}) => {
      'id': 'u1',
      'organization_id': 'org1',
      'username': 'test',
      'full_name': 'Ayşe Yılmaz',
      'organization_name': 'ARVEND Yapı A.Ş.',
      'role': 'kullanici',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': permissions,
    };

Map<String, dynamic> _projectJson() => {
      'id': 'p1',
      'project_no': 'PRJ-001',
      'name': 'Merkez Ofis İnşaatı',
      'project_type': 'Konut',
      'customer_id': 'c1',
      'customer_name': 'Ali Veli',
      'customer_phone': '',
      'customer_email': '',
      'contract_amount': 100000,
      'currency': 'TRY',
      'status': 'active',
      'start_date': null,
      'end_date': null,
      'description': '',
      'created_at': '2026-09-01T00:00:00Z',
    };

/// Proje-kapsamlı her alt-sekmenin çağırabileceği uçlar için savunmacı,
/// boş yanıtlar -- `TabBarView`'ın komşu sayfayı önceden inşa etmesi
/// (PageView davranışı) durumunda betiklenmemiş bir çağrı hatası
/// almamak için.
Map<String, List<ScriptedResponse>> _defensiveProjectScripts(String projectId) => {
      '/projects/$projectId/financial-summary': [
        (
          status: 200,
          body: {
            'current_contract_value': 100000, 'collected_amount': 20000, 'remaining_receivable': 80000,
            'total_expenses': 5000, 'subcontractor_paid': 0, 'subcontractor_remaining': 0,
            'realized_cost': 5000, 'committed_cost': 5000, 'realized_gross_profit': 15000,
            'estimated_gross_profit': 15000, 'realized_margin_percent': 15, 'estimated_margin_percent': 15,
            'currency': 'TRY',
          },
        ),
      ],
      '/projects/$projectId/expenses': [(status: 200, body: {'expenses': <dynamic>[]})],
      '/projects/$projectId/collections': [(status: 200, body: {'collections': <dynamic>[]})],
      '/projects/$projectId/tasks': [(status: 200, body: {'tasks': <dynamic>[]})],
      '/projects/$projectId/operations-summary': [
        (
          status: 200,
          body: {'open_task_count': 0, 'completed_task_count': 0, 'overdue_task_count': 0, 'active_member_count': 0},
        ),
      ],
      '/projects/$projectId/photos': [(status: 200, body: {'photos': <dynamic>[]})],
      '/projects/$projectId/files': [(status: 200, body: {'files': <dynamic>[]})],
      '/projects/$projectId/notes': [(status: 200, body: {'notes': <dynamic>[]})],
      '/projects/$projectId/cost-control': [
        (
          status: 200,
          body: {
            'summary': {
              'has_budget': false, 'contract_value': 100000, 'revised_budget': 0, 'committed_cost': 0,
              'actual_cost': 0, 'eac': 0, 'variance': 0, 'forecast_profit': 0, 'forecast_margin_percent': 0,
              'currency': 'TRY',
            },
            'lines': <dynamic>[],
          },
        ),
      ],
      '/projects/$projectId/change-orders': [(status: 200, body: {'change_orders': <dynamic>[]})],
      '/projects/$projectId/purchase-requests': [(status: 200, body: {'purchase_requests': <dynamic>[]})],
      '/projects/$projectId/rfqs': [(status: 200, body: {'rfqs': <dynamic>[]})],
      '/projects/$projectId/purchase-orders': [(status: 200, body: {'purchase_orders': <dynamic>[]})],
      '/projects/$projectId/subcontracts': [(status: 200, body: {'subcontracts': <dynamic>[]})],
    };

GoRouter _buildProjectTestRouter(String projectId) => GoRouter(
      initialLocation: '/projeler/$projectId',
      routes: [
        GoRoute(
          path: '/projeler/:id',
          builder: (c, s) => ProjectDetailScreen(projectId: s.pathParameters['id']!),
          // Gerçek uygulamadaki gibi: Aktivite /projeler/:id/aktivite.
          routes: projectActivityRoutes,
        ),
      ],
    );

Future<void> _pumpProject(WidgetTester tester, FakeHttpClientAdapter adapter, String projectId) async {
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(400, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp.router(routerConfig: _buildProjectTestRouter(projectId)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  group('ProjectDetailScreen — grup görünürlüğü (10 düz sekme yerine 4 grup)', () {
    testWidgets('tam izinli kullanıcı 4 grubu da görür: Özet/Finans/Operasyon/Dokümanlar', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [
          (
            status: 200,
            body: _meJson(permissions: [
              'projects.finance.read',
              'projects.cost_control.read',
              'projects.subcontracts.read',
              'projects.procurement.read',
              'projects.tasks.read',
              'projects.operations.read',
            ]),
          ),
        ],
        '/projects/p1': [(status: 200, body: _projectJson())],
        ..._defensiveProjectScripts('p1'),
      });
      await _pumpProject(tester, adapter, 'p1');

      expect(find.text('Özet'), findsWidgets); // AppBar tab + section nav card metni
      expect(find.widgetWithText(Tab, 'Finans'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Operasyon'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Dokümanlar'), findsOneWidget);
    });

    testWidgets('yalnızca projects.tasks.read izni olan kullanıcı SADECE Özet + Operasyon görür', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['projects.tasks.read']))],
        '/projects/p1': [(status: 200, body: _projectJson())],
        ..._defensiveProjectScripts('p1'),
      });
      await _pumpProject(tester, adapter, 'p1');

      expect(find.widgetWithText(Tab, 'Özet'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Operasyon'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Finans'), findsNothing);
      expect(find.widgetWithText(Tab, 'Dokümanlar'), findsNothing);
      // İzni olmayan bir kullanıcı için finansal özet çağrısı hiç atılmamalı.
      expect(adapter.calls, isNot(contains('/projects/p1/financial-summary')));
    });

    testWidgets('Özet\'teki "Finans" gezinme kartına dokunmak Finans sekmesine geçer', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['projects.finance.read']))],
        '/projects/p1': [(status: 200, body: _projectJson())],
        ..._defensiveProjectScripts('p1'),
      });
      await _pumpProject(tester, adapter, 'p1');

      expect(find.text('Finansal Özet'), findsOneWidget); // Özet'teki özet kartı başlığı

      await tester.tap(find.text('Finans').last);
      await tester.pumpAndSettle();

      // Finans grubunun kendi iç segment geçişi (Finans/Ek İşler) görünür olmalı.
      expect(find.text('Ek İşler'), findsWidgets);
    });

    testWidgets('Aktivite artık birincil sekme değil -- AppBar geçmiş simgesiyle açılır', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        // Olaylar projects.read ister (proje sayfasının kendisi gibi).
        '/auth/me': [(status: 200, body: _meJson(permissions: ['projects.read', 'projects.finance.read']))],
        '/projects/p1': [(status: 200, body: _projectJson())],
        '/projects/p1/events': [(status: 200, body: {'events': <dynamic>[]})],
        ..._defensiveProjectScripts('p1'),
      });
      await _pumpProject(tester, adapter, 'p1');

      expect(find.widgetWithText(Tab, 'Aktivite'), findsNothing);

      // Aynı Icons.history hem AppBar'da hem Özet'in alt satırında var --
      // AppBar'daki, tooltip'iyle tekil olarak hedeflenir.
      await tester.tap(find.byTooltip('Aktivite Geçmişi'));
      await tester.pumpAndSettle();

      expect(find.text('Aktivite Geçmişi'), findsOneWidget);
      expect(find.text('Henüz kayıtlı bir olay yok.'), findsOneWidget);
    });
  });

  group('OfferCreateScreen / OfferDetailScreen — iç fiyatlandırma ayrımı', () {
    testWidgets('yetkili kullanıcı için "İç Fiyatlandırma" / "Müşteri görmez" kutusu görünür', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [
          (status: 200, body: _meJson(permissions: ['offers.internal_pricing.manage'])),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: const MaterialApp(home: OfferCreateScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('İç Fiyatlandırma'), findsOneWidget);
      expect(find.text('Müşteri görmez'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('yetkisiz kullanıcı için iç fiyatlandırma kutusu hiç gösterilmez', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['offers.read']))],
      });
      final client = await buildFakeApiClient(adapter);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: const MaterialApp(home: OfferCreateScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('İç Fiyatlandırma'), findsNothing);
      expect(find.text('Müşteri görmez'), findsNothing);
    });
  });

  group('DashboardScreen — karşılama + izin bazlı hızlı işlemler', () {
    // Ana sayfa artık TEK uçtan (/dashboard) beslenir -- eski /projects ve
    // /tasks/mine çağrıları yok. Gövde ortak sözleşme fixture'ıdır.
    Map<String, List<ScriptedResponse>> baseScript(List<String> permissions) => {
          '/auth/me': [(status: 200, body: _meJson(permissions: permissions))],
          '/dashboard': [(status: 200, body: fixtureJson('owner'))],
          '/notifications/unread-count': [(status: 200, body: {'unread_count': 0})],
        };

    Future<void> pumpDashboard(WidgetTester tester, FakeHttpClientAdapter adapter) async {
      final client = await buildFakeApiClient(adapter);
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: const MaterialApp(home: DashboardScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('kullanıcı adı ve organizasyon adıyla karşılanır', (tester) async {
      final adapter = FakeHttpClientAdapter(script: baseScript(const []));
      await pumpDashboard(tester, adapter);

      expect(find.text('Merhaba, Ayşe'), findsOneWidget);
      expect(find.text('ARVEND Yapı A.Ş.'), findsOneWidget);
      expect(adapter.calls, contains('/dashboard'));
      expect(adapter.calls, isNot(contains('/projects')));
      expect(adapter.calls, isNot(contains('/tasks/mine')));
    });

    testWidgets('offers.create izni olmayan kullanıcı "Teklif Oluştur" hızlı işlemini görmez', (tester) async {
      final adapter = FakeHttpClientAdapter(script: baseScript(['calculations.read']));
      await pumpDashboard(tester, adapter);

      expect(find.text('Teklif Oluştur'), findsNothing);
      expect(find.text('Metraj Hesapla'), findsOneWidget);
    });

    testWidgets('offers.create izni olan kullanıcı "Teklif Oluştur" hızlı işlemini görür', (tester) async {
      final adapter = FakeHttpClientAdapter(script: baseScript(['offers.create']));
      await pumpDashboard(tester, adapter);

      expect(find.text('Teklif Oluştur'), findsOneWidget);
    });

    testWidgets('customers.manage izni olmayan kullanıcı "Müşteri Ekle" hızlı işlemini görmez', (tester) async {
      final adapter = FakeHttpClientAdapter(script: baseScript(['offers.create']));
      await pumpDashboard(tester, adapter);

      expect(find.text('Müşteri Ekle'), findsNothing);
    });
  });
}
