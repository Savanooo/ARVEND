import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/features/offers/data/offers_providers.dart';
import 'package:arvend/features/offers/presentation/offer_create_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart';

/// Teklif formundaki geçerlilik tarihi (web formundaki "Geçerlilik
/// Tarihi"nin karşılığı). Eskiden mobilde alan yoktu: süresi geçmiş bir
/// taslağın tarihi her kayıtta aynen geri gidiyor, sunucu "geçerlilik tarihi
/// bugünden önce olamaz" ile reddediyordu; taslak ne kaydedilebiliyor ne
/// gönderilebiliyordu, iş ancak web'den kurtarılıyordu.

final _user = testUser({'offers.read', 'offers.create', 'offers.update'});
final _today = DateTime.utc(2026, 10, 11);

Map<String, dynamic> _offer({String id = 'o1', String? validUntil}) => {
      'id': id,
      'offer_no': 'TKF-001',
      'revision_no': 0,
      'customer_id': null,
      'customer_name': 'Ali Veli',
      'offer_date': '2026-09-20',
      'valid_until': validUntil,
      'subtotal': 100,
      'vat_rate': 20,
      'vat_amount': 20,
      'grand_total': 120,
      'notes': '',
      'status': 'taslak',
      'is_passive': false,
      'items': [
        {'id': 'i1', 'product_name': 'Alçıpan', 'quantity': 1, 'unit_price': 100, 'line_total': 100, 'unit': 'm2'},
      ],
    };

const _defaults = (
  status: 200,
  body: {'vat_rate': 20, 'currency': 'TRY', 'validity_days': 30, 'valid_until': '2026-11-10'},
);

final _validity = find.byKey(const ValueKey('offer-valid-until'));
final _expiredNote = find.byKey(const ValueKey('offer-valid-until-expired'));

Future<FormPushProbe> _pump(WidgetTester tester, FakeHttpClientAdapter adapter, Widget form) => pumpRoutedForm(
      tester,
      adapter,
      form: form,
      user: _user,
      overrides: [offersTodayProvider.overrideWithValue(_today)],
    );

Future<void> _fillNewOffer(WidgetTester tester) async {
  await tester.enterText(formField('Müşteri Adı'), 'Ali Veli');
  await tester.enterText(formField('Ürün / Hizmet Adı').first, 'Alçıpan');
  await tester.enterText(formField('Miktar').first, '1');
  await tester.enterText(formField('Birim Fiyat').first, '100');
}

