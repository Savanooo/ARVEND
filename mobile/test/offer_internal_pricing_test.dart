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


