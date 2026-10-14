import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/my_expenses/presentation/expenses_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart' show requestBodyFor;
import '../contract_co/contract_co_test_support.dart' as cc;
import 'my_expenses_test_support.dart';

/// "Masraflar" (backend migration 0068): projeli ve genel masraflar tek
/// listede; yönetici toplamları ve giren kişiyi görür, genel masrafı
/// onaylar; herkes genel (projesiz) masraf girebilir.

final _manager = cc.buildUser(
  id: 'mgr',
  roleCode: 'admin',
  permissions: const {
    'projects.read',
    'projects.finance.read',
    'projects.finance.manage',
    'projects.expenses.create',
    'projects.expenses.approve',
  },
);

Map<String, dynamic> _generalRow(String id, {String status = 'pending', String createdBy = 'field'}) => {
      ...myExpenseRow(id, status: status, createdBy: createdBy, description: 'Yakıt'),
      'project_id': '',
      'project_name': '',
      'project_no': '',
      'project_status': '',
      'is_general': true,
      'created_by_name': 'Saha Çalışanı',
    };

Map<String, dynamic> _page({required bool seeAll, List<Map<String, dynamic>>? rows}) => {
      'expenses': rows ??
          [
            _generalRow('g1'),
            {...myExpenseRow('p1row', status: 'approved'), 'is_general': false, 'created_by_name': 'Usta Ali'},
          ],
      'limit': 500,
      'truncated': false,
      'can_see_all': seeAll,
      if (seeAll)
        'totals': [
          {'currency': 'TRY', 'approved': 1250, 'pending': 1250},
        ],
    };

Future<FakeHttpClientAdapter> _pump(
  WidgetTester tester, {
  required User user,
  required Map<String, List<ScriptedResponse>> script,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final adapter = FakeHttpClientAdapter(script: script);
  final client = await buildFakeApiClient(adapter);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => cc.FakeAuth(user)),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('tr', 'TR'),
        supportedLocales: const [Locale('tr', 'TR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const ExpensesScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return adapter;
}

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  testWidgets('yönetici genel ve projeli masrafları toplamlarla ve gireniyle görür', (tester) async {
    await _pump(tester, user: _manager, script: {
      '/expenses': [(status: 200, body: _page(seeAll: true))],
    });
    expect(find.byKey(const ValueKey('masraf-toplamlar')), findsOneWidget);
    expect(find.textContaining('Onaylı:'), findsOneWidget);
    expect(find.textContaining('Genel masraf · '), findsOneWidget);
    expect(find.textContaining('PRJ-2026-0007'), findsOneWidget);
    expect(find.textContaining('Saha Çalışanı'), findsOneWidget);
  });

  testWidgets('saha çalışanı toplam görmez, yalnızca kendi masrafları', (tester) async {
    await _pump(tester, user: myExpensesFieldUser, script: {
      '/expenses': [(status: 200, body: _page(seeAll: false, rows: [_generalRow('g1')]))],
    });
    expect(find.byKey(const ValueKey('masraf-toplamlar')), findsNothing);
    expect(find.textContaining('Saha Çalışanı'), findsNothing, reason: 'kendi listesinde giren adı gösterilmez');
    expect(find.textContaining('Genel masraf · '), findsOneWidget);
  });

  testWidgets('durum süzgeci sunucuya gider', (tester) async {
    final adapter = await _pump(tester, user: _manager, script: {
      '/expenses': [
        (status: 200, body: _page(seeAll: true)),
        (status: 200, body: _page(seeAll: true, rows: [_generalRow('g1')])),
      ],
    });
    await tester.tap(find.text('Onay bekliyor').first);
    await tester.pumpAndSettle();
    expect(adapter.requestQueries.last, {'status': 'pending'});
  });

  testWidgets('"Masraf Ekle" > Genel masraf: projesiz form /expenses/general\'a gider', (tester) async {
    final adapter = await _pump(tester, user: _manager, script: {
      '/expenses': [
        (status: 200, body: _page(seeAll: true)),
        (status: 200, body: _page(seeAll: true)),
      ],
      '/expenses/general': [(status: 201, body: _generalRow('g2', createdBy: 'mgr'))],
    });
    await tester.tap(find.byKey(const ValueKey('masraf-ekle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('masraf-hedef-genel')));
    await tester.pumpAndSettle();

    expect(find.text('Genel masraf (projesiz)'), findsOneWidget, reason: 'formun başında projesiz olduğu yazar');
    expect(find.text('Bağlantılar (opsiyonel)'), findsNothing, reason: 'genel masrafta proje bağı yok');
    await tester.enterText(find.widgetWithText(TextFormField, 'Açıklama'), 'Ofis kirası');
    await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '15.000');
    await tester.tap(find.text('Kaydet'));
    await tester.pumpAndSettle();

    final body = requestBodyFor(adapter, '/expenses/general');
    expect(body['description'], 'Ofis kirası');
    expect(body['amount'], 15000);
    expect(body['change_order_id'], '');
    expect(body['budget_line_id'], '');
    expect(body['cost_code_id'], '');
    expect(find.textContaining('onaya gönderildi'), findsOneWidget);
  });

  testWidgets('yönetici başkasının genel masrafını buradan onaylar', (tester) async {
    final adapter = await _pump(tester, user: _manager, script: {
      '/expenses': [
        (status: 200, body: _page(seeAll: true)),
        (status: 200, body: _page(seeAll: true)),
      ],
      '/expenses/general/g1/approve': [(status: 200, body: _generalRow('g1', status: 'approved'))],
    });
    await tester.tap(find.byKey(const ValueKey('masraf-g1')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Onayla'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Onayla')));
    await tester.pumpAndSettle();
    expect(adapter.calls, contains('/expenses/general/g1/approve'));
  });
}
