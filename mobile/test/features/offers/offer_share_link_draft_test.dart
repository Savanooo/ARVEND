import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/config/app_config.dart';
import 'package:arvend/features/offers/presentation/offer_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart';

/// Taslak teklifin linkinde müşteri Kabul Et / Reddet göremez ("teklif
/// atıyoruz, link vb., teklif kabul etme yok"). "Paylaşım Linki" taslakta
/// önce sorar: gönder ve link oluştur (mark_sent) / yalnızca önizleme /
/// vazgeç. Gönderilmiş teklifte soru yok.

const _canApprove = {'offers.read', 'offers.update', 'offers.approve'};
const _cannotApprove = {'offers.read', 'offers.update'};

Map<String, dynamic> _offer(String status) => {
      'id': 'o1',
      'offer_no': 'TKF-001',
      'revision_no': 0,
      'customer_name': 'Ali Veli',
      'offer_date': '2026-09-20',
      'subtotal': 1000,
      'vat_rate': 20,
      'vat_amount': 200,
      'grand_total': 1200,
      'notes': '',
      'status': status,
      'is_passive': false,
      'items': <Object>[],
    };

const _link = {
  'id': 'l1',
  'offer_id': 'o1',
  'revision_id': 'r1',
  'token': 'tok-abc',
  'created_at': '2026-09-20T10:00:00Z',
  'expires_at': null,
  'revoked_at': null,
  'is_active': true,
};

/// Açılışta liste (boş), sonra oluşturma, sonra oluşturmanın tetiklediği
/// liste tazelemesi -- sahte adaptör aynı yolu sırayla tüketir.
List<ScriptedResponse> _shareLinksScript() => [
      (status: 200, body: {'share_links': <Object>[]}),
      (status: 201, body: _link),
      (status: 200, body: {'share_links': [_link]}),
    ];

Future<void> _pump(
  WidgetTester tester,
  FakeHttpClientAdapter adapter,
  Set<String> permissions, {
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
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapShareLink(WidgetTester tester) async {
  final button = find.widgetWithText(OutlinedButton, 'Paylaşım Linki');
  // Dar ekranda liste düğmeyi henüz kurmamış olabilir: önce kaydır.
  await tester.scrollUntilVisible(button, 300, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

bool _posted(FakeHttpClientAdapter adapter) {
  for (var i = 0; i < adapter.calls.length; i++) {
    if (adapter.calls[i] == '/offers/o1/share-links' && adapter.methods[i] == 'POST') return true;
  }
  return false;
}

Finder _linkUrl() =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text('${AppConfig.apiBaseUrl}/paylas/tok-abc'));

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  testWidgets('taslak: "Gönder ve link oluştur" mark_sent gönderir, teklifi tazeler ve linki gösterir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [
        (status: 200, body: _offer('taslak')),
        (status: 200, body: _offer('gönderildi')),
      ],
      '/offers/o1/revisions': [
        (status: 200, body: {'revisions': <Object>[]}),
        (status: 200, body: {'revisions': <Object>[]}),
      ],
      '/offers/o1/share-links': _shareLinksScript(),
    });
    await _pump(tester, adapter, _canApprove);

    await _tapShareLink(tester);
    expect(find.text('Teklif taslak'), findsOneWidget);
    expect(find.textContaining("teklif 'Gönderildi' olmalı. Gönderildi olarak işaretleyip"), findsOneWidget);
    expect(find.text('Yalnızca önizleme linki'), findsOneWidget);
    expect(find.text('Vazgeç'), findsOneWidget);
    expect(find.byKey(const ValueKey('share-draft-no-permission-note')), findsNothing);
    expect(_posted(adapter), isFalse, reason: 'cevaptan önce istek yok');

    await tester.tap(find.widgetWithText(FilledButton, 'Gönder ve link oluştur'));
    await tester.pumpAndSettle();

    expect(requestBodyFor(adapter, '/offers/o1/share-links'), {'expires_in': '', 'mark_sent': true});
    expect(adapter.calls.where((c) => c == '/offers/o1').length, 2, reason: 'durum çipi için teklif tazelenir');
    expect(_linkUrl(), findsOneWidget);

    await tester.tap(find.text('Kapat'));
    await tester.pumpAndSettle();
    expect(find.text('Gönderildi Olarak İşaretle'), findsNothing, reason: 'teklif artık gönderildi');
  });

  testWidgets('taslak: "Yalnızca önizleme linki" durumu değiştirmez', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: _offer('taslak'))],
      '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
      '/offers/o1/share-links': _shareLinksScript(),
    });
    await _pump(tester, adapter, _canApprove);

    await _tapShareLink(tester);
    await tester.tap(find.text('Yalnızca önizleme linki'));
    await tester.pumpAndSettle();

    final body = requestBodyFor(adapter, '/offers/o1/share-links');
    expect(body.containsKey('mark_sent'), isFalse);
    expect(adapter.calls.where((c) => c == '/offers/o1').length, 1, reason: 'durum değişmedi, teklif tazelenmez');
    expect(_linkUrl(), findsOneWidget);
  });

  testWidgets('taslak: "Vazgeç" link oluşturmaz', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: _offer('taslak'))],
      '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
      '/offers/o1/share-links': _shareLinksScript(),
    });
    await _pump(tester, adapter, _canApprove);

    await _tapShareLink(tester);
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();

    expect(_posted(adapter), isFalse);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('taslak, durum değiştirme yetkisi yok: yalnızca önizleme + not', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: _offer('taslak'))],
      '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
      '/offers/o1/share-links': _shareLinksScript(),
    });
    await _pump(tester, adapter, _cannotApprove);

    await _tapShareLink(tester);
    expect(find.text('Teklif taslak'), findsOneWidget);
    expect(find.text('Gönder ve link oluştur'), findsNothing);
    expect(find.byKey(const ValueKey('share-draft-no-permission-note')), findsOneWidget);
    expect(find.textContaining('işaretleyip linki oluşturayım mı'), findsNothing);

    await tester.tap(find.text('Yalnızca önizleme linki'));
    await tester.pumpAndSettle();

    expect(requestBodyFor(adapter, '/offers/o1/share-links').containsKey('mark_sent'), isFalse);
    expect(_linkUrl(), findsOneWidget);
  });

  testWidgets('dar telefonda (360 pt) soru taşmadan açılır, üç seçenek de görünür', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: _offer('taslak'))],
      '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
      '/offers/o1/share-links': _shareLinksScript(),
    });
    await _pump(tester, adapter, _canApprove, size: const Size(360, 800));

    await _tapShareLink(tester);
    for (final label in ['Gönder ve link oluştur', 'Yalnızca önizleme linki', 'Vazgeç']) {
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.text(label)), findsOneWidget, reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('gönderilmiş teklif: soru yok, link doğrudan oluşur', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: _offer('gönderildi'))],
      '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
      '/offers/o1/share-links': _shareLinksScript(),
    });
    await _pump(tester, adapter, _canApprove);

    await _tapShareLink(tester);

    expect(find.text('Teklif taslak'), findsNothing);
    expect(requestBodyFor(adapter, '/offers/o1/share-links').containsKey('mark_sent'), isFalse);
    expect(_linkUrl(), findsOneWidget);
  });
}
