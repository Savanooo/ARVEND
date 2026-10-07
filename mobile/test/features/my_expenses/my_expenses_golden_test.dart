@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/finance_ledger/presentation/ledger_sections.dart';
import 'package:arvend/features/projects/my_expenses/presentation/my_expenses_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../contract_co/contract_co_test_support.dart' as cc;
import '../finance_ledger/finance_ledger_test_support.dart';
import 'my_expenses_test_support.dart';

/// "Masraflarım" ve onaylayıcının kendi masrafı (backend migration 0066)
/// ekran görüntüleri (360x800, PNG 720x1600, uygulama fontlarıyla).
/// Üretmek: flutter test --tags golden --update-goldens test/features/my_expenses
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await cc.loadAppFonts();
  });

  void at360(WidgetTester tester) {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 800) * 2.0;
    addTearDown(tester.view.reset);
  }

  Future<void> expectGolden(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    debugDisableShadows = true;
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    at360(tester);
    debugDisableShadows = false;
    final client = await buildFakeApiClient(FakeHttpClientAdapter(script: {
      '/expenses/mine': [mineResponse()],
    }));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(client),
          authControllerProvider.overrideWith(() => cc.FakeAuth(myExpensesFieldUser)),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: cc.goldenTheme(),
          locale: const Locale('tr', 'TR'),
          supportedLocales: const [Locale('tr', 'TR')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const MyExpensesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Masraflarım: sahadaki kişinin listesi', (tester) async {
    await pumpScreen(tester);
    await expectGolden(tester, 'my_expenses_field_360x800');
  });

  testWidgets('Masraflarım: reddedilen masrafın ayrıntısı (Düzenle + Geri Çek)', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('masrafim-m2')));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'my_expense_rejected_detail_field_360x800');
  });

  testWidgets('Finans: Yönetici kendi bekleyen masrafında not görür, Onayla/Reddet yok', (tester) async {
    at360(tester);
    debugDisableShadows = false;
    final client = await buildFakeApiClient(FakeHttpClientAdapter(script: {}));
    await tester.pumpWidget(buildLedgerApp(
      user: ledgerApprover,
      client: client,
      expenses: [Expense.fromJson(myExpenseRow('own', createdBy: 'approver'))],
      theme: cc.goldenTheme(),
      home: cc.embeddedSectionPage(ListView(
        padding: const EdgeInsets.all(16),
        children: [ExpensesLedgerSection(project: cc.sampleProject())],
      )),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('masraf-own')));
    await tester.pumpAndSettle();
    await expectGolden(tester, 'expense_detail_own_approver_360x800');
  });
}
