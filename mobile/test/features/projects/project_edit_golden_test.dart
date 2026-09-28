@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/domain/project_edit.dart';

import '../../test_utils/fake_api_client.dart';
import 'project_edit_fakes.dart';

/// "Proje bilgilerini düzenle" ekran görüntüleri (360x800, PNG 720x1600):
///   flutter test --tags golden --update-goldens test/features/projects
void main() {
  late ApiClient offline;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await loadAppFonts();
    offline = await buildFakeApiClient(FakeHttpClientAdapter(script: {}));
  });

  final cases = <String, ({User user, ProjectEditable project, bool scrollToEnd})>{
    'project_edit_owner_360x800': (user: projectOwner, project: sampleEditable(), scrollToEnd: false),
    'project_edit_owner_bottom_360x800': (user: projectOwner, project: sampleEditable(), scrollToEnd: true),
    'project_edit_no_finance_bottom_360x800': (
      user: projectEditorNoFinance,
      project: sampleEditable(),
      scrollToEnd: true,
    ),
    'project_edit_completed_360x800': (
      user: projectEditorNoFinance,
      project: sampleEditable(status: 'completed'),
      scrollToEnd: false,
    ),
    'project_edit_no_access_360x800': (user: projectViewer, project: sampleEditable(), scrollToEnd: false),
  };

  // Proje detayının üst çubuğundaki "Düzenle" aksiyonu (projects.update).
  testWidgets('project_detail_edit_action_360x800', (tester) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 800) * 2.0;
    addTearDown(tester.view.reset);
    await withRealShadows(() async {
      await tester.pumpWidget(projectEditApp(
        user: projectEditorNoFinance,
        repo: FakeProjectEditRepository(),
        offlineClient: offline,
        location: '/projeler/p1',
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/project_detail_edit_action_360x800.png'));
    });
  });

  for (final entry in cases.entries) {
    testWidgets(entry.key, (tester) async {
      tester.view.devicePixelRatio = 2.0;
      tester.view.physicalSize = const Size(360, 800) * 2.0;
      addTearDown(tester.view.reset);
      await withRealShadows(() async {
        await tester.pumpWidget(projectEditApp(
          user: entry.value.user,
          repo: FakeProjectEditRepository(project: entry.value.project),
          offlineClient: offline,
        ));
        await tester.pumpAndSettle();
        if (entry.value.scrollToEnd) {
          await tester.drag(find.byType(ListView).last, const Offset(0, -2000));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${entry.key}.png'));
      });
    });
  }
}
