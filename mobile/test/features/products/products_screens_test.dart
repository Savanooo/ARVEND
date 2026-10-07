import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/products/domain/price_source.dart';
import 'package:arvend/features/products/presentation/price_source_settings_sheet.dart';
import 'package:arvend/features/products/presentation/widgets/products_common.dart';
import 'package:arvend/features/products/products_routes.dart';

import 'products_fakes.dart';

/// Ürünler / Fiyat Kaynakları / Zam Geçmişi ekran davranışları: sahte depo
/// (ağ yok) + gerçek `productsRoutes` (`/diger` altına bağlı).
Future<FakeProductsRepository> _pump(
  WidgetTester tester,
  String location, {
  User? user,
  FakeProductsRepository? repo,
  Size size = const Size(420, 2600),
}) async {
  final r = repo ?? FakeProductsRepository();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(productsHarness(user: user ?? ownerUser, repo: r, location: location));
  await tester.pumpAndSettle();
  return r;
}

/// SnackBar zamanlayıcısı test sonunda askıda kalmasın.
Future<void> _drainSnackBars(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  group('menü ve rotalar', () {
    test('menü öğeleri products.read ister, rotalar /diger altındadır', () {
      // Menüde yalnızca Ürünler (web menüsüyle aynı); Zam Geçmişi ve Fiyat
      // Kaynakları Ürünler ekranından açılan kısayollar.
      expect(productsMenuEntries.map((e) => e.route), ['/diger/urunler']);
      expect(productsShortcutEntries.map((e) => e.route), ['/diger/urunler/zamlar', '/diger/urunler/kaynaklar']);
      expect(
        [...productsMenuEntries, ...productsShortcutEntries].every((e) => e.permission == 'products.read'),
        isTrue,
      );
      expect(ProductsPaths.edit('a b'), '/diger/urunler/a%20b/duzenle');
    });
  });

  group('Ürünler listesi', () {
    testWidgets('sahip: kaynak rozetleri, "listede yok", tedarikçi fiyatı, Yeni Ürün', (tester) async {
      await _pump(tester, ProductsPaths.list);
      expect(find.text('Kutu Profil 40x40x2 mm'), findsOneWidget);
      expect(find.text('Toplam 4 ürün'), findsOneWidget);
      expect(find.text('Ulaş listesinde yok'), findsOneWidget);
      expect(find.text('Demir Profil'), findsNWidgets(2));
      expect(find.text('Tedarikçi'), findsNWidgets(3)); // p3 elle eklendi: tedarikçi fiyatı yok
      expect(find.byTooltip('Yeni Ürün'), findsOneWidget);
      expect(find.text('Fiyat Kaynakları'), findsOneWidget);
      expect(find.textContaining('Hiç çekilmedi'), findsNothing);
    });

    testWidgets('salt-okunur: backend yanlışlıkla döndürse de tedarikçi fiyatı yok, ekleme yok', (tester) async {
      await _pump(tester, ProductsPaths.list, user: readOnlyUser, repo: FakeProductsRepository(manage: true));
      expect(find.text('Kutu Profil 40x40x2 mm'), findsOneWidget);
      expect(find.text('Tedarikçi'), findsNothing);
      expect(find.byTooltip('Yeni Ürün'), findsNothing);
      expect(find.byTooltip('Zam Geçmişi'), findsOneWidget);
    });

    testWidgets('izinsiz: açıklama gösterilir, hiç istek atılmaz', (tester) async {
      final repo = await _pump(tester, ProductsPaths.list, user: noAccessUser);
      expect(find.text(kProductsReadDenied), findsOneWidget);
      expect(repo.totalCalls, 0);
      expect(find.byTooltip('Zam Geçmişi'), findsNothing);
    });

    testWidgets('403: çökmez, izin açıklaması gösterilir', (tester) async {
      await _pump(tester, ProductsPaths.list, repo: FakeProductsRepository(listError: forbidden));
      expect(find.text(kProductsReadDenied), findsOneWidget);
    });

    testWidgets('arama: gecikmeli istek, sonuç sayısı', (tester) async {
      final repo = await _pump(tester, ProductsPaths.list);
      await tester.enterText(find.byType(TextField).first, 'kutu');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(repo.listCalls.last.q, 'kutu');
      expect(find.text('“kutu” için 1 ürün'), findsOneWidget);
      expect(find.text('Saten İç Cephe Boyası 2,5 Lt Beyaz'), findsNothing);
    });

    testWidgets('sayfalama: 200 sınırının altında sayfalar, sona inince sonraki sayfa', (tester) async {
      final catalog = [for (var i = 0; i < 150; i++) productJson(id: 'x$i', name: 'Ürün ${i.toString().padLeft(3, '0')}')];
      final repo = await _pump(
        tester,
        ProductsPaths.list,
        repo: FakeProductsRepository(catalog: catalog),
        size: const Size(420, 900),
      );
      expect(repo.listCalls.single.limit, lessThanOrEqualTo(200));
      expect(find.text('Toplam 150 ürün'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Ürün 099'), 600, scrollable: find.byType(Scrollable).last);
      await tester.pumpAndSettle();
      expect(repo.listCalls.map((c) => c.page), containsAllInOrder([1, 2]));
      await tester.scrollUntilVisible(find.text('Ürün 149'), 600, scrollable: find.byType(Scrollable).last);
      expect(find.text('Ürün 149'), findsOneWidget);
      expect(find.textContaining('Daha fazla göster'), findsNothing);
    });

    testWidgets('satıra dokununca detay açılır', (tester) async {
      await _pump(tester, ProductsPaths.list);
      await tester.tap(find.text('Alçı Levha 12,5 mm'));
      await tester.pumpAndSettle();
      expect(find.text('Elle eklendi'), findsOneWidget);
      expect(find.textContaining('Elle eklenen ürün: tedarikçi güncellemeleri'), findsOneWidget);
    });
  });

  group('Ürün detayı', () {
    testWidgets('Demir Profil ürünü: kaynak gösterimi, fiyat geçmişi, tedarikçi fiyatı', (tester) async {
      await _pump(tester, ProductsPaths.detail('p1'));
      expect(find.text('Kaynak: demirprofil.com.tr — Eylül 2026 listesi'), findsOneWidget);
      expect(find.text('demirprofil.com.tr'), findsOneWidget);
      expect(find.text('Demir Profil fiyatı'), findsOneWidget);
      expect(find.text('100,00 TL'), findsOneWidget);
      expect(find.text('Tedarikçi zammı'), findsOneWidget);
      expect(find.text('Kâr oranı'), findsOneWidget);
      expect(find.text('Elle'), findsOneWidget);
      expect(find.text('↑ %4,55'), findsOneWidget);
      expect(find.text('↓ %2,78'), findsOneWidget);
      expect(find.text('Tedarikçi fiyatı: 97,78 TL → 100,00 TL'), findsOneWidget);
      expect(find.byTooltip('Düzenle'), findsOneWidget);
      // Uzun açıklama katlı: önce kısa sonuç ve rakamlar, ayrıntı istenince.
      expect(find.text('Fiyat ve kategori her Demir Profil güncellemesinde listeden yeniden yazılır.'), findsOneWidget);
      expect(find.text('Listede son görülme'), findsOneWidget);
      expect(find.textContaining('Fiyat Kaynakları ekranındaki kâr oranı ayarlarını kullan'), findsNothing);
      await tester.ensureVisible(find.text('Nasıl çalışır?'));
      await tester.tap(find.text('Nasıl çalışır?'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Fiyat Kaynakları ekranındaki kâr oranı ayarlarını kullan'), findsOneWidget);
      expect(find.textContaining('adı ve birimi üzerinden eşleşir'), findsOneWidget);
    });

    testWidgets('salt-okunur: düzenleme yok, maliyet (tedarikçi) fiyatı hiç görünmez', (tester) async {
      await _pump(tester, ProductsPaths.detail('p1'), user: readOnlyUser, repo: FakeProductsRepository(manage: true));
      expect(find.byTooltip('Düzenle'), findsNothing);
      expect(find.textContaining('yalnızca görüntüleyebilirsin'), findsOneWidget);
      expect(find.text('Demir Profil fiyatı'), findsNothing);
      expect(find.textContaining('Tedarikçi fiyatı:'), findsNothing);
      expect(find.text('Kaynak: demirprofil.com.tr — Eylül 2026 listesi'), findsOneWidget);
    });

    testWidgets('fiyat kaynağı alınamazsa: Demir Profil yine kaynaksız kalmaz', (tester) async {
      await _pump(tester, ProductsPaths.detail('p1'), repo: FakeProductsRepository(sourcesError: forbidden));
      expect(find.text(kDemirProfilFallbackAttribution), findsOneWidget);
      expect(find.text('Kutu Profil 40x40x2 mm'), findsWidgets);
    });

    testWidgets('bulunamayan ürün: hata ve tekrar dene', (tester) async {
      await _pump(tester, ProductsPaths.detail('yok'));
      expect(find.text('ürün bulunamadı'), findsOneWidget);
      expect(find.text('Tekrar Dene'), findsOneWidget);
    });
  });

  group('Ürün formu', () {
    testWidgets('yeni ürün: doğrulama + Türkçe ondalık fiyat', (tester) async {
      final repo = await _pump(tester, ProductsPaths.create);
      await tester.tap(find.text('Ürün Oluştur'));
      await tester.pumpAndSettle();
      expect(find.text('Ürün adı zorunludur'), findsOneWidget);
      expect(find.text('Birim fiyat gir.'), findsOneWidget);
      expect(repo.created, isEmpty);

      await tester.enterText(find.widgetWithText(TextFormField, 'Ürün Adı *'), 'Çimento 50 kg');
      await tester.enterText(find.widgetWithText(TextFormField, 'Birim Fiyat (TL) *'), '12,345');
      await tester.tap(find.text('Ürün Oluştur'));
      await tester.pumpAndSettle();
      expect(find.text('En fazla iki ondalık basamak girilebilir.'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextFormField, 'Birim Fiyat (TL) *'), '1.250,50');
      await tester.enterText(find.widgetWithText(TextFormField, 'Kategori'), 'Yapı');
      await tester.tap(find.text('Ürün Oluştur'));
      await tester.pumpAndSettle();
      final input = repo.created.single;
      expect((input.name, input.unit, input.unitPrice, input.category), ('Çimento 50 kg', 'adet', 1250.5, 'Yapı'));
      // Listeye döner.
      expect(find.text('Toplam 4 ürün'), findsOneWidget);
      expect(find.text('Ürün eklendi.'), findsOneWidget);
      await _drainSnackBars(tester);
    });

    // Fiyat da kilitli: her senkron (gece dahil) kaynak fiyat + kâr
    // oranından yeniden yazar, elle girilen fiyat uyarısız geri alınırdı.
    testWidgets('kaynağa bağlı ürün: ad/birim/fiyat kilitli, uyarılar, özgün değerler gönderilir', (tester) async {
      final repo = await _pump(tester, ProductsPaths.edit('p1'));
      final name = tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Ürün Adı *'));
      expect(name.enabled, isFalse);
      final price = tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Birim Fiyat (TL) *'));
      expect(price.enabled, isFalse);
      expect(find.textContaining('Bu ürün Demir Profil listesinden geliyor'), findsOneWidget);
      expect(find.textContaining('Ad ve birim Demir Profil listesinden gelir'), findsOneWidget);
      expect(find.byKey(const ValueKey('product-price-locked-hint')), findsOneWidget);
      expect(find.textContaining('Demir Profil kâr oranını (genel ya da kategori bazında) ayarla'), findsOneWidget);
      expect(find.text('Kâr oranını ayarla'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextFormField, 'Kategori'), 'Profil');
      await tester.ensureVisible(find.text('Kaydet'));
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      final call = repo.updated.single;
      expect((call.id, call.input.name, call.input.unit, call.input.unitPrice, call.input.category),
          ('p1', 'Kutu Profil 40x40x2 mm', 'm', 115.0, 'Profil'));
      await _drainSnackBars(tester);
    });

    testWidgets('listede olmayan kaynak ürünü: ad/birim/fiyat düzenlenebilir', (tester) async {
      final repo = await _pump(tester, ProductsPaths.edit('p2'));
      final name = tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Ürün Adı *'));
      expect(name.enabled, isTrue);
      expect(find.textContaining('Bu ürün son Ulaş listesinde yok'), findsOneWidget);
      expect(find.byKey(const ValueKey('product-price-locked-hint')), findsNothing);
      await tester.enterText(find.widgetWithText(TextFormField, 'Birim Fiyat (TL) *'), '600');
      await tester.ensureVisible(find.text('Kaydet'));
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.updated.single.input.unitPrice, 600);
      await _drainSnackBars(tester);
    });

    testWidgets('salt-okunur: form yok, açıklama var', (tester) async {
      final repo = await _pump(tester, ProductsPaths.edit('p1'), user: readOnlyUser);
      expect(find.textContaining('yalnızca görüntüleyebilirsin'), findsOneWidget);
      expect(find.text('Kaydet'), findsNothing);
      expect(find.byType(TextFormField), findsNothing);
      expect(repo.updated, isEmpty);
    });

    testWidgets('kayıt 403: yetki açıklaması', (tester) async {
      final repo = _ForbiddenWriteRepo();
      await _pump(tester, ProductsPaths.edit('p3'), repo: repo);
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text(kProductsManageDenied), findsOneWidget);
    });
  });

  group('Fiyat Kaynakları', () {
    testWidgets('sahip: kartlar, durum, oranlar, başarısız deneme', (tester) async {
      await _pump(tester, ProductsPaths.sources);
      expect(find.text('Fiyat Kaynağı: Ulaş'), findsOneWidget);
      expect(find.text('Fiyat Kaynağı: Demir Profil (Omega Çelik)'), findsOneWidget);
      expect(find.text('Başarılı'), findsOneWidget);
      expect(find.text('Başarısız'), findsOneWidget);
      expect(find.text('%15 · 1 kategoride özel oran'), findsOneWidget);
      expect(find.text('%12,5'), findsOneWidget);
      expect(find.text('628 (1 tanesi son listede yok)'), findsOneWidget);
      expect(find.text('Kaynak: demirprofil.com.tr — Eylül 2026 listesi'), findsOneWidget);
      expect(
        find.text(
          'Son deneme başarısız: Demir Profil sayfası indirilemedi (HTTP 503). Ürünlerde değişiklik yapılmadı; '
          'aşağıdaki sayılar son başarılı güncellemeye aittir.',
        ),
        findsOneWidget,
      );
      expect(find.text("Ulaş'tan Güncelle"), findsOneWidget);
      expect(find.text("Demir Profil'den Güncelle"), findsOneWidget);
      expect(find.text('Son güncellemede 12 ürüne zam geldi (ort. %2,91); 2 ürünün fiyatı düştü.'), findsOneWidget);
    });

    testWidgets('salt-okunur: yalnızca durum; oran ve düğme yok', (tester) async {
      await _pump(tester, ProductsPaths.sources, user: readOnlyUser, repo: FakeProductsRepository(manage: true));
      expect(find.text('Fiyat Kaynağı: Ulaş'), findsOneWidget);
      expect(find.text("Ulaş'tan Güncelle"), findsNothing);
      expect(find.text('Kâr oranı ayarları'), findsNothing);
      expect(find.text('Kâr oranı'), findsNothing);
      expect(find.text(kPriceSourcesReadOnly), findsOneWidget);
    });

    Future<void> tapSyncAndConfirm(WidgetTester tester) async {
      await tester.tap(find.text("Ulaş'tan Güncelle"));
      await tester.pumpAndSettle();
      expect(find.text("Ulaş'tan güncellensin mi?"), findsOneWidget);
      await tester.tap(find.text('Güncelle'));
      await tester.pumpAndSettle();
    }

    testWidgets('Güncelle: onay + başarı sayıları', (tester) async {
      final repo = await _pump(tester, ProductsPaths.sources);
      await tapSyncAndConfirm(tester);
      expect(repo.syncCalls, ['ulas']);
      expect(
        find.text('Ulaş listesi güncellendi: toplam 630 · 2 yeni · 14 güncellenen · 614 değişmeyen · 1 listede artık yok.'),
        findsOneWidget,
      );
    });

    testWidgets('Güncelle: vazgeçilirse istek yok', (tester) async {
      final repo = await _pump(tester, ProductsPaths.sources);
      await tester.tap(find.text("Ulaş'tan Güncelle"));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(repo.syncCalls, isEmpty);
    });

    for (final (status, message, expected) in [
      (409, 'başka bir senkron çalışıyor', 'Güncelleme zaten sürüyor. Biraz sonra tekrar dene.'),
      (502, kPriceListTooShortError, 'Ulaş listesi beklenenden çok kısa geldi'),
      (502, 'tedarikçi fiyat listesi alınamadı; lütfen daha sonra tekrar deneyin', "Ulaş'a ulaşılamadı; fiyat listesi alınamadı."),
    ]) {
      testWidgets('Güncelle hatası $status: $expected', (tester) async {
        final repo = FakeProductsRepository(syncError: mapHttpError(status, message));
        await _pump(tester, ProductsPaths.sources, repo: repo);
        final before = repo.sourcesCalls;
        await tapSyncAndConfirm(tester);
        expect(find.textContaining(expected), findsOneWidget);
        // 409 dışındaki hatalarda kartın durumu sunucudan tazelenir.
        expect(repo.sourcesCalls > before, status != 409);
      });
    }

    testWidgets('kâr oranı ayarları: örnek hesap, virgül, satır hatası, tam gövde', (tester) async {
      final repo = await _pump(tester, ProductsPaths.sources);
      await tester.tap(find.text('Kâr oranı ayarları').first);
      await tester.pumpAndSettle();
      expect(find.text('Ulaş kâr oranı ayarları'), findsOneWidget);
      expect(find.text('500,00 TL Ulaş fiyatı → 575,00 TL satış'), findsOneWidget);

      final fields = find.descendant(of: find.byType(PriceSourceSettingsSheet), matching: find.byType(TextField));
      expect(fields, findsNWidgets(4)); // varsayılan + Boya, Hırdavat, Yapı Kimyasalları
      await tester.enterText(fields.at(0), '12,5');
      await tester.pump();
      expect(find.text('500,00 TL Ulaş fiyatı → 562,50 TL satış'), findsOneWidget);
      expect(find.text('Varsayılan (%12,5)'), findsWidgets); // boş satırların ipucu

      await tester.enterText(fields.at(2), '1.000');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Lütfen işaretli alanları düzelt.'), findsOneWidget);
      expect(find.textContaining('binlik ayırıcı kullanma'), findsOneWidget);
      expect(repo.settingsCalls, isEmpty);

      await tester.enterText(fields.at(2), '8');
      await tester.tap(find.byType(SwitchListTile));
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.settingsCalls.single.source, 'ulas');
      expect(repo.settingsCalls.single.body, {
        'markup_percent': 12.5,
        'auto_sync': true,
        'category_markups': [
          {'category': 'Boya', 'markup_percent': 20.0},
          {'category': 'Hırdavat', 'markup_percent': 8.0},
        ],
      });
      expect(find.byType(PriceSourceSettingsSheet), findsNothing);
      expect(find.text('Ayarlar kaydedildi · 5 ürünün fiyatı yeniden hesaplandı.'), findsOneWidget);
    });

    testWidgets('kartın Zam Geçmişi bağlantısı son senkronun satırlarını açar', (tester) async {
      final repo = await _pump(tester, ProductsPaths.sources);
      await tester.tap(find.text('Zam Geçmişi').first);
      await tester.pumpAndSettle();
      final q = repo.priceChangeCalls.last.query;
      expect((q.from, q.to, q.source, q.direction), (
        '2026-09-27T00:05:12+03:00',
        '2026-09-27T00:05:12.999999+03:00',
        'ulas',
        'all',
      ));
      expect(find.textContaining('Yalnızca bu güncellemenin değişiklikleri: 27 Eylül 2026 00:05 · Ulaş'), findsOneWidget);
    });
  });

  group('Zam Geçmişi', () {
    testWidgets('varsayılan: son 30 gün, tedarikçi, zam; özet kartları', (tester) async {
      final repo = await _pump(tester, ProductsPaths.priceChanges);
      expect(repo.summaryCalls.single, (from: '2026-08-30', to: '2026-09-28', reason: 'supplier', source: ''));
      final q = repo.priceChangeCalls.single.query;
      expect((q.direction, q.sort, q.reason), ('up', 'newest', 'supplier'));
      // Dönem kendi satırında; tarihlerin parçaları bölünmez boşlukla bağlı.
      expect(find.text('Son 30 gün: 30\u00a0Ağustos\u00a02026 – 28\u00a0Eylül\u00a02026'), findsOneWidget);
      expect(find.text('Tüm kaynaklar · Tedarikçi fiyatı değişiklikleri'), findsOneWidget);
      expect(find.text('57'), findsOneWidget);
      expect(find.text('58 zam kaydı'), findsOneWidget);
      expect(find.text('%2,12'), findsOneWidget);
      expect(find.text('%8,7'), findsOneWidget);
      expect(find.text('Zam Gelen Ürünler'), findsOneWidget);
      expect(find.text('2 kayıt'), findsOneWidget);
      expect(find.text('529,00 TL → 575,00 TL'), findsOneWidget);
      expect(find.text('+46,00 TL'), findsOneWidget);
      expect(find.text('↑ %8,7'), findsOneWidget);
      expect(find.text('Tedarikçi fiyatı: 460,00 TL → 500,00 TL'), findsOneWidget);
      expect(find.text('Kaynak: demirprofil.com.tr — Eylül 2026 listesi'), findsOneWidget);
    });

    testWidgets('salt-okunur: tedarikçi fiyatları görünmez', (tester) async {
      await _pump(tester, ProductsPaths.priceChanges, user: readOnlyUser, repo: FakeProductsRepository(manage: true));
      expect(find.text('529,00 TL → 575,00 TL'), findsOneWidget);
      expect(find.textContaining('Tedarikçi fiyatı:'), findsNothing);
    });

    testWidgets('olaya dokununca liste o olayın aralığına daralır; geri alınır', (tester) async {
      final repo = await _pump(tester, ProductsPaths.priceChanges);
      await tester.tap(find.text('21 Eylül 2026 00:05'));
      await tester.pumpAndSettle();
      final q = repo.priceChangeCalls.last.query;
      expect((q.from, q.to, q.source, q.reason, q.direction), (
        kDemirEventAt,
        kDemirEventAt,
        'demirprofil',
        'supplier',
        'all',
      ));
      expect(find.text('Fiyatı Değişen Ürünler'), findsOneWidget);
      expect(find.textContaining('21 Eylül 2026 00:05 · Demir Profil · Tedarikçi fiyat listesi'), findsOneWidget);
      expect(find.text('↓ %2,14'), findsOneWidget);
      expect(find.text('−14,80 TL'), findsOneWidget);

      await tester.tap(find.text('Tüm dönemi göster'));
      await tester.pumpAndSettle();
      final back = repo.priceChangeCalls.last.query;
      expect((back.from, back.direction), ('2026-08-30', 'up'));
      expect(find.text('Zam Gelen Ürünler'), findsOneWidget);
    });

    testWidgets('dönem çipi özeti ve listeyi yeniden sorgular', (tester) async {
      final repo = await _pump(tester, ProductsPaths.priceChanges);
      await tester.tap(find.text('Son 7 gün'));
      await tester.pumpAndSettle();
      expect(repo.summaryCalls.last.from, '2026-09-22');
      expect(repo.priceChangeCalls.last.query.from, '2026-09-22');
    });

    testWidgets('filtre sayfası: yön İndirim', (tester) async {
      final repo = await _pump(tester, ProductsPaths.priceChanges);
      await tester.tap(find.text('Filtrele'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zam').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('İndirim').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Uygula'));
      await tester.pumpAndSettle();
      expect(repo.priceChangeCalls.last.query.direction, 'down');
      expect(find.text('İndirim Gelen Ürünler'), findsOneWidget);
      expect(find.text('Filtrele (1)'), findsOneWidget);
      // Yön yalnızca listeye uygulanır: özet yeniden sorgulanmaz.
      expect(repo.summaryCalls, hasLength(1));
    });

    testWidgets('en yüksek zam kartı ürüne gider', (tester) async {
      await _pump(tester, ProductsPaths.priceChanges);
      await tester.tap(find.text('Saten İç Cephe Boyası 2,5 Lt Beyaz').first);
      await tester.pumpAndSettle();
      expect(find.text('Ulaş listesinde yok'), findsOneWidget);
    });

    testWidgets('izinsiz: istek yok', (tester) async {
      final repo = await _pump(tester, ProductsPaths.priceChanges, user: noAccessUser);
      expect(find.text(kProductsReadDenied), findsOneWidget);
      expect(repo.totalCalls, 0);
    });
  });
}

/// Yazma uçları 403 döndüren depo (izin oturum sırasında geri alındı).
class _ForbiddenWriteRepo extends FakeProductsRepository {
  _ForbiddenWriteRepo();

  @override
  Future<Never> update(String id, input) async => throw forbidden;
}
