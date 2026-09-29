@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/ops_team/ops_team_routes.dart';

import 'ops_team_test_support.dart';

/// Planlama / Proje Ekibi / Proje Erişimi ekran görüntüleri (360x800 ve
/// uzun ekranlarda tam sayfa, uygulama fontlarıyla): sahip/yönetici,
/// salt-okunur, kilitli proje ve yetkisiz varyantlar. Üretmek:
///   flutter test --tags golden --update-goldens test/features/ops_team
/// Veri deterministik (`ops_team_test_support.dart`, bugün 2026-09-29).
void main() {
  setUpAll(loadAppFonts);

  Future<void> pumpAt(
    WidgetTester tester, {
    required User user,
    required String location,
    String projectStatus = 'active',
    FakeOpsTeamRepository? repo,
  }) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 800) * 2.0;
    addTearDown(tester.view.reset);
    // Gerçek gölgeler (flutter_test varsayılanı düz siyah blok); expectGolden
    // sonunda geri alınır.
    debugDisableShadows = false;
    await tester.pumpWidget(buildOpsApp(
      user: user,
      repo: repo ?? FakeOpsTeamRepository(),
      initialLocation: location,
      projectStatus: projectStatus,
      theme: goldenTheme(),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> expectGolden(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    debugDisableShadows = true;
  }

  /// Ekranın tamamı: dikey kaydırıcının sonuna kadar uzatılmış görünüm.
  Future<void> expandToFullPage(WidgetTester tester) async {
    final scrollable = tester.state<ScrollableState>(
      find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last,
    );
    final fullHeight = (800 + scrollable.position.maxScrollExtent).ceilToDouble();
    tester.view.physicalSize = Size(360, fullHeight) * 2.0;
    await tester.pumpAndSettle();
  }

  group('Planlama', () {
    testWidgets('owner', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: schedulePath(kProjectId));
      await expectGolden(tester, 'schedule_owner_360x800');
    });

    testWidgets('owner full page', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: schedulePath(kProjectId));
      await expandToFullPage(tester);
      await expectGolden(tester, 'schedule_owner_360_full');
    });

    testWidgets('read-only', (tester) async {
      await pumpAt(tester, user: opsReadOnlyUser, location: schedulePath(kProjectId));
      await expectGolden(tester, 'schedule_readonly_360x800');
    });

    testWidgets('locked project', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: schedulePath(kProjectId), projectStatus: 'completed');
      await expectGolden(tester, 'schedule_locked_360x800');
    });

    testWidgets('no access', (tester) async {
      await pumpAt(tester, user: opsNoAccessUser, location: schedulePath(kProjectId));
      await expectGolden(tester, 'schedule_no_access_360x800');
    });

    testWidgets('empty', (tester) async {
      await pumpAt(
        tester,
        user: opsOwnerUser,
        location: schedulePath(kProjectId),
        repo: FakeOpsTeamRepository(schedule: const []),
      );
      await expectGolden(tester, 'schedule_empty_owner_360x800');
    });

    testWidgets('embedded in project detail group', (tester) async {
      await pumpAt(tester, user: opsManagerUser, location: '/projeler/$kProjectId?alt=planlama');
      await expectGolden(tester, 'schedule_embedded_manager_360x800');
    });

    testWidgets('item detail owner (overdue)', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: scheduleItemPath(kProjectId, 's3'));
      await expectGolden(tester, 'schedule_item_detail_owner_360x800');
    });

    // Tam boy varyant yok: tekrarlar kaldırılınca detay 360x800'e sığıyor.

    testWidgets('item detail planned owner', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: scheduleItemPath(kProjectId, 's5'));
      await expectGolden(tester, 'schedule_item_detail_planned_owner_360x800');
    });

    testWidgets('item detail read-only', (tester) async {
      await pumpAt(tester, user: opsReadOnlyUser, location: scheduleItemPath(kProjectId, 's3'));
      await expectGolden(tester, 'schedule_item_detail_readonly_360x800');
    });

    testWidgets('complete confirm', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: scheduleItemPath(kProjectId, 's3'));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Tamamla'));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'schedule_item_complete_confirm_360x800');
    });

    testWidgets('form create', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: scheduleNewPath(kProjectId));
      await expectGolden(tester, 'schedule_item_form_create_360x800');
    });

    testWidgets('form edit full page', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: scheduleItemEditPath(kProjectId, 's3'));
      await expandToFullPage(tester);
      await expectGolden(tester, 'schedule_item_form_edit_360_full');
    });
  });

  group('Proje Ekibi', () {
    testWidgets('owner', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: teamPath(kProjectId));
      await expectGolden(tester, 'team_owner_360x800');
    });

    testWidgets('owner full page (past expanded)', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: teamPath(kProjectId));
      await tester.tap(find.text('GEÇMİŞ EKİP (2)'));
      await tester.pumpAndSettle();
      await expandToFullPage(tester);
      await expectGolden(tester, 'team_owner_360_full');
    });

    testWidgets('read-only', (tester) async {
      await pumpAt(tester, user: opsReadOnlyUser, location: teamPath(kProjectId));
      await expectGolden(tester, 'team_readonly_360x800');
    });

    testWidgets('locked project', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: teamPath(kProjectId), projectStatus: 'cancelled');
      await expectGolden(tester, 'team_locked_360x800');
    });

    testWidgets('add sheet', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: teamPath(kProjectId));
      await tester.tap(find.text('Ekibe Ekle'));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'team_add_sheet_360x800');
    });

    testWidgets('remove confirm', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: teamPath(kProjectId));
      await tester.tap(find.byTooltip('Ekipten Çıkar').first);
      await tester.pumpAndSettle();
      await expectGolden(tester, 'team_remove_confirm_360x800');
    });
  });

  group('Proje Erişimi', () {
    testWidgets('owner', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: accessPath(kProjectId));
      await expectGolden(tester, 'access_owner_360x800');
    });

    testWidgets('manager read-only', (tester) async {
      await pumpAt(tester, user: opsManagerUser, location: accessPath(kProjectId));
      await expectGolden(tester, 'access_readonly_360x800');
    });

    testWidgets('no access', (tester) async {
      await pumpAt(tester, user: opsNoAccessUser, location: accessPath(kProjectId));
      await expectGolden(tester, 'access_no_access_360x800');
    });

    testWidgets('grant sheet', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: accessPath(kProjectId));
      await tester.tap(find.text('Erişim Ver'));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'access_grant_sheet_360x800');
    });

    testWidgets('user sheet', (tester) async {
      await pumpAt(tester, user: opsOwnerUser, location: accessPath(kProjectId));
      await tester.tap(find.text('Murat Er'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proje Yöneticisi').last);
      await tester.pumpAndSettle();
      await expectGolden(tester, 'access_user_sheet_360x800');
    });
  });
}
