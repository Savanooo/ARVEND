import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/features/offers/presentation/offer_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart';

/// Teklif detayındaki durum düğmeleri tek dokunuşla geri alınamaz sonuç
/// doğurur ("Kabul Edildi" teklifi kalıcı kilitler) -- her biri onay ister.

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

const _canApprove = {'offers.read', 'offers.update', 'offers.approve'};

Future<void> _pump(WidgetTester tester, FakeHttpClientAdapter adapter, {Set<String> permissions = _canApprove}) async {
  await tester.binding.setSurfaceSize(const Size(800, 2400));
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

Future<void> _tap(WidgetTester tester, String label) async {
  final button = find.widgetWithText(ElevatedButton, label).evaluate().isNotEmpty
      ? find.widgetWithText(ElevatedButton, label)
      : find.widgetWithText(OutlinedButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  testWidgets('"Kabul Edildi" onay ister: Vazgeç istek atmaz, onay kalıcı kilidi söyleyip durumu gönderir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [
        (status: 200, body: _offer('gönderildi')),
        (status: 200, body: _offer('kabul edildi')),
      ],
      '/offers/o1/revisions': [
        (status: 200, body: {'revisions': <Object>[]}),
        (status: 200, body: {'revisions': <Object>[]}),
      ],
      '/offers/o1/status': [(status: 200, body: _offer('kabul edildi'))],
    });
    await _pump(tester, adapter);

    await _tap(tester, 'Kabul Edildi');
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('KALICI'), findsOneWidget);
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(adapter.calls, isNot(contains('/offers/o1/status')));

    await _tap(tester, 'Kabul Edildi');
    await tester.tap(find.byKey(const ValueKey('offer-status-confirm')));
    await tester.pumpAndSettle();

    expect(requestBodyFor(adapter, '/offers/o1/status'), {'status': 'kabul edildi'});
  });

  testWidgets('"Reddedildi" de onaysız durum değiştirmez', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: _offer('gönderildi'))],
      '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
    });
    await _pump(tester, adapter);

    await _tap(tester, 'Reddedildi');
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(adapter.calls, isNot(contains('/offers/o1/status')));
  });

  testWidgets('taslak teklifte "Gönderildi Olarak İşaretle" onay ister', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/o1': [(status: 200, body: _offer('taslak'))],
      '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
    });
    await _pump(tester, adapter);

    await _tap(tester, 'Gönderildi Olarak İşaretle');
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(adapter.calls, isNot(contains('/offers/o1/status')));
  });

  // Durum ucu (PUT /offers/{id}/status) offers.approve ister; izni olmayan
  // düğmeye basıp ancak 403 snackbar'ıyla öğreniyordu. Paylaşım linki
  // sorusundaki "yetkiniz yok" notuyla aynı karar: düğme hiç gösterilmez.
  for (final status in ['taslak', 'gönderildi']) {
    testWidgets('offers.approve yok ($status): durum düğmeleri görünmez', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1': [(status: 200, body: _offer(status))],
        '/offers/o1/revisions': [(status: 200, body: {'revisions': <Object>[]})],
      });
      await _pump(tester, adapter, permissions: {'offers.read', 'offers.update'});

      for (final label in ['Gönderildi Olarak İşaretle', 'Kabul Edildi', 'Reddedildi']) {
        expect(find.text(label), findsNothing, reason: label);
      }
      // Durumla ilgisi olmayan işlemler yerinde kalır.
      expect(find.text('Paylaşım Linki'), findsOneWidget);
    });
  }
}
