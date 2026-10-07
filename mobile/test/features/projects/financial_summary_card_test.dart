import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/projects/budget/data/budget_providers.dart';
import 'package:arvend/features/projects/contract_co/data/contract_co_providers.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/finance_ledger/data/finance_ledger_providers.dart';
import 'package:arvend/features/projects/finance_plan/data/finance_plan_providers.dart';
import 'package:arvend/features/projects/ops_team/data/ops_team_providers.dart';
import 'package:arvend/features/projects/presentation/project_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../contract_co/contract_co_test_support.dart' as cc;
import '../dashboard/fixtures.dart' show kAllPermissions;
import '../finance_ledger/finance_ledger_test_support.dart' as fl;
import '../finance_plan/finance_plan_test_support.dart' as fp;
import '../ops_team/ops_team_test_support.dart' as ops;
import 'budget/budget_test_support.dart' as bt;

/// Finans özeti kartı: masraflara girilen KDV düşülmüş maliyet ("Maliyet
/// (KDV hariç)") yalnızca KDV dahilden farklıysa gösterilir; kâr satırları
/// sunucunun *_net rakamlarını aynen gösterir (istemcide hesap yok).

Map<String, dynamic> _base() => {
      'current_contract_value': 1200000,
      'collected_amount': 0,
      'remaining_receivable': 1200000,
      'total_expenses': 120000,
      'subcontractor_paid': 0,
      'subcontractor_remaining': 0,
      'realized_cost': 120000,
      'committed_cost': 120000,
      'realized_gross_profit': 1080000,
      'estimated_gross_profit': 1080000,
      'realized_margin_percent': 90,
      'estimated_margin_percent': 90,
      'currency': 'TRY',
      'contract_vat_known': true,
      'contract_vat_amount': 200000,
      'current_contract_value_net': 1000000,
      'forecast_basis': 'commitments',
      'forecast_cost': 120000,
      'forecast_profit': 1080000,
      'forecast_margin_percent': 90,
    };

Widget _app(ApiClient offline, FinancialSummary summary) {
  final router = GoRouter(
    initialLocation: '/projeler/p1?grup=finans',
    routes: [
      GoRoute(
        path: '/projeler/:id',
        builder: (_, s) => ProjectDetailScreen(
          projectId: s.pathParameters['id']!,
          initialGroup: s.uri.queryParameters['grup'],
          initialView: s.uri.queryParameters['alt'],
        ),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(offline),
      authControllerProvider.overrideWith(() => cc.FakeAuth(fl.ledgerUser('owner', kAllPermissions.toSet()))),
      projectDetailProvider.overrideWith((ref, id) async => cc.sampleProject()),
      projectFinancialSummaryProvider.overrideWith((ref, id) async => summary),
      projectExpensesProvider.overrideWith((ref, id) async => const <Expense>[]),
      projectCollectionsProvider.overrideWith((ref, id) async => const <Collection>[]),
      contractCoRepositoryProvider.overrideWithValue(cc.FakeContractCoRepository()),
      financePlanRepositoryProvider.overrideWithValue(fp.FakeFinancePlanRepository()),
      financePlanTodayProvider.overrideWithValue(fp.kFinanceToday),
      opsTeamRepositoryProvider.overrideWithValue(ops.FakeOpsTeamRepository()),
      opsTodayProvider.overrideWithValue(ops.kToday),
      financeLedgerRepositoryProvider.overrideWithValue(fl.FakeFinanceLedgerRepository()),
      budgetRepositoryProvider.overrideWithValue(bt.FakeBudgetRepository()),
      budgetClockProvider.overrideWithValue(() => DateTime(2026, 10, 7, 10)),
    ],
    child: MaterialApp.router(
      theme: AppTheme.light(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: router,
    ),
  );
}

void main() {
  late ApiClient offline;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    offline = await buildFakeApiClient(FakeHttpClientAdapter(script: {}));
  });

  Future<void> pump(WidgetTester tester, Map<String, dynamic> json) async {
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(offline, FinancialSummary.fromJson(json)));
    await tester.pumpAndSettle();
  }

  testWidgets('masraf KDV\'si girilmişse "Maliyet (KDV hariç)" gösterilir; kâr sunucunun KDV hariç rakamı', (tester) async {
    await pump(tester, {
      ..._base(),
      'expense_vat_total': 20000,
      'realized_cost_net': 100000,
      'committed_cost_net': 100000,
      'forecast_cost_net': 100000,
      'realized_gross_profit_net': 900000,
      'realized_margin_percent_net': 90,
      'forecast_profit_net': 900000,
      'forecast_margin_percent_net': 90,
    });
    expect(find.text('Gerçekleşen Maliyet'), findsOneWidget);
    expect(find.text('Maliyet (KDV hariç)'), findsNWidgets(2), reason: 'gerçekleşen + tahmini');
    expect(find.text('100.000,00 TL'), findsNWidgets(2));
    expect(find.text('Kâr (KDV hariç)'), findsOneWidget);
    expect(find.text('900.000,00 TL'), findsNWidgets(2), reason: 'gerçekleşen + tahmini kâr (KDV hariç)');
  });

  testWidgets('masraflarda KDV yoksa (ya da eski sunucu) "Maliyet (KDV hariç)" satırı yok', (tester) async {
    await pump(tester, _base());
    expect(find.text('Gerçekleşen Maliyet'), findsOneWidget);
    expect(find.text('Maliyet (KDV hariç)'), findsNothing);
  });
}
