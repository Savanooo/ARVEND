import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/presentation/login_screen.dart';

import '../test_utils/fake_api_client.dart';

/// Giriş ekranı açılıştaki oturum denetimini (GET /auth/me) izler: oturum
/// yok = 401 + refresh 401.
FakeHttpClientAdapter _signedOut([Map<String, List<ScriptedResponse>> extra = const {}]) =>
    FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 401, body: {'error': 'oturum bulunamadı'})],
      '/auth/refresh': [(status: 401, body: {'error': 'oturum bulunamadı'})],
      ...extra,
    });

Future<ProviderContainer> _pumpLogin(WidgetTester tester, FakeHttpClientAdapter adapter) async {
  final client = await buildFakeApiClient(adapter);
  final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: LoginScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('boş alanlarla gönderim: doğrulama hataları gösterilir, istek atılmaz', (tester) async {
    final adapter = _signedOut();
    await _pumpLogin(tester, adapter);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş Yap'));
    await tester.pump();

    expect(find.text('Kullanıcı adı gerekli'), findsOneWidget);
    expect(find.text('Şifre gerekli'), findsOneWidget);
    expect(adapter.calls, isNot(contains('/auth/login')));
  });

  testWidgets('yanlış şifre: backend hata mesajı ekranda gösterilir', (tester) async {
    final adapter = _signedOut({
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
    final adapter = _signedOut();
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

  testWidgets('kullanıcı pasif sebebi ekran AÇILDIKTAN sonra gelirse de gösterilir (soğuk açılış)', (tester) async {
    final container = await _pumpLogin(tester, _signedOut());
    expect(find.textContaining('erişiminiz kapatılmıştır'), findsNothing);

    // main.dart onAccountAccessBlocked: /auth/me -> refresh 403 "kullanıcı
    // pasif durumda" sonuçlandığında giriş ekranı zaten açıktır.
    container.read(accountAccessIssueProvider.notifier).state = AccountAccessIssue.userBlocked;
    await tester.pumpAndSettle();

    expect(find.text('Hesabınıza erişiminiz kapatılmıştır. Bilgi için yöneticinizle görüşün.'), findsOneWidget);
  });

  testWidgets('açılışta oturum ağ yüzünden doğrulanamadıysa sebep gösterilir', (tester) async {
    // /auth/me betiklenmedi -> bağlantı hatası; telefonda bilinen kullanıcı yok.
    SharedPreferences.setMockInitialValues({});
    await _pumpLogin(tester, FakeHttpClientAdapter(script: {}));

    expect(find.text('Bağlantı kurulamadı. İnternet bağlantınızı kontrol edin.'), findsOneWidget);
  });
}
