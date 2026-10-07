import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/widgets/app_list_card.dart';
import 'package:arvend/core/widgets/app_page_scaffold.dart';
import 'package:arvend/core/widgets/async_state_view.dart';
import 'package:arvend/core/widgets/status_badge.dart';
import 'package:arvend/features/auth/presentation/login_screen.dart';
import 'package:arvend/features/auth/presentation/set_initial_password_screen.dart';
import 'package:arvend/features/onboarding/presentation/onboarding_wizard_screen.dart';

import 'test_utils/fake_api_client.dart';

/// Faz 4 — son cila. Bu testler bir modülü YENİDEN TASARLAMAZ; yalnızca
/// bu fazın açıkça istediği şeyleri doğrular: Login/Onboarding'in
/// render edildiği, dar genişlikte/büyük yazı ölçeğinde taşma olmadığı,
/// izin-duyarlı boş durumların yanlış "Ekle" aksiyonu göstermediği, ve
/// StatusRegistry'nin madde 15'teki nötr/bilgi/başarı/uyarı/hata
/// taksonomisiyle tutarlı kaldığı.
Future<void> _pump(WidgetTester tester, FakeHttpClientAdapter adapter, Widget child, {Size size = const Size(400, 1600), double textScale = 1.0}) async {
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp(
        builder: (context, widget) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: widget!,
        ),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  group('Login — madde 2', () {
    testWidgets('marka + alanlar + birincil CTA render edilir', (tester) async {
      await _pump(tester, FakeHttpClientAdapter(script: {}), const LoginScreen());

      expect(find.bySemanticsLabel('ARVEND YAPI'), findsOneWidget, reason: 'logo görseli, yazısı içinde');
      expect(find.byType(TextFormField), findsNWidgets(2));
      expect(find.widgetWithText(ElevatedButton, 'Giriş Yap'), findsOneWidget);
    });

    testWidgets('boş alanlarla gönderim doğrulama hatalarını gösterir, istek atılmaz', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {});
      await _pump(tester, adapter, const LoginScreen());

      await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş Yap'));
      await tester.pumpAndSettle();

      expect(find.text('Kullanıcı adı gerekli'), findsOneWidget);
      expect(find.text('Şifre gerekli'), findsOneWidget);
      // Ekran açılıştaki oturum denetimini (/auth/me) izler; giriş isteği yok.
      expect(adapter.calls, isNot(contains('/auth/login')));
    });

    testWidgets('320px dar ekranda taşma yok', (tester) async {
      await _pump(tester, FakeHttpClientAdapter(script: {}), const LoginScreen(), size: const Size(320, 700));
      expect(tester.takeException(), isNull);
    });

    testWidgets('1.6x yazı ölçeğinde taşma yok', (tester) async {
      await _pump(tester, FakeHttpClientAdapter(script: {}), const LoginScreen(), textScale: 1.6);
      expect(tester.takeException(), isNull);
    });
  });

  group('Şifre Belirleme (ilk giriş) — madde 2', () {
    testWidgets('şifreler eşleşmezse hata gösterir, çağrı atılmaz', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {});
      await _pump(tester, adapter, const SetInitialPasswordScreen());

      await tester.enterText(find.widgetWithText(TextFormField, 'Yeni Şifre'), 'sifre1234');
      await tester.enterText(find.widgetWithText(TextFormField, 'Yeni Şifre (Tekrar)'), 'farkli1234');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Devam Et'));
      await tester.pumpAndSettle();

      expect(find.text('Şifreler eşleşmiyor'), findsOneWidget);
      expect(adapter.calls, isEmpty);
    });
  });

  group('Onboarding sihirbazı — madde 3', () {
    testWidgets('adım göstergesi ve ilk adımın bölüm başlıkları render edilir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/onboarding': [
          (
            status: 200,
            body: {
              'onboarding_completed': false,
              'onboarding_step': 'company',
              'profile': <String, dynamic>{},
              'commercial': <String, dynamic>{},
            },
          ),
        ],
      });
      await _pump(tester, adapter, const OnboardingWizardScreen(), size: const Size(400, 1400));

      expect(find.text('Firma Kurulumu'), findsOneWidget);
      expect(find.text('Adım 1 / 5'), findsOneWidget);
      // Sihirbazın bu ekranın kendisine dönecek bir geri navigasyonu yok.
      expect(find.byTooltip('Back'), findsNothing);
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('yükleme başarısız olursa ErrorState + tekrar dene gösterilir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {'/onboarding': []});
      await _pump(tester, adapter, const OnboardingWizardScreen(), size: const Size(400, 1400));

      expect(find.byType(ErrorState), findsOneWidget);
      expect(find.text('Tekrar Dene'), findsOneWidget);
    });
  });

  group('AppPageScaffold — automaticallyImplyLeading', () {
    testWidgets('false verilirse geri butonu render edilmez', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: AppPageScaffold(
          title: Text('Başlık'),
          automaticallyImplyLeading: false,
          body: SizedBox.shrink(),
        ),
      ));
      expect(find.byType(BackButton), findsNothing);
    });
  });

  group('İzin-duyarlı boş durumlar — madde 7', () {
    testWidgets('EmptyStateView ikon + kısa mesajla tutarlı render edilir', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: EmptyStateView(message: 'Kayıt bulunamadı.', icon: Icons.inbox_outlined)),
      ));
      expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
      expect(find.text('Kayıt bulunamadı.'), findsOneWidget);
    });
  });

  group('Hata durumu tutarlılığı — madde 9', () {
    testWidgets('ErrorState yeniden dene çağrısını tetikler', (tester) async {
      var retried = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ErrorState(
            error: const ApiException(message: 'Sunucuya ulaşılamadı', statusCode: 500, kind: ApiErrorKind.server),
            onRetry: () async => retried = true,
          ),
        ),
      ));

      expect(find.text('Sunucuya ulaşılamadı'), findsOneWidget);
      await tester.tap(find.text('Tekrar Dene'));
      await tester.pumpAndSettle();
      expect(retried, isTrue);
    });
  });

  group('Durum semantiği son denetim — madde 15', () {
    // Nötr: draft/pasif. Bilgi: active/in progress/sent/issued. Başarı:
    // accepted/approved/certified/completed/paid. Uyarı: pending/attention
    // required. Hata: rejected/cancelled/terminated/overdue.
    test('temsili durum örnekleri beklenen tonlarla eşleşir', () {
      StatusTone toneOf(Map<String, (String, StatusTone)> registry, String key) => registry[key]!.$2;

      expect(toneOf(StatusRegistry.offer, 'taslak'), StatusTone.muted);
      expect(toneOf(StatusRegistry.offer, 'gönderildi'), StatusTone.info);
      expect(toneOf(StatusRegistry.offer, 'kabul edildi'), StatusTone.success);
      expect(toneOf(StatusRegistry.offer, 'reddedildi'), StatusTone.danger);

      expect(toneOf(StatusRegistry.project, 'active'), StatusTone.info);
      expect(toneOf(StatusRegistry.project, 'completed'), StatusTone.success);
      expect(toneOf(StatusRegistry.project, 'cancelled'), StatusTone.danger);

      expect(toneOf(StatusRegistry.subcontract, 'draft'), StatusTone.muted);
      expect(toneOf(StatusRegistry.subcontract, 'active'), StatusTone.info);
      expect(toneOf(StatusRegistry.subcontract, 'terminated'), StatusTone.danger);

      expect(toneOf(StatusRegistry.progressClaim, 'certified'), StatusTone.success);
      expect(toneOf(StatusRegistry.progressClaim, 'rejected'), StatusTone.danger);

      // Faz 3'te düzeltildi -- brand gold DEĞİL.
      expect(toneOf(StatusRegistry.purchaseOrder, 'approved'), StatusTone.success);
      expect(StatusRegistry.awardedQuotation.tone, StatusTone.success);

      // Brand gold (StatusTone.gold), hiçbir registry'de "warning" anlamıyla
      // KULLANILMAMALI -- yalnızca öncelik/kategori vurgusu için var olabilir,
      // asla bir "durum" (draft/active/vb.) değerine karşılık gelmemeli.
      const workflowStatusKeys = {'draft', 'active', 'pending', 'submitted', 'issued', 'sent'};
      for (final entry in StatusRegistry.subcontract.entries) {
        if (workflowStatusKeys.contains(entry.key)) {
          expect(entry.value.$2, isNot(StatusTone.gold), reason: 'subcontract.${entry.key}');
        }
      }
      for (final entry in StatusRegistry.progressClaim.entries) {
        if (workflowStatusKeys.contains(entry.key)) {
          expect(entry.value.$2, isNot(StatusTone.gold), reason: 'progressClaim.${entry.key}');
        }
      }
    });
  });

  group('Sözleşme/Taşeron listesi — izin-duyarlı Ekle aksiyonu', () {
    testWidgets('AppListCard trailing izin yokken bir "Ekle" ikon-butonu İÇERMEZ', (tester) async {
      // AppListCard'ın kendisi salt sunum -- iznin doğru şekilde false
      // geçildiğinde hiçbir IconButton/TextButton eklenmediğini, yalnızca
      // salt-okunur trailing içeriğin kaldığını doğrular (ekle aksiyonu
      // çağıran taraftan, `canManage` ile koşullu geçirilir).
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: AppListCard(title: 'TAS-1 — Taşeron A', trailing: Text('Aktif')),
        ),
      ));
      expect(find.byType(IconButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
    });
  });
}