/// Takvimden [day]. günü seçip onaylar (test uygulamasında İngilizce "OK").
Future<void> _pickDay(WidgetTester tester, String day) async {
  await tester.ensureVisible(_validity);
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(of: _validity, matching: find.byType(InputDecorator)));
  await tester.pumpAndSettle();
  final dialog = find.byType(DatePickerDialog);
  await tester.tap(find.descendant(of: dialog, matching: find.text(day)));
  await tester.tap(find.descendant(of: dialog, matching: find.text('OK')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  group('yeni teklif', () {
    testWidgets('takvimden seçilen gün gönderilir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/defaults': [_defaults],
        '/offers/': [(status: 201, body: _offer())],
      });
      await _pump(tester, adapter, const OfferCreateScreen());

      // Takvim firma varsayılanında (Kasım 2026) açılır.
      await _pickDay(tester, '20');
      expect(find.descendant(of: _validity, matching: find.text('20.11.2026')), findsOneWidget);

      await _fillNewOffer(tester);
      await tapButton(tester, 'Teklifi Oluştur');
      expect(requestBodyFor(adapter, '/offers/')['valid_until'], '2026-11-20');
    });

    testWidgets('"Süresiz yap" boş tarih gönderir (firma süresi uygulanmaz)', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/defaults': [_defaults],
        '/offers/': [(status: 201, body: _offer())],
      });
      await _pump(tester, adapter, const OfferCreateScreen());

      await tester.tap(find.byKey(const ValueKey('offer-valid-until-clear')));
      await tester.pumpAndSettle();
      expect(find.descendant(of: _validity, matching: find.text('Süresiz')), findsOneWidget);

      await _fillNewOffer(tester);
      await tapButton(tester, 'Teklifi Oluştur');
      expect(requestBodyFor(adapter, '/offers/')['valid_until'], '');
    });

    testWidgets('takvim bugünden önceki günü seçtirmez', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/defaults': [(status: 200, body: {'vat_rate': 20, 'currency': 'TRY'})],
      });
      await _pump(tester, adapter, const OfferCreateScreen());

      await tester.tap(find.descendant(of: _validity, matching: find.byType(InputDecorator)));
      await tester.pumpAndSettle();
      final picker = tester.widget<DatePickerDialog>(find.byType(DatePickerDialog));
      expect(picker.firstDate, DateTime(2026, 10, 11));
      expect(picker.initialDate, DateTime(2026, 10, 11));
    });
  });

  group('süresi geçmiş taslak', () {
    testWidgets('uyarı görünür; tarihe dokunmadan kaydedilebilir (tarih gönderilmez)', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1': [
          (status: 200, body: _offer(validUntil: '2026-10-01')),
          (status: 200, body: _offer(validUntil: '2026-10-01')),
        ],
      });
      final probe = await _pump(tester, adapter, const OfferCreateScreen(offerId: 'o1'));

      expect(find.descendant(of: _validity, matching: find.text('01.10.2026')), findsOneWidget);
      expect(_expiredNote, findsOneWidget);
      expect(find.textContaining('müşteriye gönderemezsin'), findsOneWidget);

      await tester.enterText(formField('Miktar').first, '2');
      await tapButton(tester, 'Kaydet');

      final body = requestBodyFor(adapter, '/offers/o1');
      // Eskiden '2026-10-01' geri gidiyor, sunucu 400 veriyordu.
      expect(body['valid_until'], isNull);
      expect(probe.completed, isTrue);
    });

    testWidgets('yeni tarih seçilince uyarı kalkar ve tarih gönderilir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1': [
          (status: 200, body: _offer(validUntil: '2026-10-01')),
          (status: 200, body: _offer(validUntil: '2026-10-25')),
        ],
      });
      await _pump(tester, adapter, const OfferCreateScreen(offerId: 'o1'));

      // Geçmiş tarihte takvim bugünde (Ekim 2026) açılır.
      await _pickDay(tester, '25');
      expect(_expiredNote, findsNothing);
      expect(find.descendant(of: _validity, matching: find.text('25.10.2026')), findsOneWidget);

      await tapButton(tester, 'Kaydet');
      expect(requestBodyFor(adapter, '/offers/o1')['valid_until'], '2026-10-25');
    });

    testWidgets('360 px genişlikte alan ve uyarı taşmaz', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1': [(status: 200, body: _offer(validUntil: '2026-10-01'))],
      });
      await _pump(tester, adapter, const OfferCreateScreen(offerId: 'o1'));
      await tester.binding.setSurfaceSize(const Size(360, 780));
      await tester.pumpAndSettle();
      await tester.ensureVisible(_expiredNote);
      await tester.pumpAndSettle();

      expect(_expiredNote, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('süresiz yapılabilir', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1': [
          (status: 200, body: _offer(validUntil: '2026-10-01')),
          (status: 200, body: _offer()),
        ],
      });
      await _pump(tester, adapter, const OfferCreateScreen(offerId: 'o1'));

      await tester.tap(find.byKey(const ValueKey('offer-valid-until-clear')));
      await tester.pumpAndSettle();
      expect(_expiredNote, findsNothing);

      await tapButton(tester, 'Kaydet');
      expect(requestBodyFor(adapter, '/offers/o1')['valid_until'], '');
    });
  });
}
