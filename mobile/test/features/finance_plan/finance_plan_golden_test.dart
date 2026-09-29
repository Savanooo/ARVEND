@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/finance_plan/finance_plan_routes.dart';

import 'finance_plan_test_support.dart';

/// Ödeme Planı + Faturalar ekran görüntüleri (360x800, uygulama fontlarıyla;
/// uzun ekranlar için ayrıca tam boy): liste / detay / form x sahip-yönetici
/// ve salt-okunur, izinsiz ve kilitli proje. Üretmek:
///   flutter test --tags golden --update-goldens test/features/finance_plan
/// Veri deterministik (`kPlanItemFixtures`, `kInvoiceFixtures`, bugün
/// 2026-09-29), ağ yok.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await loadAppFonts();
  });

  Future<void> pumpAt(
    WidgetTester tester, {
    required User user,
    required String location,
    FakeFinancePlanRepository? repo,
    Project Function()? project,
  }) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 800) * 2.0;
    addTearDown(tester.view.reset);
    // Gerçek gölgeler (flutter_test varsayılanı düz siyah blok); expectGolden
    // sonunda geri alınır.
    debugDisableShadows = false;
    await tester.pumpWidget(
      buildFinancePlanApp(
        user: user,
        repo: repo ?? FakeFinancePlanRepository(),
        location: location,
        project: project,
        theme: goldenTheme(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expectGolden(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    debugDisableShadows = true;
  }

  /// Ekranın en uzun dikey kaydırılabilirini sonuna kadar gösterecek boya
  /// büyütür (tam sayfa görüntüsü). Liste önce sonuna kaydırılır: çizilmemiş
  /// çocukların yüksekliği tahminidir, gerçek içerik boyu ancak hepsi
  /// yerleşince bilinir.
  Future<void> growToFullHeight(WidgetTester tester) async {
    final scrollables = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down);
    var extra = 0.0;
    for (final element in scrollables.evaluate()) {
      final position = ((element as StatefulElement).state as ScrollableState).position;
      for (var i = 0; i < 5; i++) {
        final before = position.maxScrollExtent;
        position.jumpTo(before);
        await tester.pump();
        if (position.maxScrollExtent == before) break;
      }
      if (position.maxScrollExtent > extra) extra = position.maxScrollExtent;
      position.jumpTo(0);
      await tester.pump();
    }
    tester.view.physicalSize = Size(360, (800 + extra).ceilToDouble()) * 2.0;
    await tester.pumpAndSettle();
  }

  const planPath = '/projeler/$kProjectId/odeme-plani';
  const invoicesListPath = '/projeler/$kProjectId/faturalar';

  // ---------- Ödeme Planı ----------

  testWidgets('payment plan owner', (tester) async {
    await pumpAt(tester, user: fpOwnerUser, location: planPath);
    await expectGolden(tester, 'payment_plan_owner_360x800');
  });

  testWidgets('payment plan owner full', (tester) async {
    await pumpAt(tester, user: fpOwnerUser, location: planPath);
    await growToFullHeight(tester);
    await expectGolden(tester, 'payment_plan_owner_360_full');
  });

  testWidgets('payment plan read-only', (tester) async {
    await pumpAt(tester, user: fpReadOnlyUser, location: planPath);
    await expectGolden(tester, 'payment_plan_readonly_360x800');
  });

  testWidgets('payment plan locked project (manager)', (tester) async {
    await pumpAt(
      tester,
      user: fpManagerUser,
      location: planPath,
      project: () => financeProject(status: 'completed'),
    );
    await expectGolden(tester, 'payment_plan_locked_360x800');
  });

  testWidgets('payment plan empty (manager)', (tester) async {
    await pumpAt(tester, user: fpManagerUser, location: planPath, repo: FakeFinancePlanRepository(items: const []));
    await expectGolden(tester, 'payment_plan_empty_360x800');
  });

  testWidgets('payment plan no access', (tester) async {
    await pumpAt(tester, user: fpNoAccessUser, location: planPath);
    await expectGolden(tester, 'payment_plan_no_access_360x800');
  });

  testWidgets('plan item detail owner (overdue)', (tester) async {
    await pumpAt(tester, user: fpOwnerUser, location: paymentPlanItemPath(kProjectId, 'i2'));
    await expectGolden(tester, 'plan_item_detail_owner_360x800');
  });

  testWidgets('plan item detail owner full', (tester) async {
    await pumpAt(tester, user: fpOwnerUser, location: paymentPlanItemPath(kProjectId, 'i2'));
    await growToFullHeight(tester);
    await expectGolden(tester, 'plan_item_detail_owner_360_full');
  });

  testWidgets('plan item detail read-only', (tester) async {
    await pumpAt(tester, user: fpReadOnlyUser, location: paymentPlanItemPath(kProjectId, 'i2'));
    await growToFullHeight(tester);
    await expectGolden(tester, 'plan_item_detail_readonly_360_full');
  });

  testWidgets('plan item detail cancelled', (tester) async {
    await pumpAt(tester, user: fpOwnerUser, location: paymentPlanItemPath(kProjectId, 'i5'));
    await expectGolden(tester, 'plan_item_detail_cancelled_360x800');
  });

  testWidgets('plan item form create', (tester) async {
    await pumpAt(tester, user: fpManagerUser, location: planPath);
    await tester.tap(find.text('Kalem Ekle'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'plan_item_form_create_360x800');
  });

  testWidgets('plan item form edit (percentage)', (tester) async {
    await pumpAt(tester, user: fpOwnerUser, location: paymentPlanItemEditPath(kProjectId, 'i2'));
    await growToFullHeight(tester);
    await expectGolden(tester, 'plan_item_form_edit_360_full');
  });

  testWidgets('plan item form validation', (tester) async {
    await pumpAt(tester, user: fpOwnerUser, location: paymentPlanNewPath(kProjectId));
    await tester.tap(find.text('Kalemi Ekle'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'plan_item_form_validation_360x800');
  });

  // ---------- Faturalar ----------

  testWidgets('invoices owner', (tester) async {
    await pumpAt(tester, user: fpOwnerUser, location: invoicesListPath);
    await expectGolden(tester, 'invoices_owner_360x800');
  });

  // Tam boy varyant yok: liste 360x800'e sığıyor, görüntü birebir aynıydı.

  testWidgets('invoices read-only', (tester) async {
    await pumpAt(tester, user: fpReadOnlyUser, location: invoicesListPath);
    await expectGolden(tester, 'invoices_readonly_360x800');
  });

  testWidgets('invoices no access', (tester) async {
    await pumpAt(tester, user: fpNoAccessUser, location: invoicesListPath);
    await expectGolden(tester, 'invoices_no_access_360x800');
  });

  testWidgets('invoice detail manager (overdue sales)', (tester) async {
    await pumpAt(tester, user: fpManagerUser, location: invoicePath(kProjectId, 'f3'));
    await expectGolden(tester, 'invoice_detail_manager_360x800');
  });

  // Tam boy varyant yok: gövdedeki tekrar başlık kaldırılınca detay 360x800'e sığıyor.

  testWidgets('invoice detail read-only', (tester) async {
    await pumpAt(tester, user: fpReadOnlyUser, location: invoicePath(kProjectId, 'f3'));
    await growToFullHeight(tester);
    await expectGolden(tester, 'invoice_detail_readonly_360_full');
  });

  testWidgets('invoice status sheet', (tester) async {
    await pumpAt(tester, user: fpOwnerUser, location: invoicePath(kProjectId, 'f1'));
    await tester.scrollUntilVisible(find.text('Durumu Değiştir'), 200);
    await tester.tap(find.text('Durumu Değiştir'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'invoice_status_sheet_360x800');
  });

  testWidgets('invoice form create', (tester) async {
    await pumpAt(tester, user: fpOwnerUser, location: invoicesListPath);
    await tester.tap(find.text('Fatura Ekle'));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'invoice_form_create_360x800');
  });

  testWidgets('invoice form create full', (tester) async {
    await pumpAt(tester, user: fpOwnerUser, location: invoiceNewPath(kProjectId));
    await growToFullHeight(tester);
    await expectGolden(tester, 'invoice_form_create_360_full');
  });
}
