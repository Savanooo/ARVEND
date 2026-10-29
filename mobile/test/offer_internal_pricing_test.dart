import 'package:flutter_test/flutter_test.dart';
import 'package:arvend/features/offers/domain/offer.dart';

void main() {
  group('OfferItem internal pricing', () {
    test('fromJson reads nested internal_pricing only', () {
      final item = OfferItem.fromJson({
        'id': '1',
        'product_name': 'Çatı',
        'quantity': 1,
        'unit_price': 91000,
        'line_total': 91000,
        'unit': 'm2',
        'internal_pricing': {
          'cost': 70000,
          'pricing_mode': 'markup',
          'markup_percent': 30,
          'expected_profit': 21000,
          'effective_markup_percent': 30,
        },
      });
      expect(item.internalSubcontractCost, 70000);
      expect(item.pricingMode, OfferItem.pricingModeMarkup);
      expect(item.markupPercent, 30);
      expect(item.expectedProfit, 21000);
      expect(item.hasInternalPricing, isTrue);
    });

    test('toJson omits internal fields without flag', () {
      final item = OfferItem(
        id: '',
        productId: null,
        productName: 'X',
        quantity: 1,
        unitPrice: 100,
        lineTotal: 100,
        unit: 'ad',
        sectionLabel: null,
        calcCategoryId: null,
        calcSnapshot: null,
        internalSubcontractCost: 70,
        pricingMode: OfferItem.pricingModeManual,
      );
      final json = item.toJson();
      expect(json.containsKey('internal_subcontract_cost'), isFalse);
      final withInternal = item.toJson(includeInternalPricing: true);
      expect(withInternal['internal_subcontract_cost'], 70);
      expect(withInternal['pricing_mode'], 'manual');
    });

    test('previewMarkupUnitPrice is display-only math', () {
      expect(previewMarkupUnitPrice(70000, 30), 91000);
    });

    // Sunucu (shopspring decimal): önce 2 haneye, sonra çarpım, yarımda
    // sıfırdan uzağa. Kayan nokta 1,15 × 1,5'i 1,7249999… bulup 1,72'ye
    // yuvarlıyordu; sunucu 1,73 yazar.
    test('markup price and line total round exactly like the server', () {
      expect(previewMarkupUnitPrice(1.15, 50), 1.73);
      expect(previewMarkupUnitPrice(10.05, 10), 11.06);
      expect(previewMarkupUnitPrice(1000, -100), 0);
      expect(previewMarkupUnitPrice(1000, -12.5), 875);
      expect(previewMarkupUnitPrice(-1, 10), isNull);
      expect(offerLineTotal(1.15, 1.5), 1.73);
      expect(offerLineTotal(0.5, 0.05), 0.03);
      expect(offerLineTotal(9999999.99, 999.99), 9999899990, reason: 'büyük çarpım 64 biti aşmaz');
    });

    test('offerItemProfit: per unit, percent on cost, line; loss is negative', () {
      final p = offerItemProfit(unitPrice: 1150, unitCost: 1000, quantity: 10);
      expect(p.unitProfit, 150);
      expect(p.percent, 15);
      expect(p.lineProfit, 1500);

      final loss = offerItemProfit(unitPrice: 900, unitCost: 1000, quantity: 2);
      expect(loss.unitProfit, -100);
      expect(loss.percent, -10);
      expect(loss.lineProfit, -200);

      // backend EffectiveMarkupPercent: maliyet 0 ise oran yok.
      expect(offerItemProfit(unitPrice: 50, unitCost: 0).percent, isNull);
      expect(offerItemProfit(unitPrice: 50, unitCost: 0).lineProfit, isNull, reason: 'miktar yok');
      expect(offerItemProfit(unitPrice: 1.73, unitCost: 1.15).percent, 50.43);
    });
  });

  group('Offer editability', () {
    Offer base({required String status}) => Offer(
          id: 'o1',
          offerNo: 'T-1',
          revisionNo: 1,
          customerId: null,
          customerName: 'A',
          customerPhone: '',
          customerEmail: '',
          customerAddress: '',
          offerDate: '2026-01-01',
          validUntil: null,
          subtotal: 0,
          vatRate: 20,
          vatAmount: 0,
          grandTotal: 0,
          notes: '',
          status: status,
          isPassive: false,
          items: const [],
        );

    test('only taslak is editable', () {
      expect(base(status: Offer.statusTaslak).isEditable, isTrue);
      expect(base(status: Offer.statusGonderildi).isEditable, isFalse);
      expect(base(status: Offer.statusKabulEdildi).isEditable, isFalse);
    });

    test('revise allowed for gönderildi/reddedildi', () {
      expect(base(status: Offer.statusGonderildi).canRevise, isTrue);
      expect(base(status: Offer.statusReddedildi).canRevise, isTrue);
      expect(base(status: Offer.statusTaslak).canRevise, isFalse);
      expect(base(status: Offer.statusKabulEdildi).canRevise, isFalse);
    });
  });
}


