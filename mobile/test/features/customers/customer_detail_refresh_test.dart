import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/customers/presentation/customer_detail_screen.dart';
import 'package:arvend/features/offers/data/offers_providers.dart';
import 'package:arvend/features/projects/finance_ledger/data/finance_ledger_providers.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart' show FakeAuth, testUser;

/// Müşteri kartı: Teklifler/Projeler/Finansal Özet tazelenir (eskiden
/// yalnızca müşteri bilgisi yenileniyordu), Finansal Özet ana sayfanın
/// açık alacak kuralıyla hesaplanır ve pasif müşteride "Yeni Teklif" yoktur.

const _allPerms = {
  'customers.read',
  'customers.manage',
  'projects.read',
  'projects.finance.read',
  'offers.read',
  'offers.create',
};

Map<String, dynamic> _customer({bool active = true}) => {
      'id': 'c1',
      'name': 'Ahmet İnşaat',
      'phone': '05551112233',
      'email': '',
      'address': '',
      'tax_office': '',
      'tax_number': '',
      'notes': '',
      'is_active': active,
    };

Map<String, dynamic> _project({
  String id = 'p1',
  String name = 'Villa',
  String status = 'active',
  double value = 500000,
  double collected = 200000,
}) =>
    {
      'id': id,
      'project_no': 'PRJ-$id',
      'name': name,
      'project_type': 'konut',
      'customer_id': 'c1',
      'customer_name': 'Ahmet İnşaat',
      'customer_phone': '',
      'customer_email': '',
      'contract_amount': value,
      'currency': 'TRY',
      'status': status,
      'start_date': null,
      'end_date': null,
      'description': '',
      'created_at': '2026-01-01T00:00:00Z',
      'current_contract_value': value,
      'collected_amount': collected,
      'remaining_receivable': value - collected,
    };

Map<String, dynamic> _offer({String id = 'o1', String no = 'TKF-001'}) => {
      'id': id,
      'offer_no': no,
      'revision_no': 0,
      'customer_id': 'c1',
      'customer_name': 'Ahmet İnşaat',
      'customer_phone': '',
      'customer_email': '',
      'customer_address': '',
      'offer_date': '2026-09-20',
      'valid_until': null,
      'subtotal': 1000.0,
      'vat_rate': 20.0,
      'vat_amount': 200.0,
      'grand_total': 1200.0,
      'notes': '',
      'status': 'taslak',
      'is_passive': false,
    };

ScriptedResponse _projects(List<Map<String, dynamic>> projects) =>
    (status: 200, body: {'projects': projects, 'total': projects.length});

ScriptedResponse _offers(List<Map<String, dynamic>> offers) =>
    (status: 200, body: {'offers': offers, 'total': offers.length});

/// Kartı gerçek bir go_router yığınında açar; kartın açtığı proje/teklif
/// ekranları "ekran /yol" metniyle çizilir (geri dönülebilsin diye).
Future<ProviderContainer> _pump(WidgetTester tester, FakeHttpClientAdapter adapter, {Set<String> perms = _allPerms}) async {
  final client = await buildFakeApiClient(adapter);
  Widget stub(GoRouterState s) => Scaffold(appBar: AppBar(), body: Text('ekran ${s.uri.path}'));
  final router = GoRouter(initialLocation: '/diger/musteriler/c1', routes: [
    GoRoute(path: '/diger/musteriler/:id', builder: (_, s) => CustomerDetailScreen(customerId: s.pathParameters['id']!)),
    GoRoute(path: '/projeler/:id', builder: (_, s) => stub(s)),
    GoRoute(path: '/teklifler/yeni', builder: (_, s) => stub(s)),
    GoRoute(path: '/teklifler/:id', builder: (_, s) => stub(s)),
  ]);
  addTearDown(router.dispose);
  await tester.binding.setSurfaceSize(const Size(400, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => FakeAuth(testUser(perms))),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(CustomerDetailScreen)));
}

int _count(FakeHttpClientAdapter a, String path) => a.calls.where((c) => c == path).length;

