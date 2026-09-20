import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/data/projects_repository.dart';
import 'package:arvend/features/projects/domain/subcontract.dart';

import 'test_utils/fake_api_client.dart';

/// Sprint 5 P1 — Mobil Taşeron Sözleşmesi Ekle/Düzenle/Yaşam Döngüsü.
/// Backend'de HİÇBİR değişiklik yapılmadı (Phase 1 doğrulamasıyla teyit
/// edildi) -- bu testler yalnızca mobilin backend'in ZATEN var olan
/// sözleşmesine DOĞRU şekilde uyduğunu kanıtlar (istek gövdesi şekli, durum
/// makinesi görünürlüğü, hata haritalama, provider tazeleme).
void main() {
  group('create/edit request serialization', () {
    test('createSubcontract POSTs the backend contract shape', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontracts': [
          (status: 201, body: _subcontractJson(id: 'sc1', status: 'draft')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final sc = await repo.createSubcontract(
        'p1',
        supplierId: 'sup1',
        title: 'Elektrik Tesisatı',
        scopeSummary: 'Kat 1-5 elektrik',
        effectiveDate: '2026-01-01',
        startDate: '2026-01-05',
        plannedCompletionDate: '2026-06-01',
        retentionPercent: 10,
        advanceAmount: 5000,
        paymentTerms: '30 gün',
        notes: 'not',
        items: const [
          SubcontractItem(
            id: '',
            wbsNodeId: null,
            costCodeId: 'cc1',
            budgetLineId: null,
            description: 'Kablo döşeme',
            quantity: null,
            unit: '',
            unitPrice: null,
            originalAmount: 50000,
            sortOrder: 0,
          ),
        ],
      );

      expect(sc.id, 'sc1');
      expect(adapter.calls, ['/projects/p1/subcontracts']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['supplier_id'], 'sup1');
      expect(body['title'], 'Elektrik Tesisatı');
      expect(body['scope_summary'], 'Kat 1-5 elektrik');
      expect(body['effective_date'], '2026-01-01');
      expect(body['start_date'], '2026-01-05');
      expect(body['planned_completion_date'], '2026-06-01');
      expect(body['retention_percent'], 10);
      expect(body['advance_amount'], 5000);
      expect(body['payment_terms'], '30 gün');
      expect(body['notes'], 'not');
      final items = body['items'] as List;
      expect(items, hasLength(1));
      expect(items.single['cost_code_id'], 'cc1');
      expect(items.single['description'], 'Kablo döşeme');
      expect(items.single['original_amount'], 50000);
      // Mobil bir WBS/bütçe kalemi seçtirmez (bkz. Phase 1: minimal SOV
      // girişi) -- backend'de İKİSİ de OPTIONAL, boş string nil'e çözümlenir
      // (bkz. backend resolveWBSParentRef/resolveBudgetLineRef).
      expect(items.single['wbs_node_id'], '');
      expect(items.single['budget_line_id'], '');
    });

    test('updateSubcontract PUTs and preserves an existing item\'s wbs/budget-line linkage', () async {
      // Backend Update kalemleri HER SEFERİNDE tamamen yeniden yazar (sil-
      // yeniden-oluştur, bkz. backend insertSubcontractItems) -- bu yüzden
      // detaydan yüklenmiş mevcut bir kalemin wbsNodeId/budgetLineId'si edit
      // isteğinde OLDUĞU GİBİ geri gönderilmezse sessizce kaybolur. Bu test
      // tam olarak bu regresyonu yakalar.
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontracts/sc1': [
          (status: 200, body: _subcontractJson(id: 'sc1', status: 'draft')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      const existingItem = SubcontractItem(
        id: 'item1',
        wbsNodeId: 'wbs1',
        costCodeId: 'cc1',
        budgetLineId: 'bl1',
        description: 'Mevcut kalem',
        quantity: 2,
        unit: 'ad',
        unitPrice: 1000,
        originalAmount: 2000,
        sortOrder: 0,
      );

      await repo.updateSubcontract(
        'p1',
        'sc1',
        supplierId: 'sup1',
        title: 'Güncellenmiş Başlık',
        items: const [existingItem],
      );

      expect(adapter.calls, ['/projects/p1/subcontracts/sc1']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['title'], 'Güncellenmiş Başlık');
      final items = body['items'] as List;
      expect(items, hasLength(1));
      expect(items.single['cost_code_id'], 'cc1');
      expect(items.single['wbs_node_id'], 'wbs1');
      expect(items.single['budget_line_id'], 'bl1');
    });
  });

  group('lifecycle actions', () {
    test('activateSubcontract succeeds and parses the returned status', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontracts/sc1/activate': [
          (status: 200, body: _subcontractJson(id: 'sc1', status: 'active')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final sc = await repo.activateSubcontract('p1', 'sc1');

      expect(sc.status, 'active');
      expect(adapter.calls, ['/projects/p1/subcontracts/sc1/activate']);
    });

    test('cancelSubcontract sends the reason in the request body', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontracts/sc1/cancel': [
          (status: 200, body: _subcontractJson(id: 'sc1', status: 'cancelled')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final sc = await repo.cancelSubcontract('p1', 'sc1', reason: 'Tedarikçi vazgeçti');

      expect(sc.status, 'cancelled');
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['reason'], 'Tedarikçi vazgeçti');
    });

    test('invalid transition rejected by backend surfaces as a 409 ApiException with the server message', () async {
      // Gerçek backend davranışı (Phase 1'de doğrulandı): draft-dışından
      // Complete -> 409 + ErrSubcontractNotCompletable'ın Türkçe mesajı.
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontracts/sc1/complete': [
          (status: 409, body: {'error': 'taşeron sözleşmesi yalnızca aktif durumdan tamamlanabilir'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.completeSubcontract('p1', 'sc1'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.message, 'message', 'taşeron sözleşmesi yalnızca aktif durumdan tamamlanabilir')),
      );
    });

    test('reason-required rejection surfaces as a 400 ApiException', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontracts/sc1/cancel': [
          (status: 400, body: {'error': 'iptal/fesih gerekçesi zorunludur'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.cancelSubcontract('p1', 'sc1', reason: ''),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 400)),
      );
    });
  });

  group('lifecycle action visibility (status + permission gating)', () {
    Subcontract withStatus(String status) => Subcontract(
          id: 'sc1',
          subcontractNo: 'SC-1',
          supplierId: 's1',
          supplierCode: null,
          supplierName: null,
          title: 't',
          scopeSummary: '',
          originalAmount: 0,
          currency: 'TRY',
          status: status,
          effectiveDate: null,
          startDate: null,
          plannedCompletionDate: null,
          retentionPercent: null,
          advanceAmount: null,
          paymentTerms: '',
          notes: '',
          activatedAt: null,
          completedAt: null,
          cancelledAt: null,
          cancelReason: '',
          terminatedAt: null,
          terminationReason: '',
          createdAt: '',
        );

    test('draft: edit + activate + cancel available, complete/terminate are not', () {
      final sc = withStatus(Subcontract.statusDraft);
      expect(sc.isEditable, isTrue);
      expect(sc.canActivate, isTrue);
      expect(sc.canCancel, isTrue);
      expect(sc.canComplete, isFalse);
      expect(sc.canTerminate, isFalse);
    });

    test('active: complete + terminate available, edit/activate/cancel are not', () {
      final sc = withStatus(Subcontract.statusActive);
      expect(sc.isEditable, isFalse);
      expect(sc.canActivate, isFalse);
      expect(sc.canCancel, isFalse);
      expect(sc.canComplete, isTrue);
      expect(sc.canTerminate, isTrue);
    });

    for (final terminal in [Subcontract.statusCompleted, Subcontract.statusCancelled, Subcontract.statusTerminated]) {
      test('$terminal is terminal: no lifecycle action is available', () {
        final sc = withStatus(terminal);
        expect(sc.isEditable, isFalse);
        expect(sc.canActivate, isFalse);
        expect(sc.canCancel, isFalse);
        expect(sc.canComplete, isFalse);
        expect(sc.canTerminate, isFalse);
      });
    }

    // Rol matrisi (bkz. backend db/migrations/0038_create_subcontract_
    // foundation.up.sql rol-izin seed'i, Phase 1'de doğrulandı): owner/
    // admin/finance approve dahil TAM yetkili; legacy_user/project_manager
    // manage'e sahip ama approve'a SAHİP DEĞİL (aktivasyon/tamamlama/iptal/
    // fesih butonları onlara gösterilmez); field ikisine de sahip değil.
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

    test('finance/owner/admin-shaped permission set can manage AND approve', () {
      final user = userWith(const {
        'projects.subcontracts.read',
        'projects.subcontracts.manage',
        'projects.subcontracts.approve',
      });
      expect(user.hasPermission('projects.subcontracts.manage'), isTrue);
      expect(user.hasPermission('projects.subcontracts.approve'), isTrue);
    });

    test('legacy_user/project_manager-shaped permission set can manage but NOT approve', () {
      final user = userWith(const {'projects.subcontracts.read', 'projects.subcontracts.manage'});
      expect(user.hasPermission('projects.subcontracts.manage'), isTrue);
      expect(user.hasPermission('projects.subcontracts.approve'), isFalse);
    });

    test('field-shaped permission set has neither manage nor approve', () {
      final user = userWith(const {});
      expect(user.hasPermission('projects.subcontracts.manage'), isFalse);
      expect(user.hasPermission('projects.subcontracts.approve'), isFalse);
    });
  });

  group('list/detail refresh after create/edit/status-change', () {
    test('invalidating projectSubcontractsProvider triggers a fresh list fetch', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontracts': [
          (status: 200, body: {'subcontracts': <Map<String, dynamic>>[]}),
          (status: 200, body: {
            'subcontracts': [_subcontractJson(id: 'sc1', status: 'active')]
          }),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(projectSubcontractsProvider('p1').future);
      expect(before, isEmpty);

      container.invalidate(projectSubcontractsProvider('p1'));
      final after = await container.read(projectSubcontractsProvider('p1').future);

      expect(after, hasLength(1));
      expect(after.single.status, 'active');
      expect(adapter.calls.where((p) => p == '/projects/p1/subcontracts').length, 2);
    });

    test('invalidating subcontractDetailProvider triggers a fresh detail fetch', () async {
      const args = (projectId: 'p1', subcontractId: 'sc1');
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontracts/sc1': [
          (status: 200, body: _subcontractDetailJson(status: 'draft')),
          (status: 200, body: _subcontractDetailJson(status: 'active')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(subcontractDetailProvider(args).future);
      expect(before.subcontract.status, 'draft');

      container.invalidate(subcontractDetailProvider(args));
      final after = await container.read(subcontractDetailProvider(args).future);

      expect(after.subcontract.status, 'active');
      expect(adapter.calls.where((p) => p == '/projects/p1/subcontracts/sc1').length, 2);
    });
  });
}

Map<String, dynamic> _subcontractJson({required String id, required String status}) => {
      'id': id,
      'subcontract_no': 'SC-2026-0001',
      'supplier_id': 'sup1',
      'title': 't',
      'scope_summary': '',
      'original_amount': 50000,
      'currency': 'TRY',
      'status': status,
      'payment_terms': '',
      'notes': '',
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

Map<String, dynamic> _subcontractDetailJson({required String status}) => {
      'subcontract': _subcontractJson(id: 'sc1', status: status),
      'items': <Map<String, dynamic>>[],
      'current_value': {
        'original_amount': 50000,
        'approved_additions': 0,
        'approved_deductions': 0,
        'pending_additions': 0,
        'pending_deductions': 0,
        'current_value': 50000,
        'certified_to_date': 0,
        'remaining_commitment': 50000,
        'paid_to_date': 0,
        'remaining_payable': 0,
      },
      'commitments': <Map<String, dynamic>>[],
    };
