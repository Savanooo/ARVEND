import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/projects/ops_team/data/ops_team_repository.dart';
import 'package:arvend/features/projects/ops_team/domain/ops_dates.dart';
import 'package:arvend/features/projects/ops_team/domain/ops_permissions.dart';
import 'package:arvend/features/projects/ops_team/domain/project_access.dart';
import 'package:arvend/features/projects/ops_team/domain/schedule_item.dart';
import 'package:arvend/features/projects/ops_team/domain/team_member.dart';

import '../../test_utils/fake_api_client.dart';

/// Uç sözleşmesi (yol/gövde/sorgu) ve alan modelleri -- backend
/// `scheduleItemResponse`, `memberResponse`, `projectUserResponse` ile
/// birebir JSON örnekleri.
void main() {
  Future<(OpsTeamRepository, FakeHttpClientAdapter)> repoWith(Map<String, List<ScriptedResponse>> script) async {
    final adapter = FakeHttpClientAdapter(script: script);
    return (OpsTeamRepository(await buildFakeApiClient(adapter)), adapter);
  }

  const scheduleJson = {
    'id': 's1',
    'name': 'Kaba İnşaat',
    'description': 'Karkas',
    'start_date': '2026-09-01',
    'end_date': '2026-09-24',
    'status': 'active',
    'sort_order': 2,
    'task_count': 8,
    'completed_task_count': 3,
  };

  group('OpsTeamRepository', () {
    test('planlama: liste, oluştur (tam gövde), güncelle', () async {
      final (repo, adapter) = await repoWith({
        '/projects/p1/schedule': [
          (status: 200, body: {'items': [scheduleJson]}),
          (status: 201, body: scheduleJson),
        ],
        '/projects/p1/schedule/s1': [(status: 200, body: scheduleJson)],
      });
      final items = await repo.schedule('p1');
      expect(items.single.name, 'Kaba İnşaat');
      expect(items.single.taskCount, 8);
      expect(items.single.completedTaskCount, 3);
      expect(items.single.sortOrder, 2);

      await repo.createScheduleItem('p1', const ScheduleItemInput(name: 'Temel', startDate: '2026-10-01', sortOrder: 3));
      expect(adapter.requestBodies[1], {
        'name': 'Temel',
        'description': '',
        'start_date': '2026-10-01',
        'end_date': null,
        'status': 'planned',
        'sort_order': 3,
      });

      await repo.updateScheduleItem('p1', 's1', items.single.toInput(status: ScheduleStatus.completed));
      expect(adapter.calls.last, '/projects/p1/schedule/s1');
      expect(adapter.requestBodies.last, {
        'name': 'Kaba İnşaat',
        'description': 'Karkas',
        'start_date': '2026-09-01',
        'end_date': '2026-09-24',
        'status': 'completed',
        'sort_order': 2,
      });
    });

    test('ekip: liste, ekle, çıkar, personel seçicisi (filter=aktif)', () async {
      const member = {
        'id': 'm1',
        'employee_id': 'e1',
        'employee_name': 'Ahmet Yılmaz',
        'role_title': 'Şantiye Şefi',
        'start_date': '2026-08-01',
        'end_date': null,
        'notes': '',
        'is_active': true,
      };
      final (repo, adapter) = await repoWith({
        '/projects/p1/members': [
          (status: 200, body: {'members': [member]}),
          (status: 201, body: member),
        ],
        '/projects/p1/members/m1': [
          (status: 200, body: {...member, 'end_date': '2026-09-29', 'is_active': false}),
        ],
        '/employees': [
          (status: 200, body: {
            'employees': [
              {'id': 'e1', 'full_name': 'Ahmet Yılmaz', 'position': 'Mühendis', 'daily_wage': 1500},
            ],
          }),
        ],
      });
      final members = await repo.members('p1');
      expect(members.single.isActive, isTrue);
      expect(members.single.roleTitle, 'Şantiye Şefi');

      await repo.addMember('p1', const TeamMemberInput(employeeId: 'e1', roleTitle: 'Şef', startDate: '2026-10-01'));
      expect(adapter.requestBodies[1], {
        'employee_id': 'e1',
        'role_title': 'Şef',
        'start_date': '2026-10-01',
        'notes': '',
      });

      final ended = await repo.endMembership('p1', 'm1');
      expect(ended.isActive, isFalse);
      expect(ended.endDate, '2026-09-29');

      final employees = await repo.activeEmployees();
      expect(adapter.requestQueries.last, {'filter': 'aktif'});
      expect(employees.single.label, 'Ahmet Yılmaz — Mühendis');
    });

    test('erişim: liste, ver, rol değiştir, kaldır, kullanıcı seçicisi (limit=200)', () async {
      final (repo, adapter) = await repoWith({
        '/projects/p1/access': [
          (status: 200, body: {
            'users': [
              {
                'user_id': 'u1',
                'username': 'selin',
                'full_name': 'Selin Aydın',
                'user_is_active': true,
                'project_role': 'project_manager',
                'organization_role_code': 'project_manager',
                'organization_role_name': 'Proje Yöneticisi',
              },
            ],
          }),
          (status: 201, body: {'user_id': 'u2', 'project_role': 'viewer'}),
        ],
        '/projects/p1/access/u1': [
          (status: 200, body: {'user_id': 'u1', 'project_role': 'member'}),
          (status: 200, body: {'ok': true}),
        ],
        '/users': [
          (status: 200, body: {
            'users': [
              {'id': 'u2', 'username': 'deniz', 'full_name': 'Deniz Kara', 'is_active': true, 'organization_role_code': 'finance'},
            ],
            'total': 1,
          }),
        ],
      });
      final users = await repo.accessUsers('p1');
      expect(users.single.projectRole, ProjectRole.projectManager);
      expect(users.single.organizationRoleName, 'Proje Yöneticisi');

      await repo.grantAccess('p1', userId: 'u2', projectRole: ProjectRole.viewer);
      expect(adapter.requestBodies[1], {'user_id': 'u2', 'project_role': 'viewer'});

      await repo.changeAccessRole('p1', userId: 'u1', projectRole: ProjectRole.member);
      expect(adapter.requestBodies[2], {'project_role': 'member'});

      await repo.revokeAccess('p1', userId: 'u1');
      expect(adapter.calls[3], '/projects/p1/access/u1');

      final org = await repo.orgUsers();
      expect(adapter.requestQueries.last, {'limit': 200});
      expect(org.single.label, 'Deniz Kara — Finans');
    });

    test('403 ApiException olarak döner', () async {
      final (repo, _) = await repoWith({
        '/projects/p1/access': [
          (status: 403, body: {'error': 'bu işlem için yetkiniz yok'}),
        ],
      });
      await expectLater(
        repo.accessUsers('p1'),
        throwsA(isA<ApiException>().having((e) => e.isForbidden, 'isForbidden', isTrue)),
      );
    });
  });

  group('ScheduleItem', () {
    final today = DateTime.utc(2026, 9, 29);

    test('gecikme yalnızca açık aşamada ve bitiş bugünden önceyse', () {
      const active = ScheduleItem(id: 'a', name: 'A', endDate: '2026-09-24', status: ScheduleStatus.active);
      expect(active.isOverdue(today), isTrue);
      expect(active.overdueDays(today), 5);
      const planned = ScheduleItem(id: 'b', name: 'B', endDate: '2026-09-28');
      expect(planned.overdueDays(today), 1);
      const endsToday = ScheduleItem(id: 'c', name: 'C', endDate: '2026-09-29', status: ScheduleStatus.active);
      expect(endsToday.isOverdue(today), isFalse);
      const done = ScheduleItem(id: 'd', name: 'D', endDate: '2026-09-01', status: ScheduleStatus.completed);
      expect(done.isOverdue(today), isFalse);
      const cancelled = ScheduleItem(id: 'e', name: 'E', endDate: '2026-09-01', status: ScheduleStatus.cancelled);
      expect(cancelled.isOverdue(today), isFalse);
      const noEnd = ScheduleItem(id: 'f', name: 'F', status: ScheduleStatus.active);
      expect(noEnd.isOverdue(today), isFalse);
    });

    test('süre iki uç dahil; tarih eksikse null', () {
      expect(const ScheduleItem(id: 'a', name: 'A', startDate: '2026-09-01', endDate: '2026-09-30').durationDays, 30);
      expect(const ScheduleItem(id: 'a', name: 'A', startDate: '2026-09-01').durationDays, isNull);
      expect(const ScheduleItem(id: 'a', name: 'A', startDate: '2026-09-10', endDate: '2026-09-01').durationDays, isNull);
    });

    test('görev ilerlemesi', () {
      expect(const ScheduleItem(id: 'a', name: 'A').taskProgressPct, isNull);
      expect(const ScheduleItem(id: 'a', name: 'A', taskCount: 8, completedTaskCount: 2).taskProgressPct, 25);
    });

    test('özet sayıları', () {
      final o = ScheduleOverview.of(const [
        ScheduleItem(id: 'a', name: 'A', status: ScheduleStatus.completed, taskCount: 2, completedTaskCount: 2),
        ScheduleItem(id: 'b', name: 'B', status: ScheduleStatus.active, endDate: '2026-09-01', taskCount: 4, completedTaskCount: 1),
        ScheduleItem(id: 'c', name: 'C'),
      ], today);
      expect(o.total, 3);
      expect(o.count(ScheduleStatus.completed), 1);
      expect(o.count(ScheduleStatus.active), 1);
      expect(o.count(ScheduleStatus.planned), 1);
      expect(o.count(ScheduleStatus.cancelled), 0);
      expect(o.overdue, 1);
      expect(o.taskTotal, 6);
      expect(o.taskCompleted, 3);
    });

    test('durum etiketleri web ile aynı', () {
      expect(ScheduleStatus.labels, {
        'planned': 'Planlandı',
        'active': 'Devam Ediyor',
        'completed': 'Tamamlandı',
        'cancelled': 'İptal',
      });
    });
  });

  group('Yardımcılar', () {
    test('tarih biçimleri ve İstanbul günü', () {
      expect(parseDay('2026-09-01'), DateTime.utc(2026, 9, 1));
      expect(parseDay(''), isNull);
      expect(parseDay('bozuk'), isNull);
      expect(formatDay(DateTime.utc(2026, 1, 5)), '2026-01-05');
      // UTC 21:30 = İstanbul ertesi gün 00:30.
      expect(istanbulToday(DateTime.utc(2026, 9, 28, 21, 30)), DateTime.utc(2026, 9, 29));
      expect(istanbulToday(DateTime.utc(2026, 9, 28, 20, 59)), DateTime.utc(2026, 9, 28));
    });

    test('proje kilidi', () {
      expect(isProjectLocked('completed'), isTrue);
      expect(isProjectLocked('cancelled'), isTrue);
      expect(isProjectLocked('active'), isFalse);
      expect(isProjectLocked('paused'), isFalse);
    });

    test('erişim verilebilir kullanıcılar: aktif ve atanmamış', () {
      const all = [
        OrgUserOption(id: 'a', fullName: 'A', username: 'a'),
        OrgUserOption(id: 'b', fullName: 'B', username: 'b', isActive: false),
        OrgUserOption(id: 'c', fullName: 'C', username: 'c'),
      ];
      const assigned = [ProjectAccessUser(userId: 'c', username: 'c', fullName: 'C')];
      expect(grantableUsers(all, assigned).map((u) => u.id), ['a']);
    });

    test('seçici etiketleri', () {
      expect(const OrgUserOption(id: 'a', fullName: 'Ali', username: 'ali').label, 'Ali');
      expect(const OrgUserOption(id: 'a', fullName: 'Ali', username: 'ali', organizationRoleCode: 'owner').label,
          'Ali — Sahip (Owner)');
      expect(
        const OrgUserOption(
          id: 'a',
          fullName: 'Ali',
          username: 'ali',
          organizationRoleCode: 'custom_x',
          organizationRoleName: 'Depo',
        ).label,
        'Ali — Depo',
      );
      expect(const EmployeeOption(id: 'e', fullName: 'Veli').label, 'Veli');
      expect(ProjectRole.label('viewer'), 'Görüntüleyici');
    });

    test('ekip üyesi is_active alanı yoksa bitiş tarihinden çıkarılır', () {
      final m = ProjectTeamMember.fromJson({'id': 'm', 'employee_id': 'e', 'employee_name': 'X', 'end_date': '2026-01-01'});
      expect(m.isActive, isFalse);
    });
  });
}
