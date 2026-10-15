import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/subcontractors/presentation/subcontractor_ledger_screen.dart';
import 'package:arvend/features/subcontractors/presentation/subcontractors_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../contract_co/contract_co_test_support.dart' as cc;
import '../projects/form_test_support.dart' show requestBodyFor;

/// Taşeronlar (backend migration 0069): kart listesi ve ödenen toplamlar,
/// yeni kart, taşeronun sayfası (projelerdeki işleri + bütün ödemeler) ve
/// "Ödeme Yap" -- proje dışı ya da projedeki işine.

final _admin = cc.buildUser(
  id: 'adm',
  roleCode: 'admin',
  permissions: const {
    'organization.suppliers.read',
    'organization.suppliers.manage',
    'projects.finance.read',
    'projects.finance.manage',
  },
);

final _readerNoFinance = cc.buildUser(
  id: 'pm',
  roleCode: 'project_manager',
  permissions: const {'organization.suppliers.read'},
);

Map<String, dynamic> _card(String id, String name, {bool active = true}) => {
      'id': id,
      'code': 'TSR-0001',
      'legal_name': name,
      'specialty': 'Elektrik',
      'phone': '0555',
      'is_subcontractor': true,
      'is_active': active,
      'iban_set': true,
    };

Map<String, dynamic> _cards({bool totals = true}) => {
      'subcontractors': [
        {
          ..._card('s1', 'Elektrikçi Hasan'),
          if (totals)
            'paid_totals': [
              {'currency': 'TRY', 'amount': 9500},
            ],
          if (totals)
            'remaining_totals': [
              {'currency': 'TRY', 'amount': 12000},
            ],
        },
        _card('s2', 'Eski Usta', active: false),
      ],
      'can_see_totals': totals,
    };

Map<String, dynamic> _ledger() => {
      'subcontractor': _card('s1', 'Elektrikçi Hasan'),
      'engagements': [
        {
          'kind': 'simple',
          'id': 'ps1',
          'project_id': 'p1',
          'project_name': 'Kadıköy Konut',
          'project_no': 'PRJ-2026-0007',
          'project_status': 'active',
          'title': 'Elektrik tesisatı',
          'status': 'active',
          'currency': 'TRY',
          'contract_amount': 20000,
          'paid_amount': 8000,
          'remaining_amount': 12000,
        },
      ],
      'payments': [
        {
          'source': 'direct',
          'id': 'd1',
          'project_id': null,
          'project_name': '',
          'project_no': '',
          'engagement_id': null,
          'amount': 1500,
          'currency': 'TRY',
          'paid_date': '2026-10-14',
          'description': 'Depo tamiri',
          'voided_at': null,
          'void_reason': '',
        },
        {
          'source': 'simple',
          'id': 'sp1',
          'project_id': 'p1',
          'project_name': 'Kadıköy Konut',
          'project_no': 'PRJ-2026-0007',
          'engagement_id': 'ps1',
          'amount': 8000,
          'currency': 'TRY',
          'paid_date': '2026-10-10',
          'description': '',
          'voided_at': null,
          'void_reason': '',
        },
      ],
      'paid_totals': [
        {'currency': 'TRY', 'amount': 9500},
      ],
      'site_days': [
        for (var d = 14; d >= 8; d--)
          {
            'report_date': '2026-10-${d.toString().padLeft(2, '0')}',
            'project_id': 'p1',
            'project_name': 'Kadıköy Konut',
            'project_no': 'PRJ-2026-0007',
            'workers': 3,
            'work_note': d == 14 ? 'pano montajı' : '',
          },
      ],
    };

