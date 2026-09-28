import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/features/products/domain/price_change.dart';
import 'package:arvend/features/products/domain/price_format.dart';
import 'package:arvend/features/products/domain/price_source.dart';
import 'package:arvend/features/products/domain/product.dart';

import 'products_fakes.dart';

/// Saf yardımcılar -- web `lib/price-sources.test.mts` ve
/// `lib/price-changes.test.mts` ile aynı beklentiler.
void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  group('parsing', () {
    test('Product.fromJson: source_price null ise null kalır', () {
      final p = Product.fromJson(productJson(id: 'x', name: 'A', sourcePrice: null));
      expect(p.sourcePrice, isNull);
      expect(p.isManual, isTrue);
    });

    test('PriceSource.fromJson: yetkisiz yanıtta oranlar null', () {
      final ps = PriceSource.fromJson({...ulasSourceJson(), 'markup_percent': null, 'category_markups': null});
      expect(ps.markupPercent, isNull);
      expect(ps.categoryMarkups, isNull);
      expect(ps.lastResult.total, 628);
      expect(ps.lastChanges!.avgIncreasePercent, 2.91);
    });

    test('PriceChangeSummary.fromJson: elle olayın kaynağı null', () {
      final s = PriceChangeSummary.fromJson(summaryJson());
      expect(s.events, hasLength(3));
      expect(s.events.last.source, isNull);
      expect(s.maxIncrease!.productId, 'p2');
    });
  });

  group('kâr oranı', () {
    test('parseMarkupInput kabul/ret', () {
      expect(parseMarkupInput('15').value, 15);
      expect(parseMarkupInput('12,5').value, 12.5);
      expect(parseMarkupInput('12.5').value, 12.5);
      expect(parseMarkupInput('%15').value, 15);
      expect(parseMarkupInput('0').value, 0);
      expect(parseMarkupInput('1000').value, 1000);
      expect(parseMarkupInput('').error, 'Kâr oranı gir.');
      expect(parseMarkupInput('-1').error, contains('0 ile 1000'));
      expect(parseMarkupInput('1000,01').error, contains('0 ile 1000'));
      expect(parseMarkupInput('abc').error, contains('Geçerli bir sayı'));
      // Binlik ayırıcı: "1.000" üç ondalıklı sayılır ve reddedilir.
      expect(parseMarkupInput('1.000').error, contains('iki ondalık'));
    });

    test('formatMarkupInput Türkçe virgül, binlik ayırıcısız', () {
      expect(formatMarkupInput(15), '15');
      expect(formatMarkupInput(12.5), '12,5');
      expect(formatMarkupInput(12.25), '12,25');
      expect(formatMarkupInput(1000), '1000');
    });

    test('applyMarkup backend ile aynı (kuruş, yarım yukarı)', () {
      expect(applyMarkup(500, 15), 575);
      expect(applyMarkup(99.99, 12.5), 112.49);
      expect(applyMarkup(100, 0), 100);
    });

    test('categoryMarkupRows: Türkçe sıra + ürünü kalmamış kayıtlı oran', () {
      final ps = PriceSource.fromJson({
        ...ulasSourceJson(),
        'category_markups': [
          {'category': 'Boya', 'markup_percent': 20},
          {'category': 'Çimento', 'markup_percent': 7.5},
        ],
      });
      final rows = categoryMarkupRows(ps);
      expect(rows.map((r) => r.category), ['Boya', 'Çimento', 'Hırdavat', 'Yapı Kimyasalları']);
      expect(rows.first.markup, '20');
      expect(rows[1].productCount, 0);
      expect(rows[1].markup, '7,5');
      expect(rows[2].markup, '');
    });

    test('buildSettingsBody: tam durum, boş kategoriler varsayılan', () {
      final ok = buildSettingsBody(
        markup: '12,5',
        autoSync: true,
        rows: const [
          CategoryMarkupRow(category: 'Boya', productCount: 1, markup: '20'),
          CategoryMarkupRow(category: 'Hırdavat', productCount: 1, markup: ''),
        ],
      );
      expect(ok.ok, isTrue);
      expect(ok.body!.toJson(), {
        'markup_percent': 12.5,
        'auto_sync': true,
        'category_markups': [
          {'category': 'Boya', 'markup_percent': 20.0},
        ],
      });

      final bad = buildSettingsBody(
        markup: '',
        autoSync: false,
        rows: const [CategoryMarkupRow(category: 'Boya', productCount: 1, markup: '1.000')],
      );
      expect(bad.ok, isFalse);
      expect(bad.markupError, 'Kâr oranı gir.');
      expect(bad.rowErrors['Boya'], contains('iki ondalık'));
    });

    test('compareTr Türkçe alfabe', () {
      final list = ['Demir', 'Çelik', 'Cam', 'İzolasyon', 'Işık', 'Ölçü', 'Oluk']..sort(compareTr);
      expect(list, ['Cam', 'Çelik', 'Demir', 'Işık', 'İzolasyon', 'Oluk', 'Ölçü']);
    });
  });

  group('kaynak', () {
    final ulas = PriceSource.fromJson(ulasSourceJson());
    final demir = PriceSource.fromJson(demirSourceJson());
    final products = [for (final j in catalogJson()) Product.fromJson(j)];

    test('sourceLabels ek uyumu + bilinmeyen kaynak', () {
      expect(sourceLabels(kUlasSource).ablative, "Ulaş'tan");
      expect(sourceLabels(kDemirProfilSource).dative, "Demir Profil'e");
      expect(sourceLabels('abs', 'ABS Alçı').ablative, 'ABS Alçı kaynağından');
    });

    test('isMissingFromSource / sourceLinkOf', () {
      expect(isMissingFromSource(products[1], ulas), isTrue); // p2, eski görülme
      expect(isMissingFromSource(products[0], demir), isFalse); // p1, son listede
      expect(isMissingFromSource(products[1], null), isFalse); // kaynak bilinmiyor
      expect(sourceLinkOf(products[1], ulas), ProductSourceLink.missing);
      expect(sourceLinkOf(products[0], demir), ProductSourceLink.linked);
      expect(sourceLinkOf(products[0], null), ProductSourceLink.linked); // güvenli taraf
      expect(sourceLinkOf(products[2], null), ProductSourceLink.none);
    });

    test('sourceAttribution: Demir Profil kaynak bilgisi alınamasa da yazılır', () {
      expect(sourceAttribution(kDemirProfilSource, demir), 'Kaynak: demirprofil.com.tr — Eylül 2026 listesi');
      expect(sourceAttribution(kDemirProfilSource, null), kDemirProfilFallbackAttribution);
      expect(sourceAttribution(kUlasSource, ulas), '');
      expect(attributionsFor([kUlasSource, kDemirProfilSource, kDemirProfilSource, null], [ulas, demir]), [
        'Kaynak: demirprofil.com.tr — Eylül 2026 listesi',
      ]);
    });

    test('senkron hata metinleri', () {
      final labels = sourceLabels(kUlasSource);
      expect(priceSyncErrorMessage(409, 'x', labels), 'Güncelleme zaten sürüyor. Biraz sonra tekrar dene.');
      expect(priceSyncErrorMessage(502, kPriceListTooShortError, labels), startsWith('Ulaş listesi beklenenden çok kısa'));
      expect(priceSyncErrorMessage(502, 'başka', labels), startsWith("Ulaş'a ulaşılamadı"));
      expect(priceSyncErrorMessage(500, 'sunucu', labels), 'sunucu');
      expect(syncErrorUpdatesStatus(409), isFalse);
      expect(syncErrorUpdatesStatus(null), isFalse);
      expect(syncErrorUpdatesStatus(502), isTrue);
    });

    test('lastChangesMessage / settingsSavedMessage', () {
      expect(lastChangesMessage(ulas.lastChanges), 'Son güncellemede 12 ürüne zam geldi (ort. %2,91); 2 ürünün fiyatı düştü.');
      expect(lastChangesMessage(const PriceSyncChanges(increased: 0, decreased: 0)), 'Son güncellemede fiyatı değişen ürün olmadı.');
      expect(lastChangesMessage(null), isNull);
      expect(settingsSavedMessage(5, kUlasSyncedAt, 'Ulaş'), 'Ayarlar kaydedildi · 5 ürünün fiyatı yeniden hesaplandı.');
      expect(settingsSavedMessage(0, null, 'Ulaş'), contains('ilk Ulaş güncellemesinde'));
    });
  });

  group('fiyat girişi', () {
    test('parsePriceInput', () {
      expect(parsePriceInput('1250').value, 1250);
      expect(parsePriceInput('1250,5').value, 1250.5);
      expect(parsePriceInput('1.250,50').value, 1250.5);
      expect(parsePriceInput('1250.50').value, 1250.5);
      expect(parsePriceInput('').error, 'Birim fiyat gir.');
      expect(parsePriceInput('-5').error, isNotNull);
      expect(parsePriceInput('12,345').error, contains('iki ondalık'));
      expect(parsePriceInput('1.234').error, contains('iki ondalık'));
    });

    test('formatPriceInput', () {
      expect(formatPriceInput(575), '575');
      expect(formatPriceInput(185.5), '185,50');
      expect(formatPriceInput(0.05), '0,05');
    });
  });

  group('zam geçmişi', () {
    const today = '2026-09-28';

    test('istanbulDay: UTC gece yarısından önce İstanbul ertesi gün', () {
      expect(istanbulDay(DateTime.utc(2026, 9, 26, 21, 30)), '2026-09-27');
      expect(istanbulDay(kTestNow), today);
    });

    test('resolvePeriod presetleri ve özel aralık hataları', () {
      final d30 = resolvePeriod(const ZamlarParams(), today);
      expect((d30.from, d30.to, d30.label), ('2026-08-30', today, 'Son 30 gün'));
      expect(resolvePeriod(const ZamlarParams(period: '7'), today).from, '2026-09-22');
      expect(resolvePeriod(const ZamlarParams(period: 'yil'), today).from, '2026-01-01');
      final custom = resolvePeriod(const ZamlarParams(period: 'ozel', from: '2026-09-01'), today);
      expect((custom.from, custom.to, custom.error), ('2026-09-01', today, null));
      expect(resolvePeriod(const ZamlarParams(period: 'ozel'), today).error, contains('başlangıç tarihi seç'));
      expect(resolvePeriod(const ZamlarParams(period: 'ozel', from: '2026-02-30'), today).error, contains('geçersiz'));
      expect(
        resolvePeriod(const ZamlarParams(period: 'ozel', from: '2026-09-20', to: '2026-09-10'), today).error,
        contains('sonra olamaz'),
      );
    });

    test('ZamlarParams sorgu gidiş-dönüş; bozuk değerler varsayılana', () {
      const p = ZamlarParams(
        period: 'ozel',
        from: '2026-09-01',
        to: '2026-09-20',
        source: 'ulas',
        reason: 'all',
        direction: 'down',
        category: 'Boya',
        q: 'saten',
        sort: 'largest_decrease',
        event: EventScope(from: kUlasEventAt, to: kUlasEventAt, reason: 'supplier', source: 'ulas'),
      );
      expect(ZamlarParams.fromQuery(p.toQuery()), p);
      expect(const ZamlarParams().toQuery(), isEmpty);
      final bad = ZamlarParams.fromQuery({'period': 'x', 'reason': 'y', 'source': 'KÖTÜ', 'event_from': 'dün'});
      expect(bad, const ZamlarParams());
    });

    test('liste/özet sorguları; olay seçiliyse olayın kapsamı', () {
      const p = ZamlarParams(source: 'ulas');
      final range = resolvePeriod(p, today);
      final q = listQueryOf(p, range);
      expect(priceChangesQueryParams(q, page: 2, limit: 50), {
        'from': '2026-08-30',
        'to': today,
        'reason': 'supplier',
        'source': 'ulas',
        'direction': 'up',
        'sort': 'newest',
        'page': '2',
        'limit': '50',
      });
      final ev = PriceChangeSummary.fromJson(summaryJson()).events.first;
      final selected = selectEvent(p.copyWith(category: 'Boya', q: 'x'), ev);
      expect(selected.direction, 'all');
      expect(selected.category, '');
      final sq = listQueryOf(selected, range);
      expect((sq.from, sq.to, sq.reason, sq.source), (kUlasEventAt, kUlasEventAt, 'supplier', 'ulas'));
      expect(summaryQueryParams(summaryQueryOf(selected, range)), {
        'from': '2026-08-30',
        'to': today,
        'reason': 'supplier',
        'source': 'ulas',
      });
      expect(isSelectedEvent(selected.event, ev), isTrue);
      final cleared = clearEvent(selected);
      expect((cleared.event, cleared.direction), (null, 'up'));
    });

    test('applyFilters bağlam aynıysa olayı korur; changePeriod olayı temizler', () {
      final ev = PriceChangeSummary.fromJson(summaryJson()).events.first;
      final withEvent = selectEvent(const ZamlarParams(source: 'ulas'), ev);
      final sameCtx = applyFilters(withEvent, source: 'ulas', reason: 'supplier', direction: 'up', category: '', q: '', sort: 'newest');
      expect(sameCtx.event, isNotNull);
      final otherCtx = applyFilters(withEvent, source: '', reason: 'supplier', direction: 'up', category: '', q: '', sort: 'newest');
      expect(otherCtx.event, isNull);
      final period = changePeriod(withEvent, '7');
      expect((period.event, period.direction, period.period), (null, 'up', '7'));
    });

    test('syncEventScope: saniyeye kırpılmış senkron o saniyeyi kapsar', () {
      final s = syncEventScope('ulas', kUlasSyncedAt)!;
      expect(s.from, '2026-09-27T00:05:12+03:00');
      expect(s.to, '2026-09-27T00:05:12.999999+03:00');
      expect(syncEventScope('ulas', 'bozuk'), isNull);
      // Olay (mikrosaniyeli) bu kapsamın içindedir.
      final ev = PriceChangeSummary.fromJson(summaryJson()).events.first;
      expect(isSelectedEvent(s, ev), isTrue);
    });

    test('sourceHistoryParams: yakın senkron olay kapsamı, eski senkron özel aralık', () {
      final ulas = PriceSource.fromJson(ulasSourceJson());
      final p = sourceHistoryParams(ulas, today);
      expect(p.period, '30');
      expect(p.direction, 'all');
      expect(p.event!.to, '2026-09-27T00:05:12.999999+03:00');

      final old = PriceSource.fromJson({...ulasSourceJson(), 'last_synced_at': '2026-06-01T00:05:00+03:00'});
      final po = sourceHistoryParams(old, today);
      expect((po.period, po.from), ('ozel', '2026-06-01'));

      final noChanges = PriceSource.fromJson({
        ...ulasSourceJson(),
        'last_changes': {'increased': 0, 'decreased': 0, 'avg_increase_percent': null},
      });
      final pn = sourceHistoryParams(noChanges, today);
      expect((pn.event, pn.direction, pn.source), (null, 'up', 'ulas'));
    });

    test('changePercentOf / formatChangePercent / reasonLabel', () {
      expect(changePercentOf(110, 115), 4.55);
      expect(changePercentOf(0, 5), isNull);
      expect(changePercentOf(250, 250.01), 0);
      expect(formatChangePercent(0, changeTone(250, 250.01)), '↑ <%0,01');
      expect(formatChangePercent(4.55), '↑ %4,55');
      expect(formatChangePercent(-2.1), '↓ %2,1');
      expect(formatChangePercent(null), '—');
      expect(reasonLabel('supplier', 1, 2), 'Tedarikçi zammı');
      expect(reasonLabel('supplier', 2, 1), 'Tedarikçi indirimi');
      expect(reasonLabel('markup', 1, 2), 'Kâr oranı');
      expect(reasonLabel('manual', 1, 2), 'Elle');
    });

    test('olay metinleri', () {
      final events = PriceChangeSummary.fromJson(summaryJson()).events;
      expect(eventCountsText(events.first), '12 ürüne zam · 2 ürüne indirim');
      expect(eventCountsText(events.last), '1 fiyat artışı · 1 fiyat düşüşü');
      expect(eventTimeLabel(events.first), '27 Eylül 2026 00:05');
      expect(eventTimeLabel(events.last), '2 Eylül 2026');
      expect(eventScopeLabel(eventScopeOf(events[1])), '21 Eylül 2026 00:05 · Demir Profil · Tedarikçi fiyat listesi');
      expect(changesTitle('down'), 'İndirim Gelen Ürünler');
    });

    test('tarih biçimleri İstanbul saatiyle', () {
      expect(formatSyncTime('2026-09-26T21:05:00Z'), '27 Eylül 2026 00:05');
      expect(formatChangeTime(kUlasEventAt), '27.09.2026 00:05');
      expect(formatDayRange('2026-08-30', '2026-09-28'), '30 Ağustos 2026 – 28 Eylül 2026');
      expect(formatPricePercent(12.5), '%12,5');
      expect(formatPricePercent(1000), '%1000');
    });
  });
}
