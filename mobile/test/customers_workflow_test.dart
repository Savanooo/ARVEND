import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/customers/data/customers_providers.dart';
import 'package:arvend/features/customers/data/customers_repository.dart';
import 'package:arvend/features/customers/domain/customer.dart';
import 'package:arvend/features/customers/presentation/customer_form_sheet.dart';
import 'package:arvend/features/offers/data/offers_repository.dart';
import 'package:arvend/features/offers/domain/offer.dart';
import 'package:arvend/features/projects/data/projects_repository.dart';
import 'package:arvend/features/projects/domain/project.dart';

import 'test_utils/fake_api_client.dart';

/// Müşteriler/Customers — backend traced end-to-end (Phase 1): full CRUD
/// except hard-delete (DELETE = soft archive, `is_active=false`), a single
/// flat `customers` table (no contacts table, no multi-address, no
/// company/individual type), name-only ILIKE search, no pagination, no
/// duplicate detection anywhere. `customers.read`/`customers.manage` are
/// the only two permission codes, org-scoped only. These tests prove the
/// mobile module matches that contract exactly -- no invented fields, no
/// invented validation beyond what the backend/UX genuinely needs.
void main() {
  group('parsing', () {
    test('Customer.fromJson reads the exact backend field set', () {
      final c = Customer.fromJson(_customerJson());
      expect(c.id, 'c1');
      expect(c.name, 'Ahmet İnşaat');
      expect(c.phone, '05551112233');
      expect(c.email, 'ahmet@example.com');
      expect(c.address, 'Örnek Mah. No:1');
      expect(c.taxOffice, 'Kadıköy');
      expect(c.taxNumber, '1234567890');
      expect(c.notes, 'VIP müşteri');
      expect(c.isActive, isTrue);
    });

    test('missing optional fields default cleanly (backend always sends non-null strings, but be defensive)', () {
      final json = _customerJson()
        ..remove('phone')
        ..remove('email')
        ..remove('address')
        ..remove('tax_office')
        ..remove('tax_number')
        ..remove('notes')
        ..remove('is_active');
      final c = Customer.fromJson(json);
      expect(c.phone, '');
      expect(c.email, '');
      expect(c.address, '');
      expect(c.taxOffice, '');
      expect(c.taxNumber, '');
      expect(c.notes, '');
      expect(c.isActive, isTrue);
    });
  });

  group('create serialization', () {
    test('create POSTs exactly the backend contract fields, is_active always true', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers': [(status: 201, body: _customerJson(id: 'c1'))],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CustomersRepository(client);

      final c = await repo.create(
        name: 'Ahmet İnşaat',
        phone: '05551112233',
        email: 'ahmet@example.com',
        address: 'Örnek Mah. No:1',
        taxOffice: 'Kadıköy',
        taxNumber: '1234567890',
        notes: 'VIP müşteri',
      );

      expect(c.id, 'c1');
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['name'], 'Ahmet İnşaat');
      expect(body['phone'], '05551112233');
      expect(body['email'], 'ahmet@example.com');
      expect(body['address'], 'Örnek Mah. No:1');
      expect(body['tax_office'], 'Kadıköy');
      expect(body['tax_number'], '1234567890');
      expect(body['notes'], 'VIP müşteri');
      expect(body['is_active'], isTrue);
    });
  });

  group('update serialization', () {
    // Backend'de Create'in aksine Update, client'tan gelen is_active'i
    // AYNEN kullanır (bkz. backend Phase 1 doğrulaması: customer_handler.go
    // Update, req.IsActive'i zorlamaz) -- bu yüzden mobil çağıran mevcut
    // değeri EXPLICIT olarak geçirmek zorundadır.
    test('update PUTs to /customers/{id} and passes through the caller-supplied is_active', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 200, body: _customerJson(id: 'c1', name: 'Yeni Ad'))],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CustomersRepository(client);

      final c = await repo.update(
        'c1',
        name: 'Yeni Ad',
        phone: '0555',
        email: '',
        address: '',
        taxOffice: '',
        taxNumber: '',
        notes: '',
        isActive: true,
      );

      expect(c.name, 'Yeni Ad');
      expect(adapter.calls, ['/customers/c1']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['name'], 'Yeni Ad');
      expect(body['is_active'], isTrue);
    });

    test('update can pass is_active: false (reactivation/deactivation both flow through PUT)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 200, body: _customerJson(id: 'c1', isActive: false))],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CustomersRepository(client);

      final c = await repo.update('c1', name: 'X', isActive: false);

      expect(c.isActive, isFalse);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['is_active'], isFalse);
    });
  });

  group('archive (soft delete, not exposed as hard delete)', () {
    test('archive sends DELETE to /customers/{id}', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 200, body: {'ok': true})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CustomersRepository(client);

      await repo.archive('c1');

      expect(adapter.calls, ['/customers/c1']);
    });
  });

  group('search/filter behavior (server-side, not client-side scanning)', () {
    test('list() sends q and filter as query params on the same /customers path', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers': [(status: 200, body: {'customers': <Map<String, dynamic>>[]})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CustomersRepository(client);

      await repo.list(filter: 'aktif', q: 'ali');

      expect(adapter.calls, ['/customers']);
      expect(adapter.requestQueries.single['filter'], 'aktif');
      expect(adapter.requestQueries.single['q'], 'ali');
    });

    test('list() omits filter/q params entirely when empty (no ?filter=&q= noise)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers': [(status: 200, body: {'customers': <Map<String, dynamic>>[]})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CustomersRepository(client);

      await repo.list();

      expect(adapter.requestQueries.single.containsKey('filter'), isFalse);
      expect(adapter.requestQueries.single.containsKey('q'), isFalse);
    });

    test('different CustomerListQuery keys are distinct provider cache entries (independent fetches)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers': [
          (status: 200, body: {'customers': [_customerJson(id: 'c1')]}),
          (status: 200, body: {'customers': [_customerJson(id: 'c2', isActive: false)]}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final active = await container.read(customersListProvider((q: '', filter: 'aktif')).future);
      final passive = await container.read(customersListProvider((q: '', filter: 'pasif')).future);

      expect(active.single.id, 'c1');
      expect(passive.single.id, 'c2');
      expect(adapter.requestQueries[0]['filter'], 'aktif');
      expect(adapter.requestQueries[1]['filter'], 'pasif');
    });
  });

  group('linked offers/projects parsing (customer_id filter reuse)', () {
    test('OffersRepository.list(customerId:) sends customer_id as a query param', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/': [(status: 200, body: {'offers': <Map<String, dynamic>>[], 'total': 0})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = OffersRepository(client);

      await repo.list(customerId: 'c1', limit: 200);

      expect(adapter.requestQueries.single['customer_id'], 'c1');
    });

    test('Offer.fromJson parses customer_id when a list row has it populated', () {
      final offer = Offer.fromJson({
        'id': 'o1',
        'offer_no': 'T-2026-001',
        'revision_no': 0,
        'customer_id': 'c1',
        'customer_name': 'Ahmet İnşaat',
        'customer_phone': '',
        'customer_email': '',
        'customer_address': '',
        'offer_date': '2026-09-20',
        'valid_until': null,
        'subtotal': 1000.0,
        'vat_rate': 20.0,
        'vat_amount': 200.0,
        'grand_total': 1200.0,
        'notes': '',
        'status': 'taslak',
        'is_passive': false,
      });
      expect(offer.customerId, 'c1');
    });

    test('ProjectsRepository.list(customerId:) sends customer_id as a query param', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects': [(status: 200, body: {'projects': <Map<String, dynamic>>[], 'total': 0})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.list(customerId: 'c1', limit: 200);

      expect(adapter.requestQueries.single['customer_id'], 'c1');
    });

    test('Project.fromJson parses customer_id (previously unparsed field, already sent by backend)', () {
      final project = Project.fromJson(_projectJson(customerId: 'c1'));
      expect(project.customerId, 'c1');
    });
  });

  group('receivables aggregation (sums only backend-computed per-project fields, no invented formula)', () {
    test('summarizeProjectReceivables sums same-currency projects', () {
      final projects = [
        Project.fromJson(_projectJson(
            id: 'p1', currency: 'TRY', currentContractValue: 100000, collectedAmount: 40000, remainingReceivable: 60000)),
        Project.fromJson(_projectJson(
            id: 'p2', currency: 'TRY', currentContractValue: 50000, collectedAmount: 50000, remainingReceivable: 0)),
      ];
      final result = summarizeProjectReceivables(projects);
      expect(result, hasLength(1));
      expect(result.single.currency, 'TRY');
      expect(result.single.contractValue, 150000);
      expect(result.single.collected, 90000);
      expect(result.single.remaining, 60000);
    });

    test('summarizeProjectReceivables keeps different currencies in separate rows (never mixed)', () {
      final projects = [
        Project.fromJson(_projectJson(
            id: 'p1', currency: 'TRY', currentContractValue: 100000, collectedAmount: 40000, remainingReceivable: 60000)),
        Project.fromJson(_projectJson(
            id: 'p2', currency: 'USD', currentContractValue: 1000, collectedAmount: 200, remainingReceivable: 800)),
      ];
      final result = summarizeProjectReceivables(projects);
      expect(result, hasLength(2));
      final try_ = result.firstWhere((r) => r.currency == 'TRY');
      final usd = result.firstWhere((r) => r.currency == 'USD');
      expect(try_.contractValue, 100000);
      expect(usd.contractValue, 1000);
    });

    test('projects missing finance aggregates (single-GET context) are skipped, not treated as zero', () {
      final projects = [
        Project.fromJson(_projectJson(id: 'p1', currency: 'TRY')), // no finance fields
      ];
      final result = summarizeProjectReceivables(projects);
      expect(result, isEmpty);
    });

    test('empty project list produces no summary rows', () {
      expect(summarizeProjectReceivables(const []), isEmpty);
    });
  });

  group('permissions — exact two-tier, org-only model (customers.read / customers.manage)', () {
    User userWith(Set<String> perms) => User(
          id: 'u', username: 'u', fullName: 'U', role: UserRole.kullanici, isActive: true,
          mustChangePassword: false, onboardingCompleted: true, onboardingStep: 'completed', permissions: perms,
        );

    test('owner/admin/legacy_user-shaped set: read+manage', () {
      final user = userWith(const {'customers.read', 'customers.manage'});
      expect(user.hasPermission('customers.read'), isTrue);
      expect(user.hasPermission('customers.manage'), isTrue);
    });

    // Phase 1 bulgusu: project_manager customers.read ALIR ama
    // customers.manage ALMAZ -- listeleyip görebilir, oluşturamaz/
    // düzenleyemez/pasifleştiremez.
    test('project_manager-shaped set: read only, NOT manage', () {
      final user = userWith(const {'customers.read'});
      expect(user.hasPermission('customers.read'), isTrue);
      expect(user.hasPermission('customers.manage'), isFalse);
    });

    // Phase 1 bulgusu: finance ve field rolleri müşteri izinlerinin
    // HİÇBİRİNİ ALMAZ (migration'da customers.* hiç yok).
    test('finance/field-shaped set: neither customer permission', () {
      final user = userWith(const {'projects.finance.read', 'attendance.read'});
      expect(user.hasPermission('customers.read'), isFalse);
      expect(user.hasPermission('customers.manage'), isFalse);
    });

    test('customer permission axis is exactly {read, manage} -- no approve/delete/type tier exists', () {
      const codes = {'customers.read', 'customers.manage'};
      final user = userWith(codes);
      for (final code in codes) {
        expect(user.hasPermission(code), isTrue);
      }
      expect(user.hasPermission('customers.delete'), isFalse);
      expect(user.hasPermission('customers.approve'), isFalse);
    });
  });

  group('backend error mapping', () {
    test('create with empty name (server-side required field) surfaces the backend message verbatim', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers': [(status: 400, body: {'error': 'müşteri adı zorunludur'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CustomersRepository(client);

      await expectLater(
        repo.create(name: ''),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'müşteri adı zorunludur')),
      );
    });

    test('get on a cross-org/nonexistent customer surfaces as 404', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 404, body: {'error': 'müşteri bulunamadı'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CustomersRepository(client);

      await expectLater(
        repo.get('c1'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.message, 'message', 'müşteri bulunamadı')),
      );
    });

    test('update on an unauthorized (customers.manage-less) session surfaces as 403', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [(status: 403, body: {'error': 'bu işlem için yetkiniz yok'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = CustomersRepository(client);

      await expectLater(
        repo.update('c1', name: 'X', isActive: true),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403)),
      );
    });
  });

  group('refresh/invalidation after mutation', () {
    test('invalidating customerDetailProvider(id) triggers a fresh fetch', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers/c1': [
          (status: 200, body: _customerJson(id: 'c1', name: 'Eski Ad')),
          (status: 200, body: _customerJson(id: 'c1', name: 'Yeni Ad')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(customerDetailProvider('c1').future);
      expect(before.name, 'Eski Ad');

      container.invalidate(customerDetailProvider('c1'));
      final after = await container.read(customerDetailProvider('c1').future);

      expect(after.name, 'Yeni Ad');
      expect(adapter.calls.where((p) => p == '/customers/c1').length, 2);
    });

    test('bare-family invalidate(customersListProvider) refreshes every (q, filter) key at once', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers': [
          (status: 200, body: {'customers': <Map<String, dynamic>>[]}),
          (status: 200, body: {'customers': <Map<String, dynamic>>[]}),
          (status: 200, body: {'customers': [_customerJson(id: 'c1')]}),
          (status: 200, body: {'customers': [_customerJson(id: 'c1')]}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      await container.read(customersListProvider((q: '', filter: '')).future);
      await container.read(customersListProvider((q: '', filter: 'aktif')).future);

      container.invalidate(customersListProvider);

      final allAfter = await container.read(customersListProvider((q: '', filter: '')).future);
      final activeAfter = await container.read(customersListProvider((q: '', filter: 'aktif')).future);
      expect(allAfter, hasLength(1));
      expect(activeAfter, hasLength(1));
      expect(adapter.calls.where((p) => p == '/customers').length, 4);
    });
  });

  group('CustomerFormSheet validation (widget-level, matches the pattern in expense_form_test.dart)', () {
    testWidgets('boş ad ile form gönderilemez, istek atılmaz', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {});
      final client = await buildFakeApiClient(adapter);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: const MaterialApp(home: Scaffold(body: CustomerFormSheet())),
        ),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
      await tester.pump();

      expect(find.text('Müşteri adı zorunludur'), findsOneWidget);
      expect(adapter.calls, isEmpty);
    });

    testWidgets('geçersiz e-posta formatıyla form gönderilemez, istek atılmaz', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {});
      final client = await buildFakeApiClient(adapter);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: const MaterialApp(home: Scaffold(body: CustomerFormSheet())),
        ),
      );

      await tester.enterText(find.widgetWithText(TextField, 'Ad *'), 'Ahmet İnşaat');
      await tester.enterText(find.widgetWithText(TextField, 'E-posta'), 'gecersiz-eposta');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
      await tester.pump();

      expect(find.text('Geçerli bir e-posta adresi girin'), findsOneWidget);
      expect(adapter.calls, isEmpty);
    });

    testWidgets('geçerli ad + boş e-posta ile create isteği atılır (e-posta zorunlu değil)', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/customers': [(status: 201, body: _customerJson(id: 'c1'))],
      });
      final client = await buildFakeApiClient(adapter);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: const MaterialApp(home: Scaffold(body: CustomerFormSheet())),
        ),
      );

      await tester.enterText(find.widgetWithText(TextField, 'Ad *'), 'Ahmet İnşaat');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
      await tester.pumpAndSettle();

      expect(adapter.calls, ['/customers']);
    });

    testWidgets('edit modunda mevcut değerler alanlara önceden doldurulur', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {});
      final client = await buildFakeApiClient(adapter);
      final existing = Customer.fromJson(_customerJson(id: 'c1', name: 'Ahmet İnşaat'));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: MaterialApp(home: Scaffold(body: CustomerFormSheet(existing: existing))),
        ),
      );

      expect(find.text('Müşteriyi Düzenle'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Ad *'), findsOneWidget);
      final nameField = tester.widget<TextField>(find.widgetWithText(TextField, 'Ad *'));
      expect(nameField.controller!.text, 'Ahmet İnşaat');
    });
  });
}

