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

/// Süresiz (geçerlilik tarihi olmayan) taslak gönderilirken firmanın
/// geçerlilik süresi varsa hatırlatılır: müşteri linkten aylar sonra eski
/// fiyatla kabul edebilir. Gönderim engellenmez; firma süresi okunamazsa ya
/// da tanımlı değilse not çıkmaz.

const _all = {'offers.read', 'offers.create', 'offers.update', 'offers.approve'};
final _today = DateTime.utc(2026, 10, 11);

Map<String, dynamic> _offer({String? validUntil, String status = 'taslak', bool passive = false}) => {
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
      'is_passive': passive,
      'items': <Object>[],
    };

const _defaults30 = (status: 200, body: {'vat_rate': 20, 'currency': 'TRY', 'validity_days': 30});

FakeHttpClientAdapter _adapter(Map<String, dynamic> offer, [Map<String, List<ScriptedResponse>> extra = const {}]) =>
    FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: offer)],
      '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
      '/offers/o1/share-links': [(status: 200, body: {'share_links': <Object>[]})],
      ...extra,
    });

Future<void> _pump(
  WidgetTester tester,
  FakeHttpClientAdapter adapter, {
  Set<String> permissions = _all,
  Size size = const Size(800, 2400),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final client = await buildFakeApiClient(adapter);
  final router = GoRouter(
    initialLocation: '/teklifler/o1',
    routes: [
      GoRoute(path: '/teklifler/:id', builder: (c, s) => OfferDetailScreen(offerId: s.pathParameters['id']!)),
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
  // Dar ekranda ListView düğmeyi henüz kurmamış olabilir.
  await tester.scrollUntilVisible(find.text(label), 300, scrollable: find.byType(Scrollable).first);
  final button = find.widgetWithText(ElevatedButton, label).evaluate().isNotEmpty
      ? find.widgetWithText(ElevatedButton, label)
      : find.widgetWithText(OutlinedButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

final _note = find.byKey(const ValueKey('offer-open-ended-note'));

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  testWidgets('süresiz taslak: "Gönderildi Olarak İşaretle" onayı firma süresini hatırlatır', (tester) async {
    await _pump(tester, _adapter(_offer(), {'/offers/defaults': [_defaults30]}));

    await _tap(tester, 'Gönderildi Olarak İşaretle');
    expect(find.text('Gönderildi Olarak İşaretle'), findsWidgets);
    expect(_note, findsOneWidget);
    expect(find.descendant(of: _note, matching: find.textContaining('Firma ayarı 30 gün')), findsOneWidget);
    expect(find.descendant(of: _note, matching: find.textContaining('teklifi düzenle')), findsOneWidget);
    // Hatırlatma engellemez: onay düğmesi duruyor.
    expect(find.byKey(const ValueKey('offer-status-confirm')), findsOneWidget);
  });

  testWidgets('süresiz taslak: e-posta ve "Gönder ve link oluştur" onayında da not var', (tester) async {
    await _pump(tester, _adapter(_offer(), {'/offers/defaults': [_defaults30]}));

    await _tap(tester, 'E-posta Gönder');
    expect(_note, findsOneWidget);
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();

    await _tap(tester, 'Paylaşım Linki');
    expect(find.byKey(const ValueKey('share-draft-send')), findsOneWidget);
    expect(_note, findsOneWidget);
  });

  testWidgets('tarihi olan taslakta ve süresi tanımsız firmada not yok', (tester) async {
    final dated = _adapter(_offer(validUntil: '2026-11-10'));
    await _pump(tester, dated);
    expect(dated.calls, isNot(contains('/offers/defaults')), reason: 'tarihli taslakta varsayılan istenmez');
    await _tap(tester, 'Gönderildi Olarak İşaretle');
    expect(_note, findsNothing);
  });

  testWidgets('firma süresi tanımlı değilse not yok', (tester) async {
    await _pump(
      tester,
      _adapter(_offer(), {
        '/offers/defaults': [(status: 200, body: {'vat_rate': 20, 'currency': 'TRY', 'validity_days': null})],
      }),
    );
    await _tap(tester, 'Gönderildi Olarak İşaretle');
    expect(_note, findsNothing);
  });

  testWidgets('offers.create yoksa varsayılan istenmez (403 yerine sessiz)', (tester) async {
    final adapter = _adapter(_offer());
    await _pump(tester, adapter, permissions: {'offers.read', 'offers.update', 'offers.approve'});
    expect(adapter.calls, isNot(contains('/offers/defaults')));
    await _tap(tester, 'Gönderildi Olarak İşaretle');
    expect(_note, findsNothing);
  });

  testWidgets('varsayılan okunamazsa gönderim yine açılır, not yok', (tester) async {
    await _pump(tester, _adapter(_offer(), {'/offers/defaults': [(status: 500, body: {'error': 'x'})]}));
    await _tap(tester, 'Gönderildi Olarak İşaretle');
    expect(_note, findsNothing);
    expect(find.byKey(const ValueKey('offer-status-confirm')), findsOneWidget);
  });

  // Telefon genişliği: uyarı kartları, arşiv notu ve hatırlatma notu
  // taşma (overflow) üretmez. (Başlıktaki tutar "Gönderildi" rozetiyle
  // 360 px'te satırı taşırıyordu; artık sığmazsa küçülür.)
  for (final c in [
    (name: 'süresi geçmiş taslak', offer: _offer(validUntil: '2026-10-01')),
    (name: 'süresi geçmiş gönderilmiş teklif', offer: _offer(validUntil: '2026-10-01', status: 'gönderildi')),
    (name: 'arşivdeki teklif', offer: _offer(passive: true, status: 'gönderildi')),
  ]) {
    testWidgets('360 px genişlikte taşma yok: ${c.name}', (tester) async {
      await _pump(tester, _adapter(c.offer), size: const Size(360, 780));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('360 px: hatırlatmalı onay penceresi taşmaz', (tester) async {
    await _pump(tester, _adapter(_offer(), {'/offers/defaults': [_defaults30]}), size: const Size(360, 780));
    await _tap(tester, 'Gönderildi Olarak İşaretle');
    expect(_note, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
