import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/widgets/app_filter_bar.dart';
import 'package:arvend/features/customers/presentation/customer_detail_screen.dart';
import 'package:arvend/features/customers/presentation/customers_screen.dart';
import 'package:arvend/features/notifications/presentation/notifications_screen.dart';
import 'package:arvend/features/offers/presentation/offers_screen.dart';
import 'package:arvend/features/projects/presentation/projects_screen.dart';
import 'package:arvend/features/projects/presentation/task_detail_screen.dart';
import 'package:arvend/features/tasks/presentation/tasks_screen.dart';

import 'test_utils/fake_api_client.dart';

/// Faz 2 — liste/hesap ekranlarının yeniden tasarımı. Faz 1'in
/// `redesign_workflow_test.dart` dosyasındaki AYNI konvansiyonları izler:
/// dar genişlikte `setSurfaceSize`, `tr_TR` tarih başlatma, savunmacı uç
/// betikleme. Buradaki testler iş mantığını DEĞİL (o zaten repository/
/// provider testleriyle -- customers/notifications/task_workflow_test.dart
/// -- kapsanıyor), yeni ekran YAPISINI (filtre/arama/izin görünürlüğü/
/// gezinme) doğrular.
Map<String, dynamic> _meJson({List<String> permissions = const []}) => {
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

Map<String, dynamic> _projectJson({
  String id = 'p1',
  String name = 'Merkez Ofis İnşaatı',
  String status = 'active',
  String customerName = 'Ali Veli',
}) =>
    {
      'id': id,
      'project_no': 'PRJ-001',
      'name': name,
      'project_type': 'Konut',
      'customer_id': 'c1',
      'customer_name': customerName,
      'customer_phone': '',
      'customer_email': '',
      'contract_amount': 100000,
      'currency': 'TRY',
      'status': status,
      'start_date': null,
      'end_date': null,
      'description': '',
      'created_at': '2026-09-01T00:00:00Z',
    };

Map<String, dynamic> _offerJson({String id = 'o1', String offerNo = 'TKF-001', String status = 'taslak', String customerName = 'Ali Veli'}) => {
      'id': id,
      'offer_no': offerNo,
      'revision_no': 1,
      'customer_id': 'c1',
      'customer_name': customerName,
      'customer_phone': '',
      'customer_email': '',
      'customer_address': '',
      'offer_date': '2026-09-01',
      'valid_until': null,
      'subtotal': 1000,
      'vat_rate': 20,
      'vat_amount': 200,
      'grand_total': 1200,
      'notes': '',
      'status': status,
      'is_passive': false,
      'items': <dynamic>[],
    };

Map<String, dynamic> _customerJson({String id = 'c1', String name = 'Ali Veli', String phone = '0532 000 00 00', String email = '', bool isActive = true}) => {
      'id': id,
      'name': name,
      'phone': phone,
      'email': email,
      'address': '',
      'tax_office': '',
      'tax_number': '',
      'notes': '',
      'is_active': isActive,
    };

Map<String, dynamic> _taskJson({String id = 't1', String title = 'Elektrik tesisatı', String priority = 'normal', String status = 'todo', String? dueDate, bool overdue = false}) => {
      'id': id,
      'schedule_item_id': null,
      'title': title,
      'description': '',
      'assigned_employee_id': null,
      'assigned_name': '',
      'priority': priority,
      'status': status,
      'due_date': dueDate,
      'completed_at': null,
      'is_overdue': overdue,
    };

Map<String, dynamic> _notificationJson({String id = 'n1', String title = 'Görev atandı', String? readAt, String actionTarget = ''}) => {
      'id': id,
      'type': 'task_assigned',
      'title': title,
      'body': 'Detaylar için dokunun',
      'entity_type': 'task',
      'entity_id': 't1',
      'project_id': 'p1',
      'action_target': actionTarget,
      'read_at': readAt,
      'created_at': '2026-09-20T10:00:00Z',
    };

Future<void> _pump(WidgetTester tester, FakeHttpClientAdapter adapter, Widget child, {Size size = const Size(400, 1600)}) async {
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp(home: child),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  group('ProjectsScreen — filtre/arama/gezinme', () {
    testWidgets('durum çipine dokunmak yeni durum parametresiyle yeniden istek atar', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/projects': [
          (status: 200, body: {'projects': [_projectJson()], 'total': 1}),
          (status: 200, body: {'projects': [_projectJson(status: 'active')], 'total': 1}),
        ],
      });
      await _pump(tester, adapter, const ProjectsScreen());

      expect(find.text('Merkez Ofis İnşaatı'), findsOneWidget);

      // "Aktif" hem filtre çipinde hem de projenin durum rozetinde geçer --
      // yalnızca çipi hedeflemek için FilterChip tipiyle daralt.
      await tester.tap(find.widgetWithText(FilterChip, 'Aktif'));
      await tester.pumpAndSettle();

      final activeCallIndex = adapter.calls.lastIndexOf('/projects');
      expect(adapter.requestQueries[activeCallIndex]['status'], 'active');
    });

    testWidgets('arama proje adı/müşteri üzerinde istemci tarafında filtreler', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/projects': [
          (
            status: 200,
            body: {
              'projects': [
                _projectJson(id: 'p1', name: 'Merkez Ofis İnşaatı', customerName: 'Ali Veli'),
                _projectJson(id: 'p2', name: 'Sahil Villası', customerName: 'Zeynep Kaya'),
              ],
              'total': 2,
            },
          ),
        ],
      });
      await _pump(tester, adapter, const ProjectsScreen());

      expect(find.text('Merkez Ofis İnşaatı'), findsOneWidget);
      expect(find.text('Sahil Villası'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'sahil');
      await tester.pumpAndSettle();

      expect(find.text('Merkez Ofis İnşaatı'), findsNothing);
      expect(find.text('Sahil Villası'), findsOneWidget);
    });

    testWidgets('proje kartına dokunmak /projeler/:id yoluna yönlendirir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/projects': [(status: 200, body: {'projects': [_projectJson()], 'total': 1})],
      });
      final client = await buildFakeApiClient(adapter);
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final router = GoRouter(
        initialLocation: '/projeler',
        routes: [
          GoRoute(path: '/projeler', builder: (c, s) => const ProjectsScreen()),
          GoRoute(path: '/projeler/:id', builder: (c, s) => Scaffold(body: Text('DETAY ${s.pathParameters['id']}'))),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Merkez Ofis İnşaatı'));
      await tester.pumpAndSettle();

      expect(find.text('DETAY p1'), findsOneWidget);
    });
  });

  group('OffersScreen — filtre/arama', () {
    testWidgets('durum sekmesi ve arama birlikte istemci tarafında filtreler', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/offers/': [
          (
            status: 200,
            body: {
              'offers': [
                _offerJson(id: 'o1', offerNo: 'TKF-001', status: 'taslak'),
                _offerJson(id: 'o2', offerNo: 'TKF-002', status: 'gönderildi'),
              ],
              'total': 2,
            },
          ),
        ],
      });
      await _pump(tester, adapter, const OffersScreen());

      expect(find.text('TKF-001'), findsOneWidget);
      expect(find.text('TKF-002'), findsOneWidget);

      // "Gönderildi" hem filtre çipinde hem de TKF-002'nin durum
      // rozetinde geçer -- yalnızca çipi hedeflemek için daralt.
      await tester.tap(find.widgetWithText(FilterChip, 'Gönderildi'));
      await tester.pumpAndSettle();

      expect(find.text('TKF-001'), findsNothing);
      expect(find.text('TKF-002'), findsOneWidget);
    });

    testWidgets('Pasif çipine dokunmak pasif filtresiyle yeni bir istek atar', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/offers/': [
          (status: 200, body: {'offers': [_offerJson()], 'total': 1}),
          (status: 200, body: {'offers': <dynamic>[], 'total': 0}),
        ],
      });
      await _pump(tester, adapter, const OffersScreen());

      // Yatay filtre çubuğundaki son çip (Pasif) dar test genişliğinde
      // lazy `ListView` tarafından henüz inşa edilmemiş/hit-test edilemez
      // olabilir -- gerçek dokunuşu simüle etmek yerine, üretim kodunun
      // AYNI `onSelected` callback'ini doğrudan çağırıyoruz (widget hâlâ
      // gerçek ağaçtan bulunuyor, yalnızca piksel-seviyeli dokunuş
      // simülasyonu atlanıyor).
      await tester.dragUntilVisible(
        find.text('Pasif'),
        find.byType(AppFilterBar),
        const Offset(-80, 0),
      );
      final pasifChip = tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Pasif'));
      pasifChip.onSelected!(true);
      await tester.pumpAndSettle();

      expect(adapter.calls.where((c) => c == '/offers/').length, 2);
    });
  });

  group('CustomersScreen — filtre/arama/ara ikonu', () {
    testWidgets('Aktif çipi filter=aktif parametresiyle sunucuya istek atar', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/customers': [
          (status: 200, body: {'customers': [_customerJson()]}),
          (status: 200, body: {'customers': [_customerJson()]}),
        ],
      });
      await _pump(tester, adapter, const CustomersScreen());

      // "Aktif" hem filtre çipinde hem de müşterinin durum rozetinde geçer.
      await tester.tap(find.widgetWithText(FilterChip, 'Aktif'));
      await tester.pumpAndSettle();

      final lastIndex = adapter.calls.lastIndexOf('/customers');
      expect(adapter.requestQueries[lastIndex]['filter'], 'aktif');
    });

    testWidgets('telefonu olmayan müşteri için ara ikonu gösterilmez', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/customers': [
          (status: 200, body: {'customers': [_customerJson(id: 'c1', name: 'Ali Veli', phone: ''), _customerJson(id: 'c2', name: 'Zeynep Kaya', phone: '0532 111 11 11')]}),
        ],
      });
      await _pump(tester, adapter, const CustomersScreen());

      expect(find.byIcon(Icons.call_outlined), findsOneWidget);
    });
  });

  group('CustomerDetailScreen — bölümler ve izin görünürlüğü', () {
    testWidgets('İletişim/Teklifler/Projeler/Finansal Özet tam izinli kullanıcı için sırayla görünür', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [
          (status: 200, body: _meJson(permissions: ['customers.manage', 'projects.read', 'offers.read', 'offers.create'])),
        ],
        '/customers/c1': [(status: 200, body: _customerJson())],
        '/projects': [(status: 200, body: {'projects': [_projectJson()], 'total': 1})],
        '/offers/': [(status: 200, body: {'offers': [_offerJson()], 'total': 1})],
      });
      await _pump(tester, adapter, const CustomerDetailScreen(customerId: 'c1'));

      final sectionOrder = ['İletişim', 'Teklifler', 'Projeler', 'Finansal Özet'];
      var lastY = -1.0;
      for (final title in sectionOrder) {
        expect(find.text(title), findsOneWidget);
        final y = tester.getTopLeft(find.text(title)).dy;
        expect(y, greaterThan(lastY));
        lastY = y;
      }
    });

    testWidgets('projects.read/offers.read izni olmayan kullanıcı Projeler/Teklifler/Finansal Özet bölümlerini görmez', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['customers.manage']))],
        '/customers/c1': [(status: 200, body: _customerJson())],
      });
      await _pump(tester, adapter, const CustomerDetailScreen(customerId: 'c1'));

      expect(find.text('Projeler'), findsNothing);
      expect(find.text('Teklifler'), findsNothing);
      expect(find.text('Finansal Özet'), findsNothing);
      expect(find.text('İletişim'), findsOneWidget);
    });
  });

  group('TasksScreen — öncelik/gecikme filtreleri (AppFilterBar wrap)', () {
    testWidgets('öncelik çipi yalnızca o önceliğe uyan görevleri bırakır', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/tasks/mine': [
          (
            status: 200,
            body: {
              'tasks': [
                {..._taskJson(id: 't1', title: 'Acil görev', priority: 'urgent'), 'project_id': 'p1', 'project_name': 'Merkez Ofis'},
                {..._taskJson(id: 't2', title: 'Normal görev', priority: 'normal'), 'project_id': 'p1', 'project_name': 'Merkez Ofis'},
              ],
            },
          ),
        ],
      });
      await _pump(tester, adapter, const TasksScreen());

      expect(find.text('Acil görev'), findsOneWidget);
      expect(find.text('Normal görev'), findsOneWidget);

      // "Acil" hem filtre çipinde hem de görevin öncelik rozetinde geçer.
      await tester.tap(find.widgetWithText(FilterChip, 'Acil'));
      await tester.pumpAndSettle();

      expect(find.text('Acil görev'), findsOneWidget);
      expect(find.text('Normal görev'), findsNothing);
    });

    testWidgets('yalnızca gecikmiş çipi gecikmemiş görevleri gizler', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/tasks/mine': [
          (
            status: 200,
            body: {
              'tasks': [
                {..._taskJson(id: 't1', title: 'Gecikmiş görev', dueDate: '2026-01-01', overdue: true), 'project_id': 'p1', 'project_name': 'Merkez Ofis'},
                {..._taskJson(id: 't2', title: 'Zamanında görev'), 'project_id': 'p1', 'project_name': 'Merkez Ofis'},
              ],
            },
          ),
        ],
      });
      await _pump(tester, adapter, const TasksScreen());

      await tester.tap(find.text('Yalnızca gecikmiş'));
      await tester.pumpAndSettle();

      expect(find.text('Gecikmiş görev'), findsOneWidget);
      expect(find.text('Zamanında görev'), findsNothing);
    });
  });

  group('TaskDetailScreen — bağlam ve izin gated aksiyonlar', () {
    testWidgets('Bağlam kartında proje adı gösterilir (projectDetailProvider ile doldurulur)', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['projects.tasks.update']))],
        '/projects/p1/tasks': [(status: 200, body: {'tasks': [_taskJson()]})],
        '/projects/p1': [(status: 200, body: _projectJson(name: 'Merkez Ofis İnşaatı'))],
      });
      await _pump(tester, adapter, const TaskDetailScreen(projectId: 'p1', taskId: 't1'));

      expect(find.text('Proje'), findsOneWidget);
      expect(find.text('Merkez Ofis İnşaatı'), findsOneWidget);
    });

    testWidgets('projects.tasks.update izni olmayan kullanıcı için Düzenle/Tamamla gizlenir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson(permissions: ['projects.tasks.read']))],
        '/projects/p1/tasks': [(status: 200, body: {'tasks': [_taskJson()]})],
        '/projects/p1': [(status: 200, body: _projectJson())],
      });
      await _pump(tester, adapter, const TaskDetailScreen(projectId: 'p1', taskId: 't1'));

      expect(find.text('Düzenle'), findsNothing);
      expect(find.text('Tamamla'), findsNothing);
    });
  });

  group('NotificationsScreen — okunmamış görsel ayrım + deep link', () {
    testWidgets('okunmamış bildirim kalın başlık ve nokta göstergesiyle ayrılır', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/notifications': [
          (
            status: 200,
            body: {
              'notifications': [
                _notificationJson(id: 'n1', title: 'Okunmamış bildirim', readAt: null),
                _notificationJson(id: 'n2', title: 'Okunmuş bildirim', readAt: '2026-09-20T11:00:00Z'),
              ],
              'total': 2,
            },
          ),
        ],
      });
      await _pump(tester, adapter, const NotificationsScreen());

      final unreadText = tester.widget<Text>(find.text('Okunmamış bildirim'));
      final readText = tester.widget<Text>(find.text('Okunmuş bildirim'));
      expect(unreadText.style?.fontWeight, FontWeight.w800);
      expect(readText.style?.fontWeight, FontWeight.w600);
      // Yalnızca okunmamış bildirim için dairesel bir nokta göstergesi
      // render edilir (okunmuş satırlarda bu widget hiç oluşturulmaz).
      expect(
        find.byWidgetPredicate(
          (w) => w is DecoratedBox && (w.decoration as BoxDecoration?)?.shape == BoxShape.circle,
        ),
        findsOneWidget,
      );
    });

    testWidgets('bildirime dokunmak okundu işaretler ve actionTarget yoluna yönlendirir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _meJson())],
        '/notifications': [
          (status: 200, body: {'notifications': [_notificationJson(readAt: null, actionTarget: '/gorevler-detay')], 'total': 1}),
          (status: 200, body: {'notifications': [_notificationJson(readAt: '2026-09-20T12:00:00Z', actionTarget: '/gorevler-detay')], 'total': 1}),
        ],
        '/notifications/n1/read': [(status: 200, body: {})],
      });
      final client = await buildFakeApiClient(adapter);
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final router = GoRouter(
        initialLocation: '/bildirimler',
        routes: [
          GoRoute(path: '/bildirimler', builder: (c, s) => const NotificationsScreen()),
          GoRoute(path: '/gorevler-detay', builder: (c, s) => const Scaffold(body: Text('HEDEF EKRAN'))),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(client)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Görev atandı'));
      await tester.pumpAndSettle();

      expect(adapter.calls, contains('/notifications/n1/read'));
      expect(find.text('HEDEF EKRAN'), findsOneWidget);
    });
  });
}
