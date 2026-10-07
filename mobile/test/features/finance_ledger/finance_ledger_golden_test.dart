@Tags(['golden'])
library;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/finance_ledger/presentation/ledger_sections.dart';
import 'package:arvend/features/projects/finance_ledger/presentation/subcontractor_payments_tab.dart';

import '../../test_utils/fake_api_client.dart';
import '../contract_co/contract_co_test_support.dart' as cc;
import 'finance_ledger_test_support.dart';

/// Finans defteri ekran görüntüleri (360x800, PNG 720x1600, uygulama
/// fontlarıyla; uzun görünüm için tam boy "_360_full"): Masraflar/Tahsilatlar
/// (iptal edilmiş satır, bağ etiketleri), masraf ayrıntısı + iptal, kilitli
/// proje ve legacy Taşeron Ödemeleri (sahip / salt-okur). Üretmek:
///   flutter test --tags golden --update-goldens test/features/finance_ledger
void main() {
  late ApiClient offline;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await cc.loadAppFonts();
    offline = await buildFakeApiClient(FakeHttpClientAdapter(script: {}));
  });

  /// Proje detayının Finans grubundaki yerleşim: üstte gerçek çip şeridi,
  /// altında `Expanded` içinde gövde.
  Widget page(Widget body) => cc.embeddedSectionPage(body);

  Widget sections(Project project) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          LedgerLockedNotice(project: project),
          ExpensesLedgerSection(project: project),
          const SizedBox(height: 24),
          CollectionsLedgerSection(project: project),
        ],
      );

  Future<void> pumpAt(
    WidgetTester tester, {
    required User user,
    required Widget home,
    Project? project,
    List<Expense>? expenses,
  }) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 800) * 2.0;
    addTearDown(tester.view.reset);
    debugDisableShadows = false;
    await tester.pumpWidget(
      buildLedgerApp(
        user: user,
        client: offline,
        project: project,
        expenses: expenses,
        home: home,
        theme: cc.goldenTheme(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> expectGolden(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    debugDisableShadows = true;
  }

  group('Masraflar / Tahsilatlar', () {
    testWidgets('sahip', (tester) async {
      final project = cc.sampleProject();
      await pumpAt(tester, user: ledgerOwner, home: page(sections(project)));
      await expectGolden(tester, 'ledger_sections_owner_360x800');
    });

    // Tam boy varyant yok: bölümler 360x800'e sığıyor, görüntü birebir aynıydı.

    testWidgets('salt-okur', (tester) async {
      final project = cc.sampleProject();
      await pumpAt(tester, user: ledgerViewer, home: page(sections(project)));
      await expectGolden(tester, 'ledger_sections_viewer_360x800');
    });

    testWidgets('tamamlanmış proje (kilitli)', (tester) async {
      final project = cc.sampleProject(status: 'completed');
      await pumpAt(tester, user: ledgerOwner, project: project, home: page(sections(project)));
      await expectGolden(tester, 'ledger_sections_locked_360x800');
    });

    testWidgets('masraf ayrıntısı + İptal Et', (tester) async {
      final project = cc.sampleProject();
      await pumpAt(tester, user: ledgerOwner, home: page(sections(project)));
      await tester.tap(find.byKey(const ValueKey('masraf-e1')));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'expense_detail_sheet_owner_360x800');
    });

    testWidgets('iptal gerekçesi diyaloğu', (tester) async {
      final project = cc.sampleProject();
      await pumpAt(tester, user: ledgerOwner, home: page(sections(project)));
      await tester.tap(find.byKey(const ValueKey('tahsilat-c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'İptal Et'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Banka iadesi');
      await tester.pumpAndSettle();
      await expectGolden(tester, 'collection_void_dialog_360x800');
    });

    // Masraf onayı: bekleyen/reddedilen rozetleri, ret gerekçesi, üstte not.
    testWidgets('onay bekleyen ve reddedilen masraflar (onaylayıcı)', (tester) async {
      final project = cc.sampleProject();
      await pumpAt(tester, user: ledgerApprover, expenses: approvalExpenses, home: page(sections(project)));
      await expectGolden(tester, 'ledger_sections_approval_360x800');
    });

    testWidgets('onay bekleyen masraf ayrıntısı + Onayla/Reddet', (tester) async {
      final project = cc.sampleProject();
      await pumpAt(tester, user: ledgerApprover, expenses: approvalExpenses, home: page(sections(project)));
      await tester.tap(find.byKey(const ValueKey('masraf-e3')));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'expense_detail_sheet_pending_approver_360x800');
    });
  });

  group('Taşeron Ödemeleri', () {
    Widget tab(Project project) => cc.embeddedSectionPage(
          SubcontractorPaymentsTab(projectId: project.id, project: project),
          selected: 'taseron-odemeleri',
        );

    testWidgets('sahip', (tester) async {
      await pumpAt(tester, user: ledgerOwner, home: tab(cc.sampleProject()));
      await expectGolden(tester, 'subcontractor_payments_owner_360x800');
    });

    testWidgets('salt-okur', (tester) async {
      await pumpAt(tester, user: ledgerViewer, home: tab(cc.sampleProject()));
      await expectGolden(tester, 'subcontractor_payments_viewer_360x800');
    });

    testWidgets('ödeme ekle formu', (tester) async {
      // Formun tarihi "bugün": sabit saat verilmezse görüntü her gün değişirdi.
      await withClock(Clock.fixed(DateTime(2026, 9, 28)), () async {
        await pumpAt(tester, user: ledgerOwner, home: tab(cc.sampleProject()));
        await tester.tap(find.text('Ödeme Ekle').first);
        await tester.pumpAndSettle();
      });
      await expectGolden(tester, 'subcontractor_payment_sheet_360x800');
    });

    testWidgets('finans izni yok', (tester) async {
      await pumpAt(tester, user: ledgerPm, home: tab(cc.sampleProject()));
      await expectGolden(tester, 'subcontractor_payments_no_access_360x800');
    });
  });
}
