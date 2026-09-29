@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/budget/budget_routes.dart';
import 'package:arvend/features/projects/domain/project.dart';

import 'budget_test_support.dart';

/// Bütçe & Maliyet Kontrolü ekran görüntüleri (360x800, uygulama
/// fontlarıyla; uzun ekranlar için ayrıca tam sayfa). Sahip/yönetici (tam
/// yetki) ve salt-okunur (Proje Yöneticisi) varyantları. Üretmek:
///   flutter test --tags golden --update-goldens test/features/projects/budget
/// Veri deterministik (budget_test_support.dart), ağ yok.
void main() {
  setUpAll(loadAppFonts);

  Future<void> pumpAt(
    WidgetTester tester, {
    required User user,
    String? location,
    FakeBudgetRepository? repo,
    Project? project,
  }) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 800) * 2.0;
    addTearDown(tester.view.reset);
    debugDisableShadows = false;
    await tester.pumpWidget(
      buildBudgetApp(
        user: user,
        repo: repo ?? FakeBudgetRepository(),
        project: project,
        initialLocation: location,
        theme: goldenTheme(),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Tüm içeriği tek görüntüye sığdırır. `ListView(children:)` henüz
  /// kurulmamış çocukların yüksekliğini TAHMİN eder; sona kaydırıp gerçek
  /// kapsam sabitlenene kadar ölçülür.
  Future<void> fullPage(WidgetTester tester) async {
    ScrollableState scrollable() => tester.state<ScrollableState>(
      find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last,
    );
    var extent = -1.0;
    for (var i = 0; i < 10 && scrollable().position.maxScrollExtent != extent; i++) {
      extent = scrollable().position.maxScrollExtent;
      scrollable().position.jumpTo(extent);
      await tester.pumpAndSettle();
    }
    scrollable().position.jumpTo(0);
    await tester.pumpAndSettle();
    tester.view.physicalSize = Size(360, (800 + extent).ceilToDouble()) * 2.0;
    await tester.pumpAndSettle();
  }

  Future<void> expectGolden(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    debugDisableShadows = true;
  }

  group('Maliyet Kontrolü sekmesi (proje detayı içinde)', () {
    testWidgets('owner', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser);
      await expectGolden(tester, 'cost_control_tab_owner_360x800');
    });

    testWidgets('owner full page', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser);
      await fullPage(tester);
      await expectGolden(tester, 'cost_control_tab_owner_360_full');
    });

    testWidgets('read-only (proje yöneticisi)', (tester) async {
      await pumpAt(tester, user: budgetReadOnlyUser);
      await expectGolden(tester, 'cost_control_tab_readonly_360x800');
    });

    testWidgets('no budget yet', (tester) async {
      await pumpAt(
        tester,
        user: budgetOwnerUser,
        repo: FakeBudgetRepository(
          budget: null,
          adjustments: const [],
          commitments: const [],
          costControl: emptyCostControl(),
        ),
      );
      await fullPage(tester);
      await expectGolden(tester, 'cost_control_tab_no_budget_360_full');
    });

    testWidgets('no access (saha)', (tester) async {
      await pumpAt(tester, user: budgetFieldUser);
      await expectGolden(tester, 'cost_control_tab_no_access_360x800');
    });

    testWidgets('locked project (tamamlandı)', (tester) async {
      await pumpAt(
        tester,
        user: budgetOwnerUser,
        project: sampleProject(status: 'completed'),
      );
      await expectGolden(tester, 'cost_control_tab_locked_360x800');
    });

    testWidgets('line detail sheet (owner)', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser);
      final target = find.text('MLZ-002 — İnşaat Demiri');
      await tester.scrollUntilVisible(target, 300, scrollable: find.byType(Scrollable).last);
      await tester.tap(target);
      await tester.pumpAndSettle();
      await expectGolden(tester, 'cost_line_sheet_owner_360x800');
    });

    testWidgets('full screen hub', (tester) async {
      await pumpAt(tester, user: budgetFinanceUser, location: costControlPath(kProjectId));
      await expectGolden(tester, 'cost_control_screen_finance_360x800');
    });
  });

  group('Bütçe', () {
    testWidgets('baselined owner full', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser, location: budgetPath(kProjectId));
      await fullPage(tester);
      await expectGolden(tester, 'budget_baselined_owner_360_full');
    });

    testWidgets('draft owner', (tester) async {
      await pumpAt(
        tester,
        user: budgetOwnerUser,
        location: budgetPath(kProjectId),
        repo: FakeBudgetRepository(budget: kDraftBudget, adjustments: const []),
      );
      await expectGolden(tester, 'budget_draft_owner_360x800');
    });

    testWidgets('read-only', (tester) async {
      await pumpAt(tester, user: budgetReadOnlyUser, location: budgetPath(kProjectId));
      await expectGolden(tester, 'budget_readonly_360x800');
    });

    testWidgets('no budget owner', (tester) async {
      await pumpAt(
        tester,
        user: budgetOwnerUser,
        location: budgetPath(kProjectId),
        repo: FakeBudgetRepository(budget: null),
      );
      await expectGolden(tester, 'budget_empty_owner_360x800');
    });

    testWidgets('line form create', (tester) async {
      await pumpAt(
        tester,
        user: budgetOwnerUser,
        location: budgetLineCreatePath(kProjectId),
        repo: FakeBudgetRepository(budget: kDraftBudget),
      );
      await expectGolden(tester, 'budget_line_form_create_360x800');
    });

    testWidgets('line form edit (server computes amount)', (tester) async {
      await pumpAt(
        tester,
        user: budgetOwnerUser,
        location: budgetLineEditPath(kProjectId, 'l1'),
        repo: FakeBudgetRepository(budget: kDraftBudget),
      );
      await fullPage(tester);
      await expectGolden(tester, 'budget_line_form_edit_360_full');
    });
  });

  group('WBS', () {
    testWidgets('owner', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser, location: wbsPath(kProjectId));
      await expectGolden(tester, 'wbs_owner_360x800');
    });

    testWidgets('read-only', (tester) async {
      await pumpAt(tester, user: budgetReadOnlyUser, location: wbsPath(kProjectId));
      await expectGolden(tester, 'wbs_readonly_360x800');
    });
  });

  group('Bütçe Revizyonları', () {
    testWidgets('owner', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser, location: budgetAdjustmentsPath(kProjectId));
      await expectGolden(tester, 'adjustments_owner_360x800');
    });

    testWidgets('owner full', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser, location: budgetAdjustmentsPath(kProjectId));
      await fullPage(tester);
      await expectGolden(tester, 'adjustments_owner_360_full');
    });

    testWidgets('read-only', (tester) async {
      await pumpAt(tester, user: budgetReadOnlyUser, location: budgetAdjustmentsPath(kProjectId));
      await expectGolden(tester, 'adjustments_readonly_360x800');
    });

    testWidgets('create sheet', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser, location: budgetAdjustmentsPath(kProjectId));
      await tester.tap(find.text('Revizyon Oluştur'));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'adjustment_sheet_360x800');
    });
  });

  group('Taahhütler', () {
    testWidgets('owner', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser, location: commitmentsPath(kProjectId));
      await expectGolden(tester, 'commitments_owner_360x800');
    });

    testWidgets('owner full', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser, location: commitmentsPath(kProjectId));
      await fullPage(tester);
      await expectGolden(tester, 'commitments_owner_360_full');
    });

    testWidgets('read-only', (tester) async {
      await pumpAt(tester, user: budgetReadOnlyUser, location: commitmentsPath(kProjectId));
      await expectGolden(tester, 'commitments_readonly_360x800');
    });

    testWidgets('manual commitment sheet (owner)', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser, location: commitmentsPath(kProjectId));
      await tester.tap(find.text('Şantiye güvenlik hizmeti (Ekim)'));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'commitment_sheet_owner_360x800');
    });

    testWidgets('form', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser, location: commitmentCreatePath(kProjectId));
      await expectGolden(tester, 'commitment_form_360x800');
    });
  });

  group('Tahmin (ETC)', () {
    testWidgets('owner', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser, location: forecastPath(kProjectId));
      await expectGolden(tester, 'forecast_owner_360x800');
    });

    testWidgets('read-only', (tester) async {
      await pumpAt(tester, user: budgetReadOnlyUser, location: forecastPath(kProjectId));
      await expectGolden(tester, 'forecast_readonly_360x800');
    });

    testWidgets('sheet', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser, location: forecastPath(kProjectId));
      await tester.tap(find.text('Düzenle').first);
      await tester.pumpAndSettle();
      await expectGolden(tester, 'forecast_sheet_360x800');
    });
  });

  group('Gerçekleşen', () {
    testWidgets('owner', (tester) async {
      await pumpAt(tester, user: budgetOwnerUser, location: actualCostPath(kProjectId));
      await expectGolden(tester, 'actual_cost_owner_360x800');
    });

    testWidgets('no finance permission (proje yöneticisi)', (tester) async {
      await pumpAt(tester, user: budgetReadOnlyUser, location: actualCostPath(kProjectId));
      await expectGolden(tester, 'actual_cost_no_access_360x800');
    });
  });
}
