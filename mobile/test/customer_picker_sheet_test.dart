import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/features/offers/presentation/customer_picker_sheet.dart';

import 'test_utils/fake_api_client.dart';

/// Teklif formunun müşteri seçicisi yalnızca AKTİF müşterileri ister --
/// arşivlenmiş müşteriler eskiden işaretsiz listeleniyor ve yeni teklife
/// bağlanabiliyordu.
void main() {
  testWidgets('müşteri seçici filter=aktif ile ister', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/customers': [
        (
          status: 200,
          body: {
            'customers': [
              {
                'id': 'c1',
                'name': 'Aktif Müşteri',
                'phone': '0532 000 00 00',
                'email': '',
                'address': '',
                'tax_office': '',
                'tax_number': '',
                'notes': '',
                'is_active': true,
              },
            ],
          },
        ),
      ],
    });
    final client = await buildFakeApiClient(adapter);
    await tester.pumpWidget(ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => showCustomerPickerSheet(context), child: const Text('Aç')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Aç'));
    await tester.pumpAndSettle();

    expect(adapter.requestQueries.single['filter'], 'aktif');
    expect(find.text('Aktif Müşteri'), findsOneWidget);
  });
}
