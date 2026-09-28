import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/auth/permissions.dart';
import 'package:arvend/core/config/app_config.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/cost_codes/data/cost_codes_repository.dart';
import 'package:arvend/features/cost_codes/domain/cost_code.dart';

import '../../test_utils/fake_api_client.dart';
import 'cost_codes_test_support.dart';

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

Map<String, dynamic> _json({String id = 'c1', bool isActive = true}) => {
      'id': id,
      'code': 'MLZ-001',
      'name': 'Hazır Beton',
      'description': 'C30/37',
      'category': 'Malzeme',
      'is_active': isActive,
    };

void main() {
  group('OrganizationCostCode.fromJson', () {
    test('reads the backend costCodeResponse fields', () {
      final c = OrganizationCostCode.fromJson(_json());
      expect(c.id, 'c1');
      expect(c.code, 'MLZ-001');
      expect(c.name, 'Hazır Beton');
      expect(c.description, 'C30/37');
      expect(c.category, 'Malzeme');
      expect(c.isActive, isTrue);
    });

    test('missing optional fields default cleanly', () {
      final c = OrganizationCostCode.fromJson({'id': 'x', 'code': 'K', 'name': 'N'});
      expect(c.description, '');
      expect(c.category, '');
      expect(c.isActive, isTrue);
    });
  });

  group('CostCodesRepository HTTP contract (same calls as the web)', () {
    test('list GETs /organization/cost-codes and parses {cost_codes: [...]}', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/cost-codes': [
          (status: 200, body: {'cost_codes': [_json(), _json(id: 'c2', isActive: false)]}),
        ],
      });
      final (client, requests) = await _client(adapter);
      final list = await CostCodesRepository(client).list();
      expect(list.map((c) => c.id), ['c1', 'c2']);
      expect(requests, ['GET /organization/cost-codes']);
    });

    test('create POSTs {code, name, description, category}', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/cost-codes': [(status: 201, body: _json(id: 'new'))],
      });
      final (client, requests) = await _client(adapter);
      await CostCodesRepository(client).create(
        code: 'MLZ-001',
        input: const CostCodeInput(name: 'Hazır Beton', description: 'C30/37', category: 'Malzeme'),
      );
      expect(requests, ['POST /organization/cost-codes']);
      expect(adapter.requestBodies.single, {
        'code': 'MLZ-001',
        'name': 'Hazır Beton',
        'description': 'C30/37',
        'category': 'Malzeme',
      });
    });

    test('update PUTs WITHOUT a code (the code is immutable; backend never writes it)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/cost-codes/c1': [(status: 200, body: _json())],
      });
      final (client, requests) = await _client(adapter);
      await CostCodesRepository(client).update('c1', const CostCodeInput(name: 'Beton', category: 'Malzeme'));
      expect(requests, ['PUT /organization/cost-codes/c1']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body.containsKey('code'), isFalse);
      expect(body, {'name': 'Beton', 'description': '', 'category': 'Malzeme'});
    });

    test('archive is DELETE /{id} (soft) and reactivate is POST /{id}/reactivate', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/cost-codes/c1': [(status: 200, body: {'ok': true})],
        '/organization/cost-codes/c1/reactivate': [(status: 200, body: {'ok': true})],
      });
      final (client, requests) = await _client(adapter);
      final repo = CostCodesRepository(client);
      await repo.archive('c1');
      await repo.reactivate('c1');
      expect(requests, ['DELETE /organization/cost-codes/c1', 'POST /organization/cost-codes/c1/reactivate']);
    });

    test('403 is a forbidden ApiException', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/cost-codes': [(status: 403, body: {'error': 'bu işlem için yetkiniz yok'})],
      });
      final (client, _) = await _client(adapter);
      await expectLater(
        CostCodesRepository(client).list(),
        throwsA(isA<ApiException>().having((e) => e.isForbidden, 'isForbidden', isTrue)),
      );
    });
  });

  group('filterCostCodes (web parity: code / name / category, active by default)', () {
    test('default hides archived codes', () {
      expect(filterCostCodes(kCostCodeFixtures).any((c) => c.id == 'c7'), isFalse);
      expect(filterCostCodes(kCostCodeFixtures).length, 8);
    });

    test('archived / all', () {
      expect(filterCostCodes(kCostCodeFixtures, status: CostCodeStatusFilter.archived).map((c) => c.id), ['c7']);
      expect(filterCostCodes(kCostCodeFixtures, status: CostCodeStatusFilter.all).length, 9);
    });

    test('search by code, name and category with Turkish folding (description is not searched, like the web)', () {
      expect(filterCostCodes(kCostCodeFixtures, query: 'ekp').map((c) => c.id), ['c1']);
      expect(filterCostCodes(kCostCodeFixtures, query: 'BETON').map((c) => c.id), ['c5']);
      expect(filterCostCodes(kCostCodeFixtures, query: 'IŞÇILIK').map((c) => c.id), ['c3', 'c4']);
      expect(filterCostCodes(kCostCodeFixtures, query: 'pompalı'), isEmpty);
    });
  });

  group('groupCostCodesByCategory', () {
    test('Turkish alphabetical category order, uncategorized last, case/space variants merged', () {
      final groups = groupCostCodesByCategory(filterCostCodes(kCostCodeFixtures));
      expect(groups.map((g) => g.category), ['Ekipman', 'İşçilik', 'Malzeme', 'Taşeron', kUncategorizedLabel]);
      expect(groups[2].codes.map((c) => c.id), ['c5', 'c6', 'c8']);
      expect(groups.last.isUncategorized, isTrue);
      expect(groups.last.codes.single.id, 'c2');
    });

    test('distinctCategories feeds the form quick-pick', () {
      expect(distinctCategories(kCostCodeFixtures), ['Ekipman', 'İşçilik', 'Malzeme', 'Taşeron']);
      expect(distinctCategories(const []), isEmpty);
    });

    test('compareTurkish orders Ç/Ğ/İ/Ö/Ş/Ü correctly', () {
      final words = ['Taşeron', 'Şantiye', 'İşçilik', 'Işık', 'Çelik', 'Ekipman', 'Cam', 'Ölçüm', 'Ulaşım', 'Ücret'];
      words.sort(compareTurkish);
      expect(words, ['Cam', 'Çelik', 'Ekipman', 'Işık', 'İşçilik', 'Ölçüm', 'Şantiye', 'Taşeron', 'Ulaşım', 'Ücret']);
    });
  });

  group('strict canAccess for cost code permissions', () {
    test('owner and non-admin finance can manage; read-only cannot; empty set and null get nothing', () {
      expect(ccOwnerUser.canAccess(kCostCodesManagePermission), isTrue);
      expect(ccFinanceUser.canAccess(kCostCodesManagePermission), isTrue);
      expect(ccReadOnlyUser.canAccess(kCostCodesReadPermission), isTrue);
      expect(ccReadOnlyUser.canAccess(kCostCodesManagePermission), isFalse);
      expect(ccEmptyPermissionsUser.canAccess(kCostCodesReadPermission), isFalse);
      expect(ccNoAccessUser.canAccess(kCostCodesReadPermission), isFalse);
      const User? nobody = null;
      expect(nobody.canAccess(kCostCodesReadPermission), isFalse);
    });
  });
}
