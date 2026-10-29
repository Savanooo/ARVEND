import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/utils/event_labels.dart';
import 'package:arvend/features/projects/data/projects_repository.dart';
import 'package:arvend/features/projects/domain/procurement.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/presentation/purchase_order_detail_screen.dart';
import 'package:arvend/features/projects/presentation/purchase_request_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';

/// Satın almalar proje maliyetine girer (backend migration 0078): talep
/// onaylanırken "Proje maliyetine eklensin mi?" diye sorulur, fiyatsız
/// talepte uyarılır ve tahmini tutar girilebilir; detayda "Maliyete eklendi:
/// X" / "Maliyete eklenmedi" ve (onay izniyle) "Değiştir".

Map<String, dynamic> _me({List<String> permissions = const []}) => {
      'id': 'u1',
      'organization_id': 'org1',
      'username': 'test',
      'full_name': 'Ayşe Yılmaz',
      'organization_name': 'ARVEND Yapı',
      'role': 'kullanici',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': permissions,
    };

Map<String, dynamic> _pr({
  String status = 'submitted',
  double estimatedTotal = 0,
  bool include = true,
  Map<String, dynamic>? cost,
}) =>
    {
      'id': 'pr1', 'pr_no': 'PR-2026-0001', 'title': 'Kum talebi', 'description': '', 'status': status,
      'estimated_total': estimatedTotal, 'created_at': '2026-10-29T08:00:00Z', 'updated_at': '2026-10-29T08:00:00Z',
      'include_in_project_cost': include, 'cost_estimate': null,
      'project_cost': ?cost,
    };

Map<String, dynamic> _prDetail(Map<String, dynamic> pr, {bool priced = false}) => {
      'purchase_request': pr,
      'items': [
        {
          'id': 'i1', 'description': 'Kum', 'quantity': 3, 'unit': 'ton',
          'estimated_unit_cost': priced ? 1000 : null, 'estimated_total': priced ? 3000 : 0, 'notes': '', 'sort_order': 0,
        },
      ],
    };

const _noPrice = {
  'included': true, 'amount': 0, 'potential': 0, 'source': 'none', 'unpriced_items': 1,
  'warning': 'Bu talepte fiyat yok; maliyete 0 TL girer.',
};

Map<String, dynamic> _poDetail({String status = 'draft', bool include = true, Map<String, dynamic>? cost}) => {
      'purchase_order': {
        'id': 'po1', 'po_no': 'PO-2026-0001', 'supplier_id': 's1', 'supplier_name': 'Yapı Market',
        'currency': 'TRY', 'status': status, 'issue_date': '2026-10-29', 'payment_terms': '', 'delivery_address': '',
        'notes': '', 'subtotal': 12000, 'tax_rate': 20, 'tax': 2400, 'total': 14400,
        'purchase_request_id': 'pr1', 'include_in_project_cost': include,
        'project_cost': ?cost,
      },
      'items': [
        {'id': 'i1', 'cost_code_id': 'cc1', 'description': 'Alçıpan', 'quantity': 10, 'unit': 'adet', 'unit_price': 1200, 'line_total': 12000, 'sort_order': 0},
      ],
      'commitments': <dynamic>[],
      'receipts': <dynamic>[],
    };

Future<FakeHttpClientAdapter> _pump(
  WidgetTester tester,
  Map<String, List<({int status, Object? body})>> script,
  Widget child,
) async {
  final adapter = FakeHttpClientAdapter(script: script);
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(400, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp(home: child),
    ),
  );
  await tester.pumpAndSettle();
  return adapter;
}

