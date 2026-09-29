import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/config/app_config.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/projects/finance_plan/data/finance_plan_repository.dart';
import 'package:arvend/features/projects/finance_plan/domain/finance_dates.dart';
import 'package:arvend/features/projects/finance_plan/domain/payment_plan.dart';
import 'package:arvend/features/projects/finance_plan/domain/project_invoice.dart';
import 'package:arvend/features/projects/finance_plan/finance_plan_routes.dart';

import '../../test_utils/fake_api_client.dart';
import 'finance_plan_test_support.dart';

Future<(ApiClient, List<String>)> _client(FakeHttpClientAdapter adapter) async {
  final requests = <String>[];
  final dio = Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl + AppConfig.apiPrefix));
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
    requests.add('${o.method} ${o.path}');
    h.next(o);
  }));
  return (ApiClient.test(dio), requests);
}

Map<String, dynamic> _itemJson({String id = 'i1', String status = 'pending', Object? percentage = 20}) => {
      'id': id,
      'sort_order': 2,
      'name': 'Peşinat',
      'percentage': percentage,
      'planned_amount': 250000,
      'collected_amount': 100000,
      'remaining_amount': 150000,
      'due_date': '2026-09-15',
      'status': status,
      'notes': 'not',
    };

Map<String, dynamic> _invoiceJson({String id = 'f1', String status = 'draft'}) => {
      'id': id,
      'invoice_no': 'ARV-1',
      'invoice_type': 'sales',
      'invoice_date': '2026-09-01',
      'due_date': '2026-10-01',
      'amount': 1000.5,
      'currency': 'TRY',
      'status': status,
      'customer_name': 'Moda',
      'notes': '',
      'created_at': '2026-09-01T08:00:00Z',
    };

