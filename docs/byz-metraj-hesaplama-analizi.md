# BYZ Metraj Hesaplama Sistemi — Teknik Analiz Raporu

**Kapsam:** `/Users/tahaeryetisozen/Documents/GitHub/byz-app` — salt okuma, hiçbir kod değiştirilmedi/çalıştırılmadı.
**Yöntem:** Tüm dosyalar doğrudan okundu; 5 paralel okuyucu + 1 bağımsız "çürütücü" doğrulayıcı ile formüller ve örnek hesap çapraz kontrol edildi. Doğrulayıcı hiçbir formülü düzeltmek zorunda kalmadı. Koddan okunmayan her çıkarım **TAHMİN:** ile işaretlidir. Satır numaraları `dosya:satır` biçimindedir; aksi belirtilmedikçe dosyalar `erp_teklif_sistemi/` altındadır.

> **Görev önermesinde düzeltme:** "60x60 Asma Tavanlar → Petek Tavan" zinciri kodda **yok**. Petek tavan ayrı bir gruptur: `petek-tavanlar` (`services/material_calculation_service.py:373-378`) altında 4 kategori (`10x10-petek-tavan`, `5x5-petek-tavan`, `7-5x7-5-petek-tavan`, `15x15-petek-tavan`, `:530-535`). `60x60-asma-tavanlar` grubunda ise 6 kategori var (`:501-508`). Örneklerde gerçek zincir kullanıldı.

---

## 1. Kullanıcı akışı

Üç yüzey vardır; üçü de **aynı** servis fonksiyonunu çağırır: `calculate_material_list()` (`services/material_calculation_service.py:198`).

### A) Web — Teklif Oluştur › "Metraj Hesapla" sekmesi (ana kullanım)

Sekme: `templates/offer_create.html:447-450` (`data-tab="metraj"`). Panel: `:535-655`, JS sınıfı `CizimBolumu` (`:863-1466`), tek örnek (`:1489`).

1. **Alan Adı** (`.cizim-alan-adi-input`, `:542`) → teklif satırlarına `section_label` olarak düşer.
2. **Hesaplama Grubu** → **Hesaplama Türü** kaskadı (`initGroupCascade` `:1283-1305`). Veri, sayfaya `CALC_GROUPS` olarak gömülür (`:340-344`; sunucuda `get_calculation_categories_grouped()`, `offer_routes.py:192,276,417,832`). Yalnızca `slug` + `name` taşınır.
3. **Mod seçimi** (`:560-563`):
   - **Çizerek:** canvas üzerinde ızgaraya yuvarlanan köşeler (`toGrid` `:889-899`, `Math.round`), "1 Kare = X metre" ölçeği (`:586`), "Dikdörtgen Oluştur" kısayolu (`:1164-1171`). Çokgen → **Bitir** (≥3 nokta, kendiyle kesişme uyarısı `:1271-1280`) → **Şekil Adı** → **"+ Listeye Ekle"** (`sekilEkle` `:1232-1244`). Birden çok adlandırılmış şekil eklenebilir; alanları **toplanır** (`areaGridUnits` `:1312-1314`).
   - **Ölçü Girerek:** En/Boy **veya** doğrudan m² (`footprintAreaM2` `:1315-1324`; m²>0 ise En/Boy yok sayılır).
4. **Çatı grubunda** (`cati-hesaplamalari`) ek **Çatı Eğimi (°)** alanı (`:646-649`); alan istemcide `m2 / cos(eğim)` ile büyütülür (`:1326-1330`). Sunucu eğimi hiç görmez.
5. **Hesapla** (`hesapla()` `:1350-1409`) → `POST /calculations/api/calculate` → tablo: Malzeme / Miktar / Birim Fiyat / Tutar + Toplam (`:1385-1399`).
6. **"Bu Bölümü Ürüne Ekle"** (`ekle()` `:1412-1465`): sonuçtaki **tüm** kalemler (miktar>0) "Ürün Ekle" sekmesine yeni satır olarak eklenir, sekme otomatik değişir (`:1415`), çizim modunda kroki PNG'si `shape_sketches` için saklanır (`:1437-1453`), panel şekilleri sıfırlanır (`:1458-1463`). Başka bölüm/tür için 3-6 tekrarlanır (yorum `:1472-1474`).
7. Teklif normal form POST'u ile kaydedilir (`offer_routes.py:133-225`).

### B) Web — bağımsız `/calculations` sayfası

`routes/calculation_routes.py:14-101`, `templates/calculations.html`. Menüden grup (`base.html:67`, `hesap_gruplari` context processor `app.py:139-154`) → En/Boy/Alan formu → tür butonuna tıkla (`<button type="submit" name="category_slug">`, `calculations.html:58-61`) → sonuç tablosu + Yazdır. **"Teklife Dönüştür" butonu `disabled`** (`calculations.html:142`) — bu sayfadan teklife aktarım yoktur.

### C) Mobil (Flutter)

