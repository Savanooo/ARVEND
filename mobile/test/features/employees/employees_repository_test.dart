import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/employees/data/employees_repository.dart';
import 'package:arvend/features/employees/domain/employee_record.dart';

import '../../test_utils/fake_api_client.dart';

/// EmployeesRepository'nin backend sözleşmesi (router.go /employees,
/// employee_handler.go): aktif/pasif filtresi, tam-güncelleme gövdesi,
/// ücretlerin yalnızca employees.manage'e dönmesi.
Map<String, dynamic> _json({
  Object? salary,
  Object? dailyWage,
  Object? userId = 'u1',
  String? startDate = '2024-03-01',
}) => {
  'id': 'e1',
  'full_name': 'Mehmet Demir',
  'phone': '0532 111 22 33',
  'position': 'Şantiye Şefi',
  'salary': salary,
  'daily_wage': dailyWage,
  'start_date': startDate,
  'is_active': true,
  'description': '',
  'user_id': userId,
};

Future<(EmployeesRepository, FakeHttpClientAdapter)> _repo(Map<String, List<ScriptedResponse>> script) async {
  final adapter = FakeHttpClientAdapter(script: script);
  return (EmployeesRepository(await buildFakeApiClient(adapter)), adapter);
}

void main() {
  group('EmployeesRepository', () {
    test('liste: filtre yalnızca doluysa gönderilir', () async {
      final (repo, adapter) = await _repo({
        '/employees': [
          (
            status: 200,
            body: {
              'employees': [_json(salary: 85000)],
            },
          ),
          (status: 200, body: {'employees': <Object>[]}),
        ],
      });
      final all = await repo.list();
      await repo.list(filter: 'pasif');
      expect(all.single.salary, 85000);
      expect(adapter.requestQueries[0], isEmpty);
      expect(adapter.requestQueries[1], {'filter': 'pasif'});
    });

    test('ücret alanı null gelirse (employees.read) etiket de üretilmez', () async {
      final (repo, _) = await _repo({
        '/employees/e1': [(status: 200, body: _json())],
      });
      final e = await repo.get('e1');
      expect(e.salary, isNull);
      expect(e.dailyWage, isNull);
      expect(e.wageLabel, isNull);
      expect(e.hasLogin, isTrue);
    });

    test('create / update tam gövdeyi gönderir, archive DELETE atar', () async {
      final (repo, adapter) = await _repo({
        '/employees': [(status: 201, body: _json(dailyWage: 2500, userId: null))],
        '/employees/e1': [
          (status: 200, body: _json(dailyWage: 2500, userId: null)),
          (status: 200, body: {'ok': true}),
        ],
      });

      const input = EmployeeInput(fullName: 'Ahmet Yılmaz', position: 'Kalıpçı', dailyWage: 2500);
      await repo.create(input);
      await repo.update('e1', input);
      await repo.archive('e1');

      final expected = {
        'full_name': 'Ahmet Yılmaz',
        'phone': '',
        'position': 'Kalıpçı',
        'daily_wage': 2500.0,
        'salary': null,
        'start_date': null,
        'description': '',
        'is_active': true,
        'user_id': '',
      };
      expect(adapter.requestBodies[0], expected);
      expect(adapter.requestBodies[1], expected);
      expect(adapter.calls, ['/employees', '/employees/e1', '/employees/e1']);
    });
  });

  group('EmployeeRecord / EmployeeInput', () {
    test('boş user_id bağlantı yok sayılır', () {
      final e = EmployeeRecord.fromJson(_json(userId: ''));
      expect(e.userId, isNull);
      expect(e.hasLogin, isFalse);
    });

    test('wageLabel: yevmiye öncelikli, yoksa maaş', () {
      expect(EmployeeRecord.fromJson(_json(dailyWage: 2500, salary: 90000)).wageLabel, contains('/ gün'));
      expect(EmployeeRecord.fromJson(_json(salary: 90000)).wageLabel, contains('/ ay'));
    });

    test('fromRecord mevcut kaydı yalnızca user_id değiştirerek yeniden yazar (ücretler korunur)', () {
      final e = EmployeeRecord.fromJson(_json(salary: 85000, userId: null));
      final json = EmployeeInput.fromRecord(e, userId: 'u-yeni').toJson();
      expect(json['user_id'], 'u-yeni');
      expect(json['salary'], 85000);
      expect(json['start_date'], '2024-03-01');
      expect(json['full_name'], 'Mehmet Demir');
    });

    test('parseAmountInput Türkçe tutar biçimleri', () {
      expect(parseAmountInput(''), isNull);
      expect(parseAmountInput('1500'), 1500);
      expect(parseAmountInput('1.500'), 1500);
      expect(parseAmountInput('1.500,50'), 1500.5);
      expect(parseAmountInput('1500,5'), 1500.5);
      expect(parseAmountInput('1500.5'), 1500.5);
      expect(() => parseAmountInput('1,2,3'), throwsFormatException);
    });

    test('amountToInput / isoDate', () {
      expect(amountToInput(null), '');
      expect(amountToInput(1500), '1500');
      expect(amountToInput(1500.5), '1500,5');
      expect(isoDate(DateTime(2026, 9, 5)), '2026-09-05');
    });
  });
}
