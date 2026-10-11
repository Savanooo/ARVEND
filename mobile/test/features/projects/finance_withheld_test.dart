import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/utils/formatters.dart' show kNbsp;
import 'package:arvend/features/customers/domain/customer.dart';
import 'package:arvend/features/projects/activity/domain/project_event.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/domain/project_edit.dart';
import 'package:arvend/features/projects/presentation/project_list_card.dart';

/// `projects.finance.read` izni olmayana sunucu proje para alanlarını HİÇ
/// göndermez (backend/docs/authorization.md §11): proje yanıtında
/// contract_amount null, liste aggregate'leri yok; olay metadata'sında tutar
/// anahtarları yok; maliyet kontrolü özetinde sözleşme bedeli / tahmini kâr /
/// marj null. Modeller bunlarla çökmemeli ve tutarı 0 diye UYDURMAMALI.
Map<String, dynamic> _withheldProjectJson() => {
      'id': 'p1',
      'project_no': 'PRJ-001',
      'name': 'Merkez Ofis İnşaatı',
      'project_type': 'Konut',
      'customer_id': 'c1',
      'customer_name': 'Ali Veli',
      'customer_phone': '',
      'customer_email': '',
      'customer_address': '',
      'contract_amount': null,
      'currency': 'TRY',
      'status': 'active',
      'start_date': null,
      'end_date': null,
      'description': '',
      'internal_notes': '',
      'source_offer_id': 'o1',
      'source_offer_no': 'TKF-001',
      'source_revision_no': 2,
      'created_at': '2026-09-01T00:00:00Z',
      'updated_at': '2026-09-01T00:00:00Z',
    };

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  group('Project', () {
    test('contract_amount null ve aggregate yok: çökmez, tutarlar null kalır', () {
      final p = Project.fromJson(_withheldProjectJson());
      expect(p.name, 'Merkez Ofis İnşaatı');
      expect(p.contractAmount, isNull);
      expect(p.currentContractValue, isNull);
      expect(p.collectedAmount, isNull);
      expect(p.remainingReceivable, isNull);
    });

    test('contract_amount anahtarı hiç yoksa da null', () {
      final json = _withheldProjectJson()..remove('contract_amount');
      expect(Project.fromJson(json).contractAmount, isNull);
    });

    test('finans izinliye gelen değer olduğu gibi okunur', () {
      final json = {
        ..._withheldProjectJson(),
        'contract_amount': 125000,
        'current_contract_value': 140000.5,
        'collected_amount': 0,
        'remaining_receivable': 140000.5,
      };
      final p = Project.fromJson(json);
      expect(p.contractAmount, 125000);
      expect(p.currentContractValue, 140000.5);
      expect(p.collectedAmount, 0);
    });

    test('müşteri finansal özeti tutarı gelmeyen projeyi 0 diye toplamaz', () {
      expect(summarizeProjectReceivables([Project.fromJson(_withheldProjectJson())]), isEmpty);
    });
  });

  test('ProjectEditable: contract_amount null -> null (0 değil)', () {
    final p = ProjectEditable.fromJson(_withheldProjectJson());
    expect(p.contractAmount, isNull);
    expect(p.sourceOfferNo, 'TKF-001');
  });

  group('CostControlSummary', () {
    Map<String, dynamic> summary({num? contractValue, num? profit, num? margin}) => {
          'currency': 'TRY',
          'contract_value': contractValue,
          'original_budget': 80000,
          'approved_adjustments': 0,
          'revised_budget': 80000,
          'committed_cost': 10000,
          'actual_cost': 5000,
          'etc': 70000,
          'eac': 75000,
          'variance': -5000,
          'forecast_profit': profit,
          'forecast_margin_percent': margin,
          'has_budget': true,
        };

    test('gelir alanları null: hasRevenue false, maliyet rakamları okunur', () {
      final s = CostControlSummary.fromJson(summary());
      expect(s.hasRevenue, isFalse);
      expect(s.eac, 75000);
      expect(s.revisedBudget, 80000);
    });

    test('gelir alanları doluysa hasRevenue true', () {
      final s = CostControlSummary.fromJson(summary(contractValue: 100000, profit: 25000, margin: 25));
      expect(s.hasRevenue, isTrue);
      expect(s.contractValue, 100000);
      expect(s.forecastProfit, 25000);
    });
  });

  group('ProjectEvent', () {
    test('tutarı düşürülmüş olay: ayrıntı tutarsız yazılır, showMoney true olsa da 0 yok', () {
      final e = ProjectEvent.fromJson({
        'id': 'ev1',
        'event_type': 'collection_received',
        'user_id': null,
        'metadata': {'collection_id': 'c1'},
        'created_at': '2026-09-29T08:00:00Z',
      });
      expect(projectEventLabel(e.eventType), 'Tahsilat kaydedildi');
      expect(projectEventDetail(e, currency: 'TRY', showMoney: true), '');
    });

    test('ek iş olayı: başlık kalır, grand_total yok', () {
      final e = ProjectEvent.fromJson({
        'id': 'ev2',
        'event_type': 'change_order_approved',
        'metadata': {'title': 'Cam bölme'},
        'created_at': '2026-09-29T08:00:00Z',
      });
      expect(projectEventDetail(e, currency: 'TRY', showMoney: true), 'Cam bölme');
    });

    test('metadata null ya da yok: çökmez', () {
      final e = ProjectEvent.fromJson({'id': 'ev3', 'event_type': 'project_created', 'metadata': null});
      expect(e.metadata, isEmpty);
      expect(projectEventDetail(e, currency: 'TRY', showMoney: true), '');
    });

    test('tutar gelirse (finans izni) eskisi gibi yazılır', () {
      final e = ProjectEvent.fromJson({
        'id': 'ev4',
        'event_type': 'collection_received',
        'metadata': {'amount': 1500},
        'created_at': '2026-09-29T08:00:00Z',
      });
      expect(projectEventDetail(e, currency: 'TRY', showMoney: true), '1.500,00${kNbsp}TL');
    });
  });

  testWidgets('ProjectListCard: tutar null ise showFinance true olsa da tutar/tahsilat çizilmez', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProjectListCard(
          project: Project.fromJson(_withheldProjectJson()),
          onTap: () {},
          showFinance: true,
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('Merkez Ofis İnşaatı'), findsOneWidget);
    expect(find.textContaining('TL'), findsNothing);
    expect(find.textContaining('Tahsilat'), findsNothing);
  });
}
