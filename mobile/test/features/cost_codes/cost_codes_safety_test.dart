import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/widgets/access_notices.dart';
import 'package:arvend/core/widgets/app_data_row.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/cost_codes/cost_codes_routes.dart';

import 'cost_codes_test_support.dart';

/// Maliyet kodlarının ortak yetki görünümleri / veri satırları ve kayıt
/// sürerken formun kapatılamaması.
void main() {
  Future<void> pump(WidgetTester tester, User user, FakeCostCodesRepository repo, String location) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(480, 2400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildCostCodesApp(user: user, repo: repo, initialLocation: location));
    await tester.pumpAndSettle();
  }

  testWidgets('salt-okunur ve yetkisiz görünümler ortak bileşenler', (tester) async {
    await pump(tester, ccReadOnlyUser, FakeCostCodesRepository(), costCodeDetailPath('c5'));
    expect(find.byType(ReadOnlyNotice), findsOneWidget);
    expect(find.byType(AppDataRow), findsWidgets);
  });

  testWidgets('kayıt sürerken form kapatılamaz; bitince liste tazelenir', (tester) async {
    final gate = Completer<void>();
    final repo = FakeCostCodesRepository()..writeGate = gate;
    await pump(tester, ccOwnerUser, repo, kCostCodesPath);
    await tester.tap(find.text('Yeni Maliyet Kodu'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('cost-code-code')), 'MLZ-010');
    await tester.enterText(find.byKey(const ValueKey('cost-code-name')), 'Kum');
    await tester.tap(find.text('Kaydet'));
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    expect(find.byKey(const ValueKey('cost-code-code')), findsOneWidget);

    final listCallsBefore = repo.calls.where((c) => c == 'list').length;
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cost-code-code')), findsNothing);
    expect(repo.calls.where((c) => c == 'list').length, greaterThan(listCallsBefore));
    expect(find.text('Kum'), findsOneWidget);
  });
}
