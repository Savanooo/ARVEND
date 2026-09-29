@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/auth/domain/user.dart';
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
import 'budget/budget_test_support.dart' as bt;
import '../dashboard/fixtures.dart' show kAllPermissions;
import '../finance_ledger/finance_ledger_test_support.dart' as fl;
import '../finance_plan/finance_plan_test_support.dart' as fp;
import '../ops_team/ops_team_test_support.dart' as ops;
import 'project_edit_fakes.dart' show withRealShadows;

/// Proje detayının entegre grupları (Finans / Operasyon / Özet) -- alt
/// görünüm çip şeridi 360 dp'de tek satırda kalmalı, seçili çip görünür
/// alana kaydırılmalı, izni olmayan alt görünüm hiç çizilmemeli:
///   flutter test --tags golden --update-goldens test/features/projects/project_detail_groups_golden_test.dart
///
/// Veriler modüllerin kendi test fikstürlerinden (sahte depolar, ağ YOK);
/// betiklenmemiş bir istek sahte istemcide hata durumuna düşer.

User _user(String id, Set<String> permissions, {UserRole role = UserRole.kullanici}) => cc.buildUser(
      id: id,
      role: role,
      roleCode: id,
      permissions: permissions,
    );

final _owner = _user('owner', kAllPermissions.toSet(), role: UserRole.admin);

/// Proje Yöneticisi (rol matrisi): sözleşme taslağı + görev/operasyon,
/// finans (tutar) YOK.
final _pm = _user('project_manager', {
  'projects.read',
  'projects.update',
  'projects.contracts.read',
  'projects.contracts.manage',
  'projects.tasks.read',
  'projects.tasks.create',
  'projects.operations.read',
  'projects.operations.manage',
});

/// VARSAYILAN Proje Yöneticisi rolünün izin kümesi (migration 0034-0038):
/// bütçe + maliyet kontrolünü GÖRÜR (maliyet rakamları), finans okuma YOK --
/// sözleşme bedeli, tahmini kâr ve marj hiçbir ekranda görünmemeli.
final _pmReal = _user('project_manager', {
  'projects.read',
  'projects.update',
  'projects.contracts.read',
  'projects.contracts.manage',
  'projects.tasks.read',
  'projects.tasks.create',
  'projects.tasks.update',
  'projects.operations.read',
  'projects.operations.manage',
  'projects.access.read',
  'projects.budget.read',
  'projects.cost_control.read',
  'organization.cost_codes.read',
  'projects.procurement.read',
  'projects.procurement.manage',
  'projects.subcontracts.read',
  'projects.subcontracts.manage',
  'calculations.read',
  'products.read',
  'customers.read',
  'suppliers.read',
});

/// Yalnızca görüntüleyen operasyon kullanıcısı (yazma aksiyonu yok).
final _opsViewer = _user('viewer', {'projects.read', 'projects.operations.read', 'projects.access.read'});

final _summary = FinancialSummary.fromJson({
  'current_contract_value': 1400000,
  'collected_amount': 450000,
  'remaining_receivable': 950000,
  'total_expenses': 182500,
  'subcontractor_paid': 120000,
  'subcontractor_remaining': 80000,
  'realized_cost': 302500,
  'committed_cost': 910000,
  'realized_gross_profit': 147500,
  'estimated_gross_profit': 490000,
  'realized_margin_percent': 32.78,
  'estimated_margin_percent': 35,
  'currency': 'TRY',
});

final _expenses = [
  Expense.fromJson({
    'id': 'e1',
    'category': 'material',
    'description': 'Alçıpan ve profil',
    'amount': 84500,
    'currency': 'TRY',
    'expense_date': '2026-09-12',
    'supplier_name': 'Yapı Market',
    'invoice_no': 'YM-1042',
    'created_at': '2026-09-12T09:00:00Z',
  }),
  Expense.fromJson({
    'id': 'e2',
    'category': 'transport',
    'description': 'Hafriyat nakliyesi',
    'amount': 12000,
    'currency': 'TRY',
    'expense_date': '2026-09-08',
    'voided_at': '2026-09-09T10:00:00Z',
    'void_reason': 'Mükerrer giriş',
    'created_at': '2026-09-08T09:00:00Z',
  }),
];

