import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/presentation/project_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';
import 'form_test_support.dart';

/// Proje silme (backend migration 0070): projects.delete direkt siler;
/// projeyi düzenleyebilen talep gönderir; para hareketi olan proje
/// silinmez (409 nedeni pencerede gösterilir); yetkili bekleyen talebi
/// onaylar ya da reddeder.

Project _project({Map<String, dynamic>? deleteRequest}) => Project.fromJson({
      'id': 'p1',
      'project_no': 'PRJ-2026-0007',
      'name': 'Kadıköy Konut',
      'project_type': '',
      'customer_name': 'Ali Veli',
      'currency': 'TRY',
      'status': 'active',
      'created_at': '2026-10-01T09:00:00Z',
      'delete_request': ?deleteRequest,
    });

Map<String, dynamic> _request({String requestedBy = 'u2'}) => {
      'id': 'r1',
      'project_id': 'p1',
      'requested_by': requestedBy,
      'requested_by_name': 'Proje Yöneticisi',
      'reason': 'yanlış tekliften açıldı',
      'created_at': '2026-10-14T09:30:00Z',
    };

Future<FakeHttpClientAdapter> _pump(
  WidgetTester tester, {
  required Set<String> permissions,
  required List<Project> projects,
  Map<String, List<ScriptedResponse>> script = const {},
}) async {
  final adapter = FakeHttpClientAdapter(script: script);
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  var call = 0;
  final router = GoRouter(
    initialLocation: '/projeler/p1',
    routes: [
      GoRoute(path: '/projeler', builder: (c, s) => const Scaffold(body: Text('PROJE LİSTESİ'))),
      GoRoute(path: '/projeler/:id', builder: (c, s) => ProjectDetailScreen(projectId: s.pathParameters['id']!)),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => FakeAuth(testUser(permissions))),
        projectDetailProvider.overrideWith((ref, id) async => projects[call < projects.length ? call++ : projects.length - 1]),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return adapter;
}

const _owner = {'projects.read', 'projects.update', 'projects.delete'};
const _editor = {'projects.read', 'projects.update'};

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  testWidgets('silme yetkilisi onaydan sonra projeyi siler ve listeye döner', (tester) async {
    final adapter = await _pump(tester, permissions: _owner, projects: [_project()], script: {
      '/projects/p1': [(status: 200, body: {'ok': true})],
    });
    await tester.tap(find.byTooltip('Diğer işlemler'));
    await tester.pumpAndSettle();
    expect(find.text('Silme Talebi Gönder'), findsNothing);
    await tester.tap(find.text('Projeyi Sil'));
    await tester.pumpAndSettle();
    expect(adapter.calls, isNot(contains('/projects/p1')), reason: 'onaydan önce istek yok');
    await tester.tap(find.byKey(const ValueKey('project-delete-confirm')));
    await tester.pumpAndSettle();

    expect(adapter.methods.last, 'DELETE');
    expect(find.text('PROJE LİSTESİ'), findsOneWidget);
  });

  testWidgets('para hareketi olan proje: sunucunun nedeni pencerede gösterilir, proje kalır', (tester) async {
    await _pump(tester, permissions: _owner, projects: [_project()], script: {
      '/projects/p1': [
        (
          status: 409,
          body: {'error': 'Bu projede 2 masraf, 1 tahsilat var; proje silinemez. Kayıtlar kaybolmasın diye projeyi İptal durumuna alabilirsin.'},
        ),
      ],
    });
    await tester.tap(find.byTooltip('Diğer işlemler'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Projeyi Sil'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project-delete-confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('project-delete-blocked')), findsOneWidget);
    expect(find.textContaining('2 masraf, 1 tahsilat'), findsOneWidget);
    expect(find.text('PROJE LİSTESİ'), findsNothing);
  });

  testWidgets('silme izni olmayan gerekçeyle talep gönderir, uyarı ve geri çekme görünür', (tester) async {
    final adapter = await _pump(
      tester,
      permissions: _editor,
      projects: [_project(), _project(deleteRequest: _request(requestedBy: 'u1'))],
      script: {
        '/projects/p1/delete-request': [(status: 201, body: _request(requestedBy: 'u1'))],
      },
    );
    await tester.tap(find.byTooltip('Diğer işlemler'));
    await tester.pumpAndSettle();
    expect(find.text('Projeyi Sil'), findsNothing);
    await tester.tap(find.text('Silme Talebi Gönder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('project-delete-request-reason')), 'yanlış tekliften açıldı');
    await tester.tap(find.byKey(const ValueKey('project-delete-request-reason-confirm')));
    await tester.pumpAndSettle();

    expect(requestBodyFor(adapter, '/projects/p1/delete-request'), {'reason': 'yanlış tekliften açıldı'});
    expect(find.byKey(const ValueKey('project-delete-request-notice')), findsOneWidget);
    expect(find.byKey(const ValueKey('delete-request-withdraw')), findsOneWidget);
    expect(find.byKey(const ValueKey('delete-request-approve')), findsNothing);
  });

  testWidgets('yetkili bekleyen talebi onaylar: proje silinir', (tester) async {
    final adapter = await _pump(tester, permissions: _owner, projects: [_project(deleteRequest: _request())], script: {
      '/projects/p1/delete-request/approve': [(status: 200, body: {'ok': true})],
    });
    expect(find.textContaining('Proje Yöneticisi bu projenin silinmesini istedi'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('delete-request-approve')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project-delete-confirm')));
    await tester.pumpAndSettle();

    expect(adapter.calls, contains('/projects/p1/delete-request/approve'));
    expect(find.text('PROJE LİSTESİ'), findsOneWidget);
  });

  testWidgets('yetkili gerekçeyle reddeder: proje kalır', (tester) async {
    final adapter = await _pump(
      tester,
      permissions: _owner,
      projects: [_project(deleteRequest: _request()), _project()],
      script: {
        '/projects/p1/delete-request/reject': [(status: 200, body: {'ok': true})],
      },
    );
    await tester.tap(find.byKey(const ValueKey('delete-request-reject')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('project-delete-reject-note')), 'devam ediyor');
    await tester.tap(find.byKey(const ValueKey('project-delete-reject-note-confirm')));
    await tester.pumpAndSettle();

    expect(requestBodyFor(adapter, '/projects/p1/delete-request/reject'), {'note': 'devam ediyor'});
    expect(find.byKey(const ValueKey('project-delete-request-notice')), findsNothing);
  });
}
