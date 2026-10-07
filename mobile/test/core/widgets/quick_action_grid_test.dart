import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/core/widgets/quick_action_button.dart';

/// Ana Sayfa'nın en kalabalık hızlı işlem kümesi (yönetici): tek ve iki
/// satırlık etiketler karışık.
const _labels = [
  'Teklif Oluştur',
  'Tahsilat Gir',
  'Masraf Gir',
  'Satın Alma Talebi',
  'Görev Ekle',
  'Not Ekle',
  'Müşteri Ekle',
  'Mesai Gir',
  'Metraj',
];

Future<void> _pump(WidgetTester tester, {double width = 360, double textScale = 1.0, int count = 9}) async {
  await tester.binding.setSurfaceSize(Size(width, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 800), textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: SingleChildScrollView(
            // Sayfaların yatay boşluğu (kScreenPadding).
            padding: const EdgeInsets.all(16),
            child: QuickActionGrid(
              children: [
                for (final label in _labels.take(count))
                  QuickActionButton(icon: Icons.add, label: label, onPressed: () {}),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectEvenAndVisible(WidgetTester tester, double screenWidth) {
  final rects = [
    for (final e in find.byType(QuickActionButton).evaluate()) tester.getRect(find.byWidget(e.widget)),
  ];
  expect(rects, isNotEmpty);
  for (final r in rects) {
    expect(r.width, closeTo(rects.first.width, 0.01), reason: 'bütün kutucuklar aynı boyutta');
    expect(r.height, closeTo(rects.first.height, 0.01), reason: 'bütün kutucuklar aynı boyutta');
    expect(r.left, greaterThanOrEqualTo(16), reason: 'sol boşluk içinde');
    expect(r.right, lessThanOrEqualTo(screenWidth - 16), reason: 'hiçbir kutucuk ekran kenarında kesilmez');
  }
  // İkonlar aynı satırdaki her kutucukta aynı hizada (etiket 1 ya da 2 satır).
  final icons = [for (final e in find.byIcon(Icons.add).evaluate()) tester.getCenter(find.byWidget(e.widget))];
  final byRow = <double, List<Offset>>{};
  for (final r in rects) {
    byRow.putIfAbsent(r.top, () => []);
  }
  for (final c in icons) {
    final rowTop = byRow.keys.lastWhere((top) => top <= c.dy);
    byRow[rowTop]!.add(c);
  }
  for (final row in byRow.values) {
    expect(row.map((c) => c.dy).toSet(), hasLength(1));
  }
}

void main() {
  testWidgets('360 dp: 4 sütun, kutucuklar eşit boyda ve hiçbiri kesilmez', (tester) async {
    await _pump(tester);

    expect(tester.takeException(), isNull);
    _expectEvenAndVisible(tester, 360);
    final rects = [for (final e in find.byType(QuickActionButton).evaluate()) tester.getRect(find.byWidget(e.widget))];
    expect(rects.map((r) => r.top).toSet(), hasLength(3), reason: '9 işlem -> 4 + 4 + 1');
    expect(rects.first.width, inInclusiveRange(QuickActionGrid.minTileWidth, QuickActionGrid.maxTileWidth));
    expect(find.byType(Scrollable), findsOneWidget, reason: 'yatay kaydırma yok');
  });

  testWidgets('1.3 yazı ölçeğinde taşma yok, boyutlar yine eşit', (tester) async {
    await _pump(tester, textScale: 1.3);

    expect(tester.takeException(), isNull);
    _expectEvenAndVisible(tester, 360);
  });

  testWidgets('az işlemde kutucuklar genişlemez (aynı ızgara ölçüsü)', (tester) async {
    await _pump(tester, count: 2);
    final rects = [for (final e in find.byType(QuickActionButton).evaluate()) tester.getRect(find.byWidget(e.widget))];
    expect(rects.first.width, lessThanOrEqualTo(QuickActionGrid.maxTileWidth));
    expect(rects[0].size, rects[1].size);
  });

  test('sütun sayısı genişlikten', () {
    expect(QuickActionGrid.columnsFor(328), 4); // 360 dp telefon
    expect(QuickActionGrid.columnsFor(380), 4); // 412 dp telefon
    expect(QuickActionGrid.columnsFor(288), 3); // 320 dp dar telefon
    final tablet = QuickActionGrid.columnsFor(768);
    expect(tablet, greaterThan(4));
    expect((768 - QuickActionGrid.spacing * (tablet - 1)) / tablet, lessThanOrEqualTo(QuickActionGrid.maxTileWidth));
  });
}