/// Onaydan/karardan sonra tazelenen uçlar (listeler, özet).
Map<String, List<({int status, Object? body})>> _refreshes() => {
      '/projects/p1/purchase-requests': [(status: 200, body: {'purchase_requests': <dynamic>[]})],
      '/projects/p1/purchase-orders': [(status: 200, body: {'purchase_orders': <dynamic>[]})],
      '/projects/p1/financial-summary': [(status: 500, body: null)],
      '/projects/p1/cost-control': [(status: 500, body: null)],
    };

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  group('model', () {
    test('talep ve sipariş maliyet katkısını okur; eski sunucuda varsayılanlar', () {
      final pr = PurchaseRequest.fromJson(_pr(status: 'approved', estimatedTotal: 11000, cost: {
        'included': true, 'amount': 14400, 'potential': 14400, 'source': 'orders', 'unpriced_items': 0,
      }));
      expect(pr.includeInProjectCost, isTrue);
      expect(pr.projectCost!.amount, 14400);
      expect(pr.projectCost!.counts, isTrue);
      expect(pr.projectCost!.sourceLabel, 'Onaylı siparişlerin tutarı (tahminin yerine)');
      expect(pr.canChangeProjectCost, isTrue);

      final old = PurchaseRequest.fromJson(
          (_pr(estimatedTotal: 500)..remove('include_in_project_cost')..remove('cost_estimate')));
      expect(old.includeInProjectCost, isTrue, reason: 'eski sunucu: karar yok = eklenir');
      expect(old.projectCost, isNull);
      expect(old.costPotential, 500);
      expect(old.canChangeProjectCost, isFalse, reason: 'yalnızca onaylı talepte');

      final po = PurchaseOrder.fromJson(_poDetail(status: 'closed', include: false)['purchase_order'] as Map<String, dynamic>);
      expect(po.purchaseRequestId, 'pr1');
      expect(po.includeInProjectCost, isFalse);
      expect(po.canChangeProjectCost, isFalse, reason: 'kapatılmış sipariş kesinleşmiştir');
    });

    test('finans özeti satın alma kırılımını okur; eski sunucuda 0', () {
      final base = {
        'current_contract_value': 1000, 'collected_amount': 0, 'remaining_receivable': 1000, 'total_expenses': 0,
        'subcontractor_paid': 0, 'subcontractor_remaining': 0, 'realized_cost': 0, 'committed_cost': 0,
        'realized_gross_profit': 0, 'estimated_gross_profit': 0,
      };
      final s = FinancialSummary.fromJson({...base, 'purchase_cost': 14400, 'expense_cost': 500, 'purchase_excluded': 1200});
      expect(s.purchaseCost, 14400);
      expect(s.expenseCost, 500);
      expect(s.purchaseExcluded, 1200);
      final old = FinancialSummary.fromJson(base);
      expect(old.purchaseCost, 0);
      expect(old.purchaseExcluded, 0);
    });

    test('olay etiketleri', () {
      expect(kProjectEventLabels['purchase_request_cost_decision'], 'Talebin maliyet kararı değişti');
      expect(kProjectEventLabels['purchase_order_cost_decision'], 'Siparişin maliyet kararı değişti');
    });
  });

  group('depo', () {
    test('kararsız onay gövdesiz gider (eski davranış); kararla gövde taşır', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-requests/pr1/approve': [
          (status: 200, body: _pr(status: 'approved')),
          (status: 200, body: _pr(status: 'approved')),
        ],
        '/projects/p1/purchase-requests/pr1/project-cost': [(status: 200, body: _pr(status: 'approved', include: false))],
        '/projects/p1/purchase-orders/po1/approve': [(status: 200, body: _poDetail(status: 'approved')['purchase_order'])],
        '/projects/p1/purchase-orders/po1/project-cost': [(status: 200, body: _poDetail(status: 'approved')['purchase_order'])],
      });
      final repo = ProjectsRepository(await buildFakeApiClient(adapter));
      await repo.approvePurchaseRequest('p1', 'pr1');
      await repo.approvePurchaseRequest('p1', 'pr1', includeInProjectCost: true, costEstimate: 2500);
      final changed = await repo.setPurchaseRequestCost('p1', 'pr1', includeInProjectCost: false);
      await repo.approvePurchaseOrder('p1', 'po1', includeInProjectCost: false);
      await repo.setPurchaseOrderCost('p1', 'po1', includeInProjectCost: true);
      expect(adapter.requestBodies, [
        null,
        {'include_in_project_cost': true, 'cost_estimate': 2500.0},
        {'include_in_project_cost': false},
        {'include_in_project_cost': false},
        {'include_in_project_cost': true},
      ]);
      expect(changed.includeInProjectCost, isFalse);
    });
  });

  group('talep onayı', () {
    testWidgets('fiyatsız talep: soru, uyarı ve tahmini tutarla onay', (tester) async {
      final adapter = await _pump(tester, {
        '/auth/me': [(status: 200, body: _me())],
        '/projects/p1/purchase-requests/pr1': [
          (status: 200, body: _prDetail(_pr(cost: _noPrice))),
          (status: 200, body: _prDetail(_pr(status: 'approved', cost: {
            'included': true, 'amount': 2500, 'potential': 2500, 'source': 'estimate', 'unpriced_items': 1,
          }))),
        ],
        '/projects/p1/purchase-requests/pr1/approve': [(status: 200, body: _pr(status: 'approved'))],
        ..._refreshes(),
      }, const PurchaseRequestDetailScreen(projectId: 'p1', prId: 'pr1'));

      // Onaydan önce detay uyarır.
      expect(find.text('Onaylanınca maliyete eklenecek: 0,00 TL'), findsOneWidget);
      expect(find.text('Bu talepte fiyat yok; maliyete 0 TL girer.'), findsOneWidget);

      await tester.tap(find.text('Onayla'));
      await tester.pumpAndSettle();
      expect(find.text('Proje maliyetine eklensin mi?'), findsOneWidget);
      expect(find.text('Evet, maliyete ekle'), findsOneWidget);
      expect(find.text('Hayır (depo/stok ya da genel kullanım)'), findsOneWidget);
      expect(find.text('Maliyete eklenecek: 0,00 TL'), findsOneWidget);
      expect(find.text('Bu talepte fiyat yok; maliyete 0 TL girer.'), findsNWidgets(2));
      expect(find.byIcon(Icons.close), findsNothing, reason: 'alt sayfada X düğmesi yok');

      await tester.enterText(find.byKey(const Key('maliyet-tahmin')), '2.500');
      await tester.pumpAndSettle();
      expect(find.text('Maliyete eklenecek: 2.500,00 TL'), findsOneWidget);
      expect(find.text('Bu talepte fiyat yok; maliyete 0 TL girer.'), findsOneWidget, reason: 'sayfadaki uyarı kalktı, detaydaki kaldı');

      await tester.tap(find.byKey(const Key('maliyet-onayla')));
      await tester.pumpAndSettle();
      final i = adapter.calls.indexOf('/projects/p1/purchase-requests/pr1/approve');
      expect(adapter.requestBodies[i], {'include_in_project_cost': true, 'cost_estimate': 2500.0});
      expect(find.text('Maliyete eklendi: 2.500,00 TL'), findsOneWidget, reason: 'detay tazelendi');
      expect(find.text('Talebin tahmini tutarı'), findsOneWidget);
    });

    testWidgets('"Hayır" seçilince maliyete eklenmeden onaylanır; vazgeçince istek gitmez', (tester) async {
      final adapter = await _pump(tester, {
        '/auth/me': [(status: 200, body: _me())],
        '/projects/p1/purchase-requests/pr1': [
          (status: 200, body: _prDetail(_pr(estimatedTotal: 3000, cost: {
            'included': true, 'amount': 0, 'potential': 3000, 'source': 'none', 'unpriced_items': 0,
          }), priced: true)),
          (status: 200, body: _prDetail(_pr(status: 'approved', estimatedTotal: 3000, include: false, cost: {
            'included': false, 'amount': 0, 'potential': 3000, 'source': 'estimate', 'unpriced_items': 0,
          }), priced: true)),
        ],
        '/projects/p1/purchase-requests/pr1/approve': [(status: 200, body: _pr(status: 'approved', include: false))],
        ..._refreshes(),
      }, const PurchaseRequestDetailScreen(projectId: 'p1', prId: 'pr1'));

      await tester.tap(find.text('Onayla'));
      await tester.pumpAndSettle();
      expect(find.text('Maliyete eklenecek: 3.000,00 TL'), findsOneWidget);
      expect(find.byKey(const Key('maliyet-tahmin')), findsNothing, reason: 'fiyatlı talepte tahmin alanı yok');
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(adapter.calls, isNot(contains('/projects/p1/purchase-requests/pr1/approve')));

      await tester.tap(find.text('Onayla'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('maliyet-hayir')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('maliyet-onayla')));
      await tester.pumpAndSettle();
      final i = adapter.calls.indexOf('/projects/p1/purchase-requests/pr1/approve');
      expect(adapter.requestBodies[i], {'include_in_project_cost': false});
      expect(find.text('Maliyete eklenmedi'), findsOneWidget);
      expect(find.textContaining('3.000,00 TL proje maliyetinin dışında'), findsOneWidget);
    });
  });

  group('talep / sipariş detayı', () {
    testWidgets('onaylı talep: "Maliyete eklendi" ve onay izniyle Değiştir', (tester) async {
      final adapter = await _pump(tester, {
        '/auth/me': [(status: 200, body: _me())],
        '/projects/p1/purchase-requests/pr1': [
          (status: 200, body: _prDetail(_pr(status: 'approved', estimatedTotal: 11000, cost: {
            'included': true, 'amount': 14400, 'potential': 14400, 'source': 'orders', 'unpriced_items': 0,
          }), priced: true)),
          (status: 200, body: _prDetail(_pr(status: 'approved', estimatedTotal: 11000, include: false, cost: {
            'included': false, 'amount': 0, 'potential': 14400, 'source': 'orders', 'unpriced_items': 0,
          }), priced: true)),
        ],
        '/projects/p1/purchase-requests/pr1/project-cost': [(status: 200, body: _pr(status: 'approved', include: false))],
        ..._refreshes(),
      }, const PurchaseRequestDetailScreen(projectId: 'p1', prId: 'pr1'));

      expect(find.text('Maliyete eklendi: 14.400,00 TL'), findsOneWidget);
      expect(find.text('Onaylı siparişlerin tutarı (tahminin yerine)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('maliyet-degistir')));
      await tester.pumpAndSettle();
      expect(find.text('Karar talebin açık siparişlerine de uygulanır.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('maliyet-hayir')));
      await tester.tap(find.byKey(const Key('maliyet-onayla')));
      await tester.pumpAndSettle();
      final i = adapter.calls.indexOf('/projects/p1/purchase-requests/pr1/project-cost');
      expect(adapter.requestBodies[i], {'include_in_project_cost': false});
      expect(find.text('Maliyete eklenmedi'), findsOneWidget);
    });

    testWidgets('onay izni olmayan kararı görür, değiştiremez', (tester) async {
      await _pump(tester, {
        '/auth/me': [(status: 200, body: _me(permissions: ['projects.procurement.read', 'projects.procurement.manage']))],
        '/projects/p1/purchase-requests/pr1': [
          (status: 200, body: _prDetail(_pr(status: 'approved', estimatedTotal: 3000, cost: {
            'included': true, 'amount': 3000, 'potential': 3000, 'source': 'estimate', 'unpriced_items': 0,
          }), priced: true)),
        ],
      }, const PurchaseRequestDetailScreen(projectId: 'p1', prId: 'pr1'));
      expect(find.text('Maliyete eklendi: 3.000,00 TL'), findsOneWidget);
      expect(find.byKey(const Key('maliyet-degistir')), findsNothing);
    });

    testWidgets('sipariş onayı kararı sorar (talepten devralınan seçili) ve gönderir', (tester) async {
      final adapter = await _pump(tester, {
        '/auth/me': [(status: 200, body: _me())],
        '/projects/p1/purchase-orders/po1': [
          (status: 200, body: _poDetail(include: false, cost: {
            'included': false, 'amount': 0, 'potential': 14400, 'source': 'none', 'order_amount': 14400, 'invoiced_amount': 0,
          })),
          (status: 200, body: _poDetail(status: 'approved', cost: {
            'included': true, 'amount': 14400, 'potential': 14400, 'source': 'order', 'order_amount': 14400, 'invoiced_amount': 6000,
          })),
        ],
        ..._refreshes(),
        '/projects/p1/purchase-orders/po1/approve': [(status: 200, body: _poDetail(status: 'approved')['purchase_order'])],
      }, const PurchaseOrderDetailScreen(projectId: 'p1', poId: 'po1'));

      expect(find.text('Maliyete eklenmedi'), findsOneWidget);
      await tester.tap(find.text('Onayla'));
      await tester.pumpAndSettle();
      expect(find.text('Siparişi Onayla'), findsOneWidget);
      expect(find.textContaining('talebin tahmini tutarının yerine'), findsOneWidget);
      expect(find.text('Maliyete eklenecek: 14.400,00 TL'), findsOneWidget);
      await tester.tap(find.byKey(const Key('maliyet-evet')));
      await tester.tap(find.byKey(const Key('maliyet-onayla')));
      await tester.pumpAndSettle();
      final i = adapter.calls.indexOf('/projects/p1/purchase-orders/po1/approve');
      expect(adapter.requestBodies[i], {'include_in_project_cost': true});
      expect(find.text('Maliyete eklendi: 14.400,00 TL'), findsOneWidget);
      expect(find.text('Sipariş tutarı · faturalanan 6.000,00 TL'), findsOneWidget);
    });
  });
}