`mobile/lib/screens/hesaplama_ekrani.dart`. Giriş: Diğerler › Araçlar › "Metraj Hesaplama" (`digerler_ekrani.dart:103-108`).
Açılışta `GET /api/calculations` (`:45-46`) → **Grup** / **Tür** alt-sayfa seçicileri (`:81-115`; kategoride `image` varsa sistem kesit görseli `:250-254`) → **Alan (m²)** veya **En × Boy** (`:256-286`) → **Hesapla** → `POST /api/calculate` (`:132-136`) → sonuç paneli → **"Listeye Ekle"** (`_sonucuEkle` `:154-181`, yalnızca ekran state'inde biriktirir, tür ve girdiler sıfırlanır, grup kalır) → **"Teklif Oluştur'a Aktar (N)"** (`_teklifeAktar` `:187-204`) → `TeklifOlusturEkrani(ilkKalemler: …)` **push** edilir (pop ile sonuç döndürme yok).

---

## 2. Veri modeli

Üç Mongo koleksiyonu + `products`. Tek yazıcı: `seed_calculation_data()` (`material_calculation_service.py:322-2434`). Çalışma zamanında `calculation_recipes`'a yazan tek yer: `_resolve_recipe_products` (`:159-162`, `product_id` onarımı).

### `calculation_groups` (`:437-458`)

| Alan | Tip | Örnek |
|---|---|---|
| `_id` | ObjectId | — |
| `slug` | str (upsert anahtarı) | `"petek-tavanlar"` |
| `name` | str | `"Petek Tavanlar"` |
| `description` | str | `"Petek asma tavan hesaplamaları"` |
| `sort_order` | int | `7` |
| `is_active` | bool (seed hep `True`) | `true` |
| `created_at` / `updated_at` | datetime | — |

### `calculation_categories` (`:2269-2298`)

| Alan | Tip | Örnek |
|---|---|---|
| `slug` | str (upsert anahtarı) | `"10x10-petek-tavan"` |
| `name` | str | `"10x10 Petek Tavan"` |
| `description` | str | `"10x10 petek asma tavan malzeme hesaplama"` |
| **`group_slug`** | str \| None — **gruba bağ (string slug, ObjectId değil)** | `"petek-tavanlar"` |
| `sort_order` | int | `19` |
| `image` | str \| None (yalnızca 33 Dalsan kategorisinde) | `"img/sistemler/…png"` |
| `is_active`, `created_at`, `updated_at` | | |

### `calculation_recipes` (insert `:2411-2429`, update `:2391-2409`)

| Alan | Tip | Örnek (10x10 Petek, 1. kalem) |
|---|---|---|
| **`category_slug`** | str — **kategoriye bağ (string slug)** | `"10x10-petek-tavan"` |
| `material_name` | str | `"10x10 Petek Tavan"` |
| `normalized_material_name` | str (`normalize_text`: TR karakter → ASCII, `strip().lower()`) | `"10x10 petek tavan"` |
| `unit` | str | `"adet"` |
| **`product_id`** | ObjectId \| None — **ürüne bağ** | `ObjectId(…)` |
| `calculation_type` | str — seed'de **daima** `"area_based"` | `"area_based"` |
| `quantity_per_m2` | int/float | `5` |
| `quantity_per_meter` | seed'de daima `0` | `0` |
| `fixed_quantity` | seed'de daima `0` | `0` |
| `rounding_type` | `"none"` (781 kalem) \| `"ceil"` (33 kalem) | `"none"` |
| `waste_percentage` | seed'de daima `0`, **motor hiç okumaz** | `0` |
| `unit_price` | float — **referans** fiyat (onarım için; hesapta kullanılmaz) | `230.0` |
| `group_name` | str (UI alt başlığı; hesaba girmez) | `"Ana Malzemeler"` |
| `sort_order`, `is_active`, `created_at`, `updated_at` | | |

Reçete eşleme anahtarı (seed): `(category_slug, normalized_material_name, unit)` (`:2363-2366`).
Ürün eşleme anahtarı (seed): `(normalize_text(material_name), unit)` (`:2312-2315`).

**İndeksler** (`services/db_service.py:146-149, 175-189`): `calculation_recipes` → `category_slug`, `normalized_material_name`; `calculation_categories` → `group_slug`, `slug`, `is_active`, `sort_order`, bileşik `(group_slug, is_active, sort_order)`; `calculation_groups` → `slug`, `is_active`, `sort_order`. **Hepsi `unique=False`** — `slug` benzersizliğini yalnızca upsert filtresi sağlar.

**Envanter (doğrulanmış sayım):** 16 grup, 95 kategori, **814 reçete kalemi**, 127 farklı (ad, birim) ürün anahtarı. 13 farklı `unit`: `adet`(466) `m`(121) `kg`(79) `paket`(55) `m²`(33) `torba`(30) `rulo`(20) `m2`(3) `set`(2) `teneke`(2) `m3`(1) `metre`(1) `top`(1).

### Gerçek örnek zincir (seed'den birebir)

```python
# Grup  (:373-378)
{"slug": "petek-tavanlar", "name": "Petek Tavanlar", "description": "Petek asma tavan hesaplamaları", "sort_order": 7}
# Atama (:530-535)
"petek-tavanlar": ["10x10-petek-tavan", "5x5-petek-tavan", "7-5x7-5-petek-tavan", "15x15-petek-tavan"]
# Kategori (:695-700)
{"slug": "10x10-petek-tavan", "name": "10x10 Petek Tavan", "description": "10x10 petek asma tavan malzeme hesaplama", "sort_order": 19}
# Reçete (:1388-1398)  -- seed kısa formu: qty = m² başına miktar, price = referans fiyat
"10x10-petek-tavan": [
    {"material_name": "10x10 Petek Tavan",   "unit": "adet",  "qty": 5, "price": 230, "group": "Ana Malzemeler", "order": 1},
    {"material_name": "3600 mm Ana Taşıyıcı", "unit": "adet",  "qty": 1, "price": 110, "group": "Ana Malzemeler", "order": 2},
    {"material_name": "Tali Taşıyıcı 60cm",   "unit": "adet",  "qty": 6, "price": 30,  "group": "Tali Taşıyıcı",  "order": 3},
    {"material_name": "Tali Taşıyıcı 120cm",  "unit": "adet",  "qty": 6, "price": 60,  "group": "Tali Taşıyıcı",  "order": 4},
    {"material_name": "L Köşebent 3000 mm",   "unit": "adet",  "qty": 2, "price": 70,  "group": "Perimeter",      "order": 5},
    {"material_name": "Çelik Dübel",          "unit": "adet",  "qty": 3, "price": 4,   "group": "Aksesuar",       "order": 6},
    {"material_name": "Askı Teli 40cm",       "unit": "adet",  "qty": 6, "price": 4,   "group": "Aksesuar",       "order": 7},
    {"material_name": "Çift Yaylı Maşa",      "unit": "adet",  "qty": 3, "price": 3,   "group": "Aksesuar",       "order": 8},
    {"material_name": "Dübel Vida",           "unit": "paket", "qty": 1, "price": 170, "group": "Aksesuar",       "order": 9},
]
```

Diğer 3 petek kategorisi yalnızca 1. kalemde farklıdır (5x5: 300 TL, 7.5x7.5: 250 TL, 15x15: 150 TL; `:1400,1411,1422`). `60x60-aluminyum-tavan` reçetesi (`:1200-1210`) de aynı iskelettir (1. kalem "60x60 Alüminyum Tavan", 200 TL).

---

## 3. Hesaplama motoru — `calculate_material_list(category_slug, width=None, height=None, area=None)`

Kaynak: `services/material_calculation_service.py:198-319`. Sıra: kategori → reçete → **ürün çözümleme (DB'ye yazabilir, girdi doğrulamasından ÖNCE, `:221`)** → girdi → alan/çevre → kalem döngüsü.

### 3.1 Alan ve çevre türetme (`:229-249`)

```python
width_val  = float(width)  if width  else None   # 0 ve "" → None (truthiness)
height_val = float(height) if height else None
area_val   = float(area)   if area   else None
...
if area_val and area_val > 0:
    calculated_area = area_val                       # perimeter_val None KALIR
elif width_val and height_val:
    if width_val <= 0 or height_val <= 0:
        return {"error": "Ölçü değerleri sıfırdan büyük olmalıdır."}
    calculated_area = width_val * height_val
    perimeter_val   = 2 * (width_val + height_val)
else:
    return {"error": "Lütfen en ve boy bilgisi girin ya da doğrudan m² değeri yazın."}
```

- **`area` verildiğinde çevre hiçbir zaman hesaplanmaz** — kare varsayımı/`sqrt` yok; en/boy da gönderilse `elif` çalışmaz.
- Çevre yalnızca en×boy ile gelir: `2·(en+boy)`.
- "Adet/count" türetimi yoktur.

### 3.2 Kalem başına miktar (`:255-275`)

```python
calc_type = item.get("calculation_type", "area_based")
if calc_type == "area_based":
    qty_per_m2 = item.get("quantity_per_m2", 0)
    if calculated_area and qty_per_m2:
        base_quantity = calculated_area * qty_per_m2
elif calc_type == "perimeter_based":
    qty_per_meter = item.get("quantity_per_meter", 0)        # alan adı quantity_per_meter
    if perimeter_val and qty_per_meter:
        base_quantity = perimeter_val * qty_per_meter
elif calc_type == "fixed":
    base_quantity = item.get("fixed_quantity", 0)
# tanınmayan tip → base_quantity = 0, uyarı yok
rounding_type  = item.get("rounding_type", "none")
final_quantity = _apply_rounding(base_quantity, rounding_type)
```

| `calculation_type` | Formül | Seed'de kullanılıyor mu? |
|---|---|---|
| `area_based` | `miktar = alan × quantity_per_m2` | **Evet — 814/814 kalem** |
| `perimeter_based` | `miktar = 2·(en+boy) × quantity_per_meter` | Hayır (alan `0`); `area` gönderildiğinde zaten 0 |
| `fixed` | `miktar = fixed_quantity` | Hayır (alan `0`) |

### 3.3 Yuvarlama (`:169-181`)

```python
if not rounding_type or rounding_type == "none": return float(value)
elif rounding_type == "ceil":  return math.ceil(round(float(value), 9))   # int döner; 3.0000000000000004 → 3
elif rounding_type == "round": return round(value, 2)                     # Python round (banker's), float'a çevirmez
return float(value)
```

Sıra: **çarpım → yuvarlama → fiyat**. `"ceil"` seed'de 7 farklı malzemede (33 kalem) sabit-paket kalıbıyla kullanılır: `quantity_per_m2 = 1/paket_kapsamı` (ör. `1/3.6`, `1/50`, `1/200`, `:2369-2374` yorumu).

### 3.4 Kodda OLMAYAN şeyler (kesin)

- **Fire (`waste_percentage`)**: alan yazılır, motor **hiç okumaz** (grep: yalnızca `:2422`).
- **Minimum miktar, paket büyüklüğü, `quantity_per_m`**: kod tabanında hiç geçmez.
- **Birim dönüşümü**: yok; `unit` yalnızca çıktıya kopyalanır. `m2`/`m²`/`metre`/`m` ayrı string'lerdir.
- **Fiyat mantığı**: yalnızca `product.unit_price` (aşağıda).

### 3.5 Fiyat ve toplam (`:277-319`)

```python
product    = products_by_recipe_id.get(item["_id"])
unit_price = product.get("unit_price", 0) if product else 0
line_total = final_quantity * unit_price
total_cost += line_total                          # yuvarlanMAMIŞ birikim
...
"line_total": round(line_total, 2),  "total_cost": round(total_cost, 2)
```

Biçimleme: `_format_quantity` (`:184-189`) tam sayıysa `"100 adet"`, değilse `f"{q:.2f}"` (**nokta** ondalık); `_format_money` (`:192-195`) `"43.100,00 TL"` (**virgül** ondalık, `"TL"` sabit).

### 3.6 Hata/erken dönüş koşulları

`{"error": …}` ile: kategori yok/pasif (`:212-214`), reçete yok (`:219-220`), sayı parse hatası (`:236-237`; JSON uçlarından ulaşılamaz, bkz. §4), negatif en/boy (`:244-245`), ölçü yok (`:248-249`). `float("inf")`/`"nan"` tüm katmanlardan geçer → `int(inf)` / `math.ceil(inf)` → **500** (`:186`, `:178`).

---

## 4. İstek JSON'u

Her iki JSON ucu aynı gövdeyi kabul eder: `{"category_slug": str, "width"?: num, "height"?: num, "area"?: num}`. Sayısal alanlar `None`/`""` → `None`; parse edilemeyen değer **sessizce `None`** (`calculation_routes.py:120-126`, `api_routes.py:1674-1681`).

| Uç | Auth | Boş slug mesajı | Gövde işleme |
|---|---|---|---|
| `POST /calculations/api/calculate` (`calculation_routes.py:104-135`) | `login_required` — **session çerezi**; oturumsuz → 302 HTML | "Lütfen bir hesaplama türü seçin." | `jsonify(result)` |
| `POST /api/calculate` (`api_routes.py:1664-1687`) | `api_login_required` — Bearer token, 30 gün (`:42, 62-77`); hata 401 JSON | "Hesaplama türü seçmelisiniz" | `jsonify(_jsonlanabilir(sonuc))` |
| `POST /calculations/group/<slug>` (`calculation_routes.py:38-92`) | session | flash | **form** alanları `width/height/area/category_slug`; kendi `float()`'u |

**Web paneli gerçekte ne gönderir** (`offer_create.html:1366-1370`):
```js
body: JSON.stringify({ category_slug: categorySlug, area })
```
Yalnızca **`area`** — En/Boy istemcide çarpılıp alan olarak gider; çizim modunda `Σ shoelace(şekiller) × ölçek²` (`:835-842`, `:1312-1314`); çatıda `/cos(eğim)`. Sonuç: web panelinden **çevre sunucuya hiç ulaşmaz**.

**Mobil ne gönderir** (`hesaplama_ekrani.dart:132-136`):
```dart
{'category_slug': _kategori!['slug'],
 if (alan != null && alan > 0) 'area': alan,
 if (alan == null || alan <= 0) ...{'width': en, 'height': boy}}
```
Alan >0 ise yalnızca `area`; aksi halde `width`+`height` (bu durumda sunucu çevreyi hesaplar).

**Çoklu alan desteği:** İstek düzeyinde **yok** — tek istek = tek kategori + tek alan. Web'de aynı tür altındaki birden çok şekil **toplanıp tek alan** olarak gider; farklı türler ardışık Hesapla→Ürüne Ekle ile eklenir. Mobilde her hesaplama ayrı istektir, sonuçlar yerelde biriktirilir. DOM'daki `-bolum` ekleri ve `CizimBolumu` adına rağmen tek panel örneği vardır (TAHMİN: önceki çok-bölümlü tasarımın kalıntısı).

---

## 5. Yanıt yapısı

Başarı (200) — servis sözlüğü sarmalanmadan döner (`material_calculation_service.py:290-319`):

```json
{
  "success": true,
  "category": { "slug": "10x10-petek-tavan", "name": "10x10 Petek Tavan", "image": null },
  "input":    { "width": null, "height": null, "area": 20.0, "perimeter": null },
  "items": [
    {
      "material_name": "10x10 Petek Tavan",
      "unit": "adet",
      "quantity": 100.0,                 // rounding none → float; ceil → int
      "quantity_display": "100 adet",    // nokta ondalık ("2.78 m²")
      "unit_price": 230.0,               // products.unit_price (çalışma zamanı)
      "unit_price_display": "230,00 TL",
      "line_total": 23000.0,             // round(qty*price, 2)
      "line_total_display": "23.000,00 TL",
      "group_name": "Ana Malzemeler",
      "product_id": "66f…"               // str(ObjectId) veya null
    }
  ],
  "total_cost": 43100.0,                 // round(Σ yuvarlanmamış line_total, 2)
  "total_cost_display": "43.100,00 TL"
}
```

Hata (400): `{"error": "…"}`. Yanıtta **uyarı listesi yoktur** — çevre-bazlı kalemin 0 çıkması, ürünü bulunamayan kalemin 0 TL'ye düşmesi sessizdir.

`GET /api/calculations` (`api_routes.py:1658-1661`) → `{"groups": [{slug, name, description, categories: [<ham kategori dokümanı, _id→str>]}]}` (`get_calculation_categories_grouped` `:37-67`; grup `_id`/`sort_order` dahil değil, aktif gruba bağlı olmayan kategoriler atlanır).

---

## 6. Ürün kataloğu bağı

**Bağ:** `calculation_recipes.product_id` (ObjectId) → `products._id`. Çözümleme `_resolve_recipe_products` (`:108-166`): tek `$in` sorgusu (`:119-124`). Motor üründen yalnızca `_id` ve `unit_price` okur (`:279-282`); **ad ve birim reçeteden** gelir (`:291-292`).

**Fiyat kaynağı:** her zaman `products.unit_price` — **çalışma zamanı**, snapshot değil. Ürün fiyatı `/products` ekranından elle güncellenebilir (`routes/product_routes.py:258-283`) ve gece Ulaş senkronuyla değişebilir (`services/ulas_scraper.py:123-199`, APScheduler cron `app.py:247-250`; `source: "ulas"` ürünleri upsert eder, listeden düşenleri siler, `"Hesaplama Malzemesi"` kategorisine dokunmaz — eskiden `delete_many({})` ile hepsini siliyordu, commit `0beeca5`).

**Ürün yoksa / kaybolmuşsa** (`:150-162`): `get_or_create_product(name=material_name, unit, unit_price=<reçete referansı>, category="Hesaplama Malzemesi")` (`product_service.py:56-87`: `(normalized_name, unit)` ile arar; yoksa **birime göre tüm ürünleri çekip Python'da tarar**; yine yoksa **ürün oluşturur**) ve bulunan `_id` reçeteye **geri yazılır**. Yani bir hesaplama isteği `products.insert_one` + `calculation_recipes.update_one` tetikleyebilir.

**Kendiliğinden fiyat onarımı** (`:137-148`): ürün var, ürün fiyatı 0, reçete `unit_price` > 0, kategori `"Hesaplama Malzemesi"` ise `products.update_one` ile reçete fiyatı yazılır. Seed'de `price: 0` olan kalemler (tüm Dalsan, Lamel, Akustik, Cortega/Oasis) bu şartı geçemez → 0 TL kalır.

**Ürün hiç çözülemezse** (`material_name`/`unit` boş): `unit_price = 0`, kalem **düşürülmez**, `product_id` reçetedeki değer (varsa) string olarak döner.

**Teklife eklendiğinde snapshot'a giren alanlar** (`offer_routes.py:173-183`):

```python
{"product_id": object_id,                 # ürün çözüldüyse ObjectId, yoksa None
 "product_name": product_display_name,    # ürün çözüldüyse DB'deki ad (:166), yoksa formdaki ad
 "quantity": qty, "unit_price": price,    # FORMDAN (kullanıcı değiştirmiş olabilir); DB fiyatı alınmaz
 "line_total": round(qty * price, 2),
 "section_label": ..., "category_slug": ...}
```
Kaydedilmeyenler: **`unit`**, `group_name`, alan (m²), katsayı, hesaplama girdi/çıktısı. Kural `:170-171`: ürün çözülmüş ve `qty<=0 or price<=0` ise satır **sessizce atlanır** (0 TL Dalsan malzemesi fiyat girilmeden teklife yazılmaz — TAHMİN: canlıda yaşanıp yaşanmadığı doğrulanmadı). Mobil ise `product_id`'yi hiç taşımaz (§8).

---

## 7. Teklif entegrasyonu — "Metraj Hesapla" paneli

`ekle()` (`offer_create.html:1412-1432`):

```js
const label = alanAdı || this._lastCategoryName || 'Alan';
document.querySelector('[data-tab="urunler"]').click();
this.lastCalcItems.forEach(item => {
    if (!item.quantity || item.quantity <= 0) return;          // 0'lar atlanır
    const tpl = document.querySelector('.offer-row').cloneNode(true);
    tpl.querySelector('.combo-hidden').value      = item.product_id || '';   // product_id[]
    tpl.querySelector('.combo-name-hidden').value = item.material_name;      // product_name[]
    tpl.querySelector('.or-qty').value   = item.quantity;                    // ham float
    tpl.querySelector('.or-price').value = item.unit_price;
    tpl.querySelector('.or-total').value = (item.quantity * item.unit_price).toFixed(2); // JS'te yeniden çarpım
    tpl.querySelector('.row-section-label').value = label;                   // section_label[]
    tpl.querySelector('.row-category-slug').value = this._lastCategorySlug;  // category_slug[]
    document.getElementById('offer-rows').appendChild(tpl);
});
```

- **Tekil / tümü / çoklu:** Tekil kalem seçimi yok; her tıklama sonuçtaki **tüm** kalemleri ekler. İstenildiği kadar bölüm ardışık eklenir.
- **Aynı malzeme birleştirilir mi? HAYIR.** Mevcut satırı `product_id`/ad ile arayıp miktar toplayan hiçbir kod yok (ne JS'te ne `offer_routes.py` POST'unda). İki bölümden gelen "Çelik Dübel" → **iki ayrı satır** (farklı `section_label`).
- **Birim satıra yazılmaz** (`.offer-row`'da birim alanı yok).
- Kroki: çizim modunda `sekilEkizleri` → gizli `#shape-sketches-json` → `offer_doc["shape_sketches"]` (`offer_routes.py:55-109`, sınırlar: 20 kroki, 20 şekil/kroki, 200 nokta/şekil, `image_b64` ≤ 3 MB). Revizyon snapshot'ı krokileri içermez (`:244-245`).
- Revizede `section_label[]`/`category_slug[]` gizli alanları prefill edilir (`offer_create.html:495-496`), korunur; PDF'te `section_label` yalnızca kroki başlığında kullanılır (`offer_pdf.html:520-521`).
- **Dikkat:** `.or-qty` `type="number" step="0.01"` (`:508`); `rounding_type="none"` + kesirli katsayı ham float üretir (ör. `61.666…`). TAHMİN: HTML5 step doğrulaması gönderimi engelleyebilir; kod bunu ele almıyor.

---

## 8. Web vs Mobil

| Konu | Web (Teklif paneli) | Mobil |
|---|---|---|
| Hesaplama yeri | **Sunucu** (`calculate_material_list`) | **Sunucu** (aynı fonksiyon) — cihazda miktar/fire/fiyat aritmetiği **yok** (`hesaplama_ekrani.dart:9-11` yorumu; dosyada yalnızca `tryParse`/biçimleme) |
| İstemci matematiği | Poligon alanı (shoelace), ölçek², en×boy, çatı eğimi `/cos`, satır toplamı `qty*price` | Yalnızca teklif formunda canlı toplam `miktar×fiyat`, KDV (`teklif_olustur_ekrani.dart:56-59,130-138`) |
| Uç nokta | `POST /calculations/api/calculate` (session) | `POST /api/calculate`, `GET /api/calculations` (Bearer; base `https://app.byzdizayn.com.tr/api`, `api.dart:19-23`) |
| Girdi | alan (çizim/en×boy/m²) → **yalnızca `area`** | alan **veya** en×boy → `area` ya da `width`+`height` |
| Çevre | asla | en×boy modunda sunucu hesaplar (seed'de kullanan kalem yok) |
| Çatı eğimi | var (istemci) | **yok** |
| Kroki | var, teklife kaydedilir | yok ("kroki webde kalır", `teklif_olustur_ekrani.dart:11`) |
| Çoklu bölüm | ardışık ekleme, `section_label` | yerel biriktirme, etiket teklife **taşınmaz** |
| Teklife taşınan alanlar | `product_id, product_name, quantity, unit_price, section_label, category_slug` | **yalnızca** `product_name, quantity, unit_price` (`hesaplama_ekrani.dart:157-160`) → `urunId = null` (`teklif_olustur_ekrani.dart:87-96`) |
| Birleştirme | yok | yok (düz spread `:189-192`) |
| Sonuç düzenleme | teklif satırında | hesaplama ekranında yok; teklif formunda var |
| **Sözleşme hatası** | — | Mobil `_sonuc['area']` okur (`:168, :309`); motor alanı **`input.area`** altında döndürür (`:310-315`) → gerçek backend'de başlık `"10x10 Petek Tavan —  m²"` (boş). Demo verisi üst düzey `'area': 100.0` verdiği için (`demo_veri.dart:361`) demo'da fark edilmez. **Doğrulanmış bug.** |

Ek mobil notları: `Authorization: Bearer null` null token'da (`api.dart:97`); aktarım sonrası `_eklenenler` temizlenmez (ikinci teklife tekrar aktarılabilir); demo modu derleme zamanı sabiti (`--dart-define=DEMO=true`), `/calculate` mock'u her zaman "Taşyünü Tavan" döner.

---

## 9. Grup / kategori / reçete yönetimi

- **Admin UI: YOK.** `routes/` ve `templates/` altında `calculation_*` koleksiyonlarını yazan hiçbir ekran yok (yalnızca `products` CRUD var: `product_routes.py:233-300`). Kod yorumu bunu açıkça söyler: "*bu alanları düzenleyen bir admin ekranı olmadığından mevcut kayıtları da kod ile senkronize etmek güvenli*" (`:2385-2390`).
- **Kaynak-doğru = kod.** `seed_calculation_data()` her `create_app()` çağrısında (her gunicorn worker açılışında, `fcntl` kilidiyle sıralı) çalışır (`app.py:105-108`). Gruplar/kategoriler `UpdateOne(upsert=True, $set)`; reçeteler mevcutsa `$set` (`product_id, quantity_per_m2, rounding_type, group_name, sort_order, unit_price`), yoksa `InsertOne`; tek `bulk_write` (`:2431-2432`).
- **Kullanıcı düzenlemeleri:** DB'de elle yapılan `qty`/`round`/`price`/`name`/`is_active(grup-kategori)`/`image` değişiklikleri **her açılışta ezilir**. Ezilmeyen reçete alanları: `calculation_type`, `quantity_per_meter`, `fixed_quantity`, `waste_percentage`, `is_active`, `material_name` (update `$set` listesinde yok). Seed **hiçbir kaydı silmez**; koddan çıkarılan kalem DB'de aktif kalır (TAHMİN: bu senaryo henüz yaşanmamış).
- **Ürün fiyatları** son kullanıcı tarafından `/products` ekranından yönetilir; reçete katsayıları yalnızca geliştirici (kod değişikliği + deploy) tarafından.
- Tek çalışma-zamanı yazıcısı `_resolve_recipe_products` (`product_id` onarımı + 0 TL fiyat onarımı).

---

## 10. Örnek hesap — 20 m², `10x10-petek-tavan` (gerçek seed verisi)

Veri kaynağı: repoda **yalnızca kod sabiti** olarak var (`:1388-1398`); Mongo dump/JSON export **yok**; test fixture yok. Miktar tarafı kesindir; **fiyatlar çalışma zamanında `products`'tan okunur** — aşağıda "seed referans fiyatı = canlı fiyat" varsayımıyla (canlıda farklı olabilir).

Girdi: `{"category_slug": "10x10-petek-tavan", "area": 20}` → `calculated_area = 20.0`, `perimeter_val = None`. Her kalem `area_based`, `rounding_type="none"` → `final = float(20.0 × qty)`; fire/min/ceil adımı **yok**.

| # | Malzeme | Birim | qty/m² | 20 × qty | `quantity_display` | Ref. fiyat | `line_total` |
|---|---|---|---|---|---|---|---|
| 1 | 10x10 Petek Tavan | adet | 5 | 100.0 | "100 adet" | 230 | 23.000,00 |
| 2 | 3600 mm Ana Taşıyıcı | adet | 1 | 20.0 | "20 adet" | 110 | 2.200,00 |
| 3 | Tali Taşıyıcı 60cm | adet | 6 | 120.0 | "120 adet" | 30 | 3.600,00 |
| 4 | Tali Taşıyıcı 120cm | adet | 6 | 120.0 | "120 adet" | 60 | 7.200,00 |
| 5 | L Köşebent 3000 mm | adet | 2 | 40.0 | "40 adet" | 70 | 2.800,00 |
| 6 | Çelik Dübel | adet | 3 | 60.0 | "60 adet" | 4 | 240,00 |
| 7 | Askı Teli 40cm | adet | 6 | 120.0 | "120 adet" | 4 | 480,00 |
| 8 | Çift Yaylı Maşa | adet | 3 | 60.0 | "60 adet" | 3 | 180,00 |
| 9 | Dübel Vida | paket | 1 | 20.0 | "20 paket" | 170 | 3.400,00 |
| | | | | | | **Toplam** | **43.100,00 TL** |

`total_cost = 43100.0` → `"43.100,00 TL"`. Tüm ara değerler tam sayı olduğundan yuvarlama etkisi yok. Genel formül: `100·P1 + 20·P2 + 120·P3 + 120·P4 + 40·P5 + 60·P6 + 120·P7 + 60·P8 + 20·P9`.

**En=5, Boy=4 gönderilse:** `calculated_area = 20.0`, `perimeter_val = 18.0`; reçetede çevre-bazlı kalem olmadığı için sonuç **birebir aynı**; yalnızca `input.perimeter: 18.0` döner. "L Köşebent" `group_name="Perimeter"` etiketli olsa da 2 adet/m² olarak alanla çarpılır (TAHMİN: çevre-bazlı olması amaçlanmış, uygulanmamış).

**`ceil` örneği (seed'den):** `3cm Taşyünü`, paket, `qty = 1/3.6` → 10.8 m² × (1/3.6) = `3.0000000000000004` → `round(…, 9)` = 3.0 → `ceil` = **3 paket** (koruma olmasa 4 çıkardı, `:174-177`).

**Veri kalitesi gözlemi (koddan aritmetik):** 60x60 panel 0,36 m² → teorik 2,78 adet/m², seed 5; "Dübel Vida" 1 paket/m² → 100 m²'de 100 paket; "Alçıpan" 1 adet/m² (levha 3 m²). TAHMİN: bu değerler gerçek metraj değil, referans-alan/“en az 1 paket” niyetiyle girilmiş; kod bunu normalize etmez. Çatı grubundaki bazı katsayıların bilinçli olarak dokunulmadığı yorumda belirtilmiş (`:1612-1614`).

---

## 11. Sorunlar ve teknik borç

### 11.1 Hesaplama semantiği
1. **Fire yok** — `waste_percentage` yazılır, okunmaz. Dalsan reçeteleri "%5 fire dahil" katsayılarla girilmiş (`:1817-1818` yorumu), diğer gruplar için fire hiç yok.
2. **Çevre-bazlı kalem fiilen imkânsız**: web ve mobil alan modunda `area` gönderir → `perimeter_val=None`; en/boy+alan birlikte gelse bile çevre hesaplanmaz (`:241-247`). `perimeter_based`/`fixed` dalları seed'de hiç kullanılmaz → ölü yol.
3. Sessiz sıfırlar: bilinmeyen `calculation_type`, çözülemeyen ürün (0 TL), çevre yok → uyarısız 0; yanıtta `warnings` yok.
4. Çatı eğimi yalnızca istemcide (`offer_create.html:1328`) → mobil bunu hiç uygulayamaz; iki kanal aynı çatı için farklı sonuç üretir.
5. Sabit-paket kalemleri iki farklı kalıpla modellenmiş: `1/kapsam + ceil` (7 malzeme) vs `1 paket/m²` (Dübel Vida vb.).
6. Birim karmaşası `m2`/`m²`/`metre`/`m`; aynı ad farklı birim → ayrı ürün (`Derz Bandı` adet/m, `Shingle` paket/adet); aynı (ad,birim) çelişen seed fiyatı (`Çelik Dübel` 4 vs 0) — ürün ilk görülen fiyatı alır (`:2315 setdefault`).

### 11.2 Kayan nokta / yuvarlama
7. `total_cost` yuvarlanmamış satırlarla birikir, satırlar ayrı yuvarlanır (`:287-297,317`) → görünen satır toplamı ≠ görünen toplam (±0,01).
8. `rounding_type="none"` ham float (`33.480000000000004`) JSON `quantity`'ye ve teklif miktar kutusuna aynen gider (`offer_create.html:1424`); mobil de ham `quantity`'yi teklife yazar (`hesaplama_ekrani.dart:159`) → gösterilen ≠ kaydedilen.
9. `round(value, 2)` Python banker's; JS `.toFixed(2)` farklı yarım davranışı → JS özet ile sunucu `subtotal/vat` kuruş düzeyinde ayrışabilir (`offer_create.html:711-724` vs `offer_routes.py:179`, `calculation_service.py:52-60`).
10. `quantity` tipi tutarsız (`none` → float, `ceil` → int); `_format_quantity` nokta, `_format_money` virgül ondalık.
11. `inf`/`nan` kabul edilir → 500. `unit_price` DB'de `None`/string ise `TypeError`/string tekrarı (`:287`).

### 11.3 Sabit değerler / kod tekrarı / ölü kod
12. 2.112 satırlık seed sabiti fonksiyon gövdesinde (`:336-2265`); `"60x60-asma-tavanlar"` fallback slug (`calculation_routes.py:22`) → aktif grup yoksa **sonsuz 302 döngüsü** (`:14-32`); `"Hesaplama Malzemesi"` literali 4 yerde; `"TL"` sabit.
13. Float parse **4 yerde** (`calculation_routes.py:64-67, 120-126`; `api_routes.py:1674-1681`; servis `:229-237`); iki JSON ucu satır satır aynı; ürün-bul-yoksa-yarat kuralı 3 yerde (`product_service.py:35-87`, seed `:2311-2359`, `_resolve_recipe_products`); para biçimleme 3 yerde; satır tutarı JS'te yeniden çarpılıyor (`:1426`).
14. Ölü: `static/js/calculations.js` (hiçbir şablon yüklemiyor, hedef sınıflar yok), `find_recipe_item`, `get_calculation_categories`, `product_service.get_product_by_id/update_product_price`, `metraj()`'ın `kesitler=` parametresi (şablon kullanmıyor), `/metraj/calculate` asma_tavan dalı (UI hep `[]` gönderir), `.btn-metraj-ekle/.btn-urune-ekle` CSS'i, `routes/__pycache__/calculation_routes_v2.cpython-3xx.pyc` (kaynak `.py` git geçmişinde **hiç yok**; `2bb3edc` ile index'ten çıkarıldı, diskte duruyor).
15. `services/calculation_service.py` (903 satır) teklif/KPI/maaş hesaplarıdır, malzeme hesabıyla ilgisi yok — `calculation_routes.py`/`calculation_bp`/`material_calculation_service.py` ile isim çakışması.

### 11.4 Performans
16. Her worker açılışında tam seed: ~814 `UpdateOne` koşulsuz `$set` + ürün sorguları (`:2300-2432`; yorum "453 kalem" bayat).
17. Her sayfa render'ında menü için `calculation_groups` sorgusu (`app.py:139-154`); teklif formunda ek 2 sorgu.
18. **Okuma yolunda yazma**: `_resolve_recipe_products` her hesaplamada `products.update_one` / `insert_one` / `recipes.update_one` tetikleyebilir, girdi doğrulamasından **önce** (`:221`). Bozuk `product_id`'de birime göre tam koleksiyon taraması (`product_service.py:49`).
19. `calculation_recipes` için `(category_slug, is_active, sort_order)` bileşik indeks yok; `slug` alanlarında unique yok.

### 11.5 Güvenlik/sözleşme
20. `/calculations/api/calculate` **session** ile korunuyor; oturumsuz `fetch` 302+HTML alır, JS `response.json()` hatası (TAHMİN). Projede CSRF yok.
21. Mobil `area` anahtarı uyumsuzluğu (§8) — doğrulanmış bug.

### 11.6 `metraj_routes.py` (devre dışı) vs `calculation_routes.py` (aktif) — tam açıklama

| | Eski motor `routes/metraj_routes.py` | Yeni motor `calculation_routes.py` + `material_calculation_service.py` |
|---|---|---|
| Veri | Kod içine gömülü 3 sözlük: `ASMA_TAVAN_KESITLER` (`:8-138`), `BOLME_DUVAR_MODELLERI` (`:141-254`), `GIYDIRIME_DUVAR_MODELLERI` (`:257-344`); **DB yok** | Mongo reçeteleri |
| Formül | `miktar = m² × per_m2`; birim `m2`/`m` ise `× (1 + 0.05)` fire (`:382-387`); fiyat yok | `alan × quantity_per_m2`; fire **yok**; fiyat `products`'tan |
| Son içerik değişikliği | `36d94e0` (2026-06-04) | `eea9d37` (2026-06-08) oluşturuldu; `ba90d75` (2026-07-14) teklif sekmesi bu motora geçti; `aa273ed/8230109/23b2084` (2026-08-18) Dalsan reçeteleri seed'e taşındı |

`config.py:22-28` `ENABLE_STANDALONE_METRAJ = False` (env değil, sabit). **Tek guard `GET /metraj` view'ında** (`metraj_routes.py:357-363` → `offers.create_offer`'a redirect). **Dört POST ucu guard'sız ve canlı:** `/metraj/asma-tavan/<id>`, `/metraj/bolme-duvar/<id>`, `/metraj/giydirime-duvar/<id>`, `/metraj/calculate` (`:368-476`, yalnızca `@login_required`); `metraj_bp` koşulsuz kayıtlı (`app.py:119`). `metraj.html` bayrak kapalıyken hiç render edilmez; `offer_create.html` ve mobil `/metraj`'a hiç referans vermez. `config.py:25-27` yorumu ("sekme `calculate_asma_tavan` kullanır") `ba90d75`'ten beri **bayat**; `METRAJ_DISABLE_NOTE.md`'nin üst kısmı düzeltiyor, alt kısmı düzeltmiyor.

**Aynı Dalsan tablosu iki motorda farklı sonuç verir:** eski `tek-tek-12-15mm` (`metraj_routes.py:142-156`) ile yeni `dalsan-bolme-duvar-tek-kat-125-60` (`:1821-1831`) katsayıları birebir aynı, ama eski motor üstüne 1,05 uygular. 100 m² alçı levha: eski 220,5 m², yeni 210 m². TAHMİN: Dalsan katsayıları gerçekten fire dahilse eski motor fire'ı iki kez uyguluyordu.

### 11.7 Doküman ↔ kod (özet)
`HESAPLAMALAR_*.md` dosyaları `calculation_routes_v2.py`, `seed.py`, `calculation_detail.html`, `calculations_list.html`, `calculation_materials` koleksiyonu, "Fire Oranı input", `ensure_recipe_products_exist()` gibi **kodda olmayan** şeyleri anlatır; rota yolları (`/calculations/<slug>`) yanlıştır; `PROJE_DOKUMANTASYONU.md` "metraj kodu kullanılmıyor" der (4 POST canlı). Dokümanlarda düz metin admin parolası var (`HESAPLAMALAR_MODUL.md:224`).

---

## 12. ARVEND'e taşıma planı

ARVEND'in mevcut zeminine göre yazıldı: Go + chi + sqlc + pgx, `numeric(18,2)` para, `organization_id NOT NULL` çok-kiracılık, `products(id uuid, organization_id, name, normalized_name, unit, unit_price numeric(18,2), category, source, source_price)` (`backend/db/migrations/0003`, `0011`, `0026`), `offer_revision_items(revision_id, product_id, product_name, quantity numeric(12,2), unit_price, discount_*, line_total, sort_order)` (`0017`).

### 12.1 Olduğu gibi taşınabilecekler (kavram düzeyinde)
- Üç katmanlı model **Grup → Kategori → Reçete kalemi** ve "kategori = hesaplanabilir sistem, kalem = malzeme × katsayı".
- Üç `calculation_type` (`area_based`, `perimeter_based`, `fixed`) ve üç `rounding_type` (`none`, `ceil`, `round`); `1/paket_kapsamı + ceil` kalıbı.
- "Fiyat çalışma zamanında katalogdan, ad/birim reçeteden" ilkesi (ama teklife girerken **snapshot**).
- Tek motor, tek uç nokta, web ve mobil aynı yanıtı okur (BYZ'deki en doğru karar).
- Çizim aracı (shoelace, ölçek, çoklu şekil, kroki PNG) — React canvas bileşeni olarak; alanla birlikte **çevreyi de** hesaplayıp göndermeli.
- 814 kalemlik reçete içeriği — kaynak veri olarak (aşağıdaki temizlikle).

### 12.2 Yeniden tasarlanacaklar
- **Fire:** `waste_percent` gerçek bir alan; formül `alan × katsayı × (1 + fire/100)` → yuvarlama → min/paket. Dalsan "fire dahil" katsayıları için `waste_percent = 0` ve reçete üzerinde `notes = "katsayılar %5 fire dahil"`.
- **Min miktar / paket:** `min_quantity`, `package_size` alanları; `ceil(miktar / package_size) × package_size`.
- **Çevre:** istemci poligon çevresini hesaplayıp gönderir; en×boy'dan da türetilir; verilmezse çevre-bazlı kalemler **`warnings[]`** ile raporlanır, sessiz 0 yok.
- **Çatı eğimi:** `pitch_deg` istek alanı, çarpan **sunucuda** (`alan / cos`) → mobil de alır; yanıt `footprint_area` ve `effective_area` ikisini döner.
- **Birim sözlüğü:** `unit` serbest metin yerine sabit küme (`adet, m, m2, kg, paket, torba, rulo, set, teneke, m3, top`), `m²→m2`, `metre→m` normalizasyonu import'ta.
- **Uyarılar/tip tutarlılığı:** `quantity` her zaman `numeric` string; `warnings: [{code, item_id, message}]`.
- **Yönetim ekranı:** admin rolü için grup/kategori/reçete CRUD (ARVEND `(admin)` route grubu); seed **tek seferlik** provisioning verisi, "kod kaynak-doğru + her açılışta ez" modeli **taşınmaz**.
- **Okuma yolunda yazma yok:** motor salt okur; ürün eksikse `warnings` + `product_id NULL`, ürün yaratma yalnızca kullanıcı onayıyla ayrı uç noktadan.
- **Aritmetik:** Faz 8'deki emsalle tutarlı — `numeric` hesap **SQL'de** (`$area::numeric * quantity_per_m2`, `CEIL/ROUND`), Go tarafında float64 yok; satır toplamı yuvarlanmış `line_total`'ların toplamı (görünen = kaydedilen).

### 12.3 PostgreSQL şeması (öneri, `organization_id` her tabloda)

```sql
CREATE TABLE calc_groups (
  id uuid PK, organization_id uuid NOT NULL REFERENCES organizations(id),
  slug varchar(80) NOT NULL, name varchar(120) NOT NULL, description text NOT NULL DEFAULT '',
  sort_order int NOT NULL DEFAULT 0, is_active boolean NOT NULL DEFAULT true,
  created_at/updated_at timestamptz, UNIQUE (organization_id, slug));

CREATE TABLE calc_categories (
  id uuid PK, organization_id uuid NOT NULL, group_id uuid NOT NULL REFERENCES calc_groups(id) ON DELETE RESTRICT,
  slug varchar(80) NOT NULL, name varchar(160) NOT NULL, description text NOT NULL DEFAULT '',
  image_file_id uuid NULL,                     -- kesit görseli: mevcut dosya altyapısı
  sort_order int, is_active boolean, created_at/updated_at, UNIQUE (organization_id, slug));

CREATE TABLE calc_recipe_items (
  id uuid PK, organization_id uuid NOT NULL, category_id uuid NOT NULL REFERENCES calc_categories(id) ON DELETE CASCADE,
  product_id uuid NULL REFERENCES products(id) ON DELETE SET NULL,
  material_name varchar(200) NOT NULL, unit varchar(30) NOT NULL,
  calculation_type varchar(20) NOT NULL CHECK (calculation_type IN ('area_based','perimeter_based','fixed')),
  quantity_per_m2    numeric(14,6) NOT NULL DEFAULT 0,   -- 1/3.6 gibi kesirler için 6 hane
  quantity_per_meter numeric(14,6) NOT NULL DEFAULT 0,
  fixed_quantity     numeric(14,4) NOT NULL DEFAULT 0,
  waste_percent      numeric(5,2)  NOT NULL DEFAULT 0,
  rounding_type varchar(10) NOT NULL DEFAULT 'none' CHECK (rounding_type IN ('none','ceil','round')),
  min_quantity numeric(14,4) NOT NULL DEFAULT 0, package_size numeric(14,4) NULL,
  reference_unit_price numeric(18,2) NOT NULL DEFAULT 0, group_name varchar(60) NOT NULL DEFAULT '',
  sort_order int, is_active boolean, notes text NOT NULL DEFAULT '', created_at/updated_at);
CREATE INDEX ON calc_recipe_items (category_id, is_active, sort_order);
```
Kiracılık kararı: reçeteler **firma sahipli kopya** (organization provisioning'de fixture'dan kopyalanır) — ARVEND'in mevcut izolasyon deseniyle tutarlı, admin düzenlemesi firmaya özel. Alternatif (global şablon `organization_id NULL` + firma override) daha az veri ama daha karmaşık sorgu; ilk sürüm için önerilmez.

### 12.4 API (öneri)
- `GET /api/v1/calculations/groups` → gruplar + kategoriler (yalnızca `id, slug, name, image_url`).
- `POST /api/v1/calculations/run` → `{category_id, area?, width?, height?, perimeter?, pitch_deg?}` → `{category, input{footprint_area, effective_area, perimeter}, items[{recipe_item_id, product_id, material_name, unit, quantity, unit_price, line_total, group_name}], total_cost, warnings[]}`; miktar/para alanları string decimal.
- Admin: `/api/v1/admin/calculations/{groups|categories|recipe-items}` CRUD.
- Tek uç nokta, web+mobil ortak; JWT/cookie auth mevcut ARVEND deseniyle (BYZ'deki session-korumalı JSON ucu taşınmaz).

### 12.5 Ürün kataloğu bağı
- `calc_recipe_items.product_id → products(id)` **aynı organization** (FK + sorguda `organization_id` eşitliği).
- Fiyat çalışma zamanında `products.unit_price`; ürün silinirse `SET NULL` → motor `warnings: product_missing`, `unit_price = 0`.
- Import'ta ürün eşleme `(organization_id, normalized_name, unit)`; ARVEND `products.normalized_name` zaten var. BYZ'deki "0 TL onarımı"/"yoksa yarat" yan etkileri **taşınmaz**; import raporu eksik/0 TL ürünleri listeler.
- Ulaş senkronu benzeri bir şey gelirse `source`/`source_price` kolonları zaten hazır; reçete ürünleri `category='Hesaplama Malzemesi'` yerine ayrı bir `is_calculation_material` bayrağı (TAHMİN: kategoriye string bağımlılığı BYZ'de sürekli sorun çıkardı).

### 12.6 Teklif / proje entegrasyonu
- `offer_revision_items`'a eklenecek: `unit varchar(30)`, `section_label varchar(120)`, `calc_category_id uuid NULL`, `calc_snapshot jsonb NULL` (`{area, perimeter, pitch_deg, factor, waste_percent, rounding_type, product_unit_price_at_calc}`) — hesap izlenebilir, fiyat snapshot'ı korunur.
- "Metraj Hesapla" paneli Teklif formunda sağ panel/sekme olarak; **"Bu bölümü ekle"** + **"Aynı malzemeyi birleştir"** seçeneği (varsayılan kapalı, BYZ davranışı korunur; açıkken `(product_id ?? material_name, unit)` anahtarıyla miktar toplanır).
- Kroki: `offer_sketches` tablosu (`offer_id, section_label, category_id, footprint_area, pitch_deg, effective_area, scale, shapes jsonb, file_id`) — PNG mevcut dosya depolamasında, base64 kolon yok.
- Proje tarafı: aynı panel **Ek İş (change order)** kalemleri için; hesaplanan malzeme listesi projede "planlanan malzeme" olarak saklanıp `Masraflar` ile karşılaştırılabilir (tahmini vs gerçekleşen malzeme maliyeti) — sonraki faz.

### 12.7 Veri taşıma ve doğrulama
1. Tek seferlik script: `material_calculation_service.py` içindeki `groups_to_seed / group_assignments / categories_to_seed / recipes_per_category` sabitlerini `backend/db/seed/calc_recipes.json`'a çıkar (Python'da import edip `json.dump`; canlı Mongo'ya gerek yok).
2. Temizlik listesi (iş sahibiyle): birim normalizasyonu; `Shingle` adet/paket, `Derz Bandı` adet/m, `Çelik Dübel` 4/0 çelişkileri; `Dübel Vida` 1 paket/m² → `1/kapsam + ceil`; 60x60/petek 5 adet/m² doğrulaması; `L Köşebent` → `perimeter_based`; `Hazır Cephe Kaplaması` 2 m²/m²; `Onduline Mahyasi` yazım.
3. **Altın testler** bu rapordan: 20 m² petek → `100/20/120/120/40/60/120/60/20`, toplam 43.100,00; 10,8 m² × 1/3.6 → 3 paket; en=5 boy=4 → çevre 18; yarım-yuvarlama (`2.675`) davranışı numeric ile deterministik; çevre verilmeden `perimeter_based` → warning.
4. ARVEND'e taşınmayacaklar: `metraj_routes.py` (eski motor), açılışta seed, okuma yolunda yazma, `calculations.js`, dokümanlardaki bayat rotalar.
