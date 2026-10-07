import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/offers/domain/offer.dart';
import 'package:arvend/features/offers/presentation/offer_detail_screen.dart';
import 'package:arvend/features/offers/presentation/offer_pdf.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart' show FakeAuth, testUser;

/// Teklif detayından PDF: `GET /offers/{id}/pdf` ApiClient üzerinden
/// indirilir, backend'in dosya adıyla cihazda açılır; hata mesajı gösterilir.

Map<String, dynamic> _offer({String offerNo = 'TKL-2026-0042', int revisionNo = 1, bool passive = false}) => {
      'id': 'o1',
      'offer_no': offerNo,
      'revision_no': revisionNo,
      'customer_name': 'Ali Veli',
      'offer_date': '2026-09-20',
      'subtotal': 1000,
      'vat_rate': 20,
      'vat_amount': 200,
      'grand_total': 1200,
      'notes': '',
      'status': 'gönderildi',
      'is_passive': passive,
      'items': <Object>[],
    };

class _OpenCall {
  _OpenCall(this.filename, this.bytes);
  final String filename;
  final Uint8List bytes;
}

Future<List<_OpenCall>> _pump(WidgetTester tester, FakeHttpClientAdapter adapter, {String? openError}) async {
  await tester.binding.setSurfaceSize(const Size(800, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final opened = <_OpenCall>[];
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
        authControllerProvider.overrideWith(() => FakeAuth(testUser({'offers.read'}))),
        offerPdfOpenerProvider.overrideWithValue((filename, bytes) async {
          opened.add(_OpenCall(filename, bytes));
          return openError;
        }),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

const _pdfBytes = [0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34];

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  test('pdfFilename backend offerPDFFilename ile aynı', () {
    Offer offer(String no, int rev) => Offer.fromJson(_offer(offerNo: no, revisionNo: rev));
    expect(offer('TKL/2026 Çatı-0042', 2).pdfFilename, 'Teklif-TKL-2026-Cati-0042-R2.pdf');
    expect(offer('TKL-2026-0042', 0).pdfFilename, 'Teklif-TKL-2026-0042.pdf');
    expect(offer('--', 1).pdfFilename, 'Teklif-teklif-R1.pdf');
  });

  testWidgets('"PDF İndir": /offers/o1/pdf istenir, baytlar dosya adıyla açılır', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: _offer())],
      '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
      '/offers/o1/pdf': [(status: 200, body: _pdfBytes)],
    });
    final opened = await _pump(tester, adapter);

    final button = find.widgetWithText(OutlinedButton, 'PDF İndir');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(adapter.calls, contains('/offers/o1/pdf'));
    expect(opened.single.filename, 'Teklif-TKL-2026-0042-R1.pdf');
    expect(opened.single.bytes, _pdfBytes);
  });

  testWidgets('pasif teklifte de uygulama çubuğundan PDF indirilebilir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: _offer(passive: true))],
      '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
      '/offers/o1/pdf': [(status: 200, body: _pdfBytes)],
    });
    final opened = await _pump(tester, adapter);

    await tester.tap(find.byKey(const ValueKey('offer-pdf-appbar')));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
  });

  testWidgets('sunucu hatası ve açılamayan dosya: mesaj gösterilir, çökme yok', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: _offer())],
      '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
      '/offers/o1/pdf': [
        (status: 404, body: {'error': 'teklif bulunamadı'}),
        (status: 200, body: _pdfBytes),
      ],
    });
    final opened = await _pump(tester, adapter, openError: 'PDF açılamadı: görüntüleyici yok');

    await tester.tap(find.byKey(const ValueKey('offer-pdf-appbar')));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.takeException(), isNull);

    ScaffoldMessenger.of(tester.element(find.byType(OfferDetailScreen))).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('offer-pdf-appbar')));
    await tester.pumpAndSettle();
    expect(find.text('PDF açılamadı: görüntüleyici yok'), findsOneWidget);
  });
}
