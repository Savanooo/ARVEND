import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/features/projects/data/projects_repository.dart';
import 'package:arvend/features/projects/domain/procurement.dart';
import 'package:arvend/features/projects/presentation/purchase_order_detail_screen.dart';
import 'package:arvend/features/projects/presentation/purchase_receipt_form_screen.dart';

import '../../test_utils/fake_api_client.dart';

/// Siparişten teslim alma (backend migration 0074): 100 sipariş, 60 geldi,
/// 5 hasarlı -> 55 kabul, 5 red, 40 bekliyor; kabul edilip faturası
/// girilmemiş tutar görünür; teslim alınmış sipariş iptal edilemez.

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

Map<String, dynamic> _detail({String status = 'approved', bool received = true}) => {
      'purchase_order': {
        'id': 'po1', 'po_no': 'SAS-2026-0001', 'supplier_id': 's1', 'supplier_name': 'Alçıpan Tedarik',
        'currency': 'TRY', 'status': status, 'issue_date': '2026-10-01', 'payment_terms': '',
        'delivery_address': '', 'notes': '', 'subtotal': 100000, 'tax_rate': 20, 'tax': 20000, 'total': 120000,
        'receipt_status': received ? 'partial' : 'none', 'received_not_costed': received ? 36000 : 0,
      },
      'items': [
        {
          'id': 'i1', 'cost_code_id': 'cc1', 'description': 'Alçıpan', 'quantity': 100, 'unit': 'adet',
          'unit_price': 1000, 'line_total': 100000, 'sort_order': 0,
          'accepted_quantity': received ? 55 : 0, 'rejected_quantity': received ? 5 : 0,
          'waiting_quantity': received ? 40 : 100,
        },
      ],
      'commitments': <dynamic>[],
      'receipts': [
        if (received)
          {
            'id': 'r1', 'purchase_order_id': 'po1', 'sequence_no': 1, 'received_date': '2026-10-10',
            'delivery_note_no': 'IRS-77', 'destination': 'site', 'warehouse_id': null, 'warehouse_name': '',
            'notes': '', 'created_by': 'u1', 'created_by_name': 'Ayşe Yılmaz', 'created_at': '2026-10-10T08:00:00Z',
            'voided_at': null, 'void_reason': '',
            'items': [
              {'purchase_order_item_id': 'i1', 'accepted_quantity': 55, 'rejected_quantity': 5, 'rejection_reason': 'Kırık'},
            ],
          },
      ],
      'receipt_summary': {
        'status': received ? 'partial' : 'none',
        'accepted_total': received ? 66000 : 0,
        'costed_total': received ? 30000 : 0,
        'received_not_costed': received ? 36000 : 0,
      },
    };

Future<FakeHttpClientAdapter> _pump(
  WidgetTester tester,
  Map<String, List<({int status, Object? body})>> script,
  Widget child,
) async {
  final adapter = FakeHttpClientAdapter(script: script);
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(400, 2000));
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

