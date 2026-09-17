# BYZ Metraj Hesaplama — İçe Aktarım Öncesi Veri Kalitesi Raporu

Bu rapor, `scripts/extract_byz_calc_recipes.py` ile BYZ `material_calculation_service.py` içindeki `seed_calculation_data()` fonksiyonundan STATİK olarak (kod hiç çalıştırılmadan) çıkarılan **814 reçete kalemi** üzerinde tespit edilen sorunları listeler. Hiçbir değer burada ya da fixture'da SESSİZCE düzeltilmedi -- fixture BYZ'deki HAM değerleri taşır; düzeltme ayrı, bilinçli bir admin işlemidir (bkz. `cmd/import-calc-recipes` sonrası admin ekranı, Faz M2).

## 1) Birim tutarsızlıkları

Görülen tüm birimler ve kalem sayıları:

- `adet` — 466 kalem
- `m` — 121 kalem
- `kg` — 79 kalem
- `paket` — 55 kalem
- `m²` — 33 kalem
- `torba` — 30 kalem
- `rulo` — 20 kalem
- `m2` — 3 kalem
- `teneke` — 2 kalem
- `set` — 2 kalem
- `metre` — 1 kalem
- `top` — 1 kalem
- `m3` — 1 kalem

**m2 / m² tutarsızlığı:** aynı anlama gelen iki farklı yazım bulundu: ['m2', 'm²']. Bunlar farklı string oldukları için (ARVEND'de `unit` serbest metindir) aynı malzeme farklı birimlerle iki kez tanımlanmış gibi görünebilir.

**metre / m tutarsızlığı:** ['metre', 'm'].

**Aynı malzeme adı farklı birimlerle kayıtlı (paket/adet vb. uyuşmazlıkları):**

- 'derz bandı': ['adet', 'm']
- 'shingle': ['adet', 'paket']

## 2) Aslında çevre (perimeter) bazlı olması muhtemel satırlar

BYZ'nin motoru TÜM kalemleri `area_based` olarak seed eder (bkz. docs/byz-metraj-hesaplama-analizi.md §3.2) -- `perimeter_based` tip hiç kullanılmaz. Aşağıdaki `group_name` alanı 'Perimeter' olan ya da adı çevre/kenar/kösebent gibi kelimeler içeren kalemler, gerçekte alan yerine çevreyle orantılı olabilir; bu, alanla değil malzeme adı/etiketiyle tahmin edilmiştir, KESİN DEĞİLDİR:

- L Köşebent 3000 mm (kategori: `60x60-aluminyum-tavan`, group_name: 'Perimeter', qty/m²: 2)
- L Köşebent 3000 mm (kategori: `60x60-plastik-tavan-yildiz`, group_name: 'Perimeter', qty/m²: 2)
- L Köşebent 3000 mm (kategori: `60x60-plastik-tavan-damla`, group_name: 'Perimeter', qty/m²: 2)
- L Köşebent 3000 mm (kategori: `60x60-akustik-tavan`, group_name: 'Perimeter', qty/m²: 2)
- L Köşebent 3000 mm (kategori: `60x60-karolam-tavan`, group_name: 'Perimeter', qty/m²: 2)
- L Köşebent 3000 mm (kategori: `60x60-mesh-tavan`, group_name: 'Perimeter', qty/m²: 2)
- L Köşebent 3000 mm (kategori: `30x30-aluminyum-lay-in`, group_name: 'Perimeter', qty/m²: 2)
- Lamel Derz Çıtası (kategori: `lamel-85-tavan-citali`, group_name: 'Aksesuar', qty/m²: 3)
- L Köşebent 3000 mm (kategori: `60x60-tasyunu-deckon`, group_name: 'Perimeter', qty/m²: 2)
- L Köşebent 3000 mm (kategori: `60x60-tasyunu-cortega`, group_name: 'Perimeter', qty/m²: 2)
- L Köşebent 3000 mm (kategori: `60x60-tasyunu-oasis`, group_name: 'Perimeter', qty/m²: 2)
- L Köşebent 3000 mm (kategori: `10x10-petek-tavan`, group_name: 'Perimeter', qty/m²: 2)
- L Köşebent 3000 mm (kategori: `5x5-petek-tavan`, group_name: 'Perimeter', qty/m²: 2)
- L Köşebent 3000 mm (kategori: `7-5x7-5-petek-tavan`, group_name: 'Perimeter', qty/m²: 2)
- L Köşebent 3000 mm (kategori: `15x15-petek-tavan`, group_name: 'Perimeter', qty/m²: 2)
- Ahşap Çıta (kategori: `onduline-cati-xps-5cm`, group_name: 'Alt Yapı', qty/m²: 3.5)
- Ahşap Çıta (kategori: `onduline-besik-cati-xps-5cm`, group_name: 'Alt Yapı', qty/m²: 3.25)
- Ahşap Çıta (kategori: `shingle-cati-xps-5cm`, group_name: 'Alt Yapı', qty/m²: 3.5)
- Ahşap Çıta (kategori: `shingle-besik-cati-xps-5cm`, group_name: 'Alt Yapı', qty/m²: 3.25)
- Baskı Çıtası (3mt) (kategori: `gezilmeyen-teras-yalitimi`, group_name: 'Aksesuar', qty/m²: 2)
- Baskı Çıtası (3mt) (kategori: `teras-isi-su-yalitimi`, group_name: 'Aksesuar', qty/m²: 2)

## 3) Şüpheli katsayılar (paket-tarzı birimler)

`quantity_per_m2` değeri 1 m² başına 1'e eşit ya da bundan büyük olan `paket`/`torba`/`rulo`/`top`/`teneke` kalemler (ör. 'Dübel Vida' — 1 paket/m² → 100 m² için 100 paket), gerçek dünyada mantıksız görünebilir; muhtemelen 'X paket, Y m² kaplar' şeklinde PAKET BAŞINA KAPSAMA olarak modellenmesi gerekirken doğrudan m² katsayısı olarak girilmiştir (bkz. yeni `package_size` alanı, Faz M1). `adet` birimi BİLİNÇLİ OLARAK bu listeye DAHİL EDİLMEDİ -- vida/dübel gibi malzemelerde yüksek adet/m² değeri normaldir, yanlış pozitif üretirdi. Bunlar TAHMİN olarak işaretlenmiştir, iş sahibiyle doğrulanmalıdır:

- Dübel Vida (60x60-aluminyum-tavan): 1 paket/m²
- Dübel Vida (60x60-plastik-tavan-yildiz): 1 paket/m²
- Dübel Vida (60x60-plastik-tavan-damla): 1 paket/m²
- 60x60 Akustik Tavan (60x60-akustik-tavan): 1 paket/m²
- Dübel Vida (60x60-akustik-tavan): 1 paket/m²
- 60x60 Karolam Tavan (60x60-karolam-tavan): 1 paket/m²
- Dübel Vida (60x60-karolam-tavan): 1 paket/m²
- Dübel Vida (60x60-mesh-tavan): 1 paket/m²
- Dübel Vida (30x30-plastik-clip-in): 1 paket/m²
- Dübel Vida (30x30-aluminyum-clip-in): 1 paket/m²
- Dübel Vida (30x30-aluminyum-lay-in): 1 paket/m²
- Dübel Vida (lamel-85-tavan-citali): 1 paket/m²
- Dübel Vida (lamel-85-tavan-citasiz): 1 paket/m²
- 60x60 Taşyünü Deckon (60x60-tasyunu-deckon): 1 paket/m²
- Dübel Vida (60x60-tasyunu-deckon): 1 paket/m²
- 60x60 Taşyünü Cortega (60x60-tasyunu-cortega): 1 paket/m²
- Dübel Vida (60x60-tasyunu-cortega): 1 paket/m²
- 60x60 Taşyünü Oasis (60x60-tasyunu-oasis): 1 paket/m²
- Dübel Vida (60x60-tasyunu-oasis): 1 paket/m²
- Dübel Vida (60x60-metal-clip-in): 1 paket/m²
- Dübel Vida (60x60-aluminyum-clip-in): 1 paket/m²
- Dübel Vida (10x10-petek-tavan): 1 paket/m²
- Dübel Vida (5x5-petek-tavan): 1 paket/m²
- Dübel Vida (7-5x7-5-petek-tavan): 1 paket/m²
- Dübel Vida (15x15-petek-tavan): 1 paket/m²
- Dübel Vida (galvaniz-profilli-normal-alcipan-tavan): 1 paket/m²
- Dübel Vida (agrafli-normal-alcipan-tavan): 1 paket/m²
- Dübel Vida (galvaniz-profilli-su-yangin-alcipan-tavan): 1 paket/m²
- Dübel Vida (galvaniz-profilli-boardex-tavan): 1 paket/m²
- Dübel Vida (normal-alcipan-bolme-duvar): 1 paket/m²
- Dübel Vida (8cm-kayayunu-dolgulu-alcipan-bolme-duvar): 1 paket/m²
- Dübel Vida (su-yangin-alcipan-bolme-duvar): 1 paket/m²
- Dübel Vida (8cm-kayayunu-su-yangin-alcipan-bolme-duvar): 1 paket/m²
- 3cm Karbonlu EPS (3cm-karbonlu-eps-mantolama): 1 paket/m²
- Strafor Yapıştırıcısı (3cm-karbonlu-eps-mantolama): 1 torba/m²
- Strafor Sıvası (3cm-karbonlu-eps-mantolama): 1 torba/m²
- Mineral Sıva (Dekoratif Sıva) (3cm-karbonlu-eps-mantolama): 1 torba/m²
- 4cm Karbonlu EPS (4cm-karbonlu-eps-mantolama): 1 paket/m²
- Strafor Yapıştırıcısı (4cm-karbonlu-eps-mantolama): 1 torba/m²
- Strafor Sıvası (4cm-karbonlu-eps-mantolama): 1 torba/m²
- … ve 36 kalem daha (tam liste fixture'da).

## 4) 0 TL referans fiyatlı kalemler

378 / 814 kalemin referans fiyatı 0 TL. Bu kalemler ARVEND'e `product_id=NULL` olarak (ürün eşleşmesi yapılmadan) aktarılacak; hesaplama sırasında `product_zero_price`/`product_missing` warning üretecekler (sessizce 0 TL ile geçmeyecekler).

Kategori başına 0 TL kalem sayısı (ilk 20):

- `dalsan-asma-tavan-askili-cift-dik50`: 14
- `dalsan-asma-tavan-askili-cift-dik60`: 14
- `dalsan-asma-tavan-askili-cift-paralel40`: 14
- `dalsan-asma-tavan-askili-tek-dik50`: 13
- `dalsan-asma-tavan-askili-tek-dik60`: 13
- `dalsan-asma-tavan-askili-tek-paralel40`: 13
- `dalsan-asma-tavan-agrafli-tek-dik50`: 12
- `dalsan-asma-tavan-agrafli-tek-dik60`: 12
- `dalsan-asma-tavan-agrafli-tek-paralel40`: 12
- `dalsan-asma-tavan-agrafli-cift-dik50`: 12
- `dalsan-asma-tavan-agrafli-cift-dik60`: 12
- `dalsan-asma-tavan-agrafli-cift-paralel40`: 12
- `dalsan-giydirme-duvar-tavan-profil-cift-60`: 12
- `dalsan-giydirme-duvar-tavan-profil-cift-40`: 12
- `dalsan-giydirme-duvar-duvar-profil-cift-60`: 12
- `dalsan-giydirme-duvar-duvar-profil-cift-40`: 12
- `dalsan-giydirme-duvar-tavan-profil-tek-60`: 11
- `dalsan-giydirme-duvar-tavan-profil-tek-40`: 11
- `dalsan-giydirme-duvar-duvar-profil-tek-60`: 11
- `dalsan-giydirme-duvar-duvar-profil-tek-40`: 11

## 5) Aynı malzeme farklı kategorilerde çelişen referans fiyat

3 farklı (ad, birim) çiftinde birden fazla referans fiyat görüldü (BYZ'de ürün ilk görülen fiyatı alıyordu, sonrakiler yalnızca reçete referansına yazılıyordu):

- 'agraf' (adet): [0.0, 5.0]
- 'klips' (adet): [0.0, 3.0]
- 'çelik dübel' (adet): [0.0, 4.0]

## 6) `ceil` yuvarlamalı + taban-10'da devirli katsayı riski

ARVEND `quantity_per_m2` kolonunu `numeric(14,6)` (6 ondalık hane) olarak saklar. BYZ'deki bazı `round: ceil` kalemleri (paket kapsaması modellenirken `1/N` biçiminde girilmiş) taban-10'da DEVİRLİ (örn. 1/3.6 = 0,2777...) katsayılar taşır; 6 haneye yuvarlamak gerçek değerden çok küçük bir sapma yaratır ve BYZ'nin kendi float64 gürültüsüyle yaşadığı sorunun (bkz. docs/byz-metraj-hesaplama-analizi.md §10, '10.8×1/3.6' örneği) benzerini üretebilir (bir paket fazla/eksik). ARVEND motoru bunu `package_size` alanıyla KESİN olarak çözer (bkz. internal/domain/calc.go) -- ama bu, YALNIZCA admin bu kalemleri `quantity_per_m2=1, package_size=<kapsama m²>` biçimine DÖNÜŞTÜRÜRSE devreye girer; içe aktarma bunu OTOMATİK yapmaz. Aşağıdaki kalemler bu dönüşüm için adaydır:

- 3cm Taşyünü (3cm-tasyunu-mantolama): quantity_per_m2=0.2777777777777778 (≈ 5/18) -> ÖNERİ: quantity_per_m2=1, package_size=3.6
- 5cm Taşyünü (5cm-tasyunu-mantolama): quantity_per_m2=0.4629629629629629 (≈ 25/54) -> ÖNERİ: quantity_per_m2=1, package_size=2.16

## Özet

- Toplam grup: 16
- Toplam kategori: 95
- Toplam reçete kalemi: 814
- Farklı birim sayısı: 13
- 0 TL fiyatlı kalem: 378
- Çevre-bazlı şüphesi taşıyan kalem: 21
- Şüpheli paket katsayılı kalem (>=1 paket-tarzı birim/m²): 76
- Çelişen fiyatlı (ad, birim) çifti: 3
- `ceil` + devirli katsayı riski taşıyan kalem: 2

**Karar bekleyen madde:** Yukarıdaki hiçbir sorun bu script tarafından düzeltilmedi. İçe aktarma (`cmd/import-calc-recipes`) fixture'ı OLDUĞU GİBİ (BYZ'deki ham hâliyle) organizasyonun `calc_*` tablolarına yazar; düzeltmeler admin ekranından (Faz M1 CRUD uçları) ya da fixture dosyası elle düzenlenip yeniden import edilerek yapılmalıdır.