import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/projects/contract_co/contract_co_routes.dart';
import 'package:arvend/features/projects/contract_co/data/contract_co_repository.dart';
import 'package:arvend/features/projects/contract_co/domain/project_change_order.dart';
import 'package:arvend/features/projects/contract_co/domain/project_contract.dart';
import 'package:arvend/features/projects/contract_co/presentation/change_order_form_screen.dart';

import '../../test_utils/fake_api_client.dart';

/// Depo sözleşmesi: yollar, gövdeler ve yanıt eşlemesi backend router.go /
/// handler'larıyla birebir (gerçek ağ YOK, `FakeHttpClientAdapter`).
void main() {
  const contractJson = {
    'id': 'k1',
    'currency': 'TRY',
    'status': 'draft',
    'scope': 'Kaba inşaat',
    'payment_terms': '30 gün',
    'retention_terms': '',
    'advance_terms': '%20',
    'effective_date': '2026-09-01',
    'internal_notes': 'not',
    'created_at': '2026-09-01T07:30:00Z',
    'updated_at': '2026-09-01T07:30:00Z',
  };

  const coJson = {
    'id': 'co1',
    'project_id': 'p1',
    'sequence_no': 3,
    'change_order_no': 'EK-003',
    'change_type': 'deduction',
    'title': 'Seramik iptali',
    'description': '',
    'status': 'sent',
    'subtotal': 25000,
    'vat_rate': 20,
    'vat_amount': 5000,
    'grand_total': 30000,
    'currency': 'TRY',
    'internal_notes': '',
    'customer_notes': '',
    'created_by': 'u1',
    'created_at': '2026-09-15T08:00:00Z',
    'updated_at': '2026-09-15T08:00:00Z',
    'sent_at': '2026-09-15T11:40:00Z',
    'responded_at': null,
    'approved_at': null,
    'rejected_at': null,
    'cancelled_at': null,
    'supersedes_change_order_id': null,
    'active_share_token': 'tok-1',
    'items': [
      {
        'id': 'i1',
        'product_id': 'prod-1',
        'description': 'Seramik',
        'quantity': 50,
        'unit': 'm²',
        'unit_price': 500,
        'line_total': 25000,
        'sort_order': 0,
        'estimated_unit_cost': 320,
        'estimated_cost': 16000,
      },
    ],
  };

  Future<(ContractCoRepository, FakeHttpClientAdapter)> build(Map<String, List<ScriptedResponse>> script) async {
    final adapter = FakeHttpClientAdapter(script: script);
    return (ContractCoRepository(await buildFakeApiClient(adapter)), adapter);
  }

  group('sözleşme', () {
    test('GET 404 -> null (Sözleşme Oluştur durumu)', () async {
      final (repo, _) = await build({
        '/projects/p1/contract': [(status: 404, body: {'error': 'bu proje için henüz bir sözleşme oluşturulmamış'})],
      });
      expect(await repo.contract('p1'), isNull);
    });

    test('GET 403 fırlatılır (null DEĞİL)', () async {
      final (repo, _) = await build({
        '/projects/p1/contract': [(status: 403, body: {'error': 'yetki yok'})],
      });
      expect(
        () => repo.contract('p1'),
        throwsA(isA<ApiException>().having((e) => e.isForbidden, 'forbidden', isTrue)),
      );
    });

    test('GET eşlemesi', () async {
      final (repo, _) = await build({
        '/projects/p1/contract': [(status: 200, body: contractJson)],
      });
      final c = (await repo.contract('p1'))!;
      expect(c.isDraft, isTrue);
      expect(c.scope, 'Kaba inşaat');
      expect(c.effectiveDate, '2026-09-01');
      expect(c.plannedCompletionDate, isNull);
      expect(c.termsEditable, isTrue);
      expect(c.notesEditable, isTrue);
      expect(c.canActivate && c.canCancel, isTrue);
      expect(c.canComplete || c.canTerminate, isFalse);
    });

    test('taslak PUT gövdesi: boş tarih null gider', () async {
      final (repo, adapter) = await build({
        '/projects/p1/contract': [(status: 200, body: contractJson)],
      });
      await repo.updateContractDraft(
        'p1',
        const ContractDraftInput(
          scope: 'a',
          paymentTerms: 'b',
          retentionTerms: 'c',
          advanceTerms: 'd',
          effectiveDate: '',
          plannedCompletionDate: '2026-12-01',
        ),
      );
      expect(adapter.requestBodies.single, {
        'scope': 'a',
        'payment_terms': 'b',
        'retention_terms': 'c',
        'advance_terms': 'd',
        'effective_date': null,
        'planned_completion_date': '2026-12-01',
      });
    });

    test('not, yaşam döngüsü ve gerekçe gövdeleri', () async {
      final (repo, adapter) = await build({
        '/projects/p1/contract': [(status: 201, body: contractJson)],
        '/projects/p1/contract/notes': [(status: 200, body: contractJson)],
        '/projects/p1/contract/activate': [(status: 200, body: {...contractJson, 'status': 'active'})],
        '/projects/p1/contract/complete': [(status: 200, body: {...contractJson, 'status': 'completed'})],
        '/projects/p1/contract/cancel': [(status: 200, body: {...contractJson, 'status': 'cancelled', 'cancel_reason': 'x'})],
        '/projects/p1/contract/terminate': [
          (status: 200, body: {...contractJson, 'status': 'terminated', 'termination_reason': 'y'}),
        ],
      });
      await repo.createContract('p1');
      await repo.updateContractNotes('p1', 'yeni not');
      expect((await repo.activateContract('p1')).isActive, isTrue);
      expect((await repo.completeContract('p1')).status, ProjectContract.statusCompleted);
      final cancelled = await repo.cancelContract('p1', reason: 'x');
      expect(cancelled.statusExplanation, 'İptal edildi — x.');
      final terminated = await repo.terminateContract('p1', reason: 'y');
      expect(terminated.statusExplanation, 'Feshedildi — y.');
      expect(adapter.calls, [
        '/projects/p1/contract',
        '/projects/p1/contract/notes',
        '/projects/p1/contract/activate',
        '/projects/p1/contract/complete',
        '/projects/p1/contract/cancel',
        '/projects/p1/contract/terminate',
      ]);
      expect(adapter.requestBodies[1], {'internal_notes': 'yeni not'});
      expect(adapter.requestBodies[4], {'reason': 'x'});
      expect(adapter.requestBodies[5], {'reason': 'y'});
    });

    test('409 sunucu mesajıyla fırlatılır', () async {
      final (repo, _) = await build({
        '/projects/p1/contract/activate': [
          (status: 409, body: {'error': 'yalnızca taslak durumundaki bir sözleşme aktive edilebilir'}),
        ],
      });
      expect(
        () => repo.activateContract('p1'),
        throwsA(isA<ApiException>()
            .having((e) => e.kind, 'kind', ApiErrorKind.conflict)
            .having((e) => e.message, 'message', 'yalnızca taslak durumundaki bir sözleşme aktive edilebilir')),
      );
    });
  });

  group('ek işler', () {
    test('liste + detay eşlemesi', () async {
      final (repo, _) = await build({
        '/projects/p1/change-orders': [
          (
            status: 200,
            body: {
              'change_orders': [
                {
                  ...coJson,
                  'items': null,
                  'profitability': {
                    'revenue_effect': -30000,
                    'realized_cost': 0,
                    'committed_cost': 0,
                    'realized_profit': -30000,
                    'estimated_profit': -30000,
                    'realized_margin_percent': -100,
                    'estimated_margin_percent': -100,
                  },
                },
              ],
            },
          ),
        ],
        '/projects/p1/change-orders/co1': [(status: 200, body: coJson)],
      });
      final list = await repo.changeOrders('p1');
      expect(list.single.items, isEmpty);
      expect(list.single.profitability!.revenueEffect, -30000);
      final co = await repo.changeOrder('p1', 'co1');
      expect(co.changeOrderNo, 'EK-003');
      expect(co.isAddition, isFalse);
      expect(co.signedTotal, -30000);
      expect(co.typeLabel, 'Eksiltme');
      expect(co.hasShareLink, isTrue);
      expect(co.canEmail && co.canRevise && co.canCancel, isTrue);
      expect(co.canSend || co.isEditable, isFalse);
      expect(co.items.single.estimatedUnitCost, 320);
      expect(co.items.single.productId, 'prod-1');
      expect(co.withProfitability(list.single.profitability).profitability, isNotNull);
    });

    test('oluştur/düzenle gövdesi backend changeOrderRequest ile aynı', () async {
      final (repo, adapter) = await build({
        '/projects/p1/change-orders': [(status: 201, body: coJson)],
        '/projects/p1/change-orders/co1': [(status: 200, body: coJson)],
      });
      const input = ChangeOrderInput(
        changeType: 'addition',
        title: 'Başlık',
        description: 'Açıklama',
        vatRate: 20,
        customerNotes: 'm',
        internalNotes: 'd',
        items: [
          ChangeOrderItemInput(description: 'A', quantity: 2, unit: 'adet', unitPrice: 10),
          ChangeOrderItemInput(
            description: 'B',
            quantity: 1.5,
            unit: 'm',
            unitPrice: 4,
            productId: 'prod-1',
            estimatedUnitCost: 3,
          ),
        ],
      );
      await repo.createChangeOrder('p1', input);
      await repo.updateChangeOrder('p1', 'co1', input);
      final body = adapter.requestBodies.first as Map<String, dynamic>;
      expect(body, {
        'change_type': 'addition',
        'title': 'Başlık',
        'description': 'Açıklama',
        'vat_rate': 20.0,
        'customer_notes': 'm',
        'internal_notes': 'd',
        'items': [
          {'product_id': null, 'description': 'A', 'quantity': 2.0, 'unit': 'adet', 'unit_price': 10.0},
          {
            'product_id': 'prod-1',
            'description': 'B',
            'quantity': 1.5,
            'unit': 'm',
            'unit_price': 4.0,
            'estimated_unit_cost': 3.0,
          },
        ],
      });
      expect(adapter.requestBodies[1], body);
    });

    test('gönder / e-posta / revize / iptal yolları', () async {
      final (repo, adapter) = await build({
        '/projects/p1/change-orders/co1/send': [(status: 200, body: coJson)],
        '/projects/p1/change-orders/co1/send-email': [(status: 200, body: {'status': 'sent'})],
        '/projects/p1/change-orders/co1/revise': [(status: 200, body: {...coJson, 'id': 'co2', 'status': 'draft'})],
        '/projects/p1/change-orders/co1/cancel': [(status: 200, body: {...coJson, 'status': 'cancelled'})],
      });
      await repo.sendChangeOrder('p1', 'co1');
      await repo.sendChangeOrderEmail('p1', 'co1', const ChangeOrderEmailInput(to: 'a@b.com', subject: 'S'));
      final revised = await repo.reviseChangeOrder('p1', 'co1');
      final cancelled = await repo.cancelChangeOrder('p1', 'co1');
      expect(revised.id, 'co2');
      expect(revised.isEditable, isTrue);
      expect(cancelled.canCancel, isFalse);
      expect(adapter.requestBodies[1], {'to': 'a@b.com', 'subject': 'S', 'message': ''});
      // İptal gerekçe ALMAZ (backend CancelChangeOrder gövdesiz).
      expect(adapter.requestBodies[3], isNull);
    });

    test('müşteri kararını kaydet: yol, gövde ve kaydeden bilgisi', () async {
      final (repo, adapter) = await build({
        '/projects/p1/change-orders/co1/record-decision': [
          (
            status: 200,
            body: {
              ...coJson,
              'status': 'approved',
              'approved_at': '2026-09-16T09:00:00Z',
              'responded_at': '2026-09-16T09:00:00Z',
              'decision_recorded_by': 'u7',
              'decision_recorded_by_name': 'Ayşe Yönetici',
              'decision_note': 'telefonla onay',
            },
          ),
          (status: 409, body: {'error': 'bu ek iş için onay/red işlemi yapılamaz'}),
        ],
      });
      final approved = await repo.recordChangeOrderDecision('p1', 'co1', approved: true, note: '  telefonla onay ');
      expect(adapter.requestBodies.single, {'decision': 'approved', 'note': 'telefonla onay'});
      expect(approved.status, ProjectChangeOrder.statusApproved);
      expect(approved.decisionRecordedByStaff, isTrue);
      expect(approved.decisionRecordedByName, 'Ayşe Yönetici');
      expect(approved.decisionNote, 'telefonla onay');
      expect(approved.canRecordDecision, isFalse);
      // Liste ucundan gelen kârlılık eklense de karar bilgisi korunur.
      const profit = ChangeOrderProfitability(
        revenueEffect: 0,
        realizedCost: 0,
        committedCost: 0,
        realizedProfit: 0,
        estimatedProfit: 0,
        realizedMarginPercent: 0,
        estimatedMarginPercent: 0,
      );
      expect(approved.withProfitability(profit).decisionNote, 'telefonla onay');

      await expectLater(
        repo.recordChangeOrderDecision('p1', 'co1', approved: false),
        throwsA(isA<ApiException>()
            .having((e) => e.kind, 'kind', ApiErrorKind.conflict)
            .having((e) => e.message, 'message', 'bu ek iş için onay/red işlemi yapılamaz')),
      );
      expect(adapter.requestBodies.last, {'decision': 'rejected', 'note': ''});
    });

    test('müşteri linkinden gelen kararda kaydeden yok', () {
      final co = ProjectChangeOrder.fromJson({...coJson, 'status': 'approved'});
      expect(co.decisionRecordedByStaff, isFalse);
      expect(co.decisionRecordedByName, '');
      expect(ProjectChangeOrder.fromJson(coJson).canRecordDecision, isTrue);
    });

    test('değer özeti financial-summary kırılımından', () async {
      final (repo, _) = await build({
        '/projects/p1/financial-summary': [
          (
            status: 200,
            body: {
              'base_contract_amount': 1000,
              'approved_additions': 200,
              'approved_deductions': 50,
              'current_contract_value': 1150,
              'pending_additions': 0,
              'pending_deductions': 30,
              'potential_contract_value': 1120,
              'currency': 'TRY',
              'collected_amount': 0,
            },
          ),
        ],
      });
      final s = await repo.contractValueSummary('p1');
      expect(s.currentContractValue, 1150);
      expect(s.hasPending, isTrue);
      expect(s.pendingNet, -30);
    });

    test('olaylar: yalnızca change_order_*, zaman sırasıyla, alıcı + revizyon bağı', () async {
      final (repo, _) = await build({
        '/projects/p1/events': [
          (
            status: 200,
            body: {
              'events': [
                {
                  'id': 'e3',
                  'event_type': 'change_order_email_failed',
                  'created_at': '2026-09-15T12:00:00+03:00',
                  'metadata': {'change_order_id': 'co1', 'recipient': 'a@b.com'},
                },
                {
                  'id': 'e0',
                  'event_type': 'collection_received',
                  'created_at': '2026-09-14T08:00:00Z',
                  'metadata': {'amount': 5000},
                },
                {
                  'id': 'e2',
                  'event_type': 'change_order_superseded',
                  'created_at': '2026-09-15T08:30:00Z',
                  'metadata': {'old_change_order_id': 'co0', 'new_change_order_id': 'co1'},
                },
                {
                  'id': 'e1',
                  'event_type': 'change_order_viewed',
                  'created_at': '2026-09-15T08:00:00Z',
                  'metadata': {'change_order_id': 'co1', 'ip': '1.2.3.4'},
                },
              ],
            },
          ),
        ],
      });
      final events = await repo.changeOrderEvents('p1');
      // 12:00+03:00 = 09:00Z -> 08:00Z ve 08:30Z'den SONRA.
      expect(events.map((e) => e.id), ['e1', 'e2', 'e3']);
      expect(events.first.isView, isTrue);
      expect(events[1].changeOrderIds, {'co0', 'co1'});
      expect(events[1].newChangeOrderId, 'co1');
      expect(events.last.recipient, 'a@b.com');
    });
  });

  group('yardımcılar', () {
    test('paylaşım adresi web /ek-is/{token}', () {
      expect(changeOrderShareUrl('abc'), endsWith('/ek-is/abc'));
    });

    test('ek iş sayı girişi Türkçe okunur: nokta gruplaması binliktir (8.500 = sekiz bin beş yüz)', () {
      // Regresyon: eski ayrıştırıcı "8.500"ü 8,5 ve "64.000"i 64 okuyordu --
      // müşteriye 1000 kat küçük bir ek iş gidiyordu.
      expect(parseChangeOrderNumber('8.500'), 8500);
      expect(parseChangeOrderNumber('64.000'), 64000);
      expect(parseChangeOrderNumber('1.250'), 1250);
      expect(parseChangeOrderNumber('1.250.000'), 1250000);
      expect(parseChangeOrderNumber('12.500'), 12500);
      expect(parseChangeOrderNumber('1.250,50'), 1250.5);
      expect(parseChangeOrderNumber('12,5'), 12.5);
      expect(parseChangeOrderNumber('7.5'), 7.5);
      expect(parseChangeOrderNumber('36.25'), 36.25);
      expect(parseChangeOrderNumber(' 4 '), 4);
      expect(parseChangeOrderNumber(''), isNull);
      expect(parseChangeOrderNumber('abc'), isNull);
      // NaN/Infinity ASLA geçmez (eskiden positive() doğrulamasını aşıp
      // jsonEncode'da çöküyordu).
      expect(parseChangeOrderNumber('NaN'), isNull);
      expect(parseChangeOrderNumber('Infinity'), isNull);
      // Sütunlar numeric(…, 2): üç ondalıklı değer kabul edilmez.
      expect(parseChangeOrderNumber('1,255'), isNull);
    });

    test('bölüm tanımları: Sözleşme Ek İşler\'den önce, doğru izinler', () {
      expect(contractCoSections.map((s) => s.alt), ['sozlesme', 'ek-isler']);
      expect(contractCoSections.every((s) => s.group == 'finans'), isTrue);
      expect(contractCoSections.first.permission, kContractsReadPermission);
      expect(contractCoSections.last.permission, kChangeOrdersReadPermission);
      expect(contractCoSections.first.route('p1'), '/projeler/p1/sozlesme');
      expect(contractCoSections.last.route('p1'), '/projeler/p1/ek-isler');
      expect(contractCoSections.last.replaces, '_ChangeOrdersTab');
    });
  });
}
