import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/core/whats_new/whats_new.dart';
import 'package:arvend/core/whats_new/whats_new_sheet.dart';

/// Sayfanın düzeni: küçük telefonda ve büyük yazıda taşmaz, maddeler kayar,
/// "Tamam" hep görünür ve sayfayı kapatır.
void main() {
  final owner = whatsNewSince(lastSeenBuild: kWhatsNewLegacyBuild, installedBuild: 15, can: (_) => true)!;

  Future<void> pumpSheet(WidgetTester tester, Size size, {double textScale = 1}) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = size * 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(onPressed: () => showWhatsNewSheet(context, owner), child: const Text('Aç')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Aç'));
    await tester.pumpAndSettle();
  }

  final sheet = find.byKey(const Key('whats-new-sheet'));
  final done = find.widgetWithText(ElevatedButton, 'Tamam');

  for (final (size, scale) in [(const Size(320, 568), 1.0), (const Size(320, 568), 1.5), (const Size(360, 800), 1.3)]) {
    testWidgets('${size.width.toInt()}x${size.height.toInt()}, yazı x$scale: taşmaz, "Tamam" ekranda', (tester) async {
      await pumpSheet(tester, size, textScale: scale);
      expect(tester.takeException(), isNull);
      expect(sheet, findsOneWidget);

      final screen = Offset.zero & size;
      expect(screen.contains(tester.getBottomRight(done) - const Offset(1, 1)), isTrue);
      // Sayfa ekranın tepesine dayanmaz (arkada uygulama görünür kalır).
      expect(tester.getTopLeft(sheet).dy, greaterThan(size.height * 0.1));

      // Son madde kaydırarak görülebilir.
      await tester.scrollUntilVisible(
        find.text('Doğru tutar girişi'),
        100,
        scrollable: find.descendant(of: sheet, matching: find.byType(Scrollable)),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(done);
      await tester.pumpAndSettle();
      expect(sheet, findsNothing);
    });
  }
}
