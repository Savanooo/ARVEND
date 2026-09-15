// ARVEND açılış duman testi: kimliksiz kullanıcı /giris'e yönlendirilir ve
// giriş formu render edilir (backend'e gerçek bir çağrı yapılmadan - ApiClient
// override edilerek fetch her zaman ağ hatası döndürür, bu yüzden
// authControllerProvider.build() -> me() null'a düşer, redirect /giris'te kalır).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/app/app.dart';
import 'package:arvend/core/api/api_providers.dart';

import 'test_utils/fake_api_client.dart';

void main() {
  testWidgets('Uygulama açılışta giriş ekranını gösterir', (WidgetTester tester) async {
    final apiClient = await buildFakeApiClient(FakeHttpClientAdapter(script: {}));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(apiClient)],
        child: const ArvendApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Yönetim Sistemine Giriş'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Giriş Yap'), findsOneWidget);
  });
}
