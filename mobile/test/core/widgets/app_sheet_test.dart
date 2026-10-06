import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/widgets/app_sheet.dart';
import 'package:arvend/core/widgets/unsaved_changes_scope.dart';

Future<void> _open(WidgetTester tester, {bool dirty = false, bool busy = false}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showAppSheet<void>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => UnsavedChangesScope(
              dirty: dirty,
              busy: busy,
              child: const Padding(padding: EdgeInsets.all(24), child: Text('Masraf Ekle')),
            ),
          ),
          child: const Text('aç'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('aç'));
  await tester.pumpAndSettle();
  expect(find.text('Masraf Ekle'), findsOneWidget);
  expect(find.byKey(const Key('sheet-drag-handle')), findsOneWidget);
}

Future<void> _dragDown(WidgetTester tester) async {
  await tester.drag(find.text('Masraf Ekle'), const Offset(0, 300));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('aşağı çekince form kapanır', (tester) async {
    await _open(tester);
    await _dragDown(tester);
    expect(find.text('Masraf Ekle'), findsNothing);
  });

  testWidgets('kayıt sürerken aşağı çekmek formu kapatmaz, uyarı gösterir', (tester) async {
    await _open(tester, busy: true);
    await _dragDown(tester);
    expect(find.text('Masraf Ekle'), findsOneWidget);
    expect(find.text('Kaydediliyor, lütfen bitmesini bekle.'), findsOneWidget);
  });

  testWidgets('kaydedilmemiş değişiklik varsa aşağı çekince önce onay sorar', (tester) async {
    await _open(tester, dirty: true);
    await _dragDown(tester);
    expect(find.text('Masraf Ekle'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Çık'));
    await tester.pumpAndSettle();
    expect(find.text('Masraf Ekle'), findsNothing);
  });
}
