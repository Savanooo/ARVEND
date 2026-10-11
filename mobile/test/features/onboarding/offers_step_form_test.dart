import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/onboarding/data/onboarding_repository.dart';
import 'package:arvend/features/onboarding/domain/onboarding_state.dart';
import 'package:arvend/features/onboarding/presentation/onboarding_step_forms.dart';

import '../../test_utils/fake_api_client.dart';

/// Firma Ayarları > Teklif: varsayılan para birimi korunur ve seçilebilir.
/// Eskiden formda alan yoktu ve her kayıt "TRY" gönderiyordu -- web'de EUR
/// yapılmış varsayılan, mobilde yalnızca alt not değiştirilince sessizce
/// TRY'ye dönüyordu.

OrganizationCommercialSettings _settings(String currency) => OrganizationCommercialSettings.fromJson({
      'default_currency': currency,
      'default_vat_rate': 20,
      'offer_prefix': 'TKF',
      'offer_validity_days': 30,
      'default_offer_footer': 'Eski not',
    });

const _saved = (status: 200, body: {'onboarding_completed': true, 'onboarding_step': 'completed'});

Future<FakeHttpClientAdapter> _pump(WidgetTester tester, String currency) async {
  final adapter = FakeHttpClientAdapter(script: {
    '/organization/settings/offers': [_saved],
  });
  final repo = OnboardingRepository(await buildFakeApiClient(adapter), basePath: '/organization/settings');
  await tester.binding.setSurfaceSize(const Size(400, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: OffersStepForm(repository: repo, initial: _settings(currency), onSaved: (_) {}),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return adapter;
}

Map<String, dynamic> _body(FakeHttpClientAdapter adapter) => adapter.requestBodies.single as Map<String, dynamic>;

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('Kaydet'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('yalnızca alt not değişince kayıtlı EUR korunur (TRY gönderilmez)', (tester) async {
    final adapter = await _pump(tester, 'EUR');

    expect(find.text('EUR (Euro)'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, 'Teklif Alt Notu'), 'Yeni not');
    await _save(tester);

    expect(_body(adapter)['default_currency'], 'EUR');
    expect(_body(adapter)['default_offer_footer'], 'Yeni not');
  });

  testWidgets('para birimi seçiciden USD seçilip kaydedilebilir', (tester) async {
    final adapter = await _pump(tester, 'TRY');

    await tester.tap(find.byKey(const ValueKey('offer-default-currency')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('USD (Amerikan Doları)').last);
    await tester.pumpAndSettle();
    await _save(tester);

    expect(_body(adapter)['default_currency'], 'USD');
  });

  testWidgets('listede olmayan kayıtlı kod (web serbest metni) olduğu gibi kalır', (tester) async {
    final adapter = await _pump(tester, 'GBP');

    expect(find.text('GBP'), findsOneWidget);
    await _save(tester);

    expect(_body(adapter)['default_currency'], 'GBP');
  });

  test('"TL" ve "₺" TRY sayılır, boş değer TRY olur, kod büyütülür', () {
    expect(normalizeOfferCurrency('TL'), 'TRY');
    expect(normalizeOfferCurrency(' ₺ '), 'TRY');
    expect(normalizeOfferCurrency(''), 'TRY');
    expect(normalizeOfferCurrency('eur'), 'EUR');
  });
}