/// Tazelemede eski veri ekranda kalır (yükleniyor göstergesi yok), yani
/// kare istenmez ve pumpAndSettle sahte saati ilerletmez -- istek
/// zamanlayıcıları için saat elle ilerletilir.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  group('tazeleme', () {
    testWidgets('aşağı çekip yenileme teklifleri ve projeleri de yeniden çeker', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 200, body: _customer()), (status: 200, body: _customer())],
        '/offers/': [_offers([_offer()]), _offers([_offer(), _offer(id: 'o2', no: 'TKF-002')])],
        '/projects': [_projects([_project()]), _projects([_project(collected: 450000)])],
      });
      await _pump(tester, adapter);
      expect(find.text('TKF-002'), findsNothing);

      await tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
      await _settle(tester);

      expect(_count(adapter, '/customers/c1'), 2);
      expect(_count(adapter, '/offers/'), 2);
      expect(_count(adapter, '/projects'), 2);
      expect(find.text('TKF-002'), findsOneWidget);
      // Kalan alacak yeni tahsilatla güncellendi (500.000 - 450.000).
      expect(find.textContaining('50.000'), findsWidgets);
    });

    testWidgets('karttan açılan projeden dönünce Projeler ve Finansal Özet tazelenir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 200, body: _customer())],
        '/offers/': [_offers([]), _offers([])],
        '/projects': [_projects([_project()]), _projects([_project(collected: 500000)])],
      });
      await _pump(tester, adapter);

      await tester.tap(find.text('Villa'));
      await tester.pumpAndSettle();
      expect(find.text('ekran /projeler/p1'), findsOneWidget);

      // Proje ekranında tahsilat girildi; geri dönülür.
      GoRouter.of(tester.element(find.text('ekran /projeler/p1'))).pop();
      await _settle(tester);

      expect(_count(adapter, '/projects'), 2);
      expect(_count(adapter, '/offers/'), 2);
    });

    testWidgets('teklif akışlarının tazeleme sinyali müşteri kartının tekliflerini de yeniler', (tester) async {
      // Teklif oluşturma/durum/revizyon/silme ekranları offersListProvider('')
      // sinyalini tazeler (bkz. offer_create_screen / offer_detail_screen).
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 200, body: _customer())],
        '/offers/': [_offers([]), _offers([_offer()])],
        '/projects': [_projects([])],
      });
      final container = await _pump(tester, adapter);
      expect(find.text('TKF-001'), findsNothing);

      container.invalidate(offersListProvider(''));
      await _settle(tester);

      expect(find.text('TKF-001'), findsOneWidget);
    });

    testWidgets('bir projeye tahsilat yazılınca (invalidateProjectLedger) kartın projeleri tazelenir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 200, body: _customer())],
        '/offers/': [_offers([])],
        '/projects': [_projects([_project()]), _projects([_project(collected: 500000)])],
      });
      final container = await _pump(tester, adapter);

      invalidateProjectLedger(container.invalidate, 'p1');
      await _settle(tester);

      expect(_count(adapter, '/projects'), 2);
    });
  });

  group('Finansal Özet', () {
    testWidgets('iptal edilen proje sayılmaz; fazla tahsilat ayrı satırda, başka projenin alacağını düşürmez',
        (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 200, body: _customer())],
        '/offers/': [_offers([])],
        '/projects': [
          _projects([
            _project(id: 'a', name: 'A Blok', value: 100000, collected: 150000),
            _project(id: 'b', name: 'B Blok', value: 200000, collected: 50000),
            _project(id: 'c', name: 'İptal Blok', status: 'cancelled', value: 300000, collected: 0),
          ]),
        ],
      });
      await _pump(tester, adapter);

      Finder rowValue(String label) => find.descendant(
            of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
            matching: find.textContaining('TL'),
          );
      // Sözleşme 300.000 (iptal hariç), tahsilat 200.000, kalan 150.000
      // (eskiden 100.000 -- A'nın fazlası B'den düşülüyordu; iptalle 400.000).
      expect(tester.widget<Text>(rowValue('Sözleşme Değeri')).data, contains('300.000'));
      expect(tester.widget<Text>(rowValue('Tahsil Edilen')).data, contains('200.000'));
      expect(tester.widget<Text>(rowValue('Kalan Alacak')).data, contains('150.000'));
      expect(tester.widget<Text>(rowValue('Fazla Tahsilat')).data, contains('50.000'));
      expect(find.text('İptal edilen 1 proje özete katılmadı.'), findsOneWidget);
    });

    testWidgets('fazla tahsilat yoksa satır çizilmez', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 200, body: _customer())],
        '/offers/': [_offers([])],
        '/projects': [_projects([_project()])],
      });
      await _pump(tester, adapter);

      expect(find.text('Kalan Alacak'), findsOneWidget);
      expect(find.text('Fazla Tahsilat'), findsNothing);
      expect(find.textContaining('özete katılmadı'), findsNothing);
    });
  });

  group('pasif müşteri', () {
    testWidgets('pasif müşteride "Yeni Teklif" yok, sebebi yazılır', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 200, body: _customer(active: false))],
        '/offers/': [_offers([])],
        '/projects': [_projects([])],
      });
      await _pump(tester, adapter);

      expect(find.text('Yeni Teklif'), findsNothing);
      expect(find.byKey(const ValueKey('customer-passive-offer-note')), findsOneWidget);
      expect(find.textContaining('önce müşteriyi aktifleştir'), findsOneWidget);
    });

    testWidgets('aktif müşteride "Yeni Teklif" var; dönüşte teklifler tazelenir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 200, body: _customer())],
        '/offers/': [_offers([]), _offers([_offer()])],
        '/projects': [_projects([])],
      });
      await _pump(tester, adapter);

      expect(find.byKey(const ValueKey('customer-passive-offer-note')), findsNothing);
      await tester.tap(find.text('Yeni Teklif'));
      await tester.pumpAndSettle();
      expect(find.text('ekran /teklifler/yeni'), findsOneWidget);

      GoRouter.of(tester.element(find.text('ekran /teklifler/yeni'))).pop();
      await _settle(tester);

      expect(find.text('TKF-001'), findsOneWidget);
    });

    testWidgets('teklif oluşturma izni yoksa pasif müşteride not da gösterilmez', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 200, body: _customer(active: false))],
      });
      await _pump(tester, adapter, perms: {'customers.read'});

      expect(find.byKey(const ValueKey('customer-passive-offer-note')), findsNothing);
      expect(find.text('Yeni Teklif'), findsNothing);
    });
  });
}
