import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/offers/presentation/offer_create_screen.dart';
import 'package:arvend/features/offers/presentation/product_suggestions.dart';

import '../../test_utils/fake_api_client.dart';
import '../projects/form_test_support.dart';

/// Teklif kalemindeki katalog önerileri: "Ürün / Hizmet Adı"na yazınca
/// (2+ karakter, 300 ms bekleme) katalogdan öneri gelir; seçilen ürün adı,
/// birimi, fiyatı ve product_id'yi doldurur, alanlar sonra düzenlenebilir.
/// Eşleşme yoksa ya da çevrimdışıysa yazılan ad serbest kalem kalır.
/// products.read olmayan kullanıcı düz alanı görür, hiç istek atılmaz.

final _picker = testUser({'offers.read', 'offers.create', 'offers.update', 'products.read'});
final _noCatalog = testUser({'offers.read', 'offers.create', 'offers.update'});

Map<String, dynamic> _product(
  String id,
  String name, {
  String unit = 'boy',
  double price = 100,
  String category = '',
  String source = '',
}) =>
    {
      'id': id,
      'name': name,
      'unit': unit,
      'unit_price': price,
      'description': '',
      'category': category,
      'source': source,
      'source_synced_at': null,
      'source_price': null,
    };

ScriptedResponse _page(List<Map<String, dynamic>> products, {int? total}) =>
    (status: 200, body: {'products': products, 'total': total ?? products.length});

final _profilPage = _page([
  _product('p1', 'Siyah Kutu Profil 40×40×2 mm', price: 512, category: 'Siyah Kutu Profil', source: 'demirprofil'),
  _product('p2', 'Galvaniz Kutu Profil 40×40×1,35 mm', price: 498.75, category: 'Galvaniz Kutu Profil', source: 'demirprofil'),
], total: 37);

Map<String, dynamic> _offer() => {
      'id': 'o9',
      'offer_no': 'TKF-009',
      'revision_no': 0,
      'customer_id': null,
      'customer_name': 'Ali Veli',
      'offer_date': '2026-10-07',
      'valid_until': null,
      'subtotal': 0,
      'vat_rate': 20,
      'vat_amount': 0,
      'grand_total': 0,
      'notes': '',
      'status': 'taslak',
      'is_passive': false,
      'items': <Object>[],
    };

Finder get _nameField => formField('Ürün / Hizmet Adı');

String _fieldText(WidgetTester tester, String label) =>
    tester.widget<TextField>(find.descendant(of: formField(label), matching: find.byType(TextField))).controller!.text;

int _productCalls(FakeHttpClientAdapter adapter) => adapter.calls.where((c) => c == '/products').length;

/// Yazıp bekleme süresini geçirir; yanıt gelene kadar çizer.
Future<void> _typeAndWait(WidgetTester tester, String text) async {
  await tester.enterText(_nameField, text);
  await tester.pump(kProductSuggestDebounce);
  await tester.pumpAndSettle();
}

Map<String, dynamic> _savedItem(FakeHttpClientAdapter adapter) =>
    ((requestBodyFor(adapter, '/offers/')['items'] as List).single as Map).cast<String, dynamic>();

