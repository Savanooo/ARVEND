import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/offers/data/offers_providers.dart';
import 'package:arvend/features/offers/presentation/offer_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart';

/// Geçerlilik tarihi geçmiş teklif müşteriye gönderilemez (sunucu 409).
/// Eskiden mobil bunu ancak düğmeye basınca gelen hata metniyle söylüyordu
/// ve tarihi değiştirecek yer yoktu. Şimdi detay ne olduğunu ve ne
/// yapılacağını baştan söyler; gönderim düğmeleri istek atmadan açıklar ve
/// taslakta düzenlemeye götürür.

const _all = {'offers.read', 'offers.update', 'offers.approve'};
final _today = DateTime.utc(2026, 10, 11);

Map<String, dynamic> _offer(String status, {String? validUntil = '2026-10-01'}) => {
      'id': 'o1',
      'offer_no': 'TKF-001',
      'revision_no': 0,
      'customer_name': 'Ali Veli',
      'customer_email': 'ali@example.com',
      'offer_date': '2026-09-20',
      'valid_until': validUntil,
      'subtotal': 1000,
      'vat_rate': 20,
      'vat_amount': 200,
      'grand_total': 1200,
      'notes': '',
      'status': status,
      'is_passive': false,
      'items': <Object>[],
    };

FakeHttpClientAdapter _adapter(Map<String, dynamic> offer, [Map<String, List<ScriptedResponse>> extra = const {}]) =>
    FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: offer)],
      '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
      '/offers/o1/share-links': [(status: 200, body: {'share_links': <Object>[]})],
      ...extra,
    });

Future<void> _pump(WidgetTester tester, FakeHttpClientAdapter adapter, {Set<String> permissions = _all}) async {
  await tester.binding.setSurfaceSize(const Size(800, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final client = await buildFakeApiClient(adapter);
  final router = GoRouter(
    initialLocation: '/teklifler/o1',
    routes: [
      GoRoute(path: '/teklifler/:id', builder: (c, s) => OfferDetailScreen(offerId: s.pathParameters['id']!)),
      GoRoute(path: '/teklifler/:id/duzenle', builder: (c, s) => const Scaffold(body: Text('Düzenle ekranı'))),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => FakeAuth(testUser(permissions))),
        offersTodayProvider.overrideWithValue(_today),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String label) async {
  final button = find.widgetWithText(ElevatedButton, label).evaluate().isNotEmpty
      ? find.widgetWithText(ElevatedButton, label)
      : find.widgetWithText(OutlinedButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

final _notice = find.byKey(const ValueKey('offer-expired-notice'));
final _dialog = find.byKey(const ValueKey('offer-expired-dialog'));

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  testWidgets('süresi geçmiş taslak: uyarı ne yapılacağını söyler, "Tarihi Güncelle" düzenlemeyi açar', (tester) async {
    await _pump(tester, _adapter(_offer('taslak')));

    expect(_notice, findsOneWidget);
    expect(find.descendant(of: _notice, matching: find.textContaining('01.10.2026')), findsOneWidget);
    expect(find.descendant(of: _notice, matching: find.textContaining('yeni bir tarih seç')), findsOneWidget);

    await tester.tap(find.descendant(of: _notice, matching: find.text('Tarihi Güncelle')));
    await tester.pumpAndSettle();
    expect(find.text('Düzenle ekranı'), findsOneWidget);
  });

  testWidgets('"Gönderildi Olarak İşaretle" istek atmadan açıklar, düzenlemeye götürür', (tester) async {
    final adapter = _adapter(_offer('taslak'));
    await _pump(tester, adapter);

    await _tap(tester, 'Gönderildi Olarak İşaretle');
    expect(_dialog, findsOneWidget);
    expect(adapter.calls, isNot(contains('/offers/o1/status')));

    await tester.tap(find.descendant(of: _dialog, matching: find.text('Tarihi Güncelle')));
    await tester.pumpAndSettle();
    expect(find.text('Düzenle ekranı'), findsOneWidget);
  });

  testWidgets('"E-posta Gönder" süresi geçmiş teklifte e-posta göndermez', (tester) async {
    final adapter = _adapter(_offer('taslak'));
    await _pump(tester, adapter);

    await _tap(tester, 'E-posta Gönder');
    expect(_dialog, findsOneWidget);
    await tester.tap(find.descendant(of: _dialog, matching: find.text('Vazgeç')));
    await tester.pumpAndSettle();
    expect(adapter.calls, isNot(contains('/offers/o1/send-email')));
  });

  testWidgets('taslak paylaşım linki: yalnızca önizleme sunulur, nedeni yazılır', (tester) async {
    final adapter = _adapter(_offer('taslak'), {
      '/offers/o1/share-links': [
        (status: 200, body: {'share_links': <Object>[]}),
        (
          status: 201,
          body: {
            'id': 'l1',
            'offer_id': 'o1',
            'revision_id': 'r1',
            'token': 'tok',
            'created_at': '2026-10-11T10:00:00Z',
            'is_active': true,
          },
        ),
        (status: 200, body: {'share_links': <Object>[]}),
      ],
    });
    await _pump(tester, adapter);

    await _tap(tester, 'Paylaşım Linki');
    expect(find.byKey(const ValueKey('share-draft-send')), findsNothing);
    expect(find.byKey(const ValueKey('share-draft-expired-note')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('share-draft-preview')));
    await tester.pumpAndSettle();
    expect(requestBodyFor(adapter, '/offers/o1/share-links'), {'expires_in': ''}, reason: 'mark_sent gönderilmez');
  });

  testWidgets('gönderilmiş ve süresi geçmiş teklif: uyarı "Revize Et"i önerir, tarih düğmesi yok', (tester) async {
    await _pump(tester, _adapter(_offer('gönderildi')));

    expect(find.descendant(of: _notice, matching: find.textContaining('Revize Et ve Düzenle')), findsOneWidget);
    expect(find.descendant(of: _notice, matching: find.text('Tarihi Güncelle')), findsNothing);
  });

  testWidgets('düzenleme yetkisi yoksa uyarı kimin güncelleyebileceğini söyler, düğme yok', (tester) async {
    await _pump(tester, _adapter(_offer('taslak')), permissions: {'offers.read', 'offers.approve'});

    expect(find.descendant(of: _notice, matching: find.textContaining('düzenleme yetkisi olan biri')), findsOneWidget);
    expect(find.descendant(of: _notice, matching: find.text('Tarihi Güncelle')), findsNothing);
  });

  testWidgets('tarih bugün ise hâlâ geçerli: uyarı yok, normal onay akışı', (tester) async {
    final adapter = _adapter(_offer('taslak', validUntil: '2026-10-11'));
    await _pump(tester, adapter);

    expect(_notice, findsNothing);
    await _tap(tester, 'Gönderildi Olarak İşaretle');
    expect(_dialog, findsNothing);
    expect(find.byKey(const ValueKey('offer-status-confirm')), findsOneWidget);
  });

  testWidgets('tarihsiz (süresiz) teklifte uyarı yok', (tester) async {
    await _pump(tester, _adapter(_offer('taslak', validUntil: null)));
    expect(_notice, findsNothing);
  });
}
