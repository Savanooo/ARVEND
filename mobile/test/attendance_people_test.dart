import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/attendance/domain/attendance.dart';
import 'package:arvend/features/attendance/domain/attendance_people.dart';
import 'package:arvend/features/payroll/domain/payroll.dart';

AttendanceRecord _r(String id, String emp, String name, String date, String status, double h) => AttendanceRecord(
      id: id,
      employeeId: emp,
      employeeName: name,
      date: date,
      checkIn: '08:00',
      checkOut: '17:00',
      workHours: h,
      status: status,
      note: '',
    );

void main() {
  test('tek liste: aktif personel + o ay kaydı olan pasif; gün geldi=1 yarım=0.5; aktifler önce', () {
    final people = peopleForMonth(
      employees: const [
        Employee(id: 'e2', fullName: 'Zeki Usta', position: 'Usta', isActive: true),
        Employee(id: 'e1', fullName: 'Ali Kaya', position: 'Duvarcı', isActive: true),
      ],
      records: [
        _r('a1', 'e2', 'Zeki Usta', '2026-10-01', 'geldi', 9),
        _r('a2', 'e2', 'Zeki Usta', '2026-10-02', 'yarım gün', 4),
        _r('a3', 'e2', 'Zeki Usta', '2026-10-03', 'gelmedi', 0),
        _r('a4', 'e9', 'Ayrılan Kalfa', '2026-10-01', 'geldi', 8),
      ],
      todayIso: '2026-10-02',
    );
    expect(people.map((p) => p.fullName), ['Ali Kaya', 'Zeki Usta', 'Ayrılan Kalfa']);
    final zeki = people[1];
    expect(zeki.workedDays, 1.5);
    expect(zeki.workHours, 13);
    expect(zeki.records.first.date, '2026-10-03', reason: 'en yeni gün önce');
    expect(zeki.today?.status, 'yarım gün');
    expect(people[0].today, isNull, reason: 'Ali Kaya bugün kayıtsız');
    expect(people[2].isActive, isFalse, reason: 'aktif listesinde yok ama o ay kaydı var');
  });

  test('personel listesi okunamazsa (izin yok) kimse pasif sayılmaz', () {
    final people = peopleForMonth(
      employees: null,
      records: [_r('a1', 'e1', 'Ali Kaya', '2026-10-01', 'geldi', 9)],
    );
    expect(people.single.isActive, isTrue);
  });

  test('maaş özeti satırı kişiye bağlanır; yalnızca maaşta olan kişi de listede', () {
    final payroll = PayrollMonth.fromJson({
      'period': '2026-10',
      'summary': [
        {'employee_id': 'e1', 'full_name': 'Ali Kaya', 'is_active': true, 'wage_basis': 'günlük', 'remaining': 100},
        {'employee_id': 'e5', 'full_name': 'Ödemesi Olan', 'is_active': false, 'paid_total': 50},
      ],
      'payments': <dynamic>[],
    });
    final people = peopleForMonth(
      employees: const [Employee(id: 'e1', fullName: 'Ali Kaya', position: '', isActive: true)],
      records: const [],
      payroll: payroll,
    );
    expect(people.map((p) => p.employeeId), ['e1', 'e5']);
    expect(people.first.payroll?.remaining, 100);
    expect(people.last.isActive, isFalse);
  });
}
