@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/features/auth/domain/user.dart';

import '../../contract_co/contract_co_test_support.dart' as cc;
import 'project_activity_test_support.dart';

/// Proje Aktivite Geçmişi ekran görüntüleri (360x800 + tam boy, uygulama
/// fontlarıyla): sahip (tutarlarla) ve Proje Yöneticisi (tutarsız). Üretmek:
///   flutter test --tags golden --update-goldens test/features/projects/activity
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await cc.loadAppFonts();
  });

  Future<void> pumpAt(WidgetTester tester, User user, {double height = 800}) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = Size(360, height) * 2.0;
    addTearDown(tester.view.reset);
    debugDisableShadows = false;
    await tester.pumpWidget(buildActivityApp(user: user, repo: FakeActivityRepository(), theme: cc.goldenTheme()));
    await tester.pumpAndSettle();
  }

  Future<void> expectGolden(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    debugDisableShadows = true;
  }

  testWidgets('sahip', (tester) async {
    await pumpAt(tester, activityOwner);
    await expectGolden(tester, 'project_activity_owner_360x800');
  });

  // Tam boy varyant yok: fikstür 360x800'e sığıyor, görüntü birebir aynıydı.

  testWidgets('Proje Yöneticisi (tutar yok)', (tester) async {
    await pumpAt(tester, activityPm);
    await expectGolden(tester, 'project_activity_pm_360x800');
  });
}
