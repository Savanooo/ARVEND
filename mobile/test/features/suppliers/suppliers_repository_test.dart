import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/auth/permissions.dart';
import 'package:arvend/core/config/app_config.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/suppliers/data/suppliers_repository.dart';
import 'package:arvend/features/suppliers/domain/supplier.dart';

import '../../test_utils/fake_api_client.dart';
import 'suppliers_test_support.dart';

/// Sahte HTTP adaptörü + HTTP yöntemini de kaydeden bir interceptor --
/// DELETE (arşivle) ile POST (etkinleştir) ayrımı yalnızca yol ile
/// doğrulanamaz.
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

Map<String, dynamic> _supplierJson({String id = 's1', bool ibanSet = true, bool isActive = true}) => {
      'id': id,
      'code': 'TED-001',
      'legal_name': 'Kaya Yapı Malzemeleri A.Ş.',
      'trade_name': 'Kaya Yapı',
      'tax_number': '5840123456',
      'tax_office': 'Kozyatağı',
      'contact_name': 'Ahmet Kaya',
      'email': 'satis@kayayapi.com.tr',
      'phone': '0216 555 10 20',
      'address': 'Sanayi Cad. No:12',
      'city': 'İstanbul',
      'country': 'Türkiye',
      'specialty': 'Kaba yapı',
      'iban_set': ibanSet,
      'is_active': isActive,
      'notes': 'Vade 30 gün',
      'created_at': '2026-09-12T09:00:00Z',
      'updated_at': '2026-09-27T11:30:00Z',
    };

