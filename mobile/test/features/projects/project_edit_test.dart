import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/projects/data/project_edit_repository.dart';
import 'package:arvend/features/projects/domain/project_edit.dart';

import '../../test_utils/fake_api_client.dart';
import 'project_edit_fakes.dart';

Future<void> _pump(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(400, 2000) * 2.0;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextFormField, label);

void main() {
  late ApiClient offline;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    offline = await buildFakeApiClient(FakeHttpClientAdapter(script: {}));
  });

  group('model + repository', () {
    test('PUT body carries ONLY the editable fields (never money/offer/customer)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1': [
          (
            status: 200,
            body: {
              'id': 'p1',
              'project_no': 'PRJ-1',
              'name': 'Yeni Ad',
              'status': 'paused',
              'contract_amount': 10,
              'internal_notes': 'n',
              'source_offer_no': 'TKL-1',
              'source_revision_no': 3,
            }
          ),
        ],
      });
      final repo = ProjectEditRepository(await buildFakeApiClient(adapter));
      final p = await repo.update(
        'p1',
        const ProjectEditInput(
          name: ' Yeni Ad ',
          projectType: 'Tadilat',
          status: 'paused',
          startDate: '2026-09-01',
          endDate: null,
          description: 'd',
          internalNotes: 'n',
        ),
      );
      expect(p.sourceRevisionNo, 3);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body.keys.toSet(), {
        'name',
        'project_type',
        'status',
        'start_date',
        'end_date',
        'description',
        'internal_notes',
      });
      expect(body['name'], 'Yeni Ad');
      expect(body['end_date'], isNull);
    });

    test('status options mirror the web transitions table', () {
      expect(projectStatusOptions('planned'), ['planned', 'active', 'paused', 'cancelled']);
      expect(projectStatusOptions('active'), ['active', 'paused', 'completed', 'cancelled']);
      expect(projectStatusOptions('paused'), ['paused', 'active', 'completed', 'cancelled']);
      expect(projectStatusOptions('completed'), ['completed', 'active']);
      expect(projectStatusOptions('cancelled'), ['cancelled']);
      expect(formatApiDate(DateTime(2026, 3, 7)), '2026-03-07');
    });
  });

  group('screen', () {
    testWidgets('without projects.update: message, nothing loaded', (tester) async {
      final repo = FakeProjectEditRepository();
      await _pump(tester, projectEditApp(user: projectViewer, repo: repo, offlineClient: offline));
      expect(find.textContaining('Proje bilgilerini düzenleme yetkin yok'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('detail screen hides "Düzenle" without projects.update', (tester) async {
      await _pump(
        tester,
        projectEditApp(user: projectViewer, repo: FakeProjectEditRepository(), offlineClient: offline, location: '/projeler/p1'),
      );
      expect(find.byTooltip('Düzenle'), findsNothing);
    });

    testWidgets('detail screen shows "Düzenle" with projects.update and opens the edit screen', (tester) async {
      await _pump(
        tester,
        projectEditApp(
          user: projectEditorNoFinance,
          repo: FakeProjectEditRepository(),
          offlineClient: offline,
          location: '/projeler/p1',
        ),
      );
      expect(find.byTooltip('Düzenle'), findsOneWidget);
      await tester.tap(find.byTooltip('Düzenle'));
      await tester.pumpAndSettle();
      expect(find.text('Projeyi Düzenle'), findsOneWidget);
      expect(find.text('Değişiklikleri Kaydet'), findsOneWidget);
    });

    testWidgets('prefills, saves editable fields and returns to the detail screen', (tester) async {
      final repo = FakeProjectEditRepository();
      await _pump(
        tester,
        projectEditApp(user: projectEditorNoFinance, repo: repo, offlineClient: offline, location: '/projeler/p1'),
      );
      await tester.tap(find.byTooltip('Düzenle'));
      await tester.pumpAndSettle();

      expect(tester.widget<TextFormField>(_field('Proje Adı *')).controller!.text, 'Kadıköy Ofis Tadilatı');
      expect(find.text('01.09.2026'), findsOneWidget);
      expect(find.text('15.12.2026'), findsOneWidget);
      // Finans izni yok: sözleşme bedeli gösterilmez; diğer donmuş bilgiler görünür.
      expect(find.text('Sözleşme Bedeli'), findsNothing);
      expect(find.text('TKL-2026-0031'), findsOneWidget);
      expect(find.text('#2'), findsOneWidget);
      expect(find.text('Moda Mimarlık Ltd.'), findsOneWidget);

      await tester.enterText(_field('Proje Adı *'), 'Kadıköy Ofis Tadilatı - Faz 2');
      await tester.enterText(_field('Dahili Notlar (müşteri görmez)'), 'Yeni not');
      // Bitiş tarihini temizle.
      await tester.tap(find.byTooltip('Tarihi temizle').last);
      await tester.pump();
      await tester.tap(find.text('Aktif'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Durduruldu').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Değişiklikleri Kaydet'));
      await tester.pumpAndSettle();

      final input = repo.updates.single.input;
      expect(input.name, 'Kadıköy Ofis Tadilatı - Faz 2');
      expect(input.internalNotes, 'Yeni not');
      expect(input.status, 'paused');
      expect(input.startDate, '2026-09-01');
      expect(input.endDate, isNull);
      // Detay ekranına dönüldü.
      expect(find.text('Projeyi Düzenle'), findsNothing);
      expect(find.byTooltip('Düzenle'), findsOneWidget);
    });

    testWidgets('owner sees the contract amount (read-only)', (tester) async {
      await _pump(tester, projectEditApp(user: projectOwner, repo: FakeProjectEditRepository(), offlineClient: offline));
      expect(find.text('Sözleşme Bedeli'), findsOneWidget);
      expect(find.text('1.250.000,00 TL'), findsOneWidget);
    });

    testWidgets('cancelling asks for confirmation', (tester) async {
      final repo = FakeProjectEditRepository();
      await _pump(tester, projectEditApp(user: projectEditorNoFinance, repo: repo, offlineClient: offline));
      await tester.tap(find.text('Aktif'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('İptal Edildi').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Değişiklikleri Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Projeyi İptal Et'), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(repo.updates, isEmpty);
    });

    testWidgets('completed project can be reopened (to Aktif only) after confirmation', (tester) async {
      final repo = FakeProjectEditRepository(project: sampleEditable(status: 'completed'));
      await _pump(tester, projectEditApp(user: projectEditorNoFinance, repo: repo, offlineClient: offline));
      expect(find.text('Yeniden açmak için “Aktif”i seçin.'), findsOneWidget);

      await tester.tap(find.text('Tamamlandı'));
      await tester.pumpAndSettle();
      // Yalnızca Tamamlandı + Aktif (backend: completed -> active).
      expect(find.text('Durduruldu'), findsNothing);
      await tester.tap(find.text('Aktif').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Değişiklikleri Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Projeyi Yeniden Aç'), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(repo.updates, isEmpty);

      await tester.tap(find.text('Değişiklikleri Kaydet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yeniden Aç'));
      await tester.pumpAndSettle();
      expect(repo.updates.single.input.status, 'active');
    });

    testWidgets('cancelled project still cannot be reopened', (tester) async {
      final repo = FakeProjectEditRepository(project: sampleEditable(status: 'cancelled'));
      await _pump(tester, projectEditApp(user: projectEditorNoFinance, repo: repo, offlineClient: offline));
      expect(find.text('İptal Edildi durumundaki bir proje yeniden açılamaz.'), findsOneWidget);
    });

    testWidgets('empty name is rejected client-side; backend errors are shown', (tester) async {
      final repo = FakeProjectEditRepository()
        ..saveError = const ApiException(statusCode: 409, message: 'geçersiz proje durumu geçişi', kind: ApiErrorKind.conflict);
      await _pump(tester, projectEditApp(user: projectEditorNoFinance, repo: repo, offlineClient: offline));
      await tester.enterText(_field('Proje Adı *'), '  ');
      await tester.tap(find.text('Değişiklikleri Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Proje adı zorunludur'), findsOneWidget);
      expect(repo.calls.where((c) => c.startsWith('update')), isEmpty);

      await tester.enterText(_field('Proje Adı *'), 'Ad');
      await tester.tap(find.text('Değişiklikleri Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('geçersiz proje durumu geçişi'), findsOneWidget);
    });

    testWidgets('403 on save shows the permission message', (tester) async {
      final repo = FakeProjectEditRepository()
        ..saveError = const ApiException(statusCode: 403, message: 'bu işlem için yetkiniz yok', kind: ApiErrorKind.forbidden);
      await _pump(tester, projectEditApp(user: projectEditorNoFinance, repo: repo, offlineClient: offline));
      await tester.tap(find.text('Değişiklikleri Kaydet'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Proje bilgilerini düzenleme yetkin yok'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
