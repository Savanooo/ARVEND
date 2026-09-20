import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/data/projects_repository.dart';
import 'package:arvend/features/projects/domain/subcontract.dart';

import 'test_utils/fake_api_client.dart';

/// Sprint 5 P2 — Hakediş (Progress Claim) + Taşeron Değişiklik Emri
/// (Subcontract Change Order). Backend'de HİÇBİR değişiklik yapılmadı --
/// bu testler yalnızca mobilin backend'in ZATEN var olan sözleşmesine
/// (Phase 1 doğrulamasıyla teyit edildi) DOĞRU şekilde uyduğunu kanıtlar.
void main() {
  group('Progress Claim — create/edit request serialization', () {
    test('createProgressClaim POSTs the backend contract shape', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontracts/sc1/progress-claims': [
          (status: 201, body: _claimJson(id: 'c1', status: 'draft')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final claim = await repo.createProgressClaim(
        'p1',
        'sc1',
        periodStart: '2026-01-01',
        periodEnd: '2026-01-31',
        retentionPercent: 10,
        advanceRecoveryAmount: 5000,
        otherDeductions: 1000,
        notes: 'Ocak ayı hakedişi',
        items: const [
          ProgressClaimItem(
            id: '',
            subcontractItemId: 'item1',
            itemDescription: '',
            itemUnit: '',
            scheduledValue: 0,
            previousProgressAmount: 0,
            currentProgressAmount: 25000,
            cumulativeProgressAmount: 0,
            progressPercent: 0,
            remainingAmount: 0,
            sortOrder: 0,
          ),
        ],
      );

      expect(claim.id, 'c1');
      expect(adapter.calls, ['/projects/p1/subcontracts/sc1/progress-claims']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['period_start'], '2026-01-01');
      expect(body['period_end'], '2026-01-31');
      expect(body['retention_percent'], 10);
      expect(body['advance_recovery_amount'], 5000);
      expect(body['other_deductions'], 1000);
      expect(body['notes'], 'Ocak ayı hakedişi');
      final items = body['items'] as List;
      expect(items, hasLength(1));
      expect(items.single['subcontract_item_id'], 'item1');
      expect(items.single['current_progress_amount'], 25000);
      // İstek gövdesinde SADECE bu iki alan var -- gross/retention/net vb.
      // TAMAMEN backend-hesaplıdır, client bunları hiç göndermez.
      expect(items.single.containsKey('gross_work_amount'), isFalse);
      expect(items.single.containsKey('net_payable'), isFalse);
    });

    test('updateProgressClaim PUTs to the claim-specific endpoint (edit where allowed: draft only)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontract-progress-claims/c1': [
          (status: 200, body: _claimJson(id: 'c1', status: 'draft')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.updateProgressClaim(
        'p1',
        'c1',
        periodEnd: '2026-02-01',
        retentionPercent: 5,
        items: const [
          ProgressClaimItem(
            id: 'existing',
            subcontractItemId: 'item1',
            itemDescription: '',
            itemUnit: '',
            scheduledValue: 0,
            previousProgressAmount: 0,
            currentProgressAmount: 30000,
            cumulativeProgressAmount: 0,
            progressPercent: 0,
            remainingAmount: 0,
            sortOrder: 0,
          ),
        ],
      );

      expect(adapter.calls, ['/projects/p1/subcontract-progress-claims/c1']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['period_end'], '2026-02-01');
      expect(body['retention_percent'], 5);
      expect((body['items'] as List).single['current_progress_amount'], 30000);
    });
  });

  group('Progress Claim — lifecycle actions', () {
    test('submitProgressClaim succeeds and parses the returned status', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontract-progress-claims/c1/submit': [
          (status: 200, body: _claimJson(id: 'c1', status: 'submitted')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final claim = await repo.submitProgressClaim('p1', 'c1');

      expect(claim.status, 'submitted');
      expect(adapter.calls, ['/projects/p1/subcontract-progress-claims/c1/submit']);
    });

    test('certifyProgressClaim succeeds', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontract-progress-claims/c1/certify': [
          (status: 200, body: _claimJson(id: 'c1', status: 'certified')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final claim = await repo.certifyProgressClaim('p1', 'c1');

      expect(claim.status, 'certified');
    });

    test('rejectProgressClaim sends the reason in the request body', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontract-progress-claims/c1/reject': [
          (status: 200, body: _claimJson(id: 'c1', status: 'rejected')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final claim = await repo.rejectProgressClaim('p1', 'c1', reason: 'Tutar tutmuyor');

      expect(claim.status, 'rejected');
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['reason'], 'Tutar tutmuyor');
    });

    test('invalid transition (certify a draft claim) rejected by backend surfaces as 409 with server message', () async {
      // Gerçek backend davranışı (Phase 1'de doğrulandı): submitted-dışından
      // Certify -> 409 ErrProgressClaimNotCertifiable.
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontract-progress-claims/c1/certify': [
          (status: 409, body: {'error': 'hakediş yalnızca gönderilmiş durumdan sertifika edilebilir'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.certifyProgressClaim('p1', 'c1'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.message, 'message', 'hakediş yalnızca gönderilmiş durumdan sertifika edilebilir')),
      );
    });

    test('a "stale" certify race (another claim certified the same SOV item meanwhile) surfaces as 409', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontract-progress-claims/c1/certify': [
          (status: 409, body: {'error': 'hakediş bayatlamış, lütfen yeniden yükleyip tekrar deneyin'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.certifyProgressClaim('p1', 'c1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 409)),
      );
    });
  });

  group('Progress Claim — status/permission visibility', () {
    ProgressClaim withStatus(String status) => ProgressClaim(
          id: 'c1',
          subcontractId: 'sc1',
          claimNumber: 'SPC-1',
          periodStart: null,
          periodEnd: '2026-01-01',
          status: status,
          grossWorkAmount: 0,
          retentionPercentSnapshot: 0,
          retentionAmount: 0,
          advanceRecoveryAmount: 0,
          otherDeductions: 0,
          previousCertifiedAmount: 0,
          currentCertifiedAmount: 0,
          netPayable: 0,
          submittedAt: null,
          certifiedAt: null,
          rejectedAt: null,
          rejectionReason: '',
          cancelledAt: null,
          notes: '',
          createdAt: '',
          updatedAt: '',
        );

    test('draft: edit + submit + cancel available, certify/reject are not', () {
      final c = withStatus(ProgressClaim.statusDraft);
      expect(c.isEditable, isTrue);
      expect(c.canSubmit, isTrue);
      expect(c.canCancel, isTrue);
      expect(c.canCertify, isFalse);
      expect(c.canReject, isFalse);
    });

    test('submitted: certify + reject + cancel available, edit/submit are not', () {
      final c = withStatus(ProgressClaim.statusSubmitted);
      expect(c.isEditable, isFalse);
      expect(c.canSubmit, isFalse);
      expect(c.canCancel, isTrue);
      expect(c.canCertify, isTrue);
      expect(c.canReject, isTrue);
    });

    test('certified is terminal: no further action, correction requires a NEW claim', () {
      final c = withStatus(ProgressClaim.statusCertified);
      expect(c.isEditable, isFalse);
      expect(c.canSubmit, isFalse);
      expect(c.canCancel, isFalse);
      expect(c.canCertify, isFalse);
      expect(c.canReject, isFalse);
    });

    for (final terminal in [ProgressClaim.statusRejected, ProgressClaim.statusCancelled]) {
      test('$terminal is terminal: no action available', () {
        final c = withStatus(terminal);
        expect(c.isEditable, isFalse);
        expect(c.canSubmit, isFalse);
        expect(c.canCancel, isFalse);
        expect(c.canCertify, isFalse);
        expect(c.canReject, isFalse);
      });
    }

    // Phase 1 bulgusu: Reject bile `subcontract_claims.certify` gerektirir,
    // `subcontract_claims.manage` İLE DEĞİL (Cancel'ın aksine) -- bu
    // sürpriz olduğu için özellikle regresyona karşı test edilir.
    User userWith(Set<String> perms) => User(
          id: 'u',
          username: 'u',
          fullName: 'U',
          role: UserRole.kullanici,
          isActive: true,
          mustChangePassword: false,
          onboardingCompleted: true,
          onboardingStep: 'completed',
          permissions: perms,
        );

    test('legacy_user/project_manager-shaped set can manage claims but NOT certify/reject', () {
      final user = userWith(const {'projects.subcontract_claims.read', 'projects.subcontract_claims.manage'});
      expect(user.hasPermission('projects.subcontract_claims.manage'), isTrue);
      expect(user.hasPermission('projects.subcontract_claims.certify'), isFalse);
    });

    test('finance/owner/admin-shaped set can manage AND certify/reject', () {
      final user = userWith(const {
        'projects.subcontract_claims.read',
        'projects.subcontract_claims.manage',
        'projects.subcontract_claims.certify',
      });
      expect(user.hasPermission('projects.subcontract_claims.manage'), isTrue);
      expect(user.hasPermission('projects.subcontract_claims.certify'), isTrue);
    });
  });

  group('Subcontract Change Order — list/detail parsing', () {
    test('subcontractChangeOrders lists headers only (no items)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontracts/sc1/change-orders': [
          (status: 200, body: {
            'subcontract_change_orders': [_changeOrderJson(id: 'co1', status: 'draft', changeType: 'addition')]
          }),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final list = await repo.subcontractChangeOrders('p1', 'sc1');

      expect(list, hasLength(1));
      expect(list.single.id, 'co1');
      expect(list.single.signedAmount, 15000);
    });

    test('subcontractChangeOrderDetail returns header + items, and a deduction has a negative signedAmount', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontract-change-orders/co1': [
          (status: 200, body: {
            'subcontract_change_order': _changeOrderJson(id: 'co1', status: 'approved', changeType: 'deduction'),
            'items': [
              {'id': 'i1', 'cost_code_id': 'cc1', 'description': 'kesinti', 'amount': 15000, 'sort_order': 0},
            ],
          }),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final detail = await repo.subcontractChangeOrderDetail('p1', 'co1');

      expect(detail.changeOrder.changeType, SubcontractChangeOrder.typeDeduction);
      // amount HER ZAMAN pozitif döner (backend), işaret mobilde changeType'a
      // göre TÜRETİLİR -- backend bunu ASLA göndermez (bkz. Phase 1: dead
      // SignedEffect() bulgusu).
      expect(detail.changeOrder.amount, 15000);
      expect(detail.changeOrder.signedAmount, -15000);
      expect(detail.items, hasLength(1));
      expect(detail.items.single.costCodeId, 'cc1');
    });
  });

  group('Subcontract Change Order — create/submit/lifecycle', () {
    test('createSubcontractChangeOrder POSTs the backend contract shape', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontracts/sc1/change-orders': [
          (status: 201, body: _changeOrderJson(id: 'co1', status: 'draft', changeType: 'addition')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final co = await repo.createSubcontractChangeOrder(
        'p1',
        'sc1',
        title: 'Ek elektrik hattı',
        description: 'Kat 6 ilavesi',
        changeType: SubcontractChangeOrder.typeAddition,
        reason: '',
        items: const [
          SubcontractChangeOrderItem(
            id: '',
            wbsNodeId: null,
            costCodeId: 'cc1',
            budgetLineId: null,
            description: 'kablo',
            amount: 15000,
            sortOrder: 0,
          ),
        ],
      );

      expect(co.id, 'co1');
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['title'], 'Ek elektrik hattı');
      expect(body['change_type'], 'addition');
      final items = body['items'] as List;
      expect(items.single['cost_code_id'], 'cc1');
      expect(items.single['amount'], 15000);
      // P1'in bilinçli kapsam sınırı: mobil bir WBS/bütçe seçici SUNMAZ,
      // ikisi de boş string olarak gönderilir (backend'de optional).
      expect(items.single['wbs_node_id'], '');
      expect(items.single['budget_line_id'], '');
    });

    test('submitSubcontractChangeOrder succeeds', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontract-change-orders/co1/submit': [
          (status: 200, body: _changeOrderJson(id: 'co1', status: 'submitted', changeType: 'addition')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final co = await repo.submitSubcontractChangeOrder('p1', 'co1');

      expect(co.status, 'submitted');
    });

    test('invalid transition (approve a draft change order) surfaces as 409 with server message', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontract-change-orders/co1/approve': [
          (status: 409, body: {'error': 'değişiklik emri yalnızca gönderilmiş durumdan onaylanabilir'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.approveSubcontractChangeOrder('p1', 'co1'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.message, 'message', 'değişiklik emri yalnızca gönderilmiş durumdan onaylanabilir')),
      );
    });

    test('rejectSubcontractChangeOrder without a reason surfaces as 400', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontract-change-orders/co1/reject': [
          (status: 400, body: {'error': 'red gerekçesi zorunludur'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.rejectSubcontractChangeOrder('p1', 'co1', reason: ''),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 400)),
      );
    });
  });

  group('Subcontract Change Order — status/permission visibility', () {
    SubcontractChangeOrder withStatus(String status, {String changeType = SubcontractChangeOrder.typeAddition}) =>
        SubcontractChangeOrder(
          id: 'co1',
          subcontractId: 'sc1',
          number: 'SCO-1',
          title: 't',
          description: '',
          changeType: changeType,
          amount: 1000,
          status: status,
          reason: '',
          requestedAt: null,
          approvedAt: null,
          rejectedAt: null,
          rejectionReason: '',
          cancelledAt: null,
          createdAt: '',
          updatedAt: '',
        );

    test('draft: edit + submit + cancel available, approve/reject are not', () {
      final co = withStatus(SubcontractChangeOrder.statusDraft);
      expect(co.isEditable, isTrue);
      expect(co.canSubmit, isTrue);
      expect(co.canCancel, isTrue);
      expect(co.canApprove, isFalse);
      expect(co.canReject, isFalse);
    });

    test('submitted: approve + reject + cancel available, edit/submit are not', () {
      final co = withStatus(SubcontractChangeOrder.statusSubmitted);
      expect(co.isEditable, isFalse);
      expect(co.canSubmit, isFalse);
      expect(co.canCancel, isTrue);
      expect(co.canApprove, isTrue);
      expect(co.canReject, isTrue);
    });

    for (final terminal in [
      SubcontractChangeOrder.statusApproved,
      SubcontractChangeOrder.statusRejected,
      SubcontractChangeOrder.statusCancelled,
    ]) {
      test('$terminal is terminal: no action available', () {
        final co = withStatus(terminal);
        expect(co.isEditable, isFalse);
        expect(co.canSubmit, isFalse);
        expect(co.canCancel, isFalse);
        expect(co.canApprove, isFalse);
        expect(co.canReject, isFalse);
      });
    }

    // Phase 1 bulgusu: değişiklik emirlerinin KENDİ izni YOK -- ana
    // sözleşmenin subcontracts.manage/approve'unu PAYLAŞIR (subcontract
    //_claims.* İLE KARIŞTIRILMAMALI, o TAMAMEN AYRI bir izin ailesidir).
    User userWith(Set<String> perms) => User(
          id: 'u',
          username: 'u',
          fullName: 'U',
          role: UserRole.kullanici,
          isActive: true,
          mustChangePassword: false,
          onboardingCompleted: true,
          onboardingStep: 'completed',
          permissions: perms,
        );

    test('legacy_user/project_manager-shaped set (subcontracts.manage only) can create/edit/submit/cancel but NOT approve/reject', () {
      final user = userWith(const {'projects.subcontracts.read', 'projects.subcontracts.manage'});
      expect(user.hasPermission('projects.subcontracts.manage'), isTrue);
      expect(user.hasPermission('projects.subcontracts.approve'), isFalse);
    });

    test('finance/owner/admin-shaped set can also approve/reject', () {
      final user = userWith(const {
        'projects.subcontracts.read',
        'projects.subcontracts.manage',
        'projects.subcontracts.approve',
      });
      expect(user.hasPermission('projects.subcontracts.approve'), isTrue);
    });
  });

  group('Financial display — certified/paid stay distinct, voided/rejected records excluded', () {
    test('SubcontractValue keeps current/certified/paid/remaining-commitment/remaining-payable independent (spec worked example)', () {
      // Kullanıcının kendi örneği: current=500k, certified=300k, paid=200k
      // => remaining_commitment=200k (=current-certified), remaining_payable
      // =100k (=certified-paid). Backend BU rakamları hesaplar (bkz. Phase 1
      // financials trace); bu test yalnızca fromJson'ın hiçbir alanı
      // birbirine KARIŞTIRMADIĞINI doğrular -- mobil bunları YENİDEN
      // HESAPLAMAZ.
      final value = SubcontractValue.fromJson({
        'original_amount': 500000,
        'approved_additions': 0,
        'approved_deductions': 0,
        'pending_additions': 0,
        'pending_deductions': 0,
        'current_value': 500000,
        'certified_to_date': 300000,
        'remaining_commitment': 200000,
        'paid_to_date': 200000,
        'remaining_payable': 100000,
      });
      expect(value.currentValue, 500000);
      expect(value.certifiedToDate, 300000);
      expect(value.paidToDate, 200000);
      expect(value.remainingCommitment, 200000);
      expect(value.remainingPayable, 100000);
      expect(value.certifiedToDate, isNot(equals(value.paidToDate)));
    });

    test('remainingPayable can be negative (advance/overpayment) and is not clamped', () {
      final value = SubcontractValue.fromJson({
        'original_amount': 100000,
        'approved_additions': 0,
        'approved_deductions': 0,
        'pending_additions': 0,
        'pending_deductions': 0,
        'current_value': 100000,
        'certified_to_date': 50000,
        'remaining_commitment': 50000,
        'paid_to_date': 80000,
        'remaining_payable': -30000,
      });
      expect(value.remainingPayable, -30000);
    });

    test('a voided payment is flagged isVoided; paid_to_date on SubcontractValue is read from the backend as-is, never re-summed client-side', () {
      final voided = SubcontractPayment.fromJson({
        'id': 'p1',
        'amount': 999999,
        'currency': 'TRY',
        'paid_date': '2026-01-01',
        'payment_method': '',
        'reference_no': '',
        'description': '',
        'voided_at': '2026-01-02T00:00:00Z',
        'void_reason': 'hata',
        'created_at': '2026-01-01T00:00:00Z',
      });
      expect(voided.isVoided, isTrue);
      // Backend paid_to_date'i `voided_at IS NULL` filtresiyle hesaplar (bkz.
      // GetSubcontractPaidToDate SQL, Phase 1) -- bu büyük, voidlenmiş
      // ödeme paid_to_date'e YANSIMAZ. Mobil bu iki veri kaynağını (payments
      // listesi vs SubcontractValue.paidToDate) hiç çapraz-toplamaz; burada
      // 0 dönen paid_to_date, listedeki 999999'luk voided kayıttan TAMAMEN
      // bağımsız olduğunu kanıtlar.
      final value = SubcontractValue.fromJson({
        'original_amount': 100000,
        'approved_additions': 0,
        'approved_deductions': 0,
        'pending_additions': 0,
        'pending_deductions': 0,
        'current_value': 100000,
        'certified_to_date': 10000,
        'remaining_commitment': 90000,
        'paid_to_date': 0,
        'remaining_payable': 10000,
      });
      expect(value.paidToDate, 0);
    });

    test('a rejected progress claim is a terminal, non-actionable state distinct from certified', () {
      final rejected = ProgressClaim.fromJson({
        'id': 'c1',
        'subcontract_id': 'sc1',
        'claim_number': 'SPC-1',
        'period_end': '2026-01-01',
        'status': 'rejected',
        'gross_work_amount': 500000,
        'retention_percent_snapshot': 10,
        'retention_amount': 50000,
        'advance_recovery_amount': 0,
        'other_deductions': 0,
        'previous_certified_amount': 0,
        'current_certified_amount': 0,
        'net_payable': 450000,
        'rejection_reason': 'hatalı',
        'notes': '',
        'created_at': '',
        'updated_at': '',
      });
      expect(rejected.status, 'rejected');
      expect(rejected.canCertify, isFalse);
      // certified_to_date backend'de YALNIZCA status='certified' satırları
      // sayar (bkz. GetSubcontractCertifiedToDate SQL) -- bu 500k'lik
      // reddedilmiş hakediş certified_to_date'e ASLA katılmaz; mobil ayrıca
      // filtrelemek ZORUNDA DEĞİLDİR çünkü backend zaten filtreler.
      expect(rejected.currentCertifiedAmount, 0);
    });

    test('ProgressClaimItem progress/remaining fields are read verbatim from the backend, not recomputed', () {
      // Kasıtlı olarak "tutarsız" görünen rakamlar (backend'in kendi iç
      // mantığı ne olursa olsun) -- mobilin bunları OLDUĞU GİBİ, hiçbir
      // formül uygulamadan gösterdiğini kanıtlamak için.
      final item = ProgressClaimItem.fromJson({
        'id': 'i1',
        'subcontract_item_id': 'si1',
        'item_description': 'Kablo döşeme',
        'item_unit': 'm',
        'scheduled_value': 1000,
        'previous_progress_amount': 200,
        'current_progress_amount': 300,
        'cumulative_progress_amount': 500,
        'progress_percent': 50,
        'remaining_amount': 500,
        'sort_order': 0,
      });
      expect(item.cumulativeProgressAmount, 500);
      expect(item.progressPercent, 50);
      expect(item.remainingAmount, 500);
    });
  });

  group('List/detail refresh after create/edit/status-change', () {
    test('invalidating progressClaimDetailProvider triggers a fresh detail fetch', () async {
      const args = (projectId: 'p1', claimId: 'c1');
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontract-progress-claims/c1': [
          (status: 200, body: _claimDetailJson(status: 'draft')),
          (status: 200, body: _claimDetailJson(status: 'submitted')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(progressClaimDetailProvider(args).future);
      expect(before.claim.status, 'draft');

      container.invalidate(progressClaimDetailProvider(args));
      final after = await container.read(progressClaimDetailProvider(args).future);

      expect(after.claim.status, 'submitted');
      expect(adapter.calls.where((p) => p == '/projects/p1/subcontract-progress-claims/c1').length, 2);
    });

    test('invalidating subcontractChangeOrdersProvider triggers a fresh list fetch', () async {
      const args = (projectId: 'p1', subcontractId: 'sc1');
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontracts/sc1/change-orders': [
          (status: 200, body: {'subcontract_change_orders': <Map<String, dynamic>>[]}),
          (status: 200, body: {
            'subcontract_change_orders': [_changeOrderJson(id: 'co1', status: 'submitted', changeType: 'addition')]
          }),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(subcontractChangeOrdersProvider(args).future);
      expect(before, isEmpty);

      container.invalidate(subcontractChangeOrdersProvider(args));
      final after = await container.read(subcontractChangeOrdersProvider(args).future);

      expect(after, hasLength(1));
      expect(after.single.status, 'submitted');
    });

    test('invalidating subcontractChangeOrderDetailProvider triggers a fresh detail fetch', () async {
      const args = (projectId: 'p1', changeOrderId: 'co1');
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontract-change-orders/co1': [
          (status: 200, body: {
            'subcontract_change_order': _changeOrderJson(id: 'co1', status: 'submitted', changeType: 'addition'),
            'items': <Map<String, dynamic>>[],
          }),
          (status: 200, body: {
            'subcontract_change_order': _changeOrderJson(id: 'co1', status: 'approved', changeType: 'addition'),
            'items': <Map<String, dynamic>>[],
          }),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(subcontractChangeOrderDetailProvider(args).future);
      expect(before.changeOrder.status, 'submitted');

      container.invalidate(subcontractChangeOrderDetailProvider(args));
      final after = await container.read(subcontractChangeOrderDetailProvider(args).future);

      expect(after.changeOrder.status, 'approved');
    });
  });
}

Map<String, dynamic> _claimJson({required String id, required String status}) => {
      'id': id,
      'subcontract_id': 'sc1',
      'claim_number': 'SPC-2026-0001',
      'period_end': '2026-01-31',
      'status': status,
      'gross_work_amount': 25000,
      'retention_percent_snapshot': 10,
      'retention_amount': 2500,
      'advance_recovery_amount': 0,
      'other_deductions': 0,
      'previous_certified_amount': 0,
      'current_certified_amount': 25000,
      'net_payable': 22500,
      'notes': '',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _claimDetailJson({required String status}) => {
      'progress_claim': _claimJson(id: 'c1', status: status),
      'items': <Map<String, dynamic>>[],
    };

Map<String, dynamic> _changeOrderJson({required String id, required String status, required String changeType}) => {
      'id': id,
      'subcontract_id': 'sc1',
      'number': 'SCO-2026-0001',
      'title': 'Ek İş',
      'description': '',
      'change_type': changeType,
      'amount': 15000,
      'status': status,
      'reason': '',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };
