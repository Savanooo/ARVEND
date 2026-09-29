import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/config/app_config.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/projects/budget/data/budget_repository.dart';
import 'package:arvend/features/projects/budget/domain/budget.dart';

import '../../../test_utils/fake_api_client.dart';

/// Depo, backend router.go + web CostControlSections.tsx ile AYNI uçları,
/// AYNI HTTP yöntemleri ve gövdelerle çağırmalı.
Future<(BudgetRepository, List<String>, FakeHttpClientAdapter)> _repo(
  Map<String, List<ScriptedResponse>> script,
) async {
  final adapter = FakeHttpClientAdapter(script: script);
  final requests = <String>[];
  final dio = Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl + AppConfig.apiPrefix));
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (o, h) {
        requests.add('${o.method} ${o.path}');
        h.next(o);
      },
    ),
  );
  return (BudgetRepository(ApiClient.test(dio)), requests, adapter);
}

const _p = '/projects/p1';

Map<String, dynamic> _budgetJson({String status = 'draft'}) => {
  'id': 'b1',
  'currency': 'TRY',
  'status': status,
  'version': 1,
};

Map<String, dynamic> _lineJson() => {
  'id': 'l1',
  'cost_code_id': 'cc1',
  'cost_code_code': 'MLZ-001',
  'cost_code_name': 'Hazır Beton',
  'description': 'Temel',
  'quantity': 420,
  'unit': 'm³',
  'unit_cost': 2350,
  'original_amount': 987000,
};

Map<String, dynamic> _adjJson({String status = 'draft'}) => {
  'id': 'a1',
  'budget_line_id': 'l1',
  'amount': 5000,
  'reason': 'r',
  'status': status,
  'created_at': 'x',
};

Map<String, dynamic> _commitmentJson({String status = 'active'}) => {
  'id': 'c1',
  'cost_code_id': 'cc1',
  'cost_code_code': 'MLZ-001',
  'cost_code_name': 'Hazır Beton',
  'source_type': 'manual',
  'description': 'd',
  'committed_amount': 1500.75,
  'currency': 'TRY',
  'status': status,
  'committed_at': '2026-09-29',
};

void main() {
  test('WBS: GET/POST/PUT/DELETE (arşiv) uçları ve gövdeleri', () async {
    final (repo, requests, adapter) = await _repo({
      '$_p/wbs': [
        (
          status: 200,
          body: {
            'wbs_nodes': [
              {'id': 'w1', 'code': '01', 'name': 'Kaba', 'sort_order': 1, 'is_active': true},
            ],
          },
        ),
        (
          status: 201,
          body: {'id': 'w2', 'parent_id': 'w1', 'code': '01.01', 'name': 'Temel', 'sort_order': 0, 'is_active': true},
        ),
      ],
      '$_p/wbs/w2': [
        (
          status: 200,
          body: {
            'id': 'w2',
            'parent_id': 'w1',
            'code': '01.01',
            'name': 'Temeller',
            'sort_order': 0,
            'is_active': true,
          },
        ),
        (status: 200, body: {'ok': true}),
      ],
    });
    final nodes = await repo.wbsNodes('p1');
    expect(nodes.single.code, '01');
    final created = await repo.createWbsNode('p1', const WbsNodeInput(parentId: 'w1', code: '01.01', name: 'Temel'));
    expect(created.parentId, 'w1');
    await repo.updateWbsNode('p1', 'w2', const WbsNodeInput(code: '01.01', name: 'Temeller'));
    await repo.archiveWbsNode('p1', 'w2');
    expect(requests, ['GET $_p/wbs', 'POST $_p/wbs', 'PUT $_p/wbs/w2', 'DELETE $_p/wbs/w2']);
    expect(adapter.requestBodies[1], {'parent_id': 'w1', 'code': '01.01', 'name': 'Temel', 'sort_order': 0});
  });

  test('Bütçe: 404 -> null (bütçesiz proje), oluştur ve baseline POST', () async {
    final (repo, requests, _) = await _repo({
      '$_p/budget': [
        (status: 404, body: {'error': 'bu proje için henüz bir bütçe oluşturulmamış'}),
        (status: 201, body: _budgetJson()),
      ],
      '$_p/budget/baseline': [(status: 200, body: _budgetJson(status: 'baselined'))],
    });
    expect(await repo.budget('p1'), isNull);
    expect((await repo.createBudget('p1')).isDraft, isTrue);
    expect((await repo.baselineBudget('p1')).isBaselined, isTrue);
    expect(requests, ['GET $_p/budget', 'POST $_p/budget', 'POST $_p/budget/baseline']);
  });

  test('Bütçe: 403 null DEĞİL, hata olarak fırlar', () async {
    final (repo, _, _) = await _repo({
      '$_p/budget': [
        (status: 403, body: {'error': 'bu işlem için yetkiniz yok'}),
      ],
    });
    await expectLater(
      repo.budget('p1'),
      throwsA(isA<ApiException>().having((e) => e.isForbidden, 'isForbidden', isTrue)),
    );
  });

  test('Bütçe kalemleri: 404 -> boş liste; ekle/düzenle/sil', () async {
    final (repo, requests, adapter) = await _repo({
      '$_p/budget/lines': [
        (status: 404, body: {'error': 'bu proje için henüz bir bütçe oluşturulmamış'}),
        (
          status: 200,
          body: {
            'budget_lines': [_lineJson()],
          },
        ),
        (status: 201, body: _lineJson()),
      ],
      '$_p/budget/lines/l1': [
        (status: 200, body: _lineJson()),
        (status: 200, body: {'ok': true}),
      ],
    });
    expect(await repo.budgetLines('p1'), isEmpty);
    final lines = await repo.budgetLines('p1');
    expect(lines.single.quantity, 420);
    const input = BudgetLineInput(costCodeId: 'cc1', description: 'Temel', quantity: 420, unit: 'm³', unitCost: 2350);
    await repo.createBudgetLine('p1', input);
    await repo.updateBudgetLine('p1', 'l1', input);
    await repo.deleteBudgetLine('p1', 'l1');
    expect(requests, [
      'GET $_p/budget/lines',
      'GET $_p/budget/lines',
      'POST $_p/budget/lines',
      'PUT $_p/budget/lines/l1',
      'DELETE $_p/budget/lines/l1',
    ]);
    expect(adapter.requestBodies[2], input.toJson());
  });

  test('Revizyonlar: liste, oluştur (negatif tutar), onayla, reddet', () async {
    final (repo, requests, adapter) = await _repo({
      '$_p/budget/adjustments': [
        (
          status: 200,
          body: {
            'adjustments': [_adjJson()],
          },
        ),
        (status: 201, body: _adjJson()),
      ],
      '$_p/budget/adjustments/a1/approve': [(status: 200, body: _adjJson(status: 'approved'))],
      '$_p/budget/adjustments/a1/reject': [
        (
          status: 409,
          body: {'error': 'yalnızca taslak durumundaki bir bütçe revizyonu onaylanabilir veya reddedilebilir'},
        ),
      ],
    });
    expect((await repo.adjustments('p1')).single.isPending, isTrue);
    await repo.createAdjustment('p1', budgetLineId: 'l1', amount: -25000, reason: 'Kapsam azaldı');
    expect((await repo.approveAdjustment('p1', 'a1')).status, 'approved');
    await expectLater(
      repo.rejectAdjustment('p1', 'a1'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.kind, 'kind', ApiErrorKind.conflict)
            .having((e) => e.message, 'message', contains('yalnızca taslak')),
      ),
    );
    expect(requests, [
      'GET $_p/budget/adjustments',
      'POST $_p/budget/adjustments',
      'POST $_p/budget/adjustments/a1/approve',
      'POST $_p/budget/adjustments/a1/reject',
    ]);
    expect(adapter.requestBodies[1], {'budget_line_id': 'l1', 'amount': -25000.0, 'reason': 'Kapsam azaldı'});
  });

  test('Taahhütler: liste, manuel oluştur (idempotency), iptal (gerekçe)', () async {
    final (repo, requests, adapter) = await _repo({
      '$_p/commitments': [
        (
          status: 200,
          body: {
            'commitments': [_commitmentJson()],
          },
        ),
        (status: 201, body: _commitmentJson()),
      ],
      '$_p/commitments/c1/void': [(status: 200, body: _commitmentJson(status: 'voided'))],
    });
    expect((await repo.commitments('p1')).single.sourceType, 'manual');
    const input = ManualCommitmentInput(
      costCodeId: 'cc1',
      budgetLineId: 'l1',
      description: 'd',
      amount: 1500.75,
      committedAt: '2026-09-29',
      idempotencyKey: 'abc',
    );
    await repo.createCommitment('p1', input);
    expect((await repo.voidCommitment('p1', 'c1', reason: 'Yanlış giriş')).status, 'voided');
    expect(requests, ['GET $_p/commitments', 'POST $_p/commitments', 'POST $_p/commitments/c1/void']);
    expect(adapter.requestBodies[1], input.toJson());
    expect(adapter.requestBodies[2], {'reason': 'Yanlış giriş'});
  });

  test('Tahmin: liste ve PUT /budget/lines/{id}/forecast', () async {
    final (repo, requests, adapter) = await _repo({
      '$_p/forecasts': [
        (
          status: 200,
          body: {
            'forecasts': [
              {'budget_line_id': 'l1', 'etc_amount': 40000, 'note': 'n', 'updated_at': 'x'},
            ],
          },
        ),
      ],
      '$_p/budget/lines/l1/forecast': [
        (status: 200, body: {'budget_line_id': 'l1', 'etc_amount': 80000, 'note': 'yeni', 'updated_at': 'y'}),
      ],
    });
    expect((await repo.forecasts('p1')).single.etcAmount, 40000);
    expect((await repo.upsertForecast('p1', 'l1', etcAmount: 80000, note: 'yeni')).etcAmount, 80000);
    expect(requests, ['GET $_p/forecasts', 'PUT $_p/budget/lines/l1/forecast']);
    expect(adapter.requestBodies[1], {'etc_amount': 80000.0, 'note': 'yeni'});
  });

  test('Maliyet kontrolü, maliyet kodları ve masraflar', () async {
    final (repo, requests, _) = await _repo({
      '$_p/cost-control': [
        (
          status: 200,
          body: {
            'summary': {'currency': 'TRY', 'revised_budget': 100, 'eac': 120, 'variance': -20, 'has_budget': true},
            'lines': [
              {
                'cost_code_id': 'cc1',
                'cost_code_code': 'MLZ-001',
                'cost_code_name': 'Beton',
                'variance': -20,
                'is_unbudgeted': true,
              },
            ],
          },
        ),
      ],
      '/organization/cost-codes': [
        (
          status: 200,
          body: {
            'cost_codes': [
              {'id': 'cc1', 'code': 'MLZ-001', 'name': 'Beton', 'is_active': true},
            ],
          },
        ),
      ],
      '$_p/expenses': [
        (
          status: 200,
          body: {
            'expenses': [
              {'id': 'e1', 'description': 'd', 'amount': 10, 'cost_code_id': 'cc1'},
            ],
          },
        ),
      ],
    });
    final cc = await repo.costControl('p1');
    expect(cc.summary.variance, -20);
    expect(cc.lines.single.isUnbudgeted, isTrue);
    expect((await repo.costCodes()).single.code, 'MLZ-001');
    expect((await repo.expenses('p1')).single.costCodeId, 'cc1');
    expect(requests, ['GET $_p/cost-control', 'GET /organization/cost-codes', 'GET $_p/expenses']);
  });
}
