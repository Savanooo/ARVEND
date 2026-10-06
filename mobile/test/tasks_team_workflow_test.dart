import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/presentation/task_detail_screen.dart';
import 'package:arvend/features/projects/presentation/task_form_screen.dart';
import 'package:arvend/features/tasks/presentation/tasks_screen.dart';

import 'test_utils/fake_api_client.dart';

/// Görevler (sahada 2026-10): yönetici "Ekip" görünümünden atar ve takip
/// eder; görevi alan "Benim"de görür ve "Bilgi Ver" ile not düşer.

Map<String, dynamic> _me(List<String> permissions) => {
      'id': 'u1',
      'organization_id': 'org1',
      'username': 'test',
      'full_name': 'Ayşe Yılmaz',
      'organization_name': 'ARVEND Yapı A.Ş.',
      'role': 'kullanici',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': permissions,
    };

Map<String, dynamic> _task({
  String id = 't1',
  String title = 'Elektrik tesisatı',
  String status = 'todo',
  String? assigneeId,
  String assigneeName = '',
  String projectId = 'p1',
  String projectName = 'Merkez Ofis',
}) =>
    {
      'id': id,
      'schedule_item_id': null,
      'title': title,
      'description': '',
      'assigned_employee_id': assigneeId,
      'assigned_name': assigneeName,
      'priority': 'normal',
      'status': status,
      'due_date': null,
      'completed_at': null,
      'is_overdue': false,
      'project_id': projectId,
      'project_name': projectName,
    };

Map<String, dynamic> _project() => {
      'id': 'p1',
      'project_no': 'PRJ-1',
      'name': 'Merkez Ofis',
      'customer_id': null,
      'customer_name': '',
      'offer_id': null,
      'offer_no': '',
      'project_type': 'insaat',
      'status': 'active',
      'start_date': null,
      'end_date': null,
      'contract_amount': 0,
      'currency': 'TRY',
      'description': '',
      'created_at': '2026-09-01T00:00:00Z',
    };

const _managerPerms = ['projects.tasks.read', 'projects.tasks.create', 'projects.tasks.update'];
const _fieldPerms = ['projects.tasks.read', 'projects.tasks.update'];

