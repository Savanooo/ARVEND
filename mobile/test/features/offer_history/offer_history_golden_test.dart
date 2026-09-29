@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/offers/history/offer_history_routes.dart';

import 'offer_history_test_support.dart';

/// Teklif geçmişi ekran görüntüleri (360x800 + tam sayfa, uygulama
/// fontlarıyla): teklif detayındaki bölüm, tam ekran olaylar / mail
/// geçmişi, boş ve yetkisiz. Üretmek:
///   flutter test --tags golden --update-goldens test/features/offer_history
/// Teklif geçmişi salt-okunurdur (yazma aksiyonu yok); "yetkili" ve
/// "yetkisiz" varyantları çizilir.
void main() {
  setUpAll(loadAppFonts);

  Future<void> pumpAt(WidgetTester tester, {String? location, FakeOfferHistoryRepository? repo}) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 800) * 2.0;
    addTearDown(tester.view.reset);
    debugDisableShadows = false;
    await tester.pumpWidget(buildOfferHistoryApp(
      repo: repo ?? FakeOfferHistoryRepository(),
      initialLocation: location ?? '/teklifler/$kOfferId',
      theme: goldenTheme(),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> expectGolden(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    debugDisableShadows = true;
  }

  Future<void> expandToFullPage(WidgetTester tester) async {
    final scrollable = tester.state<ScrollableState>(
      find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last,
    );
    final fullHeight = (800 + scrollable.position.maxScrollExtent).ceilToDouble();
    tester.view.physicalSize = Size(360, fullHeight) * 2.0;
    await tester.pumpAndSettle();
  }

  testWidgets('section in offer detail', (tester) async {
    await pumpAt(tester);
    await expectGolden(tester, 'offer_history_section_360x800');
  });

  testWidgets('section in offer detail full page', (tester) async {
    await pumpAt(tester);
    await expandToFullPage(tester);
    await expectGolden(tester, 'offer_history_section_360_full');
  });

  testWidgets('events screen', (tester) async {
    await pumpAt(tester, location: offerHistoryPath(kOfferId));
    await expectGolden(tester, 'offer_history_events_360x800');
  });

  testWidgets('events screen full page', (tester) async {
    await pumpAt(tester, location: offerHistoryPath(kOfferId));
    await expandToFullPage(tester);
    await expectGolden(tester, 'offer_history_events_360_full');
  });

  testWidgets('emails screen', (tester) async {
    await pumpAt(tester, location: offerHistoryPath(kOfferId, emails: true));
    await expectGolden(tester, 'offer_history_emails_360x800');
  });

  testWidgets('empty section', (tester) async {
    await pumpAt(tester, repo: FakeOfferHistoryRepository(eventItems: const [], emailItems: const []));
    await expectGolden(tester, 'offer_history_section_empty_360x800');
  });

  testWidgets('no access section', (tester) async {
    await pumpAt(tester, repo: FakeOfferHistoryRepository()..error = forbidden);
    await expectGolden(tester, 'offer_history_section_no_access_360x800');
  });

  testWidgets('no access screen', (tester) async {
    await pumpAt(tester, location: offerHistoryPath(kOfferId), repo: FakeOfferHistoryRepository()..error = forbidden);
    await expectGolden(tester, 'offer_history_no_access_360x800');
  });
}