void main() {
  testWidgets('"profil" yazınca öneriler gelir; hızlı yazım tek istek, 2 karakterden azı hiç istek atmaz', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {'/products': [_profilPage]});
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _picker);

    await tester.enterText(_nameField, 'p');
    await tester.pump(const Duration(milliseconds: 400));
    expect(_productCalls(adapter), 0, reason: 'tek harf aranmaz');

    for (final partial in ['pr', 'pro', 'prof', 'profi']) {
      await tester.enterText(_nameField, partial);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(_productCalls(adapter), 0, reason: 'yazma sürerken istek gitmez');
    await _typeAndWait(tester, 'profil');

    expect(_productCalls(adapter), 1);
    final query = adapter.requestQueries[adapter.calls.indexOf('/products')];
    expect(query, {'page': '1', 'limit': '6', 'q': 'profil'});

    expect(find.byKey(const ValueKey('offer-product-suggestions')), findsOneWidget);
    expect(find.byKey(const ValueKey('offer-product-suggestions-currency')), findsNothing, reason: 'TL teklif');
    expect(find.text('Siyah Kutu Profil 40×40×2 mm'), findsOneWidget);
    expect(find.text('Siyah Kutu Profil · Demir Profil'), findsOneWidget);
    expect(find.text('/ boy'), findsNWidgets(2));
    expect(find.textContaining('+35 ürün daha'), findsOneWidget);
  });

  testWidgets('öneri seçilince ad, birim, fiyat ve product_id dolar; sonra düzenlenebilir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/products': [_profilPage],
      '/offers/': [(status: 201, body: _offer())],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _picker);

    await tester.enterText(formField('Müşteri Adı'), 'Ali Veli');
    await _typeAndWait(tester, 'kutu prof');
    await tester.tap(find.byKey(const ValueKey('offer-product-suggestion-p2')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('offer-product-suggestions')), findsNothing);
    expect(_fieldText(tester, 'Ürün / Hizmet Adı'), 'Galvaniz Kutu Profil 40×40×1,35 mm');
    expect(_fieldText(tester, 'Birim'), 'boy');
    // Türkçe ondalık: 498.75 -> "498,75" (formun kendi ayrıştırıcısı okur).
    expect(_fieldText(tester, 'Birim Fiyat'), '498,75');

    // Fiyat ve birim elle değişebilir; ürün bağı korunur.
    await tester.enterText(formField('Birim'), 'adet');
    await tester.enterText(formField('Birim Fiyat'), '1.250,50');
    await tester.enterText(formField('Miktar'), '3');
    await tapButton(tester, 'Teklifi Oluştur');

    final item = _savedItem(adapter);
    expect(item['product_id'], 'p2');
    expect(item['product_name'], 'Galvaniz Kutu Profil 40×40×1,35 mm');
    expect(item['unit'], 'adet');
    expect(item['unit_price'], 1250.5);
    expect(item['quantity'], 3);
    expect(_productCalls(adapter), 1, reason: 'seçimden sonra aynı ad yeniden aranmaz');
  });

  testWidgets('seçilen fiyat olduğu gibi gider; ad değiştirilince ürün bağı düşer (web ile aynı)', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/products': [_profilPage, _page(const [])],
      '/offers/': [(status: 201, body: _offer())],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _picker);

    await tester.enterText(formField('Müşteri Adı'), 'Ali Veli');
    await _typeAndWait(tester, 'profil');
    await tester.tap(find.byKey(const ValueKey('offer-product-suggestion-p1')));
    await tester.pumpAndSettle();
    await _typeAndWait(tester, 'Siyah Kutu Profil 40×40×2 mm (kesimli)');
    await tester.enterText(formField('Miktar'), '1');
    await tapButton(tester, 'Teklifi Oluştur');

    final item = _savedItem(adapter);
    expect(item['product_id'], isNull);
    expect(item['product_name'], 'Siyah Kutu Profil 40×40×2 mm (kesimli)');
    expect(item['unit'], 'boy');
    expect(item['unit_price'], 512);
  });

  testWidgets('eşleşme yoksa not çıkar, yazılan ad serbest kalem olarak kaydedilir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/products': [_page(const [])],
      '/offers/': [(status: 201, body: _offer())],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _picker);

    await tester.enterText(formField('Müşteri Adı'), 'Ali Veli');
    await _typeAndWait(tester, 'Şantiye işçiliği');
    expect(find.byKey(const ValueKey('offer-product-suggestions-empty')), findsOneWidget);
    expect(find.textContaining('serbest kalem olarak eklenir'), findsOneWidget);

    await tester.enterText(formField('Miktar'), '2');
    await tester.enterText(formField('Birim'), 'gün');
    await tester.enterText(formField('Birim Fiyat'), '4500');
    // Başka alana geçince not kapanır.
    expect(find.byKey(const ValueKey('offer-product-suggestions-empty')), findsNothing);
    await tapButton(tester, 'Teklifi Oluştur');

    final item = _savedItem(adapter);
    expect(item['product_id'], isNull);
    expect(item['product_name'], 'Şantiye işçiliği');
    expect(item['unit'], 'gün');
    expect(item['unit_price'], 4500);
  });

  testWidgets('products.read yoksa düz alan: istek yok, öneri yok, kayıt çalışır', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {'/offers/': [(status: 201, body: _offer())]});
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _noCatalog);

    await tester.enterText(formField('Müşteri Adı'), 'Ali Veli');
    await _typeAndWait(tester, 'profil');
    await tester.pump(const Duration(seconds: 1));

    expect(adapter.calls, isNot(contains('/products')));
    expect(find.byKey(const ValueKey('offer-product-suggestions-loading')), findsNothing);
    expect(find.textContaining('Katalog'), findsNothing);

    await tester.enterText(formField('Miktar'), '1');
    await tester.enterText(formField('Birim Fiyat'), '100');
    await tapButton(tester, 'Teklifi Oluştur');
    expect(_savedItem(adapter)['product_name'], 'profil');
  });

  testWidgets('çevrimdışı: çökme yok, kısa not; yazılan ad serbest kalem kalır', (tester) async {
    final adapter = _OfflineProducts(script: {'/offers/': [(status: 201, body: _offer())]});
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _picker);

    await tester.enterText(formField('Müşteri Adı'), 'Ali Veli');
    await _typeAndWait(tester, 'kutu 40');
    expect(find.byKey(const ValueKey('offer-product-suggestions-offline')), findsOneWidget);
    expect(find.textContaining('Bağlantı yok'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.enterText(formField('Miktar'), '1');
    await tester.enterText(formField('Birim Fiyat'), '100');
    await tapButton(tester, 'Teklifi Oluştur');
    expect(_savedItem(adapter)['product_name'], 'kutu 40');
    expect(_savedItem(adapter)['product_id'], isNull);
  });

  testWidgets('sunucu hatası: kısa not, kayıt engellenmez', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/products': [(status: 500, body: {'error': 'ürünler alınamadı'})],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _picker);

    await _typeAndWait(tester, 'profil');
    expect(find.byKey(const ValueKey('offer-product-suggestions-failed')), findsOneWidget);
  });

  testWidgets('yeni yazım eski isteği iptal eder; geç gelen eski yanıt yenisini ezmez', (tester) async {
    final adapter = _HeldProducts();
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _picker);

    await tester.enterText(_nameField, 'kutu');
    await tester.pump(kProductSuggestDebounce);
    expect(adapter.pending, hasLength(1));
    expect(find.byKey(const ValueKey('offer-product-suggestions-loading')), findsOneWidget);

    await tester.enterText(_nameField, 'kutu 40');
    await tester.pump(kProductSuggestDebounce);
    expect(adapter.pending, hasLength(2));
    expect(adapter.cancelled, [true, false], reason: 'ilk istek iptal edilir');

    adapter.complete(1, _page([_product('n1', 'Siyah Kutu Profil 40×40×2 mm')]).body!);
    await tester.pumpAndSettle();
    // İptal edilen eski istek geç de olsa yanıt verirse yok sayılır.
    adapter.complete(0, _page([_product('o1', 'Eski Sonuç')]).body!);
    await tester.pumpAndSettle();

    expect(find.text('Siyah Kutu Profil 40×40×2 mm'), findsOneWidget);
    expect(find.text('Eski Sonuç'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('teklif TL değilse önerilerin üstünde kur uyarısı; TL teklifte yok', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/offers/defaults': [
        (status: 200, body: {'vat_rate': 20, 'currency': 'USD', 'validity_days': null, 'valid_until': null}),
      ],
      '/products': [_profilPage],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _picker);

    await _typeAndWait(tester, 'profil');
    expect(find.byKey(const ValueKey('offer-product-suggestions-currency')), findsOneWidget);
    expect(find.textContaining('Katalog fiyatları TL; bu teklif USD'), findsOneWidget);
  });

  testWidgets('küçük telefonda (320 pt) uzun adlı öneri taşmaz', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/products': [
        _page([
          _product(
            'p9',
            'Paslanmaz Boru Ø38×2 mm AISI 304 Parlak Yüzey 6 m Boy Kaynaklı Endüstriyel Tip Uzun Ürün Adı',
            unit: 'boy',
            price: 1234567.89,
            category: 'Paslanmaz Boru ve Profil Ürünleri Uzun Kategori Adı',
            source: 'demirprofil',
          ),
        ]),
      ],
    });
    await pumpRoutedForm(tester, adapter, form: const OfferCreateScreen(), user: _picker);
    await tester.binding.setSurfaceSize(const Size(320, 1600));
    await tester.pumpAndSettle();

    await _typeAndWait(tester, 'paslanmaz boru 38');
    expect(find.byKey(const ValueKey('offer-product-suggestion-p9')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// '/products' isteğinde ağ yokmuş gibi davranır (DNS/soket hatası).
class _OfflineProducts extends FakeHttpClientAdapter {
  _OfflineProducts({required super.script});

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) {
    if (options.path == '/products') throw const SocketException('Failed host lookup');
    return super.fetch(options, requestStream, cancelFuture);
  }
}

/// '/products' yanıtlarını test elle verene kadar bekletir; iptalleri kaydeder.
class _HeldProducts extends FakeHttpClientAdapter {
  _HeldProducts() : super(script: {});

  final pending = <Completer<ResponseBody>>[];
  final cancelled = <bool>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? requestStream, Future<void>? cancelFuture) {
    if (options.path != '/products') return super.fetch(options, requestStream, cancelFuture);
    final c = Completer<ResponseBody>();
    final i = pending.length;
    pending.add(c);
    cancelled.add(false);
    cancelFuture?.then((_) => cancelled[i] = true);
    return c.future;
  }

  void complete(int i, Object body) {
    if (pending[i].isCompleted) return;
    pending[i].complete(ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    }));
  }
}