Future<void> _pump(WidgetTester tester, FakeHttpClientAdapter adapter, Widget child) async {
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(400, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp(theme: AppTheme.light(), home: child),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpRouter(WidgetTester tester, FakeHttpClientAdapter adapter, GoRouter router) async {
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(400, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  group('TasksScreen — Benim / Ekip', () {
    testWidgets('görev atayabilen Ekip ile açılır: kime atandığı ve kişi filtresi görünür', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _me(_managerPerms))],
        '/tasks/team': [
          (
            status: 200,
            body: {
              'tasks': [
                _task(id: 't1', title: 'Kalıp sökümü', assigneeId: 'e1', assigneeName: 'Mehmet Usta'),
                _task(id: 't2', title: 'Beton dökümü', assigneeId: 'e2', assigneeName: 'Ali Kalfa'),
                _task(id: 't3', title: 'Malzeme sayımı'),
              ],
            },
          ),
        ],
      });
      await _pump(tester, adapter, const TasksScreen());

      expect(adapter.calls, contains('/tasks/team'));
      expect(adapter.calls, isNot(contains('/tasks/mine')));
      expect(find.text('Merkez Ofis · Mehmet Usta'), findsOneWidget);
      expect(find.text('Merkez Ofis · Atanmamış'), findsOneWidget);
      expect(find.byKey(const Key('gorev-ata')), findsOneWidget);

      await tester.tap(find.byKey(const Key('gorev-kisi')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ali Kalfa').last);
      await tester.pumpAndSettle();
      expect(find.text('Beton dökümü'), findsOneWidget);
      expect(find.text('Kalıp sökümü'), findsNothing);
      expect(find.text('Malzeme sayımı'), findsNothing);

      await tester.tap(find.byKey(const Key('gorev-kisi')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Atanmamış').last);
      await tester.pumpAndSettle();
      expect(find.text('Malzeme sayımı'), findsOneWidget);
      expect(find.text('Beton dökümü'), findsNothing);
    });

    testWidgets('Benim\'e geçince /tasks/mine çağrılır, onay kutusu görünür', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _me(_managerPerms))],
        '/tasks/team': [(status: 200, body: {'tasks': <dynamic>[]})],
        '/tasks/mine': [
          (status: 200, body: {'tasks': [_task(title: 'Bana atanan')], 'linked_employee': true}),
        ],
      });
      await _pump(tester, adapter, const TasksScreen());
      expect(find.textContaining('Görev Ata'), findsWidgets);

      await tester.tap(find.text('Benim'));
      await tester.pumpAndSettle();
      expect(adapter.calls, contains('/tasks/mine'));
      expect(find.text('Bana atanan'), findsOneWidget);
      expect(find.byType(Checkbox), findsOneWidget);
    });

    testWidgets('saha personeli Benim ile açılır; hesap personele bağlı değilse nedeni yazar, Görev Ata yok', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _me(_fieldPerms))],
        '/tasks/mine': [
          (status: 200, body: {'tasks': <dynamic>[], 'linked_employee': false}),
        ],
      });
      await _pump(tester, adapter, const TasksScreen());

      expect(adapter.calls, isNot(contains('/tasks/team')));
      expect(find.byKey(const Key('gorev-bagli-degil')), findsOneWidget);
      expect(find.text('Hesabın bir personel kaydına bağlı değil'), findsOneWidget);
      expect(find.byKey(const Key('gorev-ata')), findsNothing);
      // Atama yetkisi yok: "ekibe geç" kısayolu da yok.
      expect(find.text('Ekibin görevlerini göster'), findsNothing);
    });

    testWidgets('bağlı hesapta boş Benim sade mesaj gösterir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _me(_fieldPerms))],
        '/tasks/mine': [
          (status: 200, body: {'tasks': <dynamic>[], 'linked_employee': true}),
        ],
      });
      await _pump(tester, adapter, const TasksScreen());
      expect(find.byKey(const Key('gorev-bagli-degil')), findsNothing);
      expect(find.text('Sana atanmış görev yok.'), findsOneWidget);
    });

    testWidgets('Görev Ata: proje seçilir, form "listeye dön" kipinde açılır', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _me(_managerPerms))],
        '/tasks/team': [
          (status: 200, body: {'tasks': <dynamic>[]}),
          (status: 200, body: {'tasks': <dynamic>[]}),
        ],
        '/dashboard/project-options': [
          (
            status: 200,
            body: {
              'projects': [
                {'id': 'p1', 'project_no': 'PRJ-1', 'name': 'Merkez Ofis', 'customer_name': '', 'currency': 'TRY', 'status': 'active'},
              ],
            },
          ),
        ],
      });
      String? opened;
      final router = GoRouter(
        initialLocation: '/gorevler',
        routes: [
          GoRoute(path: '/gorevler', builder: (_, _) => const TasksScreen()),
          GoRoute(
            path: '/projeler/:id/gorevler/yeni',
            builder: (_, state) {
              opened = '${state.pathParameters['id']}:${state.uri.queryParameters['donus']}';
              return const Scaffold(body: Text('form'));
            },
          ),
        ],
      );
      await _pumpRouter(tester, adapter, router);

      await tester.tap(find.byKey(const Key('gorev-ata')));
      await tester.pumpAndSettle();
      expect(opened, 'p1:liste');
    });
  });

  group('TaskFormScreen — listeye dön', () {
    testWidgets('Görev Ata\'dan açılan form kaydedince listeye geri döner', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _me(_managerPerms))],
        // Proje yöneticisinde employees.read yok: form /employees'i değil
        // ücretsiz /projects/{id}/assignees'i kullanır.
        '/projects/p1/assignees': [
          (
            status: 200,
            body: {
              'employees': [
                {'id': 'e1', 'full_name': 'Mehmet Usta', 'position': 'Usta', 'has_account': true},
              ],
            },
          ),
        ],
        '/projects/p1/tasks': [
          (status: 201, body: _task(title: 'İskele kur', assigneeId: 'e1', assigneeName: 'Mehmet Usta')),
        ],
      });
      final router = GoRouter(
        initialLocation: '/gorevler',
        routes: [
          GoRoute(
            path: '/gorevler',
            builder: (context, _) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => context.push('/projeler/p1/gorevler/yeni?donus=liste'),
                  child: const Text('liste'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/projeler/:id/gorevler/yeni',
            builder: (_, state) => TaskFormScreen(
              projectId: state.pathParameters['id']!,
              returnToList: state.uri.queryParameters['donus'] == 'liste',
            ),
          ),
          GoRoute(
            path: '/projeler/:id/gorevler/:taskId',
            builder: (_, _) => const Scaffold(body: Text('detay')),
          ),
        ],
      );
      await _pumpRouter(tester, adapter, router);
      await tester.tap(find.text('liste'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextFormField, 'Başlık'), 'İskele kur');
      await tester.tap(find.text('— Atanmadı —'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mehmet Usta · Usta').last);
      await tester.pumpAndSettle();
      expect(find.text('Mehmet Usta bildirim alır.'), findsOneWidget);
      await tester.ensureVisible(find.text('Görevi Oluştur'));
      await tester.tap(find.text('Görevi Oluştur'));
      await tester.pumpAndSettle();

      expect(adapter.calls, isNot(contains('/employees')));
      final post = adapter.calls.indexOf('/projects/p1/tasks');
      expect((adapter.requestBodies[post] as Map)['assigned_employee_id'], 'e1');
      expect(find.text('liste'), findsOneWidget);
      expect(find.text('detay'), findsNothing);
      expect(find.text('Görev atandı: Mehmet Usta'), findsOneWidget);
    });
  });

  group('TaskFormScreen — kaydedince gezinme', () {
    GoRouter router() => GoRouter(
          initialLocation: '/ana-sayfa',
          routes: [
            GoRoute(
              path: '/ana-sayfa',
              builder: (context, _) => Scaffold(
                body: Column(
                  children: [
                    TextButton(
                      onPressed: () => context.push('/projeler/p1/gorevler/yeni'),
                      child: const Text('yeni görev'),
                    ),
                    TextButton(
                      onPressed: () => context.push('/projeler/p1/gorevler/t1/duzenle'),
                      child: const Text('düzenle'),
                    ),
                  ],
                ),
              ),
            ),
            GoRoute(
              path: '/projeler/:id/gorevler/yeni',
              builder: (_, state) => TaskFormScreen(projectId: state.pathParameters['id']!),
            ),
            GoRoute(
              path: '/projeler/:id/gorevler/:taskId/duzenle',
              builder: (_, state) => TaskFormScreen(
                projectId: state.pathParameters['id']!,
                taskId: state.pathParameters['taskId'],
              ),
            ),
            GoRoute(
              path: '/projeler/:id/gorevler/:taskId',
              builder: (_, state) => Scaffold(appBar: AppBar(), body: Text('detay ${state.pathParameters['taskId']}')),
            ),
          ],
        );

    testWidgets('yeni görev: form yerini detaya bırakır, geri dönünce dolu form yeniden görünmez', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _me(_managerPerms))],
        '/projects/p1/assignees': [(status: 200, body: {'employees': <dynamic>[]})],
        '/projects/p1/tasks': [(status: 201, body: _task(id: 't9', title: 'İskele kur'))],
      });
      final r = router();
      await _pumpRouter(tester, adapter, r);
      await tester.tap(find.text('yeni görev'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextFormField, 'Başlık'), 'İskele kur');
      await tester.ensureVisible(find.text('Görevi Oluştur'));
      await tester.tap(find.text('Görevi Oluştur'));
      await tester.pumpAndSettle();
      expect(find.text('detay t9'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('yeni görev'), findsOneWidget);
      expect(find.text('Yeni Görev'), findsNothing);
      expect(r.routerDelegate.currentConfiguration.uri.path, '/ana-sayfa');
    });

    testWidgets('düzenleme: kaydedince açıldığı ekrana geri döner', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _me(_managerPerms))],
        '/projects/p1/assignees': [(status: 200, body: {'employees': <dynamic>[]})],
        '/projects/p1/tasks': [(status: 200, body: {'tasks': [_task()]})],
        '/projects/p1/tasks/t1': [(status: 200, body: _task(title: 'Elektrik tesisatı (revize)'))],
      });
      final r = router();
      await _pumpRouter(tester, adapter, r);
      await tester.tap(find.text('düzenle'));
      await tester.pumpAndSettle();
      expect(find.text('Görevi Düzenle'), findsOneWidget);

      await tester.ensureVisible(find.text('Kaydet'));
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();

      expect(r.routerDelegate.currentConfiguration.uri.path, '/ana-sayfa');
      expect(find.text('Görevi Düzenle'), findsNothing);
    });
  });

  group('TaskDetailScreen — notlar ve Bilgi Ver', () {
    Map<String, dynamic> update({
      String id = 'u1',
      String author = 'Mehmet Usta',
      String body = 'Kalıplar söküldü, yarın temizlik.',
      String from = '',
      String to = '',
    }) =>
        {
          'id': id,
          'user_id': 'usr1',
          'author_name': author,
          'body': body,
          'status_from': from,
          'status_to': to,
          'created_at': '2026-10-05T09:30:00Z',
        };

    testWidgets('notlar yazanı, durum değişikliğini ve metni gösterir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _me(_fieldPerms))],
        '/projects/p1/tasks': [(status: 200, body: {'tasks': [_task()]})],
        '/projects/p1/tasks/t1/updates': [
          (
            status: 200,
            body: {
              'updates': [
                update(id: 'u2', from: 'todo', to: 'in_progress', body: 'Başladım.'),
                update(id: 'u1', body: 'Malzeme eksik: 20 torba çimento.'),
              ],
            },
          ),
        ],
        '/projects/p1': [(status: 200, body: _project())],
      });
      await _pump(tester, adapter, const TaskDetailScreen(projectId: 'p1', taskId: 't1'));

      expect(find.text('Notlar'), findsOneWidget);
      expect(find.byKey(const Key('gorev-notu-u2')), findsOneWidget);
      expect(find.text('Yapılacak → Devam Ediyor'), findsOneWidget);
      expect(find.text('Başladım.'), findsOneWidget);
      expect(find.text('Malzeme eksik: 20 torba çimento.'), findsOneWidget);
      expect(find.text('Mehmet Usta'), findsNWidgets(2));
    });

    testWidgets('Bilgi Ver: boş gönderilemez; not + durum POST edilir ve notlar tazelenir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _me(_fieldPerms))],
        '/projects/p1/tasks': [
          (status: 200, body: {'tasks': [_task()]}),
          (status: 200, body: {'tasks': [_task(status: 'in_progress')]}),
        ],
        '/projects/p1/tasks/t1/updates': [
          (status: 200, body: {'updates': <dynamic>[]}),
          (
            status: 201,
            body: {
              'update': update(id: 'u9', from: 'todo', to: 'in_progress', body: 'Yarısı bitti.'),
              'task': _task(status: 'in_progress'),
            },
          ),
          (
            status: 200,
            body: {
              'updates': [update(id: 'u9', from: 'todo', to: 'in_progress', body: 'Yarısı bitti.')],
            },
          ),
        ],
        '/projects/p1': [(status: 200, body: _project())],
      });
      await _pump(tester, adapter, const TaskDetailScreen(projectId: 'p1', taskId: 't1'));
      expect(find.textContaining('Henüz not yok'), findsOneWidget);

      await tester.tap(find.byKey(const Key('gorev-bilgi-ver')));
      await tester.pumpAndSettle();
      expect(find.text('Görevi veren ve proje yöneticisi bildirim alır.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('gorev-not-gonder')));
      await tester.pumpAndSettle();
      expect(find.text('Bir not yaz ya da durumu değiştir.'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('gorev-not')), '  Yarısı bitti.  ');
      await tester.tap(find.byKey(const Key('gorev-durum-in_progress')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('gorev-not-gonder')));
      await tester.pumpAndSettle();

      final postIndex = [
        for (var i = 0; i < adapter.calls.length; i++)
          if (adapter.calls[i] == '/projects/p1/tasks/t1/updates' && adapter.requestBodies[i] != null) i,
      ].single;
      expect(adapter.requestBodies[postIndex], {'body': 'Yarısı bitti.', 'status': 'in_progress'});

      expect(find.text('Bilgi gönderildi.'), findsOneWidget);
      expect(find.byKey(const Key('gorev-notu-u9')), findsOneWidget);
      expect(find.text('Yapılacak → Devam Ediyor'), findsOneWidget);
      expect(adapter.calls.where((c) => c == '/projects/p1/tasks').length, 2);
    });

    testWidgets('yalnızca durum değiştirmek de yeterli (not boş gönderilir)', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _me(_fieldPerms))],
        '/projects/p1/tasks': [
          (status: 200, body: {'tasks': [_task(status: 'in_progress')]}),
          (status: 200, body: {'tasks': [_task(status: 'completed')]}),
        ],
        '/projects/p1/tasks/t1/updates': [
          (status: 200, body: {'updates': <dynamic>[]}),
          (
            status: 201,
            body: {
              'update': update(id: 'u3', from: 'in_progress', to: 'completed', body: ''),
              'task': _task(status: 'completed'),
            },
          ),
          (status: 200, body: {'updates': [update(id: 'u3', from: 'in_progress', to: 'completed', body: '')]}),
        ],
        '/projects/p1': [(status: 200, body: _project())],
      });
      await _pump(tester, adapter, const TaskDetailScreen(projectId: 'p1', taskId: 't1'));
      await tester.tap(find.byKey(const Key('gorev-bilgi-ver')));
      await tester.pumpAndSettle();
      // Mevcut durum seçenek olarak tekrar sunulmaz.
      expect(find.byKey(const Key('gorev-durum-in_progress')), findsNothing);
      await tester.tap(find.byKey(const Key('gorev-durum-completed')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('gorev-not-gonder')));
      await tester.pumpAndSettle();

      final postIndex = [
        for (var i = 0; i < adapter.calls.length; i++)
          if (adapter.calls[i] == '/projects/p1/tasks/t1/updates' && adapter.requestBodies[i] != null) i,
      ].single;
      expect(adapter.requestBodies[postIndex], {'body': '', 'status': 'completed'});
      expect(find.text('Devam Ediyor → Tamamlandı'), findsOneWidget);
    });
  });

  test('repository: TaskUpdate ve linked_employee ayrıştırılır', () async {
    final adapter = FakeHttpClientAdapter(script: {
      '/tasks/mine': [
        (status: 200, body: {'tasks': [_task()], 'linked_employee': false}),
        (status: 200, body: {'tasks': <dynamic>[]}),
      ],
      '/projects/p1/tasks/t1/updates': [
        (
          status: 200,
          body: {
            'updates': [
              {
                'id': 'u1',
                'user_id': null,
                'author_name': '',
                'body': 'not',
                'status_from': null,
                'status_to': null,
                'created_at': '2026-10-05T09:30:00Z',
              },
            ],
          },
        ),
      ],
    });
    final client = await buildFakeApiClient(adapter);
    final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
    addTearDown(container.dispose);
    final repo = container.read(projectsRepositoryProvider);

    final mine = await repo.myTasks();
    expect(mine.linkedEmployee, isFalse);
    expect(mine.tasks.single.$3, 'Merkez Ofis');
    // Eski sunucu alanı göndermez: bilinmiyor.
    expect((await repo.myTasks()).linkedEmployee, isNull);

    final ups = await repo.taskUpdates('p1', 't1');
    expect(ups.single.body, 'not');
    expect(ups.single.changesStatus, isFalse);
    expect(ups.single, isA<TaskUpdate>());
  });
}