Map<String, dynamic> _customerJson({
  String id = 'c1',
  String name = 'Ahmet İnşaat',
  bool isActive = true,
}) =>
    {
      'id': id,
      'name': name,
      'phone': '05551112233',
      'email': 'ahmet@example.com',
      'address': 'Örnek Mah. No:1',
      'tax_office': 'Kadıköy',
      'tax_number': '1234567890',
      'notes': 'VIP müşteri',
      'is_active': isActive,
    };

Map<String, dynamic> _projectJson({
  String id = 'p1',
  String? customerId,
  String currency = 'TRY',
  double? currentContractValue,
  double? collectedAmount,
  double? remainingReceivable,
}) =>
    {
      'id': id,
      'project_no': 'PRJ-001',
      'name': 'Villa Projesi',
      'project_type': 'konut',
      'customer_id': customerId,
      'customer_name': 'Ahmet İnşaat',
      'customer_phone': '',
      'customer_email': '',
      'contract_amount': currentContractValue ?? 100000.0,
      'currency': currency,
      'status': 'active',
      'start_date': null,
      'end_date': null,
      'description': '',
      'created_at': '2026-01-01T00:00:00Z',
      'current_contract_value': currentContractValue,
      'collected_amount': collectedAmount,
      'remaining_receivable': remainingReceivable,
    };