void main() {
  group('OrganizationSupplier.fromJson', () {
    test('reads every backend supplierResponse field; the IBAN itself is never part of the model', () {
      final s = OrganizationSupplier.fromJson(_supplierJson());
      expect(s.id, 's1');
      expect(s.code, 'TED-001');
      expect(s.legalName, 'Kaya Yapı Malzemeleri A.Ş.');
      expect(s.tradeName, 'Kaya Yapı');
      expect(s.taxNumber, '5840123456');
      expect(s.taxOffice, 'Kozyatağı');
      expect(s.contactName, 'Ahmet Kaya');
      expect(s.email, 'satis@kayayapi.com.tr');
      expect(s.phone, '0216 555 10 20');
      expect(s.address, 'Sanayi Cad. No:12');
      expect(s.city, 'İstanbul');
      expect(s.country, 'Türkiye');
      expect(s.specialty, 'Kaba yapı');
      expect(s.ibanSet, isTrue);
      expect(s.isActive, isTrue);
      expect(s.notes, 'Vade 30 gün');
      expect(s.createdAt, '2026-09-12T09:00:00Z');
      expect(s.updatedAt, '2026-09-27T11:30:00Z');
    });

    test('missing optional fields default to empty strings / false', () {
      final s = OrganizationSupplier.fromJson({'id': 'x', 'code': 'C', 'legal_name': 'L'});
      expect(s.tradeName, '');
      expect(s.specialty, '');
      expect(s.ibanSet, isFalse);
      expect(s.isActive, isTrue);
    });

    test('contactSummary follows the web "İletişim" column: contact name, else phone, else e-mail', () {
      expect(const OrganizationSupplier(id: 'a', code: 'A', legalName: 'A', contactName: 'Ali', phone: '1').contactSummary, 'Ali');
      expect(const OrganizationSupplier(id: 'a', code: 'A', legalName: 'A', phone: '1', email: 'e').contactSummary, '1');
      expect(const OrganizationSupplier(id: 'a', code: 'A', legalName: 'A', email: 'e').contactSummary, 'e');
      expect(const OrganizationSupplier(id: 'a', code: 'A', legalName: 'A').contactSummary, '');
    });
  });

  group('SupplierInput.toJson (IBAN write-only semantics)', () {
    const base = SupplierInput(code: 'TED-9', legalName: 'Yeni Tedarikçi', country: 'Türkiye', specialty: 'Elektrik');

    test('null IBAN -> the key is absent (backend keeps the stored IBAN unchanged)', () {
      expect(base.toJson().containsKey('iban'), isFalse);
    });

    test('empty / whitespace IBAN -> also absent (never sends "" which would CLEAR it)', () {
      const blank = SupplierInput(code: 'C', legalName: 'L', iban: '   ');
      expect(blank.toJson().containsKey('iban'), isFalse);
    });

    test('filled IBAN is sent; every other backend field is always present (specialty preserved)', () {
      const withIban = SupplierInput(code: 'C', legalName: 'L', iban: 'TR330006100519786457841326', specialty: 'Boya');
      final json = withIban.toJson();
      expect(json['iban'], 'TR330006100519786457841326');
      expect(json.keys.toSet(), {
        'code',
        'legal_name',
        'trade_name',
        'tax_number',
        'tax_office',
        'contact_name',
        'email',
        'phone',
        'address',
        'city',
        'country',
        'specialty',
        'iban',
        'notes',
      });
      expect(json['specialty'], 'Boya');
    });
  });

  group('SuppliersRepository HTTP contract', () {
    test('list GETs /organization/suppliers and parses {suppliers: [...]}', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/suppliers': [
          (status: 200, body: {'suppliers': [_supplierJson(), _supplierJson(id: 's2', isActive: false)]}),
        ],
      });
      final (client, requests) = await _client(adapter);
      final list = await SuppliersRepository(client).list();
      expect(list.map((s) => s.id), ['s1', 's2']);
      expect(list[1].isActive, isFalse);
      expect(requests, ['GET /organization/suppliers']);
    });

    test('get GETs /organization/suppliers/{id}', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/suppliers/s1': [(status: 200, body: _supplierJson())],
      });
      final (client, requests) = await _client(adapter);
      final s = await SuppliersRepository(client).get('s1');
      expect(s.legalName, 'Kaya Yapı Malzemeleri A.Ş.');
      expect(requests, ['GET /organization/suppliers/s1']);
    });

    test('create POSTs the input body', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/suppliers': [(status: 201, body: _supplierJson(id: 'new'))],
      });
      final (client, requests) = await _client(adapter);
      final s = await SuppliersRepository(client).create(
        const SupplierInput(code: 'TED-001', legalName: 'Kaya', country: 'Türkiye', iban: 'TR330006100519786457841326'),
      );
      expect(s.id, 'new');
      expect(requests, ['POST /organization/suppliers']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['code'], 'TED-001');
      expect(body['legal_name'], 'Kaya');
      expect(body['iban'], 'TR330006100519786457841326');
    });

    test('update PUTs /organization/suppliers/{id} without an iban key when unchanged', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/suppliers/s1': [(status: 200, body: _supplierJson())],
      });
      final (client, requests) = await _client(adapter);
      await SuppliersRepository(client).update('s1', const SupplierInput(code: 'TED-001', legalName: 'Kaya'));
      expect(requests, ['PUT /organization/suppliers/s1']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body.containsKey('iban'), isFalse);
    });

    test('archive is DELETE /{id} (soft archive) and reactivate is POST /{id}/reactivate; 204 bodies are fine',
        () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/suppliers/s1': [(status: 204, body: null)],
        '/organization/suppliers/s1/reactivate': [(status: 204, body: null)],
      });
      final (client, requests) = await _client(adapter);
      final repo = SuppliersRepository(client);
      await repo.archive('s1');
      await repo.reactivate('s1');
      expect(requests, ['DELETE /organization/suppliers/s1', 'POST /organization/suppliers/s1/reactivate']);
    });

    test('403 surfaces as a forbidden ApiException (screens turn it into a message, never a crash)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/suppliers': [
          (status: 403, body: {'error': 'bu işlem için yetkiniz yok', 'code': 'permission_denied'}),
        ],
      });
      final (client, _) = await _client(adapter);
      await expectLater(
        SuppliersRepository(client).list(),
        throwsA(isA<ApiException>().having((e) => e.isForbidden, 'isForbidden', isTrue)),
      );
    });
  });

  group('filterSuppliers (web parity: code / legal name / trade name, active by default)', () {
    test('default shows only active suppliers', () {
      final ids = filterSuppliers(kSupplierFixtures).map((s) => s.id);
      expect(ids, ['s1', 's2', 's3', 's5']);
    });

    test('archived and all filters', () {
      expect(filterSuppliers(kSupplierFixtures, status: SupplierStatusFilter.archived).map((s) => s.id), ['s4']);
      expect(filterSuppliers(kSupplierFixtures, status: SupplierStatusFilter.all).length, 5);
    });

    test('search matches code, legal name and trade name -- not city/contact (same fields as the web)', () {
      expect(filterSuppliers(kSupplierFixtures, query: 'ted-002').map((s) => s.id), ['s2']);
      expect(filterSuppliers(kSupplierFixtures, query: 'çelik').map((s) => s.id), ['s2']);
      expect(filterSuppliers(kSupplierFixtures, query: 'ege elektrik').map((s) => s.id), ['s3']);
      expect(filterSuppliers(kSupplierFixtures, query: 'Ankara'), isEmpty);
    });

    test('Turkish case folding: İ/I/ı/i are equivalent', () {
      expect(
        filterSuppliers(kSupplierFixtures, query: 'IŞIK', status: SupplierStatusFilter.all).map((s) => s.id),
        ['s4'],
      );
      expect(filterSuppliers(kSupplierFixtures, query: 'KAYA YAPI').map((s) => s.id), ['s1']);
      expect(foldForSearch('İSTANBUL'), foldForSearch('istanbul'));
    });
  });

  group('IBAN validation', () {
    test('normalizes spaces and case', () {
      expect(normalizeIban(' tr33 0006 1005 1978 6457 8413 26 '), 'TR330006100519786457841326');
    });

    test('accepts a valid TR IBAN and a valid foreign IBAN', () {
      expect(isValidIban('TR330006100519786457841326'), isTrue);
      expect(isValidIban('DE89370400440532013000'), isTrue);
    });

    test('rejects a wrong check digit, a wrong TR length and garbage', () {
      expect(isValidIban('TR340006100519786457841326'), isFalse);
      expect(isValidIban('TR33000610051978645784132'), isFalse);
      expect(isValidIban('12345'), isFalse);
      expect(isValidIban(''), isFalse);
    });
  });

  group('strict canAccess for supplier permissions (fail-closed)', () {
    test('owner and a non-admin manager can manage (no requireAdmin on suppliers)', () {
      expect(ownerUser.canAccess(kSuppliersManagePermission), isTrue);
      expect(managerUser.canAccess(kSuppliersManagePermission), isTrue);
      expect(managerUser.role, UserRole.kullanici);
    });

    test('read-only user can read but not manage', () {
      expect(readOnlyUser.canAccess(kSuppliersReadPermission), isTrue);
      expect(readOnlyUser.canAccess(kSuppliersManagePermission), isFalse);
    });

    test('empty permission set and a missing user get no access', () {
      expect(emptyPermissionsUser.canAccess(kSuppliersReadPermission), isFalse);
      const User? nobody = null;
      expect(nobody.canAccess(kSuppliersReadPermission), isFalse);
      expect(noAccessUser.canAccess(kSuppliersReadPermission), isFalse);
    });
  });
}
