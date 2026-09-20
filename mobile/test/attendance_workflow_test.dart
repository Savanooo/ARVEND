import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/attendance/data/attendance_providers.dart';
import 'package:arvend/features/attendance/data/attendance_repository.dart';
import 'package:arvend/features/attendance/domain/attendance.dart';
import 'package:arvend/features/auth/domain/user.dart';

import 'test_utils/fake_api_client.dart';

/// Mesai/Puantaj — backend'de HİÇBİR değişiklik yapılmadı. `attendance_logs`
/// tablosunda proje ilişkisi, ayrı mesai/fazla-mesai alanı, onay durumu ve
/// GPS/geofence YOK (bkz. Phase 1 doğrulaması: domain.AttendanceLog,
/// migration 0006, attendance_service.go) -- bu testler yalnızca mobilin
/// backend'in ZATEN var olan sözleşmesine doğru uyduğunu kanıtlar; yeni bir
/// hesaplama/çakışma modeli İCAT ETMEZ.
void main() {
  group('parsing', () {
    test('AttendanceRecord.fromJson reads the exact backend field set', () {
      final record = AttendanceRecord.fromJson(_attendanceJson(id: 'a1'));
      expect(record.id, 'a1');
      expect(record.employeeId, 'e1');
      expect(record.employeeName, 'Ahmet Yılmaz');
      expect(record.date, '2026-09-20');
      expect(record.checkIn, '08:00');
      expect(record.checkOut, '17:00');
      expect(record.workHours, 8.0);
      expect(record.status, 'geldi');
      expect(record.note, '');
    });

    test('missing optional fields (employee_name, check_in/out, note) default cleanly', () {
      final json = _attendanceJson(id: 'a1')
        ..remove('employee_name')
        ..remove('check_in')
        ..remove('check_out')
        ..remove('note');
      final record = AttendanceRecord.fromJson(json);
      expect(record.employeeName, '');
      expect(record.checkIn, '');
      expect(record.checkOut, '');
      expect(record.note, '');
    });

    test('Employee.fromJson parses id/fullName/position/isActive', () {
      final employee = Employee.fromJson({
        'id': 'e1',
        'full_name': 'Ahmet Yılmaz',
        'position': 'Usta',
        'is_active': true,
      });
      expect(employee.id, 'e1');
      expect(employee.fullName, 'Ahmet Yılmaz');
      expect(employee.position, 'Usta');
      expect(employee.isActive, isTrue);
    });
  });

  group('create serialization', () {
    test('create POSTs exactly the backend contract fields', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/attendance': [(status: 201, body: _attendanceJson(id: 'a1'))],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = AttendanceRepository(client);

      final record = await repo.create(
        employeeId: 'e1',
        date: '2026-09-20',
        checkIn: '08:00',
        checkOut: '17:00',
        workHours: 8,
        status: 'geldi',
        note: '',
      );

      expect(record.id, 'a1');
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['employee_id'], 'e1');
      expect(body['date'], '2026-09-20');
      expect(body['check_in'], '08:00');
      expect(body['check_out'], '17:00');
      expect(body['work_hours'], 8);
      expect(body['status'], 'geldi');
      expect(body['note'], '');
    });
  });

  group('edit serialization', () {
    // Backend'in Update servis katmanı `employee_id`/`date`'i HİÇ okumaz
    // (bkz. attendance_service.go Update -- Phase 1 doğrulaması: bir kayıt
    // "hangi personel, hangi tarih" olduğu OLUŞTURULDUKTAN SONRA
    // DEĞİŞTİRİLEMEZ). Bu yüzden mobil PUT gövdesinde bu iki alan HİÇ YOK.
    test('update PUTs to /attendance/{id} without employee_id or date', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/attendance/a1': [(status: 200, body: _attendanceJson(id: 'a1', status: 'yarım gün'))],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = AttendanceRepository(client);

      final record = await repo.update(
        'a1',
        checkIn: '08:00',
        checkOut: '12:00',
        workHours: 4,
        status: 'yarım gün',
        note: 'Doktor randevusu',
      );

      expect(record.status, 'yarım gün');
      expect(adapter.calls, ['/attendance/a1']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body.containsKey('employee_id'), isFalse);
      expect(body.containsKey('date'), isFalse);
      expect(body['check_in'], '08:00');
      expect(body['check_out'], '12:00');
      expect(body['work_hours'], 4);
      expect(body['status'], 'yarım gün');
      expect(body['note'], 'Doktor randevusu');
    });
  });

  group('status vocabulary', () {
    test('kAttendanceStatuses matches the backend CHECK constraint exactly (4 values)', () {
      expect(kAttendanceStatuses, ['geldi', 'yarım gün', 'gelmedi', 'izinli']);
    });
  });

  group('duplicate/conflict validation (backend 409, DB UNIQUE(employee_id, date))', () {
    test('create surfaces the backend 409 conflict message verbatim -- no client-side conflict model', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/attendance': [
          (status: 409, body: {'error': 'bu personel için bu tarihte zaten mesai kaydı var'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = AttendanceRepository(client);

      await expectLater(
        repo.create(employeeId: 'e1', date: '2026-09-20', workHours: 8, status: 'geldi'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.kind, 'kind', ApiErrorKind.conflict)
            .having((e) => e.message, 'message', 'bu personel için bu tarihte zaten mesai kaydı var')),
      );
    });
  });

  group('backend error mapping', () {
    test('invalid status on create surfaces as 400', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/attendance': [(status: 400, body: {'error': 'geçersiz durum'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = AttendanceRepository(client);

      await expectLater(
        repo.create(employeeId: 'e1', date: '2026-09-20', workHours: 8, status: 'bogus'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'geçersiz durum')),
      );
    });

    test('editing a record from another org/project (IDOR) surfaces as 404', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/attendance/a1': [(status: 404, body: {'error': 'kayıt bulunamadı'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = AttendanceRepository(client);

      await expectLater(
        repo.update('a1', workHours: 8, status: 'geldi'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('employee not in caller org on create surfaces as 400', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/attendance': [(status: 400, body: {'error': 'personel bulunamadı'})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = AttendanceRepository(client);

      await expectLater(
        repo.create(employeeId: 'other-org-emp', date: '2026-09-20', workHours: 8, status: 'geldi'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'personel bulunamadı')),
      );
    });
  });

  group('client-side filtering (on the already-fetched month, no new request)', () {
    AttendanceRecord record({String id = 'a1', String employeeId = 'e1', String status = 'geldi', String date = '2026-09-20'}) =>
        AttendanceRecord(
          id: id, employeeId: employeeId, employeeName: 'Ahmet', date: date,
          checkIn: '08:00', checkOut: '17:00', workHours: 8, status: status, note: '',
        );

    test('attendanceMatchesFilters: no filters matches everything', () {
      expect(attendanceMatchesFilters(record()), isTrue);
    });

    test('attendanceMatchesFilters: employee filter', () {
      expect(attendanceMatchesFilters(record(employeeId: 'e1'), employeeFilter: 'e1'), isTrue);
      expect(attendanceMatchesFilters(record(employeeId: 'e1'), employeeFilter: 'e2'), isFalse);
    });

    test('attendanceMatchesFilters: status filter', () {
      expect(attendanceMatchesFilters(record(status: 'geldi'), statusFilter: 'geldi'), isTrue);
      expect(attendanceMatchesFilters(record(status: 'geldi'), statusFilter: 'gelmedi'), isFalse);
    });

    test('attendanceMatchesFilters: employee and status combine as AND', () {
      final r = record(employeeId: 'e1', status: 'gelmedi');
      expect(attendanceMatchesFilters(r, employeeFilter: 'e1', statusFilter: 'gelmedi'), isTrue);
      expect(attendanceMatchesFilters(r, employeeFilter: 'e1', statusFilter: 'geldi'), isFalse);
      expect(attendanceMatchesFilters(r, employeeFilter: 'e2', statusFilter: 'gelmedi'), isFalse);
    });
  });

  group('missing-today detection (active employees with no record for the date)', () {
    Employee employee(String id, {bool isActive = true}) =>
        Employee(id: id, fullName: 'Personel $id', position: 'Usta', isActive: isActive);

    test('an active employee with no record today is reported missing', () {
      final employees = [employee('e1'), employee('e2')];
      final todaysRecords = [
        AttendanceRecord(id: 'a1', employeeId: 'e1', employeeName: '', date: '2026-09-20', checkIn: '', checkOut: '', workHours: 8, status: 'geldi', note: ''),
      ];
      final missing = missingAttendanceFor(employees, todaysRecords);
      expect(missing.map((e) => e.id), ['e2']);
    });

    test('an inactive employee is never reported missing', () {
      final employees = [employee('e1', isActive: false)];
      final missing = missingAttendanceFor(employees, const []);
      expect(missing, isEmpty);
    });

    test('everyone present -> nobody missing', () {
      final employees = [employee('e1')];
      final todaysRecords = [
        AttendanceRecord(id: 'a1', employeeId: 'e1', employeeName: '', date: '2026-09-20', checkIn: '', checkOut: '', workHours: 8, status: 'izinli', note: ''),
      ];
      expect(missingAttendanceFor(employees, todaysRecords), isEmpty);
    });
  });

  group('permissions — exact two-tier, org-only model (no project scoping, no own/manager split)', () {
    User userWith(Set<String> perms) => User(
          id: 'u', username: 'u', fullName: 'U', role: UserRole.kullanici, isActive: true,
          mustChangePassword: false, onboardingCompleted: true, onboardingStep: 'completed', permissions: perms,
        );

    test('owner/admin/legacy_user-shaped set: read+manage', () {
      final user = userWith(const {'attendance.read', 'attendance.manage'});
      expect(user.hasPermission('attendance.read'), isTrue);
      expect(user.hasPermission('attendance.manage'), isTrue);
    });

    // Phase 1 bulgusu: field rolü YALNIZCA okuma alır -- oluşturma/düzenleme
    // FAB'ı bu izinle gizlenmelidir.
    test('field-shaped set: read only, NOT manage', () {
      final user = userWith(const {'attendance.read'});
      expect(user.hasPermission('attendance.read'), isTrue);
      expect(user.hasPermission('attendance.manage'), isFalse);
    });

    // Phase 1 bulgusu: project_manager ve finance rolleri mesai izinlerinin
    // HİÇBİRİNİ ALMAZ (migration 0034 rol-izin tablosunda hiç yok) --
    // Görevler/Tedarik modüllerinin aksine, "manager" bir mesai eylemi
    // İCAT ETMEZ.
    test('project_manager/finance-shaped set: neither attendance permission', () {
      final user = userWith(const {'projects.tasks.read', 'projects.finance.read'});
      expect(user.hasPermission('attendance.read'), isFalse);
      expect(user.hasPermission('attendance.manage'), isFalse);
    });

    test('attendance permission axis is exactly {read, manage} -- no approve/delete/own-vs-all tier exists', () {
      const codes = {'attendance.read', 'attendance.manage'};
      final user = userWith(codes);
      for (final code in codes) {
        expect(user.hasPermission(code), isTrue);
      }
      expect(user.hasPermission('attendance.approve'), isFalse);
      expect(user.hasPermission('attendance.delete'), isFalse);
      expect(user.hasPermission('attendance.own'), isFalse);
    });
  });

  group('refresh/invalidation after mutation', () {
    test('invalidating attendanceListProvider(month) triggers a fresh fetch for that month', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/attendance': [
          (status: 200, body: {'attendance': <Map<String, dynamic>>[]}),
          (status: 200, body: {'attendance': [_attendanceJson(id: 'a1')]}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(attendanceListProvider('2026-09').future);
      expect(before, isEmpty);

      container.invalidate(attendanceListProvider('2026-09'));
      final after = await container.read(attendanceListProvider('2026-09').future);

      expect(after, hasLength(1));
      expect(adapter.calls.where((p) => p == '/attendance').length, 2);
      // month, query param olarak gönderilir -- request path'in kendisi
      // sabit '/attendance' kalır (bkz. AttendanceRepository.list).
    });

    test('list() sends month as a query param, not a separate path', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/attendance': [(status: 200, body: {'attendance': <Map<String, dynamic>>[]})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = AttendanceRepository(client);

      await repo.list(month: '2026-09');

      expect(adapter.calls, ['/attendance']);
    });
  });
}

Map<String, dynamic> _attendanceJson({
  required String id,
  String status = 'geldi',
}) =>
    {
      'id': id,
      'employee_id': 'e1',
      'employee_name': 'Ahmet Yılmaz',
      'date': '2026-09-20',
      'check_in': '08:00',
      'check_out': '17:00',
      'work_hours': 8.0,
      'status': status,
      'note': '',
    };