final _collections = [
  Collection.fromJson({
    'id': 'c1',
    'amount': 450000,
    'currency': 'TRY',
    'received_date': '2026-09-05',
    'payment_method': 'Havale',
    'description': 'Avans',
    'reference_no': 'EFT-7781',
    'created_at': '2026-09-05T09:00:00Z',
  }),
];

final _noBudget = (
  summary: CostControlSummary.fromJson({
    'has_budget': false,
    'contract_value': 1400000,
    'original_budget': 0,
    'approved_adjustments': 0,
    'revised_budget': 0,
    'committed_cost': 0,
    'actual_cost': 0,
    'etc': 0,
    'eac': 0,
    'variance': 0,
    'forecast_profit': 0,
    'forecast_margin_percent': 0,
    'currency': 'TRY',
  }),
  lines: <CostControlLine>[],
);

Widget _app({required User user, required String location, required ApiClient offline}) {
  final router = GoRouter(
    initialLocation: location,
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
      authControllerProvider.overrideWith(() => cc.FakeAuth(user)),
      projectDetailProvider.overrideWith((ref, id) async => cc.sampleProject()),
      projectFinancialSummaryProvider.overrideWith((ref, id) async => _summary),
      projectExpensesProvider.overrideWith((ref, id) async => _expenses),
      projectCollectionsProvider.overrideWith((ref, id) async => _collections),
      projectCostControlProvider.overrideWith((ref, id) async => _noBudget),
      contractCoRepositoryProvider.overrideWithValue(cc.FakeContractCoRepository()),
      financePlanRepositoryProvider.overrideWithValue(fp.FakeFinancePlanRepository()),
      financePlanTodayProvider.overrideWithValue(fp.kFinanceToday),
      opsTeamRepositoryProvider.overrideWithValue(ops.FakeOpsTeamRepository()),
      opsTodayProvider.overrideWithValue(ops.kToday),
      financeLedgerRepositoryProvider.overrideWithValue(fl.FakeFinanceLedgerRepository()),
      budgetRepositoryProvider.overrideWithValue(bt.FakeBudgetRepository()),
      budgetClockProvider.overrideWithValue(() => DateTime(2026, 9, 29, 10)),
    ],
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: cc.goldenTheme(),
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
    await cc.loadAppFonts();
    offline = await buildFakeApiClient(FakeHttpClientAdapter(script: {}));
  });

  final cases = <String, ({User user, String location, double height})>{
    // Finans: iniş görünümü (özet + masraf + tahsilat), 7 çip tek satırda.
    'project_groups_finans_owner_360x800': (user: _owner, location: '/projeler/p1?grup=finans', height: 800),
    // Aynı görünüm tam boy: masraf/tahsilat defteri (iptal edilmiş satır).
    'project_groups_finans_owner_360_full': (user: _owner, location: '/projeler/p1?grup=finans', height: 1150),
    // Legacy taşeron kaydı + gerçek ödemeler (web Finans > Taşeronlar).
    'project_groups_finans_taseron_odemeleri_owner_360x800': (
      user: _owner,
      location: '/projeler/p1?grup=finans&alt=taseron-odemeleri',
      height: 800,
    ),
    // Sondaki bir çip derin bağlantıyla açıldı -> şerit onu görünür kılar.
    'project_groups_finans_ek_isler_owner_360x800': (
      user: _owner,
      location: '/projeler/p1?grup=finans&alt=ek-isler',
      height: 800,
    ),
    // Proje Yöneticisi: Finans grubunda YALNIZCA Sözleşme (tutar yok).
    'project_groups_finans_pm_360x800': (user: _pm, location: '/projeler/p1?grup=finans', height: 800),
    // Varsayılan Proje Yöneticisi rolü: Maliyet Kontrolü maliyet rakamlarıyla,
    // sözleşme bedeli / tahmini kâr / marj OLMADAN.
    'project_groups_finans_pm_real_maliyet_360x800': (
      user: _pmReal,
      location: '/projeler/p1?grup=finans&alt=maliyet',
      height: 800,
    ),
    'project_groups_operasyon_planlama_owner_360x800': (
      user: _owner,
      location: '/projeler/p1?grup=operasyon&alt=planlama',
      height: 800,
    ),
    // Salt-okunur: Planlama/Ekip/Erişim görünür, ekleme düğmeleri yok.
    'project_groups_operasyon_ekip_viewer_360x800': (
      user: _opsViewer,
      location: '/projeler/p1?grup=operasyon&alt=ekip',
      height: 800,
    ),
    // Özet'in grup kartları yalnızca görünen alt görünümleri sayar.
    'project_overview_pm_full_360': (user: _pm, location: '/projeler/p1', height: 1100),
  };

  for (final entry in cases.entries) {
    testWidgets(entry.key, (tester) async {
      tester.view.devicePixelRatio = 2.0;
      tester.view.physicalSize = Size(360, entry.value.height) * 2.0;
      addTearDown(tester.view.reset);
      await withRealShadows(() async {
        await tester.pumpWidget(_app(user: entry.value.user, location: entry.value.location, offline: offline));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/${entry.key}.png'));
      });
    });
  }

  testWidgets('3 grup gören kullanıcıda ?grup=operasyon derin bağlantısı Operasyon grubunu açar (oturum yüklenirken 4 grup)', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(user: _opsViewer, location: '/projeler/p1?grup=operasyon&alt=ekip', offline: offline));
    await tester.pumpAndSettle();
    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.tabs.length, 3);
    final controller = DefaultTabController.of(tester.element(find.byType(TabBar)));
    expect(controller.index, 1, reason: 'Özet, Operasyon, Dokümanlar -> Operasyon');
    final ekip = tester.widget<ChoiceChip>(find.byKey(const ValueKey('proje-alt-ekip')));
    expect(ekip.selected, isTrue);
    expect(find.byKey(const ValueKey('proje-alt-dosyalar')), findsNothing);
  });

  testWidgets('Proje Yöneticisi: Finans grubunda yalnızca Sözleşme çipi, finans isteği yok', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final contractRepo = cc.FakeContractCoRepository();
    final plan = fp.FakeFinancePlanRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(offline),
          authControllerProvider.overrideWith(() => cc.FakeAuth(_pm)),
          projectDetailProvider.overrideWith((ref, id) async => cc.sampleProject()),
          projectFinancialSummaryProvider.overrideWith((ref, id) => throw StateError('finans isteği atılmamalı')),
          contractCoRepositoryProvider.overrideWithValue(contractRepo),
          financePlanRepositoryProvider.overrideWithValue(plan),
        ],
        child: MaterialApp(home: const ProjectDetailScreen(projectId: 'p1', initialGroup: 'finans')),
      ),
    );
    await tester.pumpAndSettle();
    final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)).map((c) => (c.key! as ValueKey<String>).value);
    expect(chips, ['proje-alt-sozlesme']);
    expect(contractRepo.calls, isNotEmpty);
    expect(plan.calls, isEmpty);
    expect(find.textContaining('TL'), findsNothing);
  });

  testWidgets('Özet: kaynak teklif teklife gider, dahili notlar görünür; tutar yalnızca finans izniyle', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final project = Project.fromJson({
      ...{
        'id': 'p1',
        'project_no': 'PRJ-2026-0007',
        'name': 'Kadıköy Ofis Tadilatı',
        'project_type': 'Tadilat',
        'customer_id': 'm1',
        'customer_name': 'Moda Mimarlık Ltd.',
        'customer_address': 'Caferağa Mah. Moda Cad. No: 12 Kadıköy',
        'contract_amount': 1250000,
        'currency': 'TRY',
        'status': 'active',
        'start_date': '2026-09-01',
        'end_date': '2026-12-15',
        'description': '',
        'internal_notes': 'Müşteri hafta sonu çalışmaya izin vermiyor.',
        'source_offer_id': 'o1',
        'source_offer_no': 'TKL-2026-0012',
        'source_revision_no': 3,
        'created_at': '2026-09-01T08:00:00Z',
      },
    });
    Widget app(User user) {
      final router = GoRouter(
        initialLocation: '/projeler/p1',
        routes: [
          GoRoute(path: '/projeler/:id', builder: (_, s) => ProjectDetailScreen(projectId: s.pathParameters['id']!)),
          GoRoute(path: '/teklifler/:id', builder: (_, s) => Text('teklif ${s.pathParameters['id']}')),
          GoRoute(path: '/diger/musteriler/:id', builder: (_, s) => Text('müşteri ${s.pathParameters['id']}')),
        ],
      );
      return ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(offline),
          authControllerProvider.overrideWith(() => cc.FakeAuth(user)),
          projectDetailProvider.overrideWith((ref, id) async => project),
          projectFinancialSummaryProvider.overrideWith((ref, id) async => _summary),
          projectCostControlProvider.overrideWith((ref, id) async => _noBudget),
        ],
        child: MaterialApp.router(routerConfig: router),
      );
    }

    await tester.pumpWidget(app(_pm));
    await tester.pumpAndSettle();
    expect(find.text('TKL-2026-0012 · Rev. 3'), findsOneWidget);
    expect(find.text('Dahili Notlar (müşteri görmez)'), findsOneWidget);
    expect(find.text('Caferağa Mah. Moda Cad. No: 12 Kadıköy'), findsOneWidget);
    expect(find.text('Sözleşme Tutarı'), findsNothing, reason: 'Proje Yöneticisinde finans izni yok');
    expect(find.textContaining('TL'), findsNothing);
    expect(find.text('Müşteri kartını aç'), findsNothing, reason: 'customers.read yok');

    // Yeni ProviderScope için ağaç önce boşaltılır (override'lar yeniden kurulsun).
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(_owner));
    await tester.pumpAndSettle();
    expect(find.text('Sözleşme Tutarı'), findsOneWidget);
    await tester.tap(find.text('TKL-2026-0012 · Rev. 3'));
    await tester.pumpAndSettle();
    expect(find.text('teklif o1'), findsOneWidget);
    GoRouter.of(tester.element(find.text('teklif o1'))).go('/projeler/p1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Müşteri kartını aç'));
    await tester.pumpAndSettle();
    expect(find.text('müşteri m1'), findsOneWidget);
  });

  testWidgets('varsayılan Proje Yöneticisi: Maliyet Kontrolü\'nde gelir/kâr/marj yok, maliyet var', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(user: _pmReal, location: '/projeler/p1?grup=finans&alt=maliyet', offline: offline));
    await tester.pumpAndSettle();
    final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)).map((c) => (c.key! as ValueKey<String>).value);
    expect(chips, ['proje-alt-sozlesme', 'proje-alt-maliyet']);
    expect(find.text('Revize Bütçe'), findsOneWidget);
    expect(find.text('Sözleşme Bedeli'), findsNothing);
    expect(find.text('Tahmini Kâr'), findsNothing);
    expect(find.text('Tahmini Marj'), findsNothing);
  });

  testWidgets('gruplar arasında gidip gelince seçili alt görünüm çipi korunur', (tester) async {
    // Regresyon: TabBarView ekran dışındaki grubu atıyordu; Finans > Ek İşler
    // -> Operasyon -> Finans dönüşü ilk çipe (ya da ?alt= değerine) düşüyordu.
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(user: _owner, location: '/projeler/p1?grup=finans&alt=maliyet', offline: offline));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('proje-alt-ek-isler')));
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('proje-alt-ek-isler'))).selected, isTrue);

    await tester.tap(find.widgetWithText(Tab, 'Operasyon'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, 'Finans'));
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('proje-alt-ek-isler'))).selected, isTrue);
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('proje-alt-maliyet'))).selected, isFalse);
  });

  testWidgets('grup sekmeleri başa hizalı: 360 dp\'de dört grup da görünür (Dokümanlar kesilmez)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(user: _owner, location: '/projeler/p1', offline: offline));
    await tester.pumpAndSettle();
    final ozet = tester.getRect(find.widgetWithText(Tab, 'Özet'));
    final dok = tester.getRect(find.widgetWithText(Tab, 'Dokümanlar'));
    expect(ozet.left, lessThan(24), reason: 'Material 3 startOffset boşluğu yok');
    expect(dok.right, lessThanOrEqualTo(360));
  });
}
