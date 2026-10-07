import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/projects/domain/project.dart';

Map<String, dynamic> _base() => {
      'id': 'e1',
      'category': 'material',
      'description': 'Çimento',
      'amount': 120000,
      'currency': 'TRY',
      'expense_date': '2026-10-07',
      'created_at': '2026-10-07T08:00:00Z',
      'approval_status': 'pending',
    };

void main() {
  test('KDV alanları sunucudan okunur (backend migration 0065)', () {
    final e = Expense.fromJson({..._base(), 'vat_rate': 20, 'vat_amount': 20000, 'net_amount': 100000});
    expect(e.vatRate, 20);
    expect(e.vatAmount, 20000);
    expect(e.netAmount, 100000);
    expect(e.amount, 120000, reason: 'tutar KDV dahil ödenen tutar olarak kalır');
  });

  test('KDV belirtilmemiş (null) ve KDV yok (%0) ayrı tutulur', () {
    final unspecified = Expense.fromJson({..._base(), 'vat_rate': null, 'vat_amount': null, 'net_amount': null});
    expect(unspecified.vatRate, isNull);
    expect(unspecified.vatAmount, isNull);
    expect(unspecified.netAmount, isNull);

    final zero = Expense.fromJson({..._base(), 'vat_rate': 0, 'vat_amount': 0, 'net_amount': 120000});
    expect(zero.vatRate, 0);
    expect(zero.netAmount, 120000);
  });

  test('eski sunucu (alanlar yok): KDV bilgisi yok, diğer alanlar aynen', () {
    final e = Expense.fromJson(_base());
    expect(e.vatRate, isNull);
    expect(e.vatAmount, isNull);
    expect(e.netAmount, isNull);
    expect(e.isPending, isTrue);
    expect(e.description, 'Çimento');
  });
}