/// Formu gerçek bir sayfa gibi açar (kaydedince pop(true) bir alt sayfaya döner).
class _Host extends StatefulWidget {
  const _Host();
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  Object? result = 'açılmadı';
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(
          children: [
            Text('sonuç: $result'),
            TextButton(
              onPressed: () async {
                final r = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => const PurchaseReceiptFormScreen(projectId: 'p1', poId: 'po1')),
                );
                setState(() => result = r);
              },
              child: const Text('aç'),
            ),
          ],
        ),
      );
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  group('depo', () {
    test('detay teslimleri, özeti ve kalem miktarlarını okur; eski sunucuda boş', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-orders/po1': [
          (status: 200, body: _detail()),
          (
            status: 200,
            body: {
              'purchase_order': (_detail()['purchase_order'] as Map<String, dynamic>)
                ..remove('receipt_status')
                ..remove('received_not_costed'),
              'items': <dynamic>[],
              'commitments': <dynamic>[],
            }
          ),
        ],
      });
      final repo = ProjectsRepository(await buildFakeApiClient(adapter));
      final d = await repo.purchaseOrderDetail('p1', 'po1');
      expect(d.order.receiptStatus, kReceiptPartial);
      expect(d.order.canCancel, isFalse, reason: 'teslim alınmış sipariş iptal edilemez');
      expect(d.order.canClose, isTrue);
      expect(d.items.single.waitingQuantity, 40);
      expect(d.items.single.maxAcceptable, 45, reason: 'kabul tavanı = sipariş - kabul');
      expect(d.receipts.single.items.single.rejectionReason, 'Kırık');
      expect(d.receiptSummary.receivedNotCosted, 36000);

      final old = await repo.purchaseOrderDetail('p1', 'po1');
      expect(old.receipts, isEmpty);
      expect(old.receiptSummary.status, kReceiptNone);
      expect(old.order.canCancel, isTrue, reason: 'eski sunucu: teslim yok, iptal serbest');
    });

    test('teslim gövdesi ve iptal ucu', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-orders/po1/receipts': [
          (status: 201, body: (_detail()['receipts'] as List).first),
        ],
        '/projects/p1/purchase-receipts/r1/void': [
          (status: 200, body: {...(_detail()['receipts'] as List).first as Map<String, dynamic>, 'voided_at': '2026-10-11T00:00:00Z'}),
        ],
      });
      final repo = ProjectsRepository(await buildFakeApiClient(adapter));
      await repo.createPurchaseReceipt(
        'p1',
        'po1',
        receivedDate: '2026-10-10',
        deliveryNoteNo: 'IRS-77',
        destination: 'warehouse',
        warehouseId: 'w1',
        idempotencyKey: 'k1',
        items: const [PurchaseReceiptItem(purchaseOrderItemId: 'i1', acceptedQuantity: 55, rejectedQuantity: 5, rejectionReason: 'Kırık')],
      );
      final body = adapter.requestBodies.first as Map;
      expect(body['destination'], 'warehouse');
      expect(body['warehouse_id'], 'w1');
      expect(body['idempotency_key'], 'k1');
      expect((body['items'] as List).single, {
        'purchase_order_item_id': 'i1',
        'accepted_quantity': 55.0,
        'rejected_quantity': 5.0,
        'rejection_reason': 'Kırık',
      });
      final voided = await repo.voidPurchaseReceipt('p1', 'r1', reason: 'Yanlış');
      expect(adapter.calls.last, '/projects/p1/purchase-receipts/r1/void');
      expect(adapter.requestBodies.last, {'reason': 'Yanlış'});
      expect(voided.isVoided, isTrue);
    });
  });

  group('sipariş detayı', () {
    testWidgets('kabul / red / bekleyen, teslim özeti ve teslim listesi; teslim alınmışta İptal Et yok', (tester) async {
      await _pump(tester, {
        '/auth/me': [(status: 200, body: _me())],
        '/projects/p1/purchase-orders/po1': [(status: 200, body: _detail())],
      }, const PurchaseOrderDetailScreen(projectId: 'p1', poId: 'po1'));

      expect(find.text('Teslim Alma'), findsOneWidget);
      expect(find.text('Kabul 55 · Red 5 · Bekleyen 40'), findsOneWidget);
      expect(find.text('Kısmi teslim'), findsOneWidget);
      expect(find.text('66.000,00 TL'), findsOneWidget);
      expect(find.text('36.000,00 TL'), findsOneWidget);
      expect(find.byKey(const ValueKey('po-receive')), findsOneWidget);
      expect(find.textContaining('İrsaliye IRS-77'), findsOneWidget);
      expect(find.textContaining('red 5 adet (Kırık)'), findsOneWidget);
      expect(find.text('İptal Et'), findsNothing, reason: 'teslim alınmış sipariş iptal edilemez, kapatılır');
      expect(find.text('Kapat'), findsOneWidget);
    });

    testWidgets('teslim izni olmayan Teslim Al ve teslim iptali görmez', (tester) async {
      await _pump(tester, {
        '/auth/me': [(status: 200, body: _me(permissions: ['projects.procurement.read']))],
        '/projects/p1/purchase-orders/po1': [(status: 200, body: _detail())],
      }, const PurchaseOrderDetailScreen(projectId: 'p1', poId: 'po1'));
      expect(find.byKey(const ValueKey('po-receive')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('po-receipt-r1')));
      await tester.pumpAndSettle();
      expect(find.text('Teslim 1'), findsWidgets);
      expect(find.byKey(const ValueKey('receipt-void')), findsNothing);
    });

    testWidgets('kapatma onayı teslim kaydı varsa teslim alınanın kalacağını söyler', (tester) async {
      await _pump(tester, {
        '/auth/me': [(status: 200, body: _me())],
        '/projects/p1/purchase-orders/po1': [(status: 200, body: _detail())],
      }, const PurchaseOrderDetailScreen(projectId: 'p1', poId: 'po1'));
      await tester.tap(find.text('Kapat'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Gelmeyen kısım taahhütten çıkar; teslim alınan 66.000,00 TL kalır.'), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
    });

    testWidgets('teslim iptali gerekçeyle .../void çağırır', (tester) async {
      final adapter = await _pump(tester, {
        '/auth/me': [(status: 200, body: _me())],
        '/projects/p1/purchase-orders/po1': [
          (status: 200, body: _detail()),
          (status: 200, body: _detail(received: false)),
        ],
        '/projects/p1/purchase-orders': [(status: 200, body: {'purchase_orders': <dynamic>[]})],
        '/projects/p1/financial-summary': [(status: 500, body: null)],
        '/projects/p1/cost-control': [(status: 500, body: null)],
        '/projects/p1/purchase-receipts/r1/void': [
          (status: 200, body: {...(_detail()['receipts'] as List).first as Map<String, dynamic>, 'voided_at': '2026-10-11T00:00:00Z'}),
        ],
      }, const PurchaseOrderDetailScreen(projectId: 'p1', poId: 'po1'));
      await tester.tap(find.byKey(const ValueKey('po-receipt-r1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('receipt-void')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('receipt-void-reason')), 'Yanlış irsaliye');
      await tester.tap(find.byKey(const ValueKey('receipt-void-reason-confirm')));
      await tester.pumpAndSettle();
      expect(adapter.calls, contains('/projects/p1/purchase-receipts/r1/void'));
      expect(find.text('Teslim iptal edildi.'), findsOneWidget);
      expect(find.text('Teslim yok'), findsOneWidget, reason: 'detay tazelendi');
    });
  });

  group('teslim formu', () {
    testWidgets('bekleyenle dolu açılır, tavanı ve red nedenini denetler, doğru gövdeyle kaydeder', (tester) async {
      final adapter = await _pump(tester, {
        '/auth/me': [(status: 200, body: _me())],
        '/projects/p1/purchase-orders/po1': [(status: 200, body: _detail())],
        '/projects/p1/purchase-orders/po1/receipts': [
          (status: 201, body: (_detail()['receipts'] as List).first),
        ],
      }, const _Host());
      await tester.tap(find.text('aç'));
      await tester.pumpAndSettle();

      final accepted = find.byKey(const ValueKey('receipt-accepted-i1'));
      expect(tester.widget<TextFormField>(accepted).controller!.text, '40', reason: 'bekleyenle dolu');
      await tester.enterText(accepted, '46');
      await tester.enterText(find.byKey(const ValueKey('receipt-rejected-i1')), '2');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('receipt-save')));
      await tester.pumpAndSettle();
      expect(find.text('En fazla 45'), findsOneWidget);
      expect(find.text('Red nedenini yazın'), findsOneWidget);
      expect(adapter.calls, isNot(contains('/projects/p1/purchase-orders/po1/receipts')));

      await tester.enterText(accepted, '45');
      await tester.enterText(find.byKey(const ValueKey('receipt-reason-i1')), 'Islak');
      await tester.enterText(find.byKey(const ValueKey('receipt-delivery-note')), 'IRS-78');
      await tester.tap(find.byKey(const ValueKey('receipt-save')));
      await tester.pumpAndSettle();

      final body = adapter.requestBodies.last as Map;
      expect(body['destination'], 'site');
      expect(body['delivery_note_no'], 'IRS-78');
      expect(body.containsKey('warehouse_id'), isFalse);
      expect((body['idempotency_key'] as String), startsWith('po-receipt-po1-'));
      expect((body['items'] as List).single, {
        'purchase_order_item_id': 'i1',
        'accepted_quantity': 45.0,
        'rejected_quantity': 2.0,
        'rejection_reason': 'Islak',
      });
      expect(find.text('sonuç: true'), findsOneWidget);
    });

    testWidgets('depoya teslimde depo seçimi istenir', (tester) async {
      final adapter = await _pump(tester, {
        '/auth/me': [(status: 200, body: _me())],
        '/projects/p1/purchase-orders/po1': [(status: 200, body: _detail())],
        '/inventory/warehouses': [
          (
            status: 200,
            body: {
              'warehouses': [
                {'id': 'w1', 'name': 'Merkez Depo', 'is_active': true},
                {'id': 'w2', 'name': 'Kapalı Depo', 'is_active': false},
              ],
            }
          ),
        ],
        '/projects/p1/purchase-orders/po1/receipts': [
          (status: 201, body: (_detail()['receipts'] as List).first),
        ],
      }, const _Host());
      await tester.tap(find.text('aç'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Depo'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('receipt-save')));
      await tester.pumpAndSettle();
      expect(find.text('Depoyu seçin'), findsOneWidget);
      expect(adapter.calls, isNot(contains('/projects/p1/purchase-orders/po1/receipts')));

      await tester.tap(find.byKey(const ValueKey('receipt-warehouse')));
      await tester.pumpAndSettle();
      expect(find.text('Kapalı Depo'), findsNothing, reason: 'kapalı depo seçilemez');
      await tester.tap(find.text('Merkez Depo').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('receipt-save')));
      await tester.pumpAndSettle();
      final body = adapter.requestBodies.last as Map;
      expect(body['destination'], 'warehouse');
      expect(body['warehouse_id'], 'w1');
    });
  });
}
