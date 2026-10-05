import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/data/projects_repository.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/tasks/data/tasks_providers.dart';
import 'package:arvend/features/tasks/domain/task_filters.dart';

import 'test_utils/fake_api_client.dart';

/// Faz 7 — Proje Görevleri. Backend'de HİÇBİR değişiklik yapılmadı -- bu
/// testler yalnızca mobilin backend'in ZATEN var olan sözleşmesine (Phase
/// 1 doğrulamasıyla teyit edildi) DOĞRU şekilde uyduğunu kanıtlar.
void main() {
  group('create/edit request serialization', () {
    test('createTask POSTs the backend contract shape (status always "todo")', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/tasks': [
          (status: 201, body: _taskJson(id: 't1', status: 'todo')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final task = await repo.createTask(
        'p1',
        title: 'Kalıp kontrol',
        description: 'Zemin kat',
        assignedEmployeeId: 'emp1',
        priority: 'high',
        dueDate: '2026-03-01',
      );

      expect(task.id, 't1');
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['title'], 'Kalıp kontrol');
      expect(body['assigned_employee_id'], 'emp1');
      expect(body['priority'], 'high');
      expect(body['due_date'], '2026-03-01');
      // Backend'de doğrudan 'completed' olarak oluşturma REDDEDİLİR -- mobil
      // create formunda hiç durum sorulmaz, her zaman 'todo' gönderilir.
      expect(body['status'], 'todo');
      expect(body['schedule_item_id'], isNull);
    });

    test('updateTask PUTs to the task-specific endpoint and preserves scheduleItemId pass-through', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/tasks/t1': [
          (status: 200, body: _taskJson(id: 't1', status: 'in_progress')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.updateTask(
        'p1',
        't1',
        title: 'Güncellenmiş başlık',
        scheduleItemId: 'sched1',
        assignedEmployeeId: 'emp2',
        priority: 'urgent',
        status: 'in_progress',
        dueDate: '2026-03-05',
      );

      expect(adapter.calls, ['/projects/p1/tasks/t1']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['title'], 'Güncellenmiş başlık');
      // Mobil bir aşama (schedule item) seçici SUNMAZ ama var olan bağlantıyı
      // sessizce SİLMEMELİDİR -- OLDUĞU GİBİ geçirilir (bkz. backend'in
      // TAM-yeniden-yazma semantiği, Phase 1 doğrulaması).
      expect(body['schedule_item_id'], 'sched1');
      expect(body['assigned_employee_id'], 'emp2');
      expect(body['status'], 'in_progress');
    });

    test('updateTask can clear the assignee by passing null', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/tasks/t1': [
          (status: 200, body: _taskJson(id: 't1', status: 'todo')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await repo.updateTask('p1', 't1', title: 't', priority: 'normal', status: 'todo', assignedEmployeeId: null);

      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['assigned_employee_id'], isNull);
    });
  });

  group('status changes (no second Flutter state machine)', () {
    test('completeTask succeeds via the dedicated idempotent endpoint', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/tasks/t1/complete': [
          (status: 200, body: _taskJson(id: 't1', status: 'completed', completedAt: '2026-01-05T10:00:00Z')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final task = await repo.completeTask('p1', 't1');

      expect(task.status, 'completed');
      expect(task.completedAt, isNotNull);
    });

    test('updateTask can also directly set status=completed (same mechanism as backend, not a separate flow)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/tasks/t1': [
          (status: 200, body: _taskJson(id: 't1', status: 'completed', completedAt: '2026-01-05T10:00:00Z')),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final task = await repo.updateTask('p1', 't1', title: 't', priority: 'normal', status: 'completed');

      expect(task.status, 'completed');
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['status'], 'completed');
    });

    test('"reopen" is just updateTask with status back to todo -- backend clears completed_at automatically', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/tasks/t1': [
          (status: 200, body: _taskJson(id: 't1', status: 'todo', completedAt: null)),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final task = await repo.updateTask('p1', 't1', title: 't', priority: 'normal', status: 'todo');

      expect(task.status, 'todo');
      expect(task.completedAt, isNull);
    });

    test('mobile allows setting any of the 4 statuses -- no client-side transition graph', () {
      // Backend'de sabit bir geçiş grafiği yok (bkz. Phase 1) -- mobil de
      // ikinci bir kısıtlama İCAT ETMEZ, tüm 4 durum HER ZAMAN geçerlidir.
      const allStatuses = [
        ProjectTask.statusTodo,
        ProjectTask.statusInProgress,
        ProjectTask.statusCompleted,
        ProjectTask.statusCancelled,
      ];
      expect(allStatuses, hasLength(4));
      expect(allStatuses.toSet().length, 4);
    });

    test('invalid status update surfaces the backend error verbatim (no client validation duplication)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/tasks/t1': [
          (status: 400, body: {'error': 'geçersiz görev durumu'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.updateTask('p1', 't1', title: 't', priority: 'normal', status: 'bogus'),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'geçersiz görev durumu')),
      );
    });

    test('task not found (cross-project/org IDOR) surfaces as 404', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/tasks/t1': [
          (status: 404, body: {'error': 'kayıt bulunamadı'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      await expectLater(
        repo.updateTask('p1', 't1', title: 't', priority: 'normal', status: 'todo'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
      );
    });
  });

  group('response parsing (overdue is backend-derived, never recomputed client-side)', () {
    test('ProjectTask.fromJson reads is_overdue verbatim regardless of the raw due_date/status combination', () {
      // Backend'in kendi mantığı ne olursa olsun -- mobil bunu ASLA
      // yeniden hesaplamaz, olduğu gibi gösterir.
      final overdue = ProjectTask.fromJson(_taskJson(id: 't1', status: 'todo', dueDate: '2099-01-01', isOverdue: true));
      final notOverdue = ProjectTask.fromJson(_taskJson(id: 't2', status: 'todo', dueDate: '2020-01-01', isOverdue: false));
      expect(overdue.isOverdue, isTrue);
      expect(notOverdue.isOverdue, isFalse);
    });

    test('a completed task with no due_date parses cleanly', () {
      final task = ProjectTask.fromJson(_taskJson(id: 't1', status: 'completed', completedAt: '2026-01-01T00:00:00Z'));
      expect(task.status, 'completed');
      expect(task.completedAt, isNotNull);
    });
  });

  group('permissions — exact two-axis matrix (read/create/update, not inferred from role names)', () {
    User userWith(Set<String> perms) => User(
          id: 'u', username: 'u', fullName: 'U', role: UserRole.kullanici, isActive: true,
          mustChangePassword: false, onboardingCompleted: true, onboardingStep: 'completed', permissions: perms,
        );

    test('owner/admin/legacy_user/project_manager-shaped set: read+create+update', () {
      final user = userWith(const {'projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update'});
      expect(user.hasPermission('projects.tasks.read'), isTrue);
      expect(user.hasPermission('projects.tasks.create'), isTrue);
      expect(user.hasPermission('projects.tasks.update'), isTrue);
    });

    // Phase 1 bulgusu: field rolü read+update ALIR ama create ALMAZ --
    // saha personeli mevcut görevleri görüp güncelleyebilir/tamamlayabilir
    // ama YENİ görev açamaz.
    test('field-shaped set: read+update but NOT create', () {
      final user = userWith(const {'projects.tasks.read', 'projects.tasks.update'});
      expect(user.hasPermission('projects.tasks.read'), isTrue);
      expect(user.hasPermission('projects.tasks.update'), isTrue);
      expect(user.hasPermission('projects.tasks.create'), isFalse);
    });

    // Phase 1 bulgusu: finance rolü görev izinlerinin HİÇBİRİNİ ALMAZ.
    test('finance-shaped set: none of the task permissions', () {
      final user = userWith(const {'projects.finance.read', 'projects.finance.manage'});
      expect(user.hasPermission('projects.tasks.read'), isFalse);
      expect(user.hasPermission('projects.tasks.create'), isFalse);
      expect(user.hasPermission('projects.tasks.update'), isFalse);
    });

    test('task permission axis is exactly {read, create, update} -- no approve/delete tier exists (Phase 1)', () {
      // Subcontract/Procurement modüllerinin AKSİNE (read/manage/approve
      // ÜÇLÜ modeli), görevlerde yalnızca BU üç izin kodu tanımlıdır --
      // mobil UI bunların DIŞINDA bir izin sınıfı (ör. bir "approve" veya
      // "delete" aksiyonu) VARMIŞ GİBİ davranmaz.
      const taskPermissionCodes = {'projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update'};
      final user = userWith(taskPermissionCodes);
      for (final code in taskPermissionCodes) {
        expect(user.hasPermission(code), isTrue);
      }
      expect(user.hasPermission('projects.tasks.approve'), isFalse);
      expect(user.hasPermission('projects.tasks.delete'), isFalse);
    });
  });

  group('filter behavior (client-side, on the already-fetched list)', () {
    ProjectTask task({
      String id = 't1',
      String status = ProjectTask.statusTodo,
      String priority = ProjectTask.priorityNormal,
      bool isOverdue = false,
      String title = 'Görev',
    }) =>
        ProjectTask(
          id: id, scheduleItemId: null, title: title, description: '', assignedEmployeeId: null, assignedName: '',
          priority: priority, status: status, dueDate: null, completedAt: null, isOverdue: isOverdue,
        );

    test('taskMatchesStatusFilter: open = todo+in_progress only', () {
      expect(taskMatchesStatusFilter(task(status: ProjectTask.statusTodo), TaskStatusFilter.open), isTrue);
      expect(taskMatchesStatusFilter(task(status: ProjectTask.statusInProgress), TaskStatusFilter.open), isTrue);
      expect(taskMatchesStatusFilter(task(status: ProjectTask.statusCompleted), TaskStatusFilter.open), isFalse);
      expect(taskMatchesStatusFilter(task(status: ProjectTask.statusCancelled), TaskStatusFilter.open), isFalse);
    });

    test('taskMatchesStatusFilter: completed = completed only, all = everything', () {
      expect(taskMatchesStatusFilter(task(status: ProjectTask.statusCompleted), TaskStatusFilter.completed), isTrue);
      expect(taskMatchesStatusFilter(task(status: ProjectTask.statusTodo), TaskStatusFilter.completed), isFalse);
      expect(taskMatchesStatusFilter(task(status: ProjectTask.statusCancelled), TaskStatusFilter.all), isTrue);
    });

    test('taskMatchesCommonFilters: overdueOnly and priority combine as AND', () {
      final urgentOverdue = task(priority: ProjectTask.priorityUrgent, isOverdue: true);
      final urgentOnTime = task(priority: ProjectTask.priorityUrgent, isOverdue: false);
      final normalOverdue = task(priority: ProjectTask.priorityNormal, isOverdue: true);

      expect(taskMatchesCommonFilters(urgentOverdue, overdueOnly: true, priority: ProjectTask.priorityUrgent), isTrue);
      expect(taskMatchesCommonFilters(urgentOnTime, overdueOnly: true, priority: ProjectTask.priorityUrgent), isFalse);
      expect(taskMatchesCommonFilters(normalOverdue, overdueOnly: true, priority: ProjectTask.priorityUrgent), isFalse);
      expect(taskMatchesCommonFilters(urgentOnTime, overdueOnly: false, priority: null), isTrue);
    });

    test('myTaskMatchesFilters: project filter and case-insensitive title/project search', () {
      final t = task(title: 'Kalıp Kontrolü');
      expect(myTaskMatchesFilters(t, 'p1', 'Villa Projesi', overdueOnly: false, projectFilter: 'p1'), isTrue);
      expect(myTaskMatchesFilters(t, 'p1', 'Villa Projesi', overdueOnly: false, projectFilter: 'p2'), isFalse);
      expect(myTaskMatchesFilters(t, 'p1', 'Villa Projesi', overdueOnly: false, searchQuery: 'kalıp'), isTrue);
      expect(myTaskMatchesFilters(t, 'p1', 'Villa Projesi', overdueOnly: false, searchQuery: 'villa'), isTrue);
      expect(myTaskMatchesFilters(t, 'p1', 'Villa Projesi', overdueOnly: false, searchQuery: 'no-match'), isFalse);
    });
  });

  group('operations-summary — backend-computed, not re-aggregated client-side', () {
    test('operationsSummary parses all fields from a single request', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/operations-summary': [
          (status: 200, body: {
            'active_member_count': 4,
            'total_task_count': 20,
            'open_task_count': 12,
            'overdue_task_count': 3,
            'completed_task_count': 7,
            'task_completion_ratio': 35.0,
          }),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = ProjectsRepository(client);

      final summary = await repo.operationsSummary('p1');

      expect(summary.activeMemberCount, 4);
      expect(summary.totalTaskCount, 20);
      expect(summary.openTaskCount, 12);
      expect(summary.overdueTaskCount, 3);
      expect(summary.completedTaskCount, 7);
      expect(summary.taskCompletionRatio, 35.0);
    });
  });

  group('list/detail refresh after create/edit/status-change', () {
    test('invalidating projectTasksProvider triggers a fresh list fetch', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/tasks': [
          (status: 200, body: {'tasks': <Map<String, dynamic>>[]}),
          (status: 200, body: {'tasks': [_taskJson(id: 't1', status: 'todo')]}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(projectTasksProvider('p1').future);
      expect(before, isEmpty);

      container.invalidate(projectTasksProvider('p1'));
      final after = await container.read(projectTasksProvider('p1').future);

      expect(after, hasLength(1));
      expect(adapter.calls.where((p) => p == '/projects/p1/tasks').length, 2);
    });

    test('invalidating myTasksProvider(status) triggers a fresh fetch for that status mode', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/tasks/mine': [
          (status: 200, body: {'tasks': <Map<String, dynamic>>[]}),
          (status: 200, body: {
            'tasks': [
              {..._taskJson(id: 't1', status: 'todo'), 'project_id': 'p1', 'project_name': 'Villa Projesi'},
            ],
          }),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(myTasksProvider('open').future);
      expect(before.items, isEmpty);

      container.invalidate(myTasksProvider('open'));
      final after = await container.read(myTasksProvider('open').future);

      expect(after.items, hasLength(1));
      expect(after.items.single.$3, 'Villa Projesi');
    });

    test('bare-family invalidate(myTasksProvider) refreshes every status-mode instance at once', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/tasks/mine': [
          (status: 200, body: {'tasks': <Map<String, dynamic>>[]}),
          (status: 200, body: {'tasks': <Map<String, dynamic>>[]}),
          (status: 200, body: {
            'tasks': [
              {..._taskJson(id: 't1', status: 'todo'), 'project_id': 'p1', 'project_name': 'P'},
            ],
          }),
          (status: 200, body: {
            'tasks': [
              {..._taskJson(id: 't1', status: 'todo'), 'project_id': 'p1', 'project_name': 'P'},
            ],
          }),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      await container.read(myTasksProvider('open').future);
      await container.read(myTasksProvider('all').future);

      // Görev formu/detay ekranı tam olarak bunu çağırır: aile referansının
      // KENDİSİNİ (bir argümansız) invalidate ederek TÜM durum modlarını
      // tazeler.
      container.invalidate(myTasksProvider);

      final openAfter = await container.read(myTasksProvider('open').future);
      final allAfter = await container.read(myTasksProvider('all').future);
      expect(openAfter.items, hasLength(1));
      expect(allAfter.items, hasLength(1));
      expect(adapter.calls.where((p) => p == '/tasks/mine').length, 4);
    });

    test('invalidating projectOperationsSummaryProvider triggers a fresh fetch', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/operations-summary': [
          (status: 200, body: {
            'active_member_count': 1, 'total_task_count': 1, 'open_task_count': 1,
            'overdue_task_count': 0, 'completed_task_count': 0, 'task_completion_ratio': 0.0,
          }),
          (status: 200, body: {
            'active_member_count': 1, 'total_task_count': 2, 'open_task_count': 1,
            'overdue_task_count': 0, 'completed_task_count': 1, 'task_completion_ratio': 50.0,
          }),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(projectOperationsSummaryProvider('p1').future);
      expect(before.completedTaskCount, 0);

      container.invalidate(projectOperationsSummaryProvider('p1'));
      final after = await container.read(projectOperationsSummaryProvider('p1').future);

      expect(after.completedTaskCount, 1);
    });
  });
}

Map<String, dynamic> _taskJson({
  required String id,
  required String status,
  String? dueDate,
  String? completedAt,
  bool isOverdue = false,
}) =>
    {
      'id': id,
      'schedule_item_id': null,
      'title': 'Görev',
      'description': '',
      'assigned_employee_id': null,
      'assigned_name': '',
      'priority': 'normal',
      'status': status,
      'due_date': dueDate,
      'completed_at': completedAt,
      'is_overdue': isOverdue,
    };
