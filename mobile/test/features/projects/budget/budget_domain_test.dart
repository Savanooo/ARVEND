import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/projects/budget/domain/budget.dart';

import 'budget_test_support.dart';

void main() {
  group('parseTrDecimal (Türkçe ondalık giriş)', () {
    double? v(String s, {int digits = 2, bool neg = false}) =>
        parseTrDecimal(s, maxFractionDigits: digits, allowNegative: neg).value;
    String? err(String s, {int digits = 2, bool neg = false}) =>
        parseTrDecimal(s, maxFractionDigits: digits, allowNegative: neg).error;

    test('ondalık virgül ve binlik noktası', () {
      expect(v('1.234.567,89'), 1234567.89);
      expect(v('1234,5'), 1234.5);
      expect(v('1.250'), 1250);
      expect(v('1.250.000'), 1250000);
      expect(v('0,75'), 0.75);
      expect(v(' 12 500 '), 12500);
    });

    test('virgülsüz noktalı yazım: üçlü grup değilse ondalık nokta', () {
      expect(v('1234.5'), 1234.5);
      expect(v('12.50'), 12.5);
    });

    test('boş girdi değer de hata da değildir', () {
      final r = parseTrDecimal('   ');
      expect(r.value, isNull);
      expect(r.error, isNull);
    });

    test('geçersiz biçimler reddedilir', () {
      expect(err('1,2,3'), isNotNull);
      expect(err('abc'), isNotNull);
      expect(err('12,'), isNotNull);
      expect(err('1.2.3'), isNotNull);
    });

    test('ondalık basamak sınırı', () {
      expect(err('10,123'), contains('2 ondalık'));
      expect(v('10,1234', digits: 4), 10.1234);
      expect(err('1234.567'), isNotNull);
    });

    test('negatif yalnızca izin verilirse (U+2212 eksi dahil)', () {
      expect(err('-500'), 'Negatif değer girilemez.');
      expect(v('-25.000', neg: true), -25000);
      expect(v('−25.000,5', neg: true), -25000.5);
    });

    test('üst sınır', () {
      expect(err('1.000.000.000.000'), isNotNull);
      expect(v('999999999999,99'), 999999999999.99);
    });
  });

  test('formatTrDecimalInput: gruplamasız, ondalık virgül, gereksiz sıfırlar atılır', () {
    expect(formatTrDecimalInput(1250000.5), '1250000,5');
    expect(formatTrDecimalInput(12), '12');
    expect(formatTrDecimalInput(0.75), '0,75');
    expect(formatTrDecimalInput(12.3456, maxFractionDigits: 4), '12,3456');
    expect(formatTrDecimalInput(null), '');
    // Gidiş-dönüş.
    expect(parseTrDecimal(formatTrDecimalInput(987654.32)).value, 987654.32);
  });

  group('flattenWbsTree', () {
    test('web ile aynı sıra: kökler ve kardeşler sort_order, sonra kod; derinlik doğru', () {
      final tree = flattenWbsTree([...kWbsNodes.reversed]);
      expect(tree.map((e) => e.node.code), ['01', '01.01', '01.02', '02', '02.01', '02.02', '03']);
      expect(tree.map((e) => e.depth), [0, 1, 1, 0, 1, 1, 0]);
    });

    test('üstü listede olmayan düğüm kaybolmaz, kök sayılır', () {
      final tree = flattenWbsTree(const [
        WbsNode(id: 'a', code: 'A', name: 'A'),
        WbsNode(id: 'x', parentId: 'missing', code: 'X', name: 'Yetim'),
      ]);
      expect(tree.map((e) => (e.node.id, e.depth)), [('a', 0), ('x', 0)]);
    });

    test('döngü sonsuz döngüye girmez, her düğüm bir kez yazılır', () {
      final tree = flattenWbsTree(const [
        WbsNode(id: 'a', parentId: 'b', code: 'A', name: 'A'),
        WbsNode(id: 'b', parentId: 'a', code: 'B', name: 'B'),
      ]);
      expect(tree.length, 2);
      expect(tree.map((e) => e.node.id).toSet(), {'a', 'b'});
    });
  });

  group('fromJson (backend yanıt şekilleri)', () {
    test('WbsNode', () {
      final n = WbsNode.fromJson({
        'id': 'w1',
        'parent_id': 'w0',
        'code': '01',
        'name': 'Kaba',
        'sort_order': 3,
        'is_active': false,
      });
      expect((n.id, n.parentId, n.code, n.name, n.sortOrder, n.isActive), ('w1', 'w0', '01', 'Kaba', 3, false));
    });

    test('ProjectBudget', () {
      final b = ProjectBudget.fromJson({
        'id': 'b1',
        'currency': 'TRY',
        'status': 'baselined',
        'version': 1,
        'baselined_at': '2026-09-01T09:30:00Z',
      });
      expect(b.isBaselined, isTrue);
      expect(b.isDraft, isFalse);
      expect(b.baselinedAt, '2026-09-01T09:30:00Z');
    });

    test('BudgetLine: opsiyonel miktar/birim fiyat null kalır', () {
      final l = BudgetLine.fromJson({
        'id': 'l1',
        'cost_code_id': 'cc1',
        'cost_code_code': 'MLZ-001',
        'cost_code_name': 'Hazır Beton',
        'description': 'Temel',
        'original_amount': 987000,
      });
      expect(l.quantity, isNull);
      expect(l.unitCost, isNull);
      expect(l.wbsNodeId, isNull);
      expect(l.originalAmount, 987000);
      expect(l.costCodeLabel, 'MLZ-001 — Hazır Beton');
    });

    test('BudgetAdjustment / CostForecast / ActualExpense', () {
      final a = BudgetAdjustment.fromJson({
        'id': 'a1',
        'budget_line_id': 'l1',
        'amount': -60000,
        'reason': 'r',
        'status': 'draft',
        'created_at': '2026-09-05T11:20:00Z',
      });
      expect(a.isPending, isTrue);
      expect(a.amount, -60000);

      final f = CostForecast.fromJson({'budget_line_id': 'l1', 'etc_amount': 40000, 'note': 'n', 'updated_at': 'x'});
      expect((f.budgetLineId, f.etcAmount, f.note), ('l1', 40000.0, 'n'));

      final e = ActualExpense.fromJson({
        'id': 'e1',
        'description': 'd',
        'amount': 10,
        'currency': 'TRY',
        'expense_date': '2026-09-01',
        'voided_at': '2026-09-02T00:00:00Z',
      });
      expect(e.isVoided, isTrue);
      expect(e.costCodeId, isNull);
    });
  });

  group('istek gövdeleri (web ile aynı alanlar)', () {
    test('WbsNodeInput: kökte parent_id boş metin', () {
      expect(const WbsNodeInput(code: '01', name: 'Kaba').toJson(), {
        'parent_id': '',
        'code': '01',
        'name': 'Kaba',
        'sort_order': 0,
      });
      expect(
        const WbsNodeInput(parentId: 'w1', code: '01.01', name: 'Temel', sortOrder: 2).toJson()['parent_id'],
        'w1',
      );
    });

    test('BudgetLineInput: miktar/birim fiyat null gönderilebilir, notlar taşınır', () {
      final json = const BudgetLineInput(
        costCodeId: 'cc1',
        description: 'Temel',
        originalAmount: 1000,
        notes: 'not',
      ).toJson();
      expect(json, {
        'wbs_node_id': '',
        'cost_code_id': 'cc1',
        'description': 'Temel',
        'quantity': null,
        'unit': '',
        'unit_cost': null,
        'original_amount': 1000.0,
        'notes': 'not',
      });
      expect(
        const BudgetLineInput(costCodeId: 'c', description: 'd', quantity: 2, unitCost: 3).amountComputedByServer,
        isTrue,
      );
    });

    test('ManualCommitmentInput', () {
      expect(
        const ManualCommitmentInput(
          costCodeId: 'cc1',
          description: 'd',
          amount: 1500.75,
          committedAt: '2026-09-29',
          idempotencyKey: 'k',
        ).toJson(),
        {
          'cost_code_id': 'cc1',
          'budget_line_id': '',
          'description': 'd',
          'committed_amount': 1500.75,
          'committed_at': '2026-09-29',
          'idempotency_key': 'k',
        },
      );
    });
  });

  test('canVoidCommitmentHere: yalnızca aktif MANUEL taahhüt', () {
    final byId = {for (final c in kCommitments) c.id: c};
    expect(canVoidCommitmentHere(byId['c1']!), isTrue); // manuel, aktif
    expect(canVoidCommitmentHere(byId['c3']!), isFalse); // satın alma siparişi
    expect(canVoidCommitmentHere(byId['c4']!), isFalse); // taşeron
    expect(canVoidCommitmentHere(byId['c7']!), isFalse); // zaten iptal
  });

  test('fikstürler backend formülleriyle tutarlı (revize/EAC/varyans)', () {
    final cc = costControlFixture();
    expect(cc.summary.revisedBudget, 12059500);
    expect(cc.summary.eac, 12348500);
    expect(cc.summary.variance, -289000);
    expect(overBudgetLines(cc.lines).map((l) => l.costCodeCode), ['MLZ-002', 'EKP-001', 'MLZ-004']);
    expect(isoDate(DateTime(2026, 9, 3)), '2026-09-03');
  });
}
