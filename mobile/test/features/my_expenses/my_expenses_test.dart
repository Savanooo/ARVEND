import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/core/widgets/access_notices.dart';
import 'package:arvend/core/widgets/app_filter_bar.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/domain/expense_actions.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/finance_ledger/presentation/ledger_sections.dart';
import 'package:arvend/features/projects/my_expenses/presentation/my_expenses_screen.dart';
import 'package:arvend/features/projects/presentation/expense_form_sheet.dart';

import '../../test_utils/fake_api_client.dart';
import '../contract_co/contract_co_test_support.dart' as cc;
import '../finance_ledger/finance_ledger_test_support.dart';
import 'my_expenses_test_support.dart';

/// Masrafı herkes girer, onayı yalnızca en üst yönetim verir (backend
/// migration 0066): sahadaki kişinin masraf girişi (bağ seçicisi yok),
/// "Masraflarım" (durumlar, ret nedeni, düzelt / geri çek), bildirimden
/// gelen derin bağlantı ve onaylayıcının kendi masrafı.

Future<FakeHttpClientAdapter> _pumpScreen(
  WidgetTester tester, {
  required Map<String, List<ScriptedResponse>> script,
  User? user,
  String? projectId,
  String? initialExpenseId,
}) async {
  await tester.binding.setSurfaceSize(const Size(400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final adapter = FakeHttpClientAdapter(script: script);
  final client = await buildFakeApiClient(adapter);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => cc.FakeAuth(user ?? myExpensesFieldUser)),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('tr', 'TR'),
        supportedLocales: const [Locale('tr', 'TR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: MyExpensesScreen(projectId: projectId, initialExpenseId: initialExpenseId),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return adapter;
}

Future<void> _openRow(WidgetTester tester, String id) async {
  await tester.ensureVisible(find.byKey(ValueKey('masrafim-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('masrafim-$id')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  group('expenseActionsFor (backend 0066 kuralları)', () {
    final pending = Expense.fromJson(myExpenseRow('x'));
    final rejected = Expense.fromJson(myExpenseRow('x', status: 'rejected'));
    final approved = Expense.fromJson(myExpenseRow('x', status: 'approved'));
    final others = Expense.fromJson(myExpenseRow('x', createdBy: 'someone'));
    final manager = cc.buildUser(
      id: 'fin',
      roleCode: 'finance',
      permissions: const {'projects.finance.read', 'projects.finance.manage', 'projects.expenses.create'},
    );
    User approver(String id, String roleCode) => cc.buildUser(
          id: id,
          roleCode: roleCode,
          permissions: const {'projects.finance.manage', 'projects.expenses.create', 'projects.expenses.approve'},
        );

    test('sahadaki kişi: kendi bekleyen/reddedileninde Düzenle + Geri Çek; onaylıda ve başkasınınkinde hiçbir şey', () {
      for (final e in [pending, rejected]) {
        final a = expenseActionsFor(myExpensesFieldUser, e, open: true);
        expect([a.canEdit, a.canWithdraw, a.canVoid, a.canDecide], [true, true, false, false], reason: e.approvalStatus);
      }
      for (final e in [approved, others]) {
        final a = expenseActionsFor(myExpensesFieldUser, e, open: true);
        expect([a.canEdit, a.canWithdraw, a.canVoid, a.canDecide], [false, false, false, false]);
      }
      final closed = expenseActionsFor(myExpensesFieldUser, pending, open: false);
      expect([closed.canEdit, closed.canWithdraw], [false, false], reason: 'kapalı proje');
      final withdrawn = Expense.fromJson(myExpenseRow('x', voidedBy: 'field'));
      expect(withdrawn.isWithdrawn, isTrue);
      expect(expenseActionsFor(myExpensesFieldUser, withdrawn, open: true).canEdit, isFalse);
    });

    test('finans yöneticisi her masrafta Düzenle + İptal Et (geri çekme değil), onay izni yoksa karar yok', () {
      for (final e in [pending, approved, others]) {
        final a = expenseActionsFor(manager, e, open: true);
        expect([a.canEdit, a.canVoid, a.canWithdraw, a.canDecide], [true, true, false, false]);
      }
    });

    test('Yönetici kendi masrafına karar veremez (not), başkasınınkine verir; Sahip kendininkine de verir', () {
      final admin = approver('field', 'admin'); // masrafları "field" girdi
      final own = expenseActionsFor(admin, pending, open: true);
      expect([own.canDecide, own.ownDecisionBlocked], [false, true]);
      final other = expenseActionsFor(admin, others, open: true);
      expect([other.canDecide, other.ownDecisionBlocked], [true, false]);
      final owner = expenseActionsFor(approver('field', 'owner'), pending, open: true);
      expect([owner.canDecide, owner.ownDecisionBlocked], [true, false]);
      // Karar verilmiş masrafta not da yok.
      expect(expenseActionsFor(admin, approved, open: true).ownDecisionBlocked, isFalse);
    });
  });

  group('Masraf formu -- finans izni olmayan kişi', () {
    Future<FakeHttpClientAdapter> openForm(WidgetTester tester, Map<String, List<ScriptedResponse>> script,
        {Expense? initial}) async {
      await tester.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = FakeHttpClientAdapter(script: script);
      final client = await buildFakeApiClient(adapter);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(client),
            authControllerProvider.overrideWith(() => cc.FakeAuth(myExpensesFieldUser)),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => showExpenseFormSheet(context, 'p1', currency: 'TRY', initial: initial),
                    child: const Text('Aç'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Aç'));
      await tester.pumpAndSettle();
      return adapter;
    }

    Future<void> save(WidgetTester tester) async {
      final button = find.widgetWithText(ElevatedButton, 'Kaydet');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    testWidgets('masraf girer: bağ seçicisi yok, seçici isteği yok, bağlar boş gider, onaya gönderilir', (tester) async {
      final adapter = await openForm(tester, {
        '/projects/p1/expenses': [(status: 201, body: myExpenseRow('n1'))],
      });
      expect(find.text('Bağlantılar (opsiyonel)'), findsNothing);
      expect(adapter.calls, isEmpty, reason: 'ek iş / bütçe / maliyet kodu listesi istenmez');

      await tester.enterText(find.widgetWithText(TextFormField, 'Açıklama'), 'Çivi');
      await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '1.250');
      await tester.enterText(find.widgetWithText(TextFormField, 'Kime ödendi (opsiyonel)'), 'Usta Ali');
      await save(tester);

      expect(adapter.calls, ['/projects/p1/expenses']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['amount'], 1250);
      expect(body['supplier_name'], 'Usta Ali');
      expect([body['change_order_id'], body['cost_code_id'], body['budget_line_id']], ['', '', '']);
      expect(find.text('Masraf onaya gönderildi.'), findsOneWidget);
    });

    testWidgets('reddedilen masrafını düzeltir: finansın bağı boş gider (sunucuda kalır), PUT', (tester) async {
      final rejected = Expense.fromJson(myExpenseRow('m2', status: 'rejected', note: 'Fiş okunmuyor', costCodeId: 'cc9'));
      final adapter = await openForm(tester, {
        '/projects/p1/expenses/m2': [(status: 200, body: myExpenseRow('m2', amount: 1100, costCodeId: 'cc9'))],
      }, initial: rejected);
      expect(find.text('Masrafı Düzenle'), findsOneWidget);
      expect(find.textContaining('Red nedeni: Fiş okunmuyor'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '1.100');
      await save(tester);

      expect(adapter.methods.single, 'PUT');
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['amount'], 1100);
      expect(body['cost_code_id'], '', reason: 'boş = sunucudaki bağı koru');
      expect(find.text('Masraf güncellendi; yeniden onaya gönderildi.'), findsOneWidget);
    });
  });

  group('Masraflarım', () {
    testWidgets('yalnızca kendi masrafları: durum çipleri, ret nedeni, geri çekilen; süzgeç; toplam yok', (tester) async {
      final adapter = await _pumpScreen(tester, script: {'/expenses/mine': [mineResponse()]});
      expect(adapter.calls, ['/expenses/mine']);
      expect(adapter.requestQueries.single, isEmpty, reason: 'proje süzgeci yok');

      expect(find.text('Masraflarım'), findsOneWidget);
      for (final label in ['Onay bekliyor', 'Reddedildi', 'Onaylandı', 'Geri çekildi']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.text('Red nedeni: Fiş okunmuyor'), findsOneWidget);
      expect(find.textContaining('PRJ-2026-0009 · Üsküdar Kafe'), findsOneWidget, reason: 'projeler arası');
      expect(find.textContaining(RegExp('toplam', caseSensitive: false)), findsNothing);

      // Süzgeç çipleri yatay kayar (Proje/Teklif listeleriyle aynı çubuk).
      final chips = find.descendant(of: find.byType(AppFilterBar), matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(find.text('Reddedildi (1)'), 80, scrollable: chips);
      await tester.ensureVisible(find.text('Reddedildi (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reddedildi (1)'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('masrafim-m2')), findsOneWidget);
      expect(find.byKey(const ValueKey('masrafim-m1')), findsNothing);
      await tester.scrollUntilVisible(find.text('Onay bekliyor (2)'), -80, scrollable: chips);
      await tester.ensureVisible(find.text('Onay bekliyor (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Onay bekliyor (2)'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('masrafim-m1')), findsOneWidget);
      expect(find.byKey(const ValueKey('masrafim-m5')), findsOneWidget);
      expect(find.byKey(const ValueKey('masrafim-m4')), findsNothing, reason: 'geri çekilen bekleyen sayılmaz');
    });

    testWidgets('reddedilen: ayrıntıda neden + Düzenle; kaydedince PUT ve liste tazelenir', (tester) async {
      final adapter = await _pumpScreen(tester, script: {
        '/expenses/mine': [
          mineResponse(),
          mineResponse([myExpenseRow('m2', amount: 1100, description: 'Kalıp tahtası')]),
        ],
        '/projects/p1/expenses/m2': [(status: 200, body: myExpenseRow('m2', amount: 1100))],
      });
      await _openRow(tester, 'm2');
      expect(find.text('Red nedeni'), findsOneWidget);
      expect(find.text('Proje'), findsOneWidget);
      expect(find.byKey(const ValueKey('masraf-duzenle')), findsOneWidget);
      expect(find.byKey(const ValueKey('masraf-geri-cek')), findsOneWidget);
      expect(find.text('İptal Et'), findsNothing, reason: 'finans iptali yalnızca finans yöneticisinde');
      expect(find.text('Onayla'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('masraf-duzenle')));
      await tester.pumpAndSettle();
      expect(find.text('Bağlantılar (opsiyonel)'), findsNothing);
      await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '1.100');
      final save = find.widgetWithText(ElevatedButton, 'Kaydet');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      final put = adapter.calls.indexOf('/projects/p1/expenses/m2');
      expect(adapter.methods[put], 'PUT');
      expect((adapter.requestBodies[put] as Map)['cost_code_id'], '');
      expect(adapter.calls.where((c) => c == '/expenses/mine'), hasLength(2), reason: 'liste tazelenir');
      expect(find.text('Masraf güncellendi; yeniden onaya gönderildi.'), findsOneWidget);
    });

    testWidgets('onay bekleyen: Geri Çek onay penceresinden sonra POST void, "Geri çekildi"', (tester) async {
      final adapter = await _pumpScreen(tester, script: {
        '/expenses/mine': [
          mineResponse(),
          mineResponse([myExpenseRow('m1', voidedBy: 'field', description: 'Çivi ve vida')]),
        ],
        '/projects/p1/expenses/m1/void': [(status: 200, body: null)],
      });
      await _openRow(tester, 'm1');
      await tester.tap(find.byKey(const ValueKey('masraf-geri-cek')));
      await tester.pumpAndSettle();
      expect(adapter.calls, ['/expenses/mine'], reason: 'önce onay penceresi');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Geri Çek')));
      await tester.pumpAndSettle();

      final i = adapter.calls.indexOf('/projects/p1/expenses/m1/void');
      expect(adapter.methods[i], 'POST');
      expect(find.text('Masraf geri çekildi.'), findsOneWidget);
      expect(find.text('Geri çekildi'), findsOneWidget);
    });

    testWidgets('onaylı ya da kapalı projedeki masrafta Düzenle / Geri Çek yok', (tester) async {
      await _pumpScreen(tester, script: {'/expenses/mine': [mineResponse()]});
      for (final id in ['m3', 'm5', 'm4']) {
        await _openRow(tester, id);
        expect(find.byKey(const ValueKey('masraf-duzenle')), findsNothing, reason: id);
        expect(find.byKey(const ValueKey('masraf-geri-cek')), findsNothing, reason: id);
        await tester.tapAt(const Offset(200, 20));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('bildirimden (?masraf=) gelince o masrafın ayrıntısı kendiliğinden açılır; proje süzgeci gider', (
      tester,
    ) async {
      final adapter = await _pumpScreen(
        tester,
        projectId: 'p1',
        initialExpenseId: 'm2',
        script: {'/expenses/mine': [mineResponse()]},
      );
      expect(adapter.requestQueries.single, {'project_id': 'p1'});
      expect(find.text('Red nedeni'), findsOneWidget);
      expect(find.byKey(const ValueKey('masraf-duzenle')), findsOneWidget);
    });

    // Masraflarım açıkken karar bildirimine dokunuldu: ikinci ekran aynı
    // (önbellekteki) listeyi paylaşır; o kopyada masraf hâlâ "Onay bekliyor".
    // Bildirimin anlattığı durum (ret nedeni) görünmeliydi.
    testWidgets('Masraflarım açıkken bildirimden gelince liste tazelenir, ayrıntı güncel durumu gösterir', (
      tester,
    ) async {
      final adapter = await _pumpScreen(tester, script: {
        '/expenses/mine': [
          mineResponse([myExpenseRow('m2', description: 'Kalıp tahtası')]),
          mineResponse([myExpenseRow('m2', status: 'rejected', note: 'Fiş okunmuyor', description: 'Kalıp tahtası')]),
        ],
      });
      expect(find.text('Onay bekliyor'), findsWidgets);

      Navigator.of(tester.element(find.byType(MyExpensesScreen))).push(
        MaterialPageRoute<void>(builder: (_) => const MyExpensesScreen(initialExpenseId: 'm2')),
      );
      await tester.pumpAndSettle();

      expect(adapter.calls.where((c) => c == '/expenses/mine').length, 2);
      expect(find.text('Red nedeni'), findsOneWidget);
    });

    testWidgets('masraf girme izni yoksa açıklama, istek yok', (tester) async {
      final adapter = await _pumpScreen(
        tester,
        user: cc.buildUser(id: 'v', permissions: const {'projects.read'}),
        script: {},
      );
      expect(find.text(kMyExpensesNoAccessText), findsOneWidget);
      expect(find.byType(ReadOnlyNotice), findsOneWidget);
      expect(adapter.calls, isEmpty);
    });
  });

  group('Finans listesi -- onaylayıcının kendi masrafı', () {
    Future<void> pumpLedger(WidgetTester tester, User user, List<Expense> expenses) async {
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final client = await buildFakeApiClient(FakeHttpClientAdapter(script: {}));
      await tester.pumpWidget(buildLedgerApp(
        user: user,
        client: client,
        expenses: expenses,
        home: Scaffold(body: ListView(children: [ExpensesLedgerSection(project: cc.sampleProject())])),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('masraf-own')));
      await tester.pumpAndSettle();
    }

    Expense ownBy(String userId) => Expense.fromJson(myExpenseRow('own', createdBy: userId));

    testWidgets('Yönetici kendi masrafında Onayla/Reddet görmez, nedenini görür', (tester) async {
      // ledgerApprover: kimliği ve rol kodu "approver" (Sahip değil).
      await pumpLedger(tester, ledgerApprover, [ownBy('approver')]);
      expect(find.widgetWithText(ElevatedButton, 'Onayla'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Reddet'), findsNothing);
      expect(find.text(kExpenseOwnDecisionText), findsOneWidget);
    });

    testWidgets('Sahip kendi masrafına karar verebilir (üstünde kimse yok)', (tester) async {
      final owner = ledgerUser('owner', {
        'projects.read',
        'projects.finance.read',
        'projects.finance.manage',
        'projects.expenses.create',
        'projects.expenses.approve',
      }, role: UserRole.admin);
      await pumpLedger(tester, owner, [ownBy('owner')]);
      expect(find.widgetWithText(ElevatedButton, 'Onayla'), findsOneWidget);
      expect(find.text(kExpenseOwnDecisionText), findsNothing);
    });
  });
}
