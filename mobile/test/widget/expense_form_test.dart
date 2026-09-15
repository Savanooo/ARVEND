import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/features/projects/presentation/expense_form_sheet.dart';

import '../test_utils/fake_api_client.dart';

void main() {
  testWidgets('geçersiz tutar/boş açıklama ile masraf formu gönderilemez, istek atılmaz', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {});
    final client = await buildFakeApiClient(adapter);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(client)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showExpenseFormSheet(context, 'p1', currency: 'TRY'),
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

    // Açıklama boş, tutar boş -> Kaydet doğrulama hatalarını göstermeli.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
    await tester.pump();

    expect(find.text('Açıklama gerekli'), findsOneWidget);
    expect(find.text('Geçerli bir tutar girin'), findsOneWidget);
    expect(adapter.calls, isEmpty, reason: 'form geçersizken hiçbir istek atılmamalı');

    // Açıklama var ama tutar <= 0 -> yine reddedilmeli.
    await tester.enterText(find.widgetWithText(TextFormField, 'Açıklama'), 'Çimento');
    await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '0');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
    await tester.pump();

    expect(find.text('Geçerli bir tutar girin'), findsOneWidget);
    expect(adapter.calls, isEmpty);
  });
}
