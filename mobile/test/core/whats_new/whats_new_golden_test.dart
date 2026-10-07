@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/whats_new/whats_new.dart';
import 'package:arvend/core/whats_new/whats_new_sheet.dart';

import '../../features/settings/settings_fakes.dart' show goldenTheme, loadAppFonts;

/// "Yenilikler" sayfasının ekran görüntüleri (uygulama fontlarıyla): 1.5.9
/// notları sahip için (6 madde), saha çalışanı için (2 madde) ve küçük
/// telefonda (320x568, maddeler kayar, "Tamam" yerinde). Üretmek:
///   flutter test --tags golden --update-goldens test/core/whats_new
void main() {
  setUpAll(loadAppFonts);

  final owner = whatsNewSince(lastSeenBuild: kWhatsNewLegacyBuild, installedBuild: 15, can: (_) => true)!;
  final field = whatsNewSince(lastSeenBuild: kWhatsNewLegacyBuild, installedBuild: 15, can: (_) => false)!;

  Future<void> pumpSheet(WidgetTester tester, Size size, WhatsNewNotes notes) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = size * 2.0;
    addTearDown(tester.view.reset);
    // Gerçek gölgeler (flutter_test varsayılanı düz siyah blok); expectGolden
    // sonunda geri alınır.
    debugDisableShadows = false;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: goldenTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('Ana Sayfa')),
            body: Center(
              child: TextButton(onPressed: () => showWhatsNewSheet(context, notes), child: const Text('Aç')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Aç'));
    await tester.pumpAndSettle();
  }

  Future<void> expectGolden(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    debugDisableShadows = true;
  }

  testWidgets('sahip: 1.5.9 notlarının tamamı', (tester) async {
    await pumpSheet(tester, const Size(360, 800), owner);
    await expectGolden(tester, 'whats_new_owner_360x800');
  });

  testWidgets('saha çalışanı: yalnızca herkese açık maddeler', (tester) async {
    await pumpSheet(tester, const Size(360, 800), field);
    await expectGolden(tester, 'whats_new_field_360x800');
  });

  testWidgets('küçük telefon: maddeler kayar, "Tamam" görünür kalır', (tester) async {
    await pumpSheet(tester, const Size(320, 568), owner);
    await expectGolden(tester, 'whats_new_owner_320x568');
  });
}