void main() {
  group('PaymentPlanItem / PaymentPlan', () {
    test('reads the backend paymentPlanItemResponse fields', () {
      final i = PaymentPlanItem.fromJson(_itemJson());
      expect(i.id, 'i1');
      expect(i.sortOrder, 2);
      expect(i.percentage, 20);
      expect(i.plannedAmount, 250000);
      expect(i.collectedAmount, 100000);
      expect(i.remainingAmount, 150000);
      expect(i.dueDate, '2026-09-15');
      expect(i.status, kPlanItemPending);
      expect(i.notes, 'not');
      expect(i.isOpen, isTrue);
      expect(i.collectedPercent, 40);
    });

    test('null percentage / due date and empty strings are tolerated', () {
      final i = PaymentPlanItem.fromJson({
        'id': 'x',
        'name': 'Avans',
        'percentage': null,
        'planned_amount': 10,
        'collected_amount': 0,
        'remaining_amount': 10,
        'due_date': null,
        'status': 'cancelled',
      });
      expect(i.percentage, isNull);
      expect(i.dueDate, isNull);
      expect(i.notes, '');
      expect(i.isCancelled, isTrue);
      expect(i.isOpen, isFalse);
    });

    test('collectedPercent is clamped to 0..100 (over-collection)', () {
      const i = PaymentPlanItem(
        id: 'a',
        sortOrder: 0,
        name: 'A',
        percentage: null,
        plannedAmount: 100,
        collectedAmount: 150,
        remainingAmount: 0,
        dueDate: null,
        status: kPlanItemPaid,
      );
      expect(i.collectedPercent, 100);
    });

    test('plan totals use the server planned_total and exclude cancelled items', () {
      final plan = PaymentPlan(items: kPlanItemFixtures, plannedTotal: 1250000);
      expect(plan.plannedTotal, 1250000);
      expect(plan.activeItems.length, 4);
      expect(plan.collectedTotal, 400000);
      expect(plan.remainingTotal, 850000);
      expect(plan.collectedPercent, closeTo(32, 0.001));
      expect(plan.countByStatus(kPlanItemOverdue), 1);
      expect(plan.countByStatus(kPlanItemCancelled), 1);
    });

    test('openItemsByDueDate: overdue/earliest first, undated last, cancelled/paid excluded', () {
      final plan = PaymentPlan(
        items: [
          ...kPlanItemFixtures,
          const PaymentPlanItem(
            id: 'u',
            sortOrder: 9,
            name: 'Vadesiz',
            percentage: null,
            plannedAmount: 1,
            collectedAmount: 0,
            remainingAmount: 1,
            dueDate: null,
            status: kPlanItemPending,
          ),
        ],
        plannedTotal: 0,
      );
      expect(plan.openItemsByDueDate().map((i) => i.id), ['i2', 'i3', 'i4', 'u']);
    });

    test('PaymentPlan.fromJson reads {items, planned_total}', () {
      final plan = PaymentPlan.fromJson({
        'items': [_itemJson(), _itemJson(id: 'i2', status: 'overdue')],
        'planned_total': 500000.25,
      });
      expect(plan.items.length, 2);
      expect(plan.plannedTotal, 500000.25);
    });

    test('input: percentage omits planned_amount (backend computes it from contract_amount)', () {
      const input = PaymentPlanItemInput(name: ' Peşinat ', percentage: 20, sortOrder: 3, notes: ' x ');
      expect(input.toJson(), {
        'name': 'Peşinat',
        'percentage': 20.0,
        'due_date': null,
        'sort_order': 3,
        'notes': 'x',
      });
    });

    test('input: amount omits percentage and keeps the due date', () {
      const input = PaymentPlanItemInput(name: 'Hakediş', plannedAmount: 375000, dueDate: '2026-10-10', sortOrder: 0);
      final json = input.toJson();
      expect(json.containsKey('percentage'), isFalse);
      expect(json['planned_amount'], 375000.0);
      expect(json['due_date'], '2026-10-10');
    });

    test('status labels match the web registry', () {
      expect(planItemStatusLabel('pending'), 'Bekliyor');
      expect(planItemStatusLabel('partial'), 'Kısmi Tahsil');
      expect(planItemStatusLabel('paid'), 'Tahsil Edildi');
      expect(planItemStatusLabel('overdue'), 'Gecikti');
      expect(planItemStatusLabel('cancelled'), 'İptal');
    });
  });

  group('ProjectInvoice', () {
    test('reads the backend invoiceResponse fields', () {
      final f = ProjectInvoice.fromJson(_invoiceJson());
      expect(f.invoiceNo, 'ARV-1');
      expect(f.isSales, isTrue);
      expect(f.invoiceDate, '2026-09-01');
      expect(f.dueDate, '2026-10-01');
      expect(f.amount, 1000.5);
      expect(f.customerName, 'Moda');
      expect(f.createdAt, '2026-09-01T08:00:00Z');
    });

    test('overdue = dashboard rule: sales + issued/sent + due before today', () {
      final today = DateTime.utc(2026, 9, 29);
      ProjectInvoice inv({String type = 'sales', String status = 'issued', String? due = '2026-09-28'}) =>
          ProjectInvoice(
            id: 'x',
            invoiceNo: 'x',
            invoiceType: type,
            invoiceDate: '2026-09-01',
            dueDate: due,
            amount: 1,
            currency: 'TRY',
            status: status,
          );
      expect(inv().isOverdueOn(today), isTrue);
      expect(inv(status: 'sent').isOverdueOn(today), isTrue);
      expect(inv(status: 'draft').isOverdueOn(today), isFalse);
      expect(inv(status: 'paid').isOverdueOn(today), isFalse);
      expect(inv(status: 'cancelled').isOverdueOn(today), isFalse);
      expect(inv(type: 'purchase').isOverdueOn(today), isFalse);
      // Vade gününün kendisi henüz gecikmiş sayılmaz.
      expect(inv(due: '2026-09-29').isOverdueOn(today), isFalse);
      expect(inv(due: null).isOverdueOn(today), isFalse);
    });

    test('input always starts as draft and trims text', () {
      const input = InvoiceInput(
        invoiceNo: ' ARV-9 ',
        invoiceType: 'purchase',
        invoiceDate: '2026-09-29',
        amount: 99.9,
        currency: 'TRY',
        customerName: ' Kaya ',
      );
      expect(input.toJson(), {
        'invoice_no': 'ARV-9',
        'invoice_type': 'purchase',
        'invoice_date': '2026-09-29',
        'due_date': null,
        'amount': 99.9,
        'currency': 'TRY',
        'status': 'draft',
        'customer_name': 'Kaya',
        'notes': '',
      });
    });

    test('labels and the usual next step', () {
      expect(invoiceStatusLabel('draft'), 'Taslak');
      expect(invoiceStatusLabel('issued'), 'Kesildi');
      expect(invoiceStatusLabel('sent'), 'Gönderildi');
      expect(invoiceStatusLabel('paid'), 'Ödendi');
      expect(invoiceStatusLabel('cancelled'), 'İptal');
      expect(invoiceTypeLabel('sales'), 'Satış');
      expect(invoiceTypeLabel('purchase'), 'Alış');
    });

    test('next step is type- and overdue-aware', () {
      final today = DateTime.utc(2026, 9, 29);
      ProjectInvoice inv(String status, {String type = 'sales', String? due}) => ProjectInvoice(
            id: 'x',
            invoiceNo: 'x',
            invoiceType: type,
            invoiceDate: '2026-09-01',
            dueDate: due,
            amount: 1,
            currency: 'TRY',
            status: status,
          );
      // Satış: Taslak -> Kesildi -> Gönderildi -> Ödendi.
      expect(nextInvoiceStatus(inv('draft'), today), 'issued');
      expect(nextInvoiceStatus(inv('issued'), today), 'sent');
      expect(nextInvoiceStatus(inv('sent'), today), 'paid');
      expect(nextInvoiceStatus(inv('paid'), today), isNull);
      expect(nextInvoiceStatus(inv('cancelled'), today), isNull);
      // Alış: tedarikçinin faturası bize gelir -- "Gönderildi" adımı yok.
      expect(nextInvoiceStatus(inv('draft', type: 'purchase'), today), 'issued');
      expect(nextInvoiceStatus(inv('issued', type: 'purchase'), today), 'paid');
      // Vadesi geçmiş satış faturası: şerit "Ödendi yap" diyor, birincil
      // düğme de Ödendi.
      expect(nextInvoiceStatus(inv('issued', due: '2026-09-19'), today), 'paid');
      expect(nextInvoiceStatus(inv('sent', due: '2026-09-19'), today), 'paid');
      // Vadesi bugün olan henüz gecikmiş değil.
      expect(nextInvoiceStatus(inv('issued', due: '2026-09-29'), today), 'sent');
    });
  });

  group('dates and amounts', () {
    test('istanbulToday uses UTC+3 regardless of device zone', () {
      expect(istanbulToday(DateTime.utc(2026, 9, 28, 21, 30)), DateTime.utc(2026, 9, 29));
      expect(istanbulToday(DateTime.utc(2026, 9, 28, 20, 59)), DateTime.utc(2026, 9, 28));
    });

    test('dueHint: overdue, today, within 14 days, far away', () {
      final today = DateTime.utc(2026, 9, 29);
      expect(dueHint('2026-09-15', today)!.text, '14 gün gecikti');
      expect(dueHint('2026-09-15', today)!.tone, DueTone.overdue);
      expect(dueHint('2026-09-29', today)!.text, 'Bugün vadeli');
      expect(dueHint('2026-10-10', today)!.text, '11 gün kaldı');
      expect(dueHint('2026-12-20', today), isNull);
      expect(dueHint(null, today), isNull);
    });

    test('apiDate / parseApiDate round-trip', () {
      expect(apiDate(DateTime.utc(2026, 1, 5)), '2026-01-05');
      expect(parseApiDate('2026-01-05'), DateTime.utc(2026, 1, 5));
      expect(parseApiDate(''), isNull);
      expect(parseApiDate('bozuk'), isNull);
    });

    test('parseAmountInput accepts Turkish and plain formats', () {
      expect(parseAmountInput('250000'), 250000);
      expect(parseAmountInput('250000,50'), 250000.5);
      expect(parseAmountInput('1.250.000,50'), 1250000.5);
      expect(parseAmountInput('1,250,000.50'), 1250000.5);
      expect(parseAmountInput('1.250.000'), 1250000);
      expect(parseAmountInput('12.5'), 12.5);
      expect(parseAmountInput('12.50'), 12.5);
      // Türkçe binlik: tek nokta + üç hane = bin (bütçe/personel ile aynı).
      expect(parseAmountInput('64.000'), 64000);
      expect(parseAmountInput('1.250'), 1250);
      expect(parseAmountInput(' 20 '), 20);
      expect(parseAmountInput(''), isNull);
      expect(parseAmountInput('abc'), isNull);
      expect(parseAmountInput('-5'), isNull);
    });

    test('parsePercentInput: nokta ve virgül ondalıktır, binlik YOK (33.333 = 33333 değil)', () {
      // Regresyon: yüzde alanı tutar ayrıştırıcısıyla okunuyordu -- "33.333"
      // 33 333, "12.500" 12 500 yüzde oluyordu.
      expect(parsePercentInput('12,5'), 12.5);
      expect(parsePercentInput('12.5'), 12.5);
      expect(parsePercentInput('33,33'), 33.33);
      expect(parsePercentInput('30'), 30);
      expect(parsePercentInput('%20'), 20);
      expect(parsePercentInput('33.333'), isNull, reason: 'numeric(5,2): en çok 2 ondalık');
      expect(parsePercentInput('12.500'), isNull);
      expect(parsePercentInput('1.250'), isNull);
      expect(parsePercentInput('1000'), isNull, reason: 'numeric(5,2) üst sınırı');
      expect(parsePercentInput(''), isNull);
      expect(parsePercentInput('abc'), isNull);
    });
  });

  group('paths and descriptors', () {
    test('absolute paths live under the project detail route', () {
      expect(paymentPlanPath('p1'), '/projeler/p1/odeme-plani');
      expect(paymentPlanNewPath('p1'), '/projeler/p1/odeme-plani/yeni');
      expect(paymentPlanItemPath('p1', 'i1'), '/projeler/p1/odeme-plani/i1');
      expect(paymentPlanItemEditPath('p1', 'i1'), '/projeler/p1/odeme-plani/i1/duzenle');
      expect(invoicesPath('p1'), '/projeler/p1/faturalar');
      expect(invoiceNewPath('p1'), '/projeler/p1/faturalar/yeni');
      expect(invoicePath('p1', 'f1'), '/projeler/p1/faturalar/f1');
    });

    test('descriptors: Finans group, finance permissions, fail-open visibility like the project detail', () {
      expect(financePlanViews.map((v) => v.alt), ['odeme-plani', 'faturalar']);
      expect(financePlanViews.map((v) => v.label), ['Ödeme Planı', 'Faturalar']);
      for (final v in financePlanViews) {
        expect(v.group, 'finans');
        expect(v.readPermission, 'projects.finance.read');
        expect(v.managePermission, 'projects.finance.manage');
        expect(v.visibleFor(fpReadOnlyUser), isTrue);
        expect(v.visibleFor(fpNoAccessUser), isFalse);
        expect(v.visibleFor(null), isTrue);
      }
      expect(financePlanViews.first.routeFor('p1'), '/projeler/p1/odeme-plani');
    });
  });

  group('FinancePlanRepository HTTP contract (same calls as the web)', () {
    test('payment plan: GET list, POST create, PUT update, DELETE cancel', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/payment-plan': [
          (status: 200, body: {'items': [_itemJson()], 'planned_total': 250000}),
          (status: 201, body: _itemJson(id: 'n1')),
        ],
        '/projects/p1/payment-plan/i1': [
          (status: 200, body: _itemJson()),
          (status: 200, body: {'ok': true}),
        ],
      });
      final (client, requests) = await _client(adapter);
      final repo = FinancePlanRepository(client);

      final plan = await repo.paymentPlan('p1');
      expect(plan.items.single.id, 'i1');
      expect(plan.plannedTotal, 250000);

      final created = await repo.createPlanItem(
        'p1',
        const PaymentPlanItemInput(name: 'Peşinat', percentage: 20, sortOrder: 1),
      );
      expect(created.id, 'n1');
      await repo.updatePlanItem(
        'p1',
        'i1',
        const PaymentPlanItemInput(name: 'Peşinat', plannedAmount: 300000, sortOrder: 2),
      );
      await repo.cancelPlanItem('p1', 'i1');

      expect(requests, [
        'GET /projects/p1/payment-plan',
        'POST /projects/p1/payment-plan',
        'PUT /projects/p1/payment-plan/i1',
        'DELETE /projects/p1/payment-plan/i1',
      ]);
      expect(adapter.requestBodies[1], {
        'name': 'Peşinat',
        'percentage': 20.0,
        'due_date': null,
        'sort_order': 1,
        'notes': '',
      });
      expect((adapter.requestBodies[2] as Map)['planned_amount'], 300000.0);
      expect((adapter.requestBodies[2] as Map)['sort_order'], 2);
    });

    test('invoices: GET list, POST create (draft), PUT status', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/invoices': [
          (status: 200, body: {'invoices': [_invoiceJson(), _invoiceJson(id: 'f2', status: 'paid')]}),
          (status: 201, body: _invoiceJson(id: 'f3')),
        ],
        '/projects/p1/invoices/f1/status': [(status: 200, body: _invoiceJson(status: 'issued'))],
      });
      final (client, requests) = await _client(adapter);
      final repo = FinancePlanRepository(client);

      final list = await repo.invoices('p1');
      expect(list.map((f) => f.id), ['f1', 'f2']);
      await repo.createInvoice(
        'p1',
        const InvoiceInput(
          invoiceNo: 'ARV-3',
          invoiceType: 'sales',
          invoiceDate: '2026-09-29',
          amount: 10,
          currency: 'TRY',
        ),
      );
      final updated = await repo.updateInvoiceStatus('p1', 'f1', 'issued');
      expect(updated.status, 'issued');

      expect(requests, [
        'GET /projects/p1/invoices',
        'POST /projects/p1/invoices',
        'PUT /projects/p1/invoices/f1/status',
      ]);
      expect((adapter.requestBodies[1] as Map)['status'], 'draft');
      expect(adapter.requestBodies[2], {'status': 'issued'});
    });

    test('409 (locked project) surfaces as a conflict ApiException with the backend message', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/payment-plan': [
          (status: 409, body: {'error': 'tamamlanmış veya iptal edilmiş projede yeni finans hareketi oluşturulamaz'}),
        ],
      });
      final (client, _) = await _client(adapter);
      final repo = FinancePlanRepository(client);
      await expectLater(
        repo.createPlanItem('p1', const PaymentPlanItemInput(name: 'A', plannedAmount: 1, sortOrder: 0)),
        throwsA(isA<ApiException>()
            .having((e) => e.kind, 'kind', ApiErrorKind.conflict)
            .having((e) => e.message, 'message', contains('yeni finans hareketi'))),
      );
    });
  });
}
