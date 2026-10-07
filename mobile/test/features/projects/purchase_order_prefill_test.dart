import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/utils/formatters.dart';
import 'package:arvend/features/projects/domain/procurement.dart';
import 'package:arvend/features/projects/presentation/purchase_order_form_screen.dart';
import 'package:arvend/features/projects/presentation/purchase_request_form_screen.dart';

import '../../test_utils/fake_api_client.dart';
import 'form_test_support.dart';

/// Sipariş formu bütçe kalemi/WBS bağlarını korur; ödüllü tekliften sipariş
/// maliyet kodunu, KDV oranını ve iskontoyu taşır (toplam kazanan teklifle
/// tutar).

RFQItem _rfqItem(String id, String description, {String? costCodeId, String? budgetLineId, String? wbsNodeId}) => RFQItem(
      id: id,
      sourcePrItemId: null,
      wbsNodeId: wbsNodeId,
      costCodeId: costCodeId,
      budgetLineId: budgetLineId,
      description: description,
      quantity: 1,
      unit: 'adet',
      sortOrder: 0,
    );

QuotationItem _qItem(String rfqItemId, double quantity, double unitPrice) => QuotationItem(
      id: 'q-$rfqItemId',
      rfqItemId: rfqItemId,
      quantity: quantity,
      unitPrice: unitPrice,
      lineTotal: quantity * unitPrice,
      notes: '',
    );

double _sum(List<PurchaseOrderItem> items) =>
    items.fold<double>(0, (s, i) => s + ((i.quantity * i.unitPrice) * 100).roundToDouble() / 100);

