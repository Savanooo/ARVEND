import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/features/auth/presentation/login_screen.dart';

import '../test_utils/fake_api_client.dart';

Future<void> _pumpLogin(WidgetTester tester, FakeHttpClientAdapter adapter) async {
  final client = await buildFakeApiClient(adapter);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: const MaterialApp(home: LoginScreen()),
    ),
  );
}

void main() {
  testWidgets('boş alanlarla gönderim: doğrulama hataları gösterilir, istek atılmaz', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {});
    await _pumpLogin(tester, adapter);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş Yap'));
    await tester.pump();

    expect(find.text('Kullanıcı adı gerekli'), findsOneWidget);
    expect(find.text('Şifre gerekli'), findsOneWidget);
    expect(adapter.calls, isEmpty);
  });

  testWidgets('yanlış şifre: backend hata mesajı ekranda gösterilir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/login': [
        (status: 401, body: {'error': 'kullanıcı adı veya şifre hatalı'}),
      ],
    });
    await _pumpLogin(tester, adapter);

    await tester.enterText(find.byType(TextFormField).first, 'admin');
    await tester.enterText(find.byType(TextFormField).last, 'yanlis-sifre');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş Yap'));
    await tester.pumpAndSettle();

    expect(find.text('kullanıcı adı veya şifre hatalı'), findsOneWidget);
  });

  testWidgets('şifre göster/gizle ikonu obscureText\'i değiştirir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {});
    await _pumpLogin(tester, adapter);

    // TextFormField kendi obscureText'ini dışa açmaz; alttaki TextField'a bakılır.
    final passwordTextField = find.descendant(
      of: find.byType(TextFormField).last,
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(passwordTextField).obscureText, isTrue);

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pump();

    expect(tester.widget<TextField>(passwordTextField).obscureText, isFalse);
  });
}
