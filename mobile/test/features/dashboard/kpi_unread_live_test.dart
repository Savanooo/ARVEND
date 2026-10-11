import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/features/dashboard/domain/dashboard.dart';
import 'package:arvend/features/dashboard/domain/dashboard_registry.dart';
import 'package:arvend/features/dashboard/presentation/widgets/kpi_grid.dart';
import 'package:arvend/features/notifications/data/notifications_providers.dart';

import 'fixtures.dart';

/// "Okunmamış bildirim" kutucuğu zil rozetiyle aynı sayacı okur: eskiden
/// bildirimler okundu işaretlenip dönülünce zil 0, kutucuk anlık
/// görüntüdeki eski sayıyı gösteriyordu.

/// Personel bağı olmayan saha kullanıcısı: kutucuklarda "Okunmamış bildirim"
/// var (bkz. dashboard_model_test pickKpis); anlık görüntüde 2 okunmamış.
Dashboard _dashboard() {
  final json = fixtureJson('field');
  ((json['sections'] as Map)['tasks'] as Map)['mine'] = {
    'linked_employee': false,
    'open': 0,
    'overdue': 0,
    'due_today': 0,
    'items': <dynamic>[],
  };
  return Dashboard.fromJson(json);
}

Future<void> _pump(WidgetTester tester, Override unread) async {
  final d = _dashboard();
  final kpis = pickKpis(d);
  expect(kpis, contains(KpiKey.unread));
  await tester.pumpWidget(ProviderScope(
    overrides: [unread],
    child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: KpiGrid(data: d, kpis: kpis)))),
  ));
  await tester.pumpAndSettle();
}

Finder _unreadValue(String value) =>
    find.descendant(of: find.byKey(const ValueKey('kpi-unread')), matching: find.text(value));

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  testWidgets('canlı sayaç anlık görüntünün yerine geçer (zil ile aynı sayı)', (tester) async {
    await _pump(tester, unreadNotificationCountProvider.overrideWith((ref) async => 0));
    expect(_unreadValue('0'), findsOneWidget);
    expect(_unreadValue('2'), findsNothing);
  });

  testWidgets('sayaç alınamazsa anlık görüntüdeki sayı gösterilir', (tester) async {
    await _pump(tester, unreadNotificationCountProvider.overrideWith((ref) async => throw Exception('ağ yok')));
    expect(_unreadValue('2'), findsOneWidget);
  });
}
