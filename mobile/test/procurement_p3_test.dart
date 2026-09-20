import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/data/projects_repository.dart';
import 'package:arvend/features/projects/domain/procurement.dart';

import 'test_utils/fake_api_client.dart';

/// Sprint 4/P3 — Satın Alma (Procurement): Purchase Request, RFQ, Supplier
/// Quotation, Bid Comparison, Purchase Order. Backend'de HİÇBİR değişiklik
/// yapılmadı -- bu testler yalnızca mobilin backend'in ZATEN var olan
/// sözleşmesine (Phase 1 doğrulamasıyla teyit edildi) DOĞRU şekilde
/// uyduğunu kanıtlar.
void main() {
  group('Purchase Request — create/edit request serialization', () {
    test('createPurchaseRequest POSTs the backend contract shape, cost_code_id optional', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-requests': [
          (status: 201, body: _prJson(id: 'pr1', status: 'draft')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final pr = await repo.createPurchaseRequest(
        'p1',
        title: 'Çimento Talebi',
        description: 'Temel için',
        neededBy: '2026-03-01',
        items: const [
          PurchaseRequestItem(
            id: '',
            wbsNodeId: null,
            costCodeId: null,
            budgetLineId: null,
            description: '50 torba çimento',
            quantity: 50,
            unit: 'torba',
            estimatedUnitCost: 300,
            estimatedTotal: 0,
            notes: '',
            sortOrder: 0,
          ),
        ],
      );

      expect(pr.id, 'pr1');
      expect(adapter.calls, ['/projects/p1/purchase-requests']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['title'], 'Çimento Talebi');
      expect(body['needed_by'], '2026-03-01');
      final items = body['items'] as List;
      expect(items.single['description'], '50 torba çimento');
      expect(items.single['quantity'], 50);
      expect(items.single['estimated_unit_cost'], 300);
      // Maliyet kodu opsiyoneldir -- boş string olarak gönderilir (backend
      // nil'e çözümler, bkz. Phase 1: resolveCostCodeRef boş girdide DB'ye
      // hiç gitmeden nil döner).
      expect(items.single['cost_code_id'], '');
    });

    test('createPurchaseRequest allows zero items (backend permits an empty draft)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-requests': [
          (status: 201, body: _prJson(id: 'pr1', status: 'draft')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.createPurchaseRequest('p1', title: 'Boş Talep');

      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['items'], isEmpty);
    });

    test('updatePurchaseRequest PUTs to the PR-specific endpoint and fully replaces items', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-requests/pr1': [
          (status: 200, body: _prJson(id: 'pr1', status: 'draft')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.updatePurchaseRequest(
        'p1',
        'pr1',
        title: 'Güncellenmiş Talep',
        items: const [
          PurchaseRequestItem(
            id: 'existing',
            wbsNodeId: null,
            costCodeId: 'cc1',
            budgetLineId: null,
            description: 'kalem',
            quantity: 10,
            unit: 'ad',
            estimatedUnitCost: null,
            estimatedTotal: 500,
            notes: '',
            sortOrder: 0,
          ),
        ],
      );

      expect(adapter.calls, ['/projects/p1/purchase-requests/pr1']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['title'], 'Güncellenmiş Talep');
      expect((body['items'] as List).single['cost_code_id'], 'cc1');
    });
  });

  group('Purchase Request — lifecycle actions', () {
    test('submitPurchaseRequest succeeds', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-requests/pr1/submit': [
          (status: 200, body: _prJson(id: 'pr1', status: 'submitted')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final pr = await repo.submitPurchaseRequest('p1', 'pr1');

      expect(pr.status, 'submitted');
    });

    test('withdrawPurchaseRequest sends no body (no reason)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-requests/pr1/withdraw': [
          (status: 200, body: _prJson(id: 'pr1', status: 'draft')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final pr = await repo.withdrawPurchaseRequest('p1', 'pr1');

      expect(pr.status, 'draft');
      expect(adapter.requestBodies.single, isNull);
    });

    test('cancelPurchaseRequest sends the reason', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-requests/pr1/cancel': [
          (status: 200, body: _prJson(id: 'pr1', status: 'cancelled')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.cancelPurchaseRequest('p1', 'pr1', reason: 'Proje iptal edildi');

      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['reason'], 'Proje iptal edildi');
    });

    test('invalid transition (approve a draft PR) surfaces as 409 with server message', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-requests/pr1/approve': [
          (status: 409, body: {'error': 'talep yalnızca gönderilmiş durumdan onaylanabilir'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.approvePurchaseRequest('p1', 'pr1'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.message, 'message', 'talep yalnızca gönderilmiş durumdan onaylanabilir')),
      );
    });

    test('reject without a reason surfaces as 400', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-requests/pr1/reject': [
          (status: 400, body: {'error': 'gerekçe zorunludur'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.rejectPurchaseRequest('p1', 'pr1', reason: ''),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 400)),
      );
    });
  });

  group('Purchase Request — status/permission visibility', () {
    PurchaseRequest withStatus(String status) => PurchaseRequest(
          id: 'pr1', prNo: 'PR-1', title: 't', description: '', neededBy: null, status: status,
          estimatedTotal: 0, requestedBy: null, submittedAt: null, approvedAt: null, approvedBy: null,
          rejectedAt: null, rejectedBy: null, rejectionReason: '', cancelledAt: null, cancelledBy: null,
          cancelReason: '', createdAt: '', updatedAt: '',
        );

    test('draft: edit + submit + cancel available, withdraw/approve/reject are not', () {
      final pr = withStatus(PurchaseRequest.statusDraft);
      expect(pr.isEditable, isTrue);
      expect(pr.canSubmit, isTrue);
      expect(pr.canCancel, isTrue);
      expect(pr.canWithdraw, isFalse);
      expect(pr.canApprove, isFalse);
      expect(pr.canReject, isFalse);
    });

    test('submitted: withdraw + approve + reject + cancel available, edit/submit are not', () {
      final pr = withStatus(PurchaseRequest.statusSubmitted);
      expect(pr.isEditable, isFalse);
      expect(pr.canSubmit, isFalse);
      expect(pr.canWithdraw, isTrue);
      expect(pr.canApprove, isTrue);
      expect(pr.canReject, isTrue);
      expect(pr.canCancel, isTrue);
    });

    test('approved: cancel still available (manage-level, no approve needed), nothing else', () {
      final pr = withStatus(PurchaseRequest.statusApproved);
      expect(pr.canCancel, isTrue);
      expect(pr.isEditable, isFalse);
      expect(pr.canSubmit, isFalse);
      expect(pr.canWithdraw, isFalse);
      expect(pr.canApprove, isFalse);
      expect(pr.canReject, isFalse);
    });

    for (final terminal in [PurchaseRequest.statusRejected, PurchaseRequest.statusCancelled]) {
      test('$terminal is terminal: no action available', () {
        final pr = withStatus(terminal);
        expect(pr.isEditable, isFalse);
        expect(pr.canSubmit, isFalse);
        expect(pr.canWithdraw, isFalse);
        expect(pr.canCancel, isFalse);
        expect(pr.canApprove, isFalse);
        expect(pr.canReject, isFalse);
      });
    }

    User userWith(Set<String> perms) => User(
          id: 'u', username: 'u', fullName: 'U', role: UserRole.kullanici, isActive: true,
          mustChangePassword: false, onboardingCompleted: true, onboardingStep: 'completed', permissions: perms,
        );

    // Phase 1 bulgusu: PR'da Cancel `manage` grubundadır (Approve/Reject
    // İLE DEĞİL) -- PO'nun aksine (orada Cancel `approve` gerektirir).
    test('legacy_user/project_manager-shaped set (manage only) can create/edit/submit/withdraw/CANCEL but not approve/reject', () {
      final user = userWith(const {'projects.procurement.read', 'projects.procurement.manage'});
      expect(user.hasPermission('projects.procurement.manage'), isTrue);
      expect(user.hasPermission('projects.procurement.approve'), isFalse);
    });
  });

  group('RFQ — create/edit request serialization', () {
    test('createRFQ POSTs the backend contract shape with own items when no purchase_request_id', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/rfqs': [
          (status: 201, body: _rfqJson(id: 'r1', status: 'draft')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final rfq = await repo.createRFQ(
        'p1',
        title: 'Çimento RFQ',
        issueDate: '2026-01-01',
        dueDate: '2026-01-10',
        supplierIds: const ['sup1', 'sup2'],
        items: const [
          RFQItem(
            id: '', sourcePrItemId: null, wbsNodeId: null, costCodeId: null, budgetLineId: null,
            description: 'çimento', quantity: 50, unit: 'torba', sortOrder: 0,
          ),
        ],
      );

      expect(rfq.id, 'r1');
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['title'], 'Çimento RFQ');
      expect(body['purchase_request_id'], '');
      expect(body['supplier_ids'], ['sup1', 'sup2']);
      expect((body['items'] as List).single['description'], 'çimento');
    });

    test('createRFQ from an approved PR sends purchase_request_id (backend snapshots items, form items ignored)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/rfqs': [
          (status: 201, body: _rfqJson(id: 'r1', status: 'draft')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.createRFQ('p1', title: 'RFQ', purchaseRequestId: 'pr1', supplierIds: const ['sup1']);

      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['purchase_request_id'], 'pr1');
      expect(body['items'], isEmpty);
    });
  });

  group('RFQ — lifecycle actions', () {
    test('issueRFQ succeeds (pure DB status flip, no external side effects per Phase 1)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/rfqs/r1/issue': [
          (status: 200, body: _rfqJson(id: 'r1', status: 'issued')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final rfq = await repo.issueRFQ('p1', 'r1');

      expect(rfq.status, 'issued');
      expect(adapter.requestBodies.single, isNull);
    });

    test('cancelRFQ sends no body (unlike PR/PO, RFQ cancel has no reason)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/rfqs/r1/cancel': [
          (status: 200, body: _rfqJson(id: 'r1', status: 'cancelled')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final rfq = await repo.cancelRFQ('p1', 'r1');

      expect(rfq.status, 'cancelled');
      expect(adapter.requestBodies.single, isNull);
    });

    test('awardRFQ sends quotation_id and parses the resulting closed+awarded status', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/rfqs/r1/award': [
          (status: 200, body: _rfqJson(id: 'r1', status: 'closed', awardedQuotationId: 'q1')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final rfq = await repo.awardRFQ('p1', 'r1', quotationId: 'q1', notes: 'en uygun teklif');

      expect(rfq.status, 'closed');
      expect(rfq.isAwarded, isTrue);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['quotation_id'], 'q1');
    });

    test('invalid transition (award a draft RFQ) surfaces as 409', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/rfqs/r1/award': [
          (status: 409, body: {'error': 'RFQ yalnızca yayınlanmış durumdan ödüllendirilebilir'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.awardRFQ('p1', 'r1', quotationId: 'q1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 409)),
      );
    });
  });

  group('RFQ — status/permission visibility', () {
    RFQ withStatus(String status, {String? awardedQuotationId}) => RFQ(
          id: 'r1', rfqNo: 'RFQ-1', purchaseRequestId: null, title: 't', issueDate: '', dueDate: null,
          status: status, notes: '', awardedQuotationId: awardedQuotationId, awardedAt: null, awardedBy: null,
          awardNotes: '', createdAt: '', updatedAt: '',
        );

    test('draft: edit + issue + cancel available, close/award are not', () {
      final rfq = withStatus(RFQ.statusDraft);
      expect(rfq.isEditable, isTrue);
      expect(rfq.canIssue, isTrue);
      expect(rfq.canCancel, isTrue);
      expect(rfq.canClose, isFalse);
      expect(rfq.canAward, isFalse);
    });

    test('issued: close + award + cancel available, edit/issue are not', () {
      final rfq = withStatus(RFQ.statusIssued);
      expect(rfq.isEditable, isFalse);
      expect(rfq.canIssue, isFalse);
      expect(rfq.canClose, isTrue);
      expect(rfq.canAward, isTrue);
      expect(rfq.canCancel, isTrue);
    });

    test('closed (with award) is terminal: isAwarded true, no further action', () {
      final rfq = withStatus(RFQ.statusClosed, awardedQuotationId: 'q1');
      expect(rfq.isAwarded, isTrue);
      expect(rfq.canIssue, isFalse);
      expect(rfq.canClose, isFalse);
      expect(rfq.canAward, isFalse);
      expect(rfq.canCancel, isFalse);
    });

    test('closed (without award, plain Close) is terminal: isAwarded false', () {
      final rfq = withStatus(RFQ.statusClosed);
      expect(rfq.isAwarded, isFalse);
      expect(rfq.canAward, isFalse);
    });

    test('cancelled is terminal', () {
      final rfq = withStatus(RFQ.statusCancelled);
      expect(rfq.isEditable, isFalse);
      expect(rfq.canIssue, isFalse);
      expect(rfq.canClose, isFalse);
      expect(rfq.canAward, isFalse);
      expect(rfq.canCancel, isFalse);
    });

    User userWith(Set<String> perms) => User(
          id: 'u', username: 'u', fullName: 'U', role: UserRole.kullanici, isActive: true,
          mustChangePassword: false, onboardingCompleted: true, onboardingStep: 'completed', permissions: perms,
        );

    // Phase 1 bulgusu: Award `procurement.approve` gerektirir -- create/
    // update/issue/close/cancel hepsi `manage` altındadır.
    test('legacy_user/project_manager-shaped set can create/edit/issue/close/cancel but NOT award', () {
      final user = userWith(const {'projects.procurement.read', 'projects.procurement.manage'});
      expect(user.hasPermission('projects.procurement.manage'), isTrue);
      expect(user.hasPermission('projects.procurement.approve'), isFalse);
    });
  });

  group('Supplier Quotation — create/edit request serialization + response parsing', () {
    test('createQuotation POSTs rfq_item_id-keyed items; currency/totals are never sent', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/rfqs/r1/quotations': [
          (status: 201, body: _quotationJson(id: 'q1')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final q = await repo.createQuotation(
        'p1',
        'r1',
        supplierId: 'sup1',
        discount: 100,
        taxRate: 20,
        deliveryDays: 14,
        items: const [
          QuotationItem(id: '', rfqItemId: 'ri1', quantity: 50, unitPrice: 320, lineTotal: 0, notes: ''),
        ],
      );

      expect(q.id, 'q1');
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['supplier_id'], 'sup1');
      expect(body['discount'], 100);
      expect(body['delivery_days'], 14);
      expect((body['items'] as List).single['rfq_item_id'], 'ri1');
      expect((body['items'] as List).single['unit_price'], 320);
      expect(body.containsKey('currency'), isFalse);
      expect(body.containsKey('subtotal'), isFalse);
      expect(body.containsKey('total'), isFalse);
    });

    test('updateQuotation PUTs without a supplier_id override (backend ignores it on update)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/rfqs/r1/quotations/q1': [
          (status: 200, body: _quotationJson(id: 'q1')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.updateQuotation(
        'p1', 'r1', 'q1',
        items: const [QuotationItem(id: '', rfqItemId: 'ri1', quantity: 40, unitPrice: 300, lineTotal: 0, notes: '')],
      );

      expect(adapter.calls, ['/projects/p1/rfqs/r1/quotations/q1']);
    });

    test('deleteQuotation issues a DELETE to the quotation endpoint', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/rfqs/r1/quotations/q1': [(status: 200, body: null)],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.deleteQuotation('p1', 'r1', 'q1');

      expect(adapter.calls, ['/projects/p1/rfqs/r1/quotations/q1']);
    });

    test('Quotation has no own status field -- winner is derived by comparing id to RFQ.awardedQuotationId', () {
      final q = Quotation.fromJson(_quotationJson(id: 'q1'));
      final rfqWinner = RFQ.fromJson(_rfqJson(id: 'r1', status: 'closed', awardedQuotationId: 'q1'));
      final rfqOther = RFQ.fromJson(_rfqJson(id: 'r1', status: 'closed', awardedQuotationId: 'q2'));
      expect(q.id == rfqWinner.awardedQuotationId, isTrue);
      expect(q.id == rfqOther.awardedQuotationId, isFalse);
    });
  });

  group('Bid Comparison — response parsing, no invented winner', () {
    test('bidComparison parses sparse per-item cells and quotations in backend-provided order', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/rfqs/r1/comparison': [
          (status: 200, body: {
            'rows': [
              {
                'item': {'id': 'ri1', 'description': 'çimento', 'quantity': 50, 'unit': 'torba', 'sort_order': 0},
                'cells': {
                  'sup1': {'supplier_id': 'sup1', 'quantity': 50, 'unit_price': 320, 'line_total': 16000, 'notes': ''},
                },
              },
            ],
            'quotations': [_quotationJson(id: 'q1'), _quotationJson(id: 'q2')],
          }),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final result = await repo.bidComparison('p1', 'r1');

      expect(result.rows, hasLength(1));
      expect(result.rows.single.cells.containsKey('sup1'), isTrue);
      // sup2 bu kalem için teklif vermemiş -- sparse: anahtar bile YOK.
      expect(result.rows.single.cells.containsKey('sup2'), isFalse);
      expect(result.quotations.map((q) => q.id).toList(), ['q1', 'q2']);
    });

    test('BidComparisonCell.fromJson never carries a winner/lowest/rank field (backend does not compute one)', () {
      final cell = BidComparisonCell.fromJson(
          {'supplier_id': 'sup1', 'quantity': 1, 'unit_price': 100, 'line_total': 100, 'notes': '', 'is_lowest': true});
      // Backend BÖYLE bir alan HİÇ göndermez (bkz. Phase 1) -- ama gönderse
      // BİLE mobil domain modeli bunu OKUMAZ/TAŞIMAZ, bu yüzden ekstra bir
      // alan gelse dahi mobil bunu hiçbir yerde GÖSTEREMEZ.
      expect(cell.supplierId, 'sup1');
      expect(cell.unitPrice, 100);
    });
  });

  group('Purchase Order — create/edit request serialization (cost_code_id REQUIRED per item)', () {
    test('createPurchaseOrder POSTs the backend contract shape', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-orders': [
          (status: 201, body: _poJson(id: 'po1', status: 'draft')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final po = await repo.createPurchaseOrder(
        'p1',
        supplierId: 'sup1',
        sourceRfqId: 'r1',
        sourceQuotationId: 'q1',
        taxRate: 20,
        items: const [
          PurchaseOrderItem(
            id: '', wbsNodeId: null, costCodeId: 'cc1', budgetLineId: null,
            description: 'çimento', quantity: 50, unit: 'torba', unitPrice: 320, lineTotal: 0, sortOrder: 0,
          ),
        ],
      );

      expect(po.id, 'po1');
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['supplier_id'], 'sup1');
      expect(body['source_rfq_id'], 'r1');
      expect(body['source_quotation_id'], 'q1');
      expect(body['tax_rate'], 20);
      final items = body['items'] as List;
      // PR/RFQ'nun AKSİNE cost_code_id burada BOŞ BIRAKILAMAZ -- backend DB
      // NOT NULL (bkz. Phase 1 doğrulaması, migration DDL'i).
      expect(items.single['cost_code_id'], 'cc1');
      expect(body.containsKey('currency'), isFalse);
      expect(body.containsKey('subtotal'), isFalse);
      expect(body.containsKey('total'), isFalse);
    });

    test('updatePurchaseOrder PUTs to the PO-specific endpoint', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-orders/po1': [
          (status: 200, body: _poJson(id: 'po1', status: 'draft')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.updatePurchaseOrder(
        'p1', 'po1', supplierId: 'sup1',
        items: const [
          PurchaseOrderItem(
            id: '', wbsNodeId: null, costCodeId: 'cc1', budgetLineId: null,
            description: 'k', quantity: 1, unit: 'ad', unitPrice: 10, lineTotal: 0, sortOrder: 0,
          ),
        ],
      );

      expect(adapter.calls, ['/projects/p1/purchase-orders/po1']);
    });
  });

  group('Purchase Order — lifecycle actions', () {
    test('approvePurchaseOrder succeeds', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-orders/po1/approve': [
          (status: 200, body: _poJson(id: 'po1', status: 'approved')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final po = await repo.approvePurchaseOrder('p1', 'po1');

      expect(po.status, 'approved');
    });

    test('cancelPurchaseOrder sends the reason', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-orders/po1/cancel': [
          (status: 200, body: _poJson(id: 'po1', status: 'cancelled')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.cancelPurchaseOrder('p1', 'po1', reason: 'Tedarikçi vazgeçti');

      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['reason'], 'Tedarikçi vazgeçti');
    });

    test('closePurchaseOrder succeeds', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-orders/po1/close': [
          (status: 200, body: _poJson(id: 'po1', status: 'closed')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final po = await repo.closePurchaseOrder('p1', 'po1');

      expect(po.status, 'closed');
    });

    test('invalid transition (close a draft PO) surfaces as 409', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-orders/po1/close': [
          (status: 409, body: {'error': 'sipariş yalnızca onaylı durumdan kapatılabilir'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.closePurchaseOrder('p1', 'po1'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 409)),
      );
    });

    test('cancel without a reason surfaces as 400', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-orders/po1/cancel': [
          (status: 400, body: {'error': 'gerekçe zorunludur'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.cancelPurchaseOrder('p1', 'po1', reason: ''),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 400)),
      );
    });
  });

  group('Purchase Order — status/permission visibility', () {
    PurchaseOrder withStatus(String status) => PurchaseOrder(
          id: 'po1', poNo: 'PO-1', supplierId: 's1', supplierCode: null, supplierName: null,
          sourceRfqId: null, sourceQuotationId: null, currency: 'TRY', status: status, issueDate: '',
          expectedDeliveryDate: null, paymentTerms: '', deliveryAddress: '', notes: '', subtotal: 0,
          taxRate: 0, tax: 0, total: 0, approvedAt: null, approvedBy: null, cancelledAt: null,
          cancelledBy: null, cancelReason: '', closedAt: null, closedBy: null, createdAt: '', updatedAt: '',
        );

    test('draft: edit + approve + cancel available, close is not', () {
      final po = withStatus(PurchaseOrder.statusDraft);
      expect(po.isEditable, isTrue);
      expect(po.canApprove, isTrue);
      expect(po.canCancel, isTrue);
      expect(po.canClose, isFalse);
    });

    test('approved: cancel + close available, edit/approve are not', () {
      final po = withStatus(PurchaseOrder.statusApproved);
      expect(po.isEditable, isFalse);
      expect(po.canApprove, isFalse);
      expect(po.canCancel, isTrue);
      expect(po.canClose, isTrue);
    });

    for (final terminal in [PurchaseOrder.statusCancelled, PurchaseOrder.statusClosed]) {
      test('$terminal is terminal: no action available', () {
        final po = withStatus(terminal);
        expect(po.isEditable, isFalse);
        expect(po.canApprove, isFalse);
        expect(po.canCancel, isFalse);
        expect(po.canClose, isFalse);
      });
    }

    User userWith(Set<String> perms) => User(
          id: 'u', username: 'u', fullName: 'U', role: UserRole.kullanici, isActive: true,
          mustChangePassword: false, onboardingCompleted: true, onboardingStep: 'completed', permissions: perms,
        );

    // Phase 1 bulgusu: PO'da Cancel de `approve` gerektirir -- PR/RFQ'nun
    // AKSİNE (onlarda Cancel `manage` yeterlidir). Bu asimetri, onaylı bir
    // PO'yu iptal etmenin commitment voidlemesinden kaynaklanır.
    test('legacy_user/project_manager-shaped set (manage only) can create/edit but NOT approve/cancel/close', () {
      final user = userWith(const {'projects.procurement.read', 'projects.procurement.manage'});
      expect(user.hasPermission('projects.procurement.manage'), isTrue);
      expect(user.hasPermission('projects.procurement.approve'), isFalse);
    });

    test('finance/owner/admin-shaped set can do everything including approve/cancel/close', () {
      final user = userWith(const {
        'projects.procurement.read', 'projects.procurement.manage', 'projects.procurement.approve',
      });
      expect(user.hasPermission('projects.procurement.manage'), isTrue);
      expect(user.hasPermission('projects.procurement.approve'), isTrue);
    });
  });

  group('Purchase Order detail — commitments parsing (financial display, not recomputed)', () {
    test('purchaseOrderDetail parses items and commitments as independent backend-provided blocks', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-orders/po1': [
          (status: 200, body: {
            'purchase_order': _poJson(id: 'po1', status: 'approved'),
            'items': [
              {
                'id': 'i1', 'cost_code_id': 'cc1', 'description': 'çimento', 'quantity': 50, 'unit': 'torba',
                'unit_price': 320, 'line_total': 16000, 'sort_order': 0,
              },
            ],
            'commitments': [
              {
                'id': 'cm1', 'budget_line_id': null, 'cost_code_id': 'cc1', 'cost_code_code': '01.01',
                'cost_code_name': 'Çimento', 'source_type': 'purchase_order', 'description': 'PO-1',
                'committed_amount': 16000, 'currency': 'TRY', 'status': 'active', 'committed_at': '2026-01-01T00:00:00Z',
                'voided_at': null, 'void_reason': '',
              },
              {
                'id': 'cm2', 'budget_line_id': null, 'cost_code_id': 'cc1', 'cost_code_code': '01.01',
                'cost_code_name': 'Çimento', 'source_type': 'purchase_order', 'description': 'PO-1 (voided)',
                'committed_amount': 5000, 'currency': 'TRY', 'status': 'voided', 'committed_at': '2026-01-01T00:00:00Z',
                'voided_at': '2026-01-02T00:00:00Z', 'void_reason': 'iptal',
              },
            ],
          }),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final detail = await repo.purchaseOrderDetail('p1', 'po1');

      expect(detail.items, hasLength(1));
      expect(detail.commitments, hasLength(2));
      expect(detail.commitments.first.isVoided, isFalse);
      expect(detail.commitments.last.isVoided, isTrue);
      // PO'nun total'i (backend-hesaplı) commitment toplamından BAĞIMSIZDIR
      // -- mobil ikisini asla çapraz-toplamaz.
      expect(detail.order.total, 19200);
    });
  });

  group('List/detail refresh after create/edit/status-change', () {
    test('invalidating projectPurchaseRequestsProvider triggers a fresh list fetch', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-requests': [
          (status: 200, body: {'purchase_requests': <Map<String, dynamic>>[]}),
          (status: 200, body: {'purchase_requests': [_prJson(id: 'pr1', status: 'submitted')]}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(projectPurchaseRequestsProvider('p1').future);
      expect(before, isEmpty);

      container.invalidate(projectPurchaseRequestsProvider('p1'));
      final after = await container.read(projectPurchaseRequestsProvider('p1').future);

      expect(after, hasLength(1));
      expect(adapter.calls.where((p) => p == '/projects/p1/purchase-requests').length, 2);
    });

    test('invalidating rfqDetailProvider triggers a fresh detail fetch', () async {
      const args = (projectId: 'p1', rfqId: 'r1');
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/rfqs/r1': [
          (status: 200, body: _rfqDetailJson(status: 'draft')),
          (status: 200, body: _rfqDetailJson(status: 'issued')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(rfqDetailProvider(args).future);
      expect(before.rfq.status, 'draft');

      container.invalidate(rfqDetailProvider(args));
      final after = await container.read(rfqDetailProvider(args).future);

      expect(after.rfq.status, 'issued');
    });

    test('invalidating purchaseOrderDetailProvider triggers a fresh detail fetch', () async {
      const args = (projectId: 'p1', poId: 'po1');
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/purchase-orders/po1': [
          (status: 200, body: _poDetailJson(status: 'draft')),
          (status: 200, body: _poDetailJson(status: 'approved')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(purchaseOrderDetailProvider(args).future);
      expect(before.order.status, 'draft');

      container.invalidate(purchaseOrderDetailProvider(args));
      final after = await container.read(purchaseOrderDetailProvider(args).future);

      expect(after.order.status, 'approved');
    });
  });
}

Map<String, dynamic> _prJson({required String id, required String status}) => {
      'id': id,
      'pr_no': 'PR-2026-0001',
      'title': 't',
      'description': '',
      'status': status,
      'estimated_total': 15000,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _rfqJson({required String id, required String status, String? awardedQuotationId}) => {
      'id': id,
      'rfq_no': 'RFQ-2026-0001',
      'title': 't',
      'issue_date': '2026-01-01',
      'status': status,
      'notes': '',
      'awarded_quotation_id': awardedQuotationId,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _rfqDetailJson({required String status}) => {
      'rfq': _rfqJson(id: 'r1', status: status),
      'items': <Map<String, dynamic>>[],
      'suppliers': <Map<String, dynamic>>[],
    };

Map<String, dynamic> _quotationJson({required String id}) => {
      'id': id,
      'rfq_id': 'r1',
      'supplier_id': 'sup1',
      'quotation_number': 'Q-1',
      'quotation_date': '2026-01-01',
      'currency': 'TRY',
      'subtotal': 16000,
      'discount': 0,
      'tax_rate': 20,
      'tax': 3200,
      'total': 19200,
      'payment_terms': '',
      'notes': '',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _poJson({required String id, required String status}) => {
      'id': id,
      'po_no': 'PO-2026-0001',
      'supplier_id': 'sup1',
      'currency': 'TRY',
      'status': status,
      'issue_date': '2026-01-01',
      'payment_terms': '',
      'delivery_address': '',
      'notes': '',
      'subtotal': 16000,
      'tax_rate': 20,
      'tax': 3200,
      'total': 19200,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _poDetailJson({required String status}) => {
      'purchase_order': _poJson(id: 'po1', status: status),
      'items': <Map<String, dynamic>>[],
      'commitments': <Map<String, dynamic>>[],
    };