Future<FakeHttpClientAdapter> _pump(
  WidgetTester tester, {
  required User user,
  required Map<String, List<ScriptedResponse>> script,
  String initial = '/diger/taseronlar',
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final adapter = FakeHttpClientAdapter(script: script);
  final client = await buildFakeApiClient(adapter);
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/diger/taseronlar',
        builder: (c, s) => const SubcontractorsScreen(),
        routes: [
          GoRoute(path: ':id', builder: (c, s) => SubcontractorLedgerScreen(subcontractorId: s.pathParameters['id']!)),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => cc.FakeAuth(user)),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        locale: const Locale('tr', 'TR'),
        supportedLocales: const [Locale('tr', 'TR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return adapter;
}

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  testWidgets('liste aktif kartları ödenen toplamla gösterir, arşiv ayrı', (tester) async {
    await _pump(tester, user: _admin, script: {
      '/subcontractors': [(status: 200, body: _cards())],
    });
    expect(find.text('Elektrikçi Hasan'), findsOneWidget);
    expect(find.text('Eski Usta'), findsNothing);
    expect(find.textContaining('9.500'), findsOneWidget);
    await tester.tap(find.text('Arşiv'));
    await tester.pumpAndSettle();
    expect(find.text('Eski Usta'), findsOneWidget);
  });

  testWidgets('listede kalan borç finans okuyana görünür', (tester) async {
    await _pump(tester, user: _admin, script: {
      '/subcontractors': [(status: 200, body: _cards())],
    });
    expect(find.byKey(const ValueKey('taseron-kalan-s1')), findsOneWidget);
    expect(find.textContaining('Kalan 12.000'), findsOneWidget);
  });

  testWidgets('finans okuyamayan toplam görmez, yeni taşeron ekleyemez', (tester) async {
    await _pump(tester, user: _readerNoFinance, script: {
      '/subcontractors': [(status: 200, body: _cards(totals: false))],
    });
    expect(find.text('Ödenen'), findsNothing);
    expect(find.byKey(const ValueKey('taseron-ekle')), findsNothing);
  });

  testWidgets('"Yeni Taşeron" kart açar ve sayfasına gider', (tester) async {
    final adapter = await _pump(tester, user: _admin, script: {
      // GET liste -> POST kart -> GET liste (kart açılınca tazelenir).
      '/subcontractors': [
        (status: 200, body: _cards()),
        (status: 201, body: _card('s9', 'Sıvacı Mehmet')),
        (status: 200, body: _cards()),
        (status: 200, body: _cards()),
      ],
      '/subcontractors/s9/ledger': [
        (status: 200, body: {..._ledger(), 'subcontractor': _card('s9', 'Sıvacı Mehmet'), 'engagements': [], 'payments': []}),
      ],
    });
    await tester.tap(find.byKey(const ValueKey('taseron-ekle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('taseron-ad')), 'Sıvacı Mehmet');
    await tester.tap(find.byKey(const ValueKey('taseron-kaydet')));
    await tester.pumpAndSettle();

    final body = requestBodyFor(adapter, '/subcontractors');
    expect(body['legal_name'], 'Sıvacı Mehmet');
    expect(body['code'], '', reason: 'kodu sunucu verir');
    expect(find.text('Henüz bir projede çalışmadı.'), findsOneWidget);
  });

  testWidgets('taşeron sayfası projelerdeki işi ve bütün ödemeleri gösterir', (tester) async {
    await _pump(tester, user: _admin, initial: '/diger/taseronlar/s1', script: {
      '/subcontractors/s1/ledger': [(status: 200, body: _ledger())],
    });
    expect(find.textContaining('Kalan'), findsWidgets);
    expect(find.textContaining('Proje dışı'), findsOneWidget);
    expect(find.textContaining('PRJ-2026-0007 · Kadıköy Konut'), findsWidgets);
    expect(find.byKey(const ValueKey('taseron-toplam-odenen')), findsOneWidget);
  });

  testWidgets('taşeron sayfası sahada çalıştığı günleri, aramayı ve düzenlemeyi gösterir', (tester) async {
    await _pump(tester, user: _admin, initial: '/diger/taseronlar/s1', script: {
      '/subcontractors/s1/ledger': [(status: 200, body: _ledger())],
    });
    expect(find.text('7 gün · toplam 21 adam-gün'), findsOneWidget);
    expect(find.byKey(const ValueKey('taseron-saha-2026-10-14-p1')), findsOneWidget);
    expect(find.textContaining('pano montajı'), findsOneWidget);
    // İlk 5 gün açık; "Tümünü göster" kalanları açar.
    expect(find.byKey(const ValueKey('taseron-saha-2026-10-08-p1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('taseron-saha-tumu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('taseron-saha-2026-10-08-p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('taseron-ara')), findsOneWidget);
    expect(find.byKey(const ValueKey('taseron-karti-duzenle')), findsOneWidget);
  });

  testWidgets('tedarikçi yönetme izni olmayan kartı düzenleyemez', (tester) async {
    final financeOnly = cc.buildUser(
      id: 'fin',
      roleCode: 'finance',
      permissions: const {'organization.suppliers.read', 'projects.finance.read'},
    );
    await _pump(tester, user: financeOnly, initial: '/diger/taseronlar/s1', script: {
      '/subcontractors/s1/ledger': [(status: 200, body: {..._ledger(), 'site_days': []})],
    });
    expect(find.byKey(const ValueKey('taseron-karti-duzenle')), findsNothing);
    expect(find.text('Günlük raporlarda henüz görünmedi.'), findsOneWidget);
  });

  testWidgets('"Ödeme Yap" proje dışı ödemeyi taşeronun kendisine yazar', (tester) async {
    final adapter = await _pump(tester, user: _admin, initial: '/diger/taseronlar/s1', script: {
      '/subcontractors/s1/ledger': [
        (status: 200, body: _ledger()),
        (status: 200, body: _ledger()),
      ],
      '/subcontractors/s1/payments': [
        (status: 201, body: (_ledger()['payments'] as List).first),
      ],
      '/subcontractors': [(status: 200, body: _cards())],
    });
    await tester.tap(find.byKey(const ValueKey('taseron-odeme-yap')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('taseron-odeme-tutar')), '1.500');
    await tester.enterText(find.byKey(const ValueKey('taseron-odeme-aciklama')), 'Depo tamiri');
    await tester.tap(find.byKey(const ValueKey('taseron-odeme-kaydet')));
    await tester.pumpAndSettle();

    final body = requestBodyFor(adapter, '/subcontractors/s1/payments');
    expect(body['amount'], 1500);
    expect(body['description'], 'Depo tamiri');
    expect(find.text('Ödeme kaydedildi.'), findsOneWidget);
  });

  testWidgets('"Ödeme Yap" projedeki işe seçilince projenin taşeron ödemesine gider', (tester) async {
    final adapter = await _pump(tester, user: _admin, initial: '/diger/taseronlar/s1', script: {
      '/subcontractors/s1/ledger': [
        (status: 200, body: _ledger()),
        (status: 200, body: _ledger()),
      ],
      '/projects/p1/subcontractors/ps1/payments': [
        (
          status: 201,
          body: {
            'id': 'sp2',
            'subcontractor_id': 'ps1',
            'amount': 2000,
            'currency': 'TRY',
            'paid_date': '2026-10-14',
            'description': '',
          },
        ),
      ],
      '/subcontractors': [(status: 200, body: _cards())],
    });
    await tester.tap(find.byKey(const ValueKey('taseron-odeme-yap')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('taseron-odeme-hedef')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Elektrik tesisatı').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Kalan: '), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('taseron-odeme-tutar')), '2.000');
    await tester.tap(find.byKey(const ValueKey('taseron-odeme-kaydet')));
    await tester.pumpAndSettle();

    final body = requestBodyFor(adapter, '/projects/p1/subcontractors/ps1/payments');
    expect(body['amount'], 2000);
    expect(adapter.calls, isNot(contains('/subcontractors/s1/payments')));
  });
}
