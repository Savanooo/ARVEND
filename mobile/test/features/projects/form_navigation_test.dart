import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/offers/presentation/offer_create_screen.dart';
import 'package:arvend/features/projects/presentation/purchase_request_form_screen.dart';

import '../../test_utils/fake_api_client.dart';
import 'form_test_support.dart';

/// Kaydedilen form, onu açan `push`'u TAMAMLAR (ana sayfanın hızlı işlem
/// kilidi bu Future'ı bekler; eskiden `context.go` ile hiç tamamlanmıyor,
/// kilit açık kalıp mükerrer kayda yol açıyordu). Oluşturmada yeni kaydın
/// detayı açılır ve geri, formu açan ekrana döner; düzenlemede form yalnızca
/// kapanır.

const _prCreated = (status: 201, body: {'id': 'pr1', 'pr_no': 'PR-1', 'title': 'Demir', 'status': 'draft'});

void main() {
  testWidgets('talep oluştur: açan push tamamlanır, detay açılır, geri formu açana döner', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/organization/cost-codes': [kCostCodesResponse],
      '/projects/p1/purchase-requests': [_prCreated],
    });
    final probe = await pumpRoutedForm(tester, adapter, form: const PurchaseRequestFormScreen(projectId: 'p1'));

    await tester.enterText(formField('Başlık'), 'Demir ihtiyacı');
    await tapButton(tester, 'Talebi Oluştur');

    expect(probe.completed, isTrue, reason: 'formu açan push tamamlanmalı');
    expect(find.text('detay /projeler/p1/satin-alma/talepler/pr1'), findsOneWidget);
    expect(find.text('Yeni Satın Alma Talebi'), findsNothing, reason: 'dolu form yığında kalmamalı');

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Aç'), findsOneWidget, reason: 'detaydan geri, formu açan ekrana döner');
  });

  testWidgets('talep düzenle: form kapanır (detay zaten alttadır), push tamamlanır', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/organization/cost-codes': [kCostCodesResponse],
      '/projects/p1/purchase-requests/pr1': [
        (
          status: 200,
          body: {
            'purchase_request': {'id': 'pr1', 'pr_no': 'PR-1', 'title': 'Demir', 'status': 'draft'},
            'items': <Object>[],
          },
        ),
        (status: 200, body: {'id': 'pr1', 'pr_no': 'PR-1', 'title': 'Demir 2', 'status': 'draft'}),
      ],
    });
    final probe = await pumpRoutedForm(
      tester,
      adapter,
      form: const PurchaseRequestFormScreen(projectId: 'p1', prId: 'pr1'),
    );

    await tapButton(tester, 'Kaydet');

    expect(probe.completed, isTrue);
    expect(find.text('Aç'), findsOneWidget, reason: 'düzenleme formu kapanıp açan ekrana döner');
    expect(find.textContaining('detay '), findsNothing, reason: 'detay ikinci kez yığına eklenmez');
  });

  testWidgets('teklif oluştur: açan push tamamlanır ve teklif detayı açılır', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/': [
        (
          status: 201,
          body: {
            'id': 'o9',
            'offer_no': 'TKF-009',
            'revision_no': 0,
            'customer_name': 'Ali Veli',
            'offer_date': '2026-10-06',
            'subtotal': 100,
            'vat_rate': 20,
            'vat_amount': 20,
            'grand_total': 120,
            'status': 'taslak',
            'is_passive': false,
            'items': <Object>[],
          },
        ),
      ],
    });
    final probe = await pumpRoutedForm(
      tester,
      adapter,
      form: const OfferCreateScreen(),
      user: testUser({'offers.read', 'offers.create'}),
    );

    await tester.enterText(formField('Müşteri Adı'), 'Ali Veli');
    await tester.enterText(formField('Ürün / Hizmet Adı'), 'Alçıpan');
    await tester.enterText(formField('Miktar'), '1');
    await tester.enterText(formField('Birim Fiyat'), '100');
    await tapButton(tester, 'Teklifi Oluştur');

    expect(probe.completed, isTrue);
    expect(find.text('detay /teklifler/o9'), findsOneWidget);
  });
}