void main() {
  group('purchaseOrderItemsFromAward', () {
    final rfqItems = [
      _rfqItem('r1', 'Nervürlü demir', costCodeId: 'cc1', budgetLineId: 'bl1', wbsNodeId: 'w1'),
      _rfqItem('r2', 'Çimento', costCodeId: 'cc2'),
    ];

    test('maliyet kodu, bütçe kalemi ve WBS RFQ kaleminden taşınır; iskontosuz fiyat aynen kalır', () {
      final items = purchaseOrderItemsFromAward(
        rfqItems: rfqItems,
        quotationItems: [_qItem('r1', 10, 1000), _qItem('r2', 1, 500)],
      );
      expect(items.map((i) => i.costCodeId), ['cc1', 'cc2']);
      expect(items.first.budgetLineId, 'bl1');
      expect(items.first.wbsNodeId, 'w1');
      expect(items.map((i) => i.unitPrice), [1000, 500]);
    });

    test('iskonto birim fiyatlara oranlı dağıtılır: sipariş ara toplamı = teklif ara toplamı − iskonto', () {
      final items = purchaseOrderItemsFromAward(
        rfqItems: rfqItems,
        quotationItems: [_qItem('r1', 10, 1000), _qItem('r2', 1, 500)],
        discount: 1050,
      );
      expect(items.map((i) => i.unitPrice), [900, 450]);
      expect(_sum(items), 9450);
    });

    test('kuruş yuvarlaması miktarı en küçük satıra yüklenir, toplam birebir tutar', () {
      // 3 x 333,33 + 1 x 100 = 1.099,99; iskonto 100 -> 999,99.
      final items = purchaseOrderItemsFromAward(
        rfqItems: rfqItems,
        quotationItems: [_qItem('r1', 3, 333.33), _qItem('r2', 1, 100)],
        discount: 100,
      );
      expect(_sum(items), 999.99);
      expect(items.every((i) => i.unitPrice > 0), isTrue);
    });

    test('iskonto ara toplamı karşılıyorsa dağıtılmaz (fiyat sıfırlanamaz)', () {
      final items = purchaseOrderItemsFromAward(
        rfqItems: rfqItems,
        quotationItems: [_qItem('r1', 1, 100)],
        discount: 100,
      );
      expect(items.single.unitPrice, 100);
    });
  });

  testWidgets('taslak siparişi düzenlemek kalemin bütçe kalemi ve WBS bağını silmez', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/organization/suppliers': [kSuppliersResponse],
      '/organization/cost-codes': [kCostCodesResponse],
      '/projects/p1': [kProjectResponse],
      '/projects/p1/purchase-orders/po1': [
        (
          status: 200,
          body: {
            'purchase_order': {'id': 'po1', 'po_no': 'PO-1', 'supplier_id': 's1', 'status': 'draft', 'tax_rate': 20},
            'items': [
              {
                'id': 'i1',
                'wbs_node_id': 'w1',
                'cost_code_id': 'cc1',
                'budget_line_id': 'bl1',
                'description': 'Nervürlü demir',
                'quantity': 2,
                'unit': 'ton',
                'unit_price': 25000,
                'line_total': 50000,
              },
            ],
            'commitments': <Object>[],
          },
        ),
        (status: 200, body: {'id': 'po1', 'po_no': 'PO-1', 'supplier_id': 's1', 'status': 'draft'}),
      ],
    });
    await pumpRoutedForm(tester, adapter, form: const PurchaseOrderFormScreen(projectId: 'p1', poId: 'po1'));

    expect(find.text('Bütçe kalemine bağlı -- bağ kayıtta korunur.'), findsOneWidget);
    await tapButton(tester, 'Kaydet');

    final item = (requestBodyFor(adapter, '/projects/p1/purchase-orders/po1')['items'] as List).single as Map;
    expect(item['budget_line_id'], 'bl1');
    expect(item['wbs_node_id'], 'w1');
    expect(item['cost_code_id'], 'cc1');
    expect(item['quantity'], 2);
    expect(item['unit_price'], 25000);
  });

  testWidgets('ödüllü tekliften sipariş: KDV oranı ve maliyet kodu taşınır, toplam önizlemesi teklifle aynı', (tester) async {
    final prefillItems = purchaseOrderItemsFromAward(
      rfqItems: [_rfqItem('r1', 'Nervürlü demir', costCodeId: 'cc1'), _rfqItem('r2', 'Çimento', costCodeId: 'cc2')],
      quotationItems: [_qItem('r1', 10, 1000), _qItem('r2', 1, 500)],
      discount: 1050,
    );
    final adapter = FakeHttpClientAdapter(script: {
      '/organization/suppliers': [kSuppliersResponse],
      '/organization/cost-codes': [kCostCodesResponse],
      '/projects/p1': [kProjectResponse],
      '/projects/p1/purchase-orders': [
        (status: 201, body: {'id': 'po9', 'po_no': 'PO-9', 'supplier_id': 's1', 'status': 'draft'}),
      ],
    });
    await pumpRoutedForm(
      tester,
      adapter,
      form: PurchaseOrderFormScreen(
        projectId: 'p1',
        prefillSupplierId: 's1',
        sourceRfqId: 'rfq1',
        sourceQuotationId: 'q1',
        prefillItems: prefillItems,
        prefillTaxRate: 10,
        prefillDiscount: 1050,
      ),
    );

    // Kazanan teklif: (10.500 − 1.050) + %10 KDV = 10.395.
    expect(find.text(Formatters.money(9450)), findsOneWidget);
    expect(find.text(Formatters.money(10395)), findsOneWidget);
    expect(find.textContaining('iskonto'), findsOneWidget);

    await tapButton(tester, 'Siparişi Oluştur');

    final body = requestBodyFor(adapter, '/projects/p1/purchase-orders');
    expect(body['tax_rate'], 10);
    expect(body['source_quotation_id'], 'q1');
    final items = (body['items'] as List).cast<Map<String, dynamic>>();
    expect(items.map((i) => i['cost_code_id']), ['cc1', 'cc2']);
    expect(items.map((i) => i['unit_price']), [900, 450]);
  });

  testWidgets('talep düzenlemesi kalemin bütçe/WBS bağını, notunu ve birim fiyatsız tahmini toplamını korur', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/organization/cost-codes': [kCostCodesResponse],
      '/projects/p1/purchase-requests/pr1': [
        (
          status: 200,
          body: {
            'purchase_request': {'id': 'pr1', 'pr_no': 'PR-1', 'title': 'Demir', 'status': 'draft'},
            'items': [
              {
                'id': 'i1',
                'wbs_node_id': 'w1',
                'cost_code_id': 'cc1',
                'budget_line_id': 'bl1',
                'description': 'Nervürlü demir',
                'quantity': 2,
                'unit': 'ton',
                'estimated_unit_cost': null,
                'estimated_total': 48000,
                'notes': 'Ø12',
              },
            ],
          },
        ),
        (status: 200, body: {'id': 'pr1', 'pr_no': 'PR-1', 'title': 'Demir', 'status': 'draft'}),
      ],
    });
    await pumpRoutedForm(tester, adapter, form: const PurchaseRequestFormScreen(projectId: 'p1', prId: 'pr1'));

    await tapButton(tester, 'Kaydet');

    final item = (requestBodyFor(adapter, '/projects/p1/purchase-requests/pr1')['items'] as List).single as Map;
    expect(item['budget_line_id'], 'bl1');
    expect(item['wbs_node_id'], 'w1');
    expect(item['notes'], 'Ø12');
    expect(item['estimated_total'], 48000);
  });
}
