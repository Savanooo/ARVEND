# Elektrik ürün fiyat kaynakları (ARVEND fiyat senkronu için)

Araştırma tarihi: 29.10.2026. Yöntem: her siteyi açtım (curl, WebFetch, gerekirse tarayıcı). PDF'ler için HTTP başlıklarına baktım (Last-Modified ve boyut). 10 MB altındaki PDF'lerin metnini `pdftotext` ile çıkarıp içini okudum. "Doğrulanmadı" yazan her şey arama sonucuna ya da erişilemeyen bir siteye dayanıyor.

## Kısa sonuç

- **Hemen bağlanabilecek en iyi kaynaklar üreticilerin herkese açık PDF fiyat listeleri:** Hes Kablo, Öznur Kablo ve Makel. Üçü de güncel (2026), giriş istemiyor, PDF'te metin katmanı var, fiyatlar TL ve KDV hariç (Makel'de KDV ibaresi bulunamadı). robots.txt hiçbirinde engel koymuyor.
- **Büyük markalar listeyi form ya da bayi portalının arkasında tutuyor:** Viko/Panasonic ve Legrand formla veriyor. Schneider, ABB, Siemens ve Hager'in kamuya açık güncel bir listesi yok. Bunlar için izin ya da bayi hesabı şart.
- **Çevrimiçi satıcıların fiyatı perakende ve KDV dahil.** Schneider e-mağaza kullanım şartlarında robotu açıkça yasaklıyor. Kablocu izinsiz kopyalamayı yasaklıyor. Elektromarketim'de açık bir yasak bulamadım, yine de izin almak doğru olur.
- **Herkese açık, elektriğe özgü bir "bayi XML" akışı ilan eden distribütör bulamadım.** XML ya da Excel ancak bayi olunca veriliyor; Horoz B2B'de "Ürün Listesini İndir (Excel)" özelliği var.
- **ÇŞB, TEDAŞ ve birimfiyat birim fiyatları lisanslı.** İzinsiz içe aktarılamaz; önceki bulgu elektrik pozları için de geçerli.

## Teknik not (ARVEND'e özgü)

- `pricesource.go` gövdeyi `maxBodyBytes = 5 << 20` (5 MiB) ile sınırlıyor. Makel PDF'i ~8,4 MiB, Hes PDF'i 5.279.918 bayt (5 MiB'ın biraz üstü). Bu yüzden `fetchSpec`'e kaynak başına bir boyut sınırı eklenmeli. Viko ~28 MiB, Mutlusan ~58 MiB, Pelsan ~43 MiB.
- Repoda PDF okuyan bir kütüphane yok; `go.mod`'daki `go-pdf/fpdf` yalnızca PDF üretiyor. Bir metin çıkarıcı gerekecek: Go kütüphanesi ya da sunucuda `pdftotext -layout`.
- Kablo listeleri **TL/km** veriyor. Ürün birimi "m" olacaksa fiyatı 1000'e bölmek gerekir.
- Bunların hepsi **liste fiyatı**. Makel iskonto oranlarının bayiden öğrenileceğini yazıyor; kabloda da gerçek alış fiyatı listenin çok altında olabilir. Ekranda "liste fiyatı" diye etiketlenmeli ya da firma bazında bir iskonto oranı tanımlanabilmeli.
- Dosya adları her dönem değişiyor (ör. Makel `2026-2_6471777361.pdf`). Bu yüzden önce sabit bir liste sayfası indirilip PDF bağlantısı oradan bulunmalı. Host allowlist mantığı aynen korunur.

## 1. Üretici fiyat listeleri

| Kaynak | Kapsam | Adres, format, tarih | Fiyat tipi | Erişim ve hukuki durum | Skor |
|---|---|---|---|---|---|
| **Hes Kablo** | NYA/NYAF, NYM, TTR (H05VV-F), NYY, N2XH/halojensiz, kumanda, OG kabloları | https://www.hes.com.tr/fiyat-listeleri sayfasından `/assets/images/temp/Fiyat_Listeleri_2026.pdf`. 51 sayfa, 5,3 MB, Last-Modified 16.10.2026. Metin katmanı var (~1.000+ kesit satırı) | TL/km, liste fiyatı; sayfalarda KDV hariç olduğu yazıyor | Giriş yok. robots.txt yok (404). Kullanım şartı sayfası görmedim. Not: dosya `temp` klasöründe, adres değişebilir | **4** |
| **Öznur Kablo** | Hes ile aynı kablo tipleri, ayrıca alüminyum ve OG | https://www.oznurkablo.com.tr sayfasından `/upl/fiyat-listesi-Haziran-2026.pdf`. 36 sayfa, 4,7 MB, Last-Modified 03.06.2026. Metin katmanı var (~1.100 satır) | TL/km, KDV hariç | Giriş yok. robots.txt'de `User-agent: *` için engel yok | **4** |
| **Makel** | Anahtar-priz (Cellia, Lumia, Modüler, Manolya, Defne...), otomatik sigorta, kaçak akım, kompakt şalter, kontaktör, röle, sigorta kutusu, grup priz, LED | https://www.makel.com.tr/tr/cozum-merkezi/fiyat-listesi sayfasından `/Download/files/2026-2_6471777361.pdf`. 33 sayfa, 8,8 MB, Last-Modified 11.06.2026. Listede 9 Haziran 2026'dan itibaren verilen siparişler için geçerli olduğu yazıyor. Metin katmanı var ama iki sütunlu düzen ve renk başına fiyat kolonları var (Beyaz/Siyah/Renkli) | TL. 90 gün vade esaslı liste; iskonto bayiden. KDV ibaresi bulunamadı (büyük ihtimalle KDV hariç, doğrulanmalı) | Giriş yok. robots.txt `Allow: /` (yalnızca birkaç PDF yasaklı). Yılda 2 dönem | **4** |
| **Viko (Panasonic)** | Anahtar-priz (Karre, Linnera...), grup priz, buat/kasa, kablo kanalı, LED | https://ewtr.panasonic.com/fiyat-listeleri sayfasından `/Uploads/File/panasonic_viko_fiyat_listesi_2026-2.pdf`. ~29 MB, Last-Modified 11.08.2026. Metin katmanı **doğrulanmadı** (dosya inceleme sınırımın üstünde) | Doğrulanmadı | Site, listeye erişmek için bir kereye mahsus iletişim bilgisi istiyor (sayfada form var). Dosya adresi teknik olarak açık ama form atlanarak otomatik indirmek doğru olmaz, **izin gerekli**. robots.txt yalnızca sorgu parametrelerini kapatıyor | **3** |
| **Mutlusan** | Anahtar-priz, grup priz, sigorta kutusu, buat | https://www.mutlusan.com.tr/tr/sayfa/75/e-fiyat-listesi sayfasından `/Upload/04082026_fiyat_listesi.pdf`. ~60 MB, Last-Modified 15.10.2026. Metin katmanı doğrulanmadı | Doğrulanmadı | Giriş yok. robots.txt yok | **3** |
| **Pelsan Aydınlatma** | LED panel, armatür | https://pelsan.com.tr/fiyat-listeleri sayfasından `storage/documents/5080921792660975.pdf`. ~45 MB, Last-Modified 22.10.2026. Metin katmanı doğrulanmadı. Dosya adı rastgele, sayfadan okunmalı | Doğrulanmadı | Giriş yok. robots.txt yok (HTML dönüyor) | **3** |
| **Cata (Uğur Aydınlatma)** | LED panel, spot, armatür, acil aydınlatma | https://cata.com.tr/katalog sayfasında "2026 Fiyat Listemize Göz Atın" bağlantısı. PDF ~34 MB, Last-Modified 24.03.2026. Ürün sayfalarında fiyat yok | Doğrulanmadı | robots.txt `Allow: /` | **2-3** |
| **Legrand Türkiye** | Anahtar-priz, şalt | https://www.legrand.com.tr/fiyatlisteleri.php. Güncel liste ancak form doldurunca veriliyor (ad, e-posta, meslek). Açıkta duran dosyalar 2020'den: `anahtarpriz2020.pdf`, `salt2020.pdf`, `legrand-bim.xlsx` | — | Form ya da izin | **1-2** |
| **Schneider Electric TR** | Acti9, şalt, Easy9 vb. | se.com/tr bize 403 verdi. Arama sonucuna göre AG listesi formla veriliyor ve 25.11.2024 tarihli (**doğrulanmadı**) | — | Form ya da izin | **1** |
| **ABB Türkiye** | Sigorta, anahtar-priz | Arama sonucunda yalnızca `2021-tesisat-urunleri-fiyat-listesi.pdf` (Aralık 2020) çıktı. new.abb.com buradan açılmadı (**doğrulanmadı**) | Tavsiye edilen satış fiyatı (snippet) | Güncel liste yok | **1** |
| **Siemens TR** | Sentron | Industry Mall ürün sayfası 403 verdi. Snippet'e göre fiyat giriş yapınca görünüyor (**doğrulanmadı**) | — | Giriş gerekli | **1** |
| **Hager TR** | Pano, sigorta | hager.com/tr-tr ürün sayfası açıldı, fiyat yok | — | — | **1** |
| **Prysmian TR** | Kablo | tr.prysmian.com'da yalnızca katalog var (`Enerji_Katalog.pdf`, 2025-08). Fiyat listesi bulunamadı | — | — | **1** |
| **Günsan** | Anahtar-priz | gunsanelectric.com buradan 403 verdi (gunsan.com.tr başka bir firma, yay üreticisi). Kamuya açık liste **bulunamadı/doğrulanmadı** | — | — | **?** |
| **Horoz Elektrik / Noas** | LED aydınlatma | https://b2b.horozelektrik.com ve https://b2b.noas.com.tr bayi girişi istiyor. Horoz'da "Yeni Bayi Kayıt" (VKN/TCKN) ve "Ürün Listesini İndir (Excel)" var | Bayi fiyatı (iskontolu) | Bayi sözleşmesi gerekli | **3** (bayi olunca) |

## 2. Çevrimiçi toptan ve perakende siteler

| Site | Kapsam | Veri ve format | Fiyat tipi | robots ve kullanım şartları | Skor |
|---|---|---|---|---|---|
| **Elektromarketim** (Ümelsan Elk., Yalova; T-Soft altyapısı) https://www.elektromarketim.com | Schneider, Legrand, Siemens, Wago, Viko, kablo (Öznur, Erse...), aydınlatma; el aletleri de var | `sitemap.xml` içinde `product.xml` 5.467 ürün adresi taşıyor (her gün güncelleniyor). Ürün sayfalarında schema.org JSON-LD `price`/`priceCurrency: TRY` var. Herkese açık XML ya da API yok. 15.000 ₺ üstü için kurumsal teklif veriliyor | Perakende satış, **KDV dahil** (`urun-fiyat-kdvli`) | robots.txt'de `User-agent: *` için `Allow: /` var ve yorum satırı ürün ile kategori sayfalarının taranabilir olduğunu söylüyor (sayfalama ve sıralama parametreleri yasak). Üyelik sözleşmesinde bot ya da kopyalama yasağı bulamadım; altbilgide "Tüm hakları saklıdır" yazıyor. **Yazılı izin önerilir** | **3** |
| **Kablocu** (Aktem Elektrik; T-Soft) https://www.kablocu.com.tr | Kablo (Öznur, Pamukkale, N2XH, NYA...) | `product.xml` 1.180 ürün, JSON-LD fiyat. Bayi girişi var | "KDV Dahil Fiyat" | robots taramaya izin veriyor ama üyelik sözleşmesi (madde 1.b) site içeriğinin izinsiz kopyalanmasını yasaklıyor. **İzin gerekli** | **2** |
| **Schneider e-mağaza** https://eshop.se.com/tr (işleten: Schneider Elektrik San. ve Tic. A.Ş.; ürünleri yetkili satıcılar satıyor) | Schneider (yalnızca AG kategorisinde 1.128 ürün) | HTML. robots.txt'yi bot korumasından dolayı okuyamadım | TL, "Vergi Hariç" | [Kullanım Şartları](https://eshop.se.com/tr/terms-and-conditions) (Ekim 2024) erişim için "robot, örümcek veya benzer cihaz, süreç ve yöntemler kullanmak" yasak diyor. **Yazılı izin olmadan olmaz** | **1** |
| elektrikdeposu.com, elektrikmarket.com.tr, elektrikmalzemesi.com (IdeaSoft) | Küçük perakendeciler | — | Perakende | robots yalnızca bazı botları kapatıyor. Kullanım şartlarını incelemedim | **2** (doğrulanmadı) |
| elektrikmalzemem.com, ekolaser.com, elektrikcidukkani.com | — | Sırasıyla HTTP 410, 436 ve 503 verdi; **erişilemedi** | — | — | — |
| Akakçe, Cimri, Trendyol, Koçtaş, Bauhaus | — | — | — | Önceki araştırma: kullanım şartları otomatik veri toplamayı yasaklıyor (yeniden kontrol etmedim) | **1** |

## 3. Endeks ve birim fiyat kaynakları

- **ÇŞB 2026 birim fiyatları (elektrik tesisat pozları dahil):** hakedis.org'a göre lisanslı kullanım hakkı yine AMP Yazılım'da; erişim AMP Kurumsal Hakediş ya da birimfiyat.net üzerinden. Önceki bulgu değişmedi: **yazılı izin ya da lisans olmadan içe aktarılamaz.** Skor **1**.
- **TEDAŞ birim fiyatları:** birimfiyat.com'da poz bazında yayınlanıyor; lisans durumu aynı şekilde izin gerektirir (doğrulanmadı). Zaten dağıtım şebekesine yönelik, iç tesisata değil. Skor **1**.
- **EMO / ELDER:** Malzeme fiyat listesi yayınladıklarına dair bir kaynak bulamadım. Bulunan EMO PDF'i proje hizmet sözleşmesi örnekleriydi.

## 4. Bayi XML akışları

- Elektrik üreticisi ya da distribütörü olup sitesinde XML ürün/fiyat akışını açıkça ilan eden bir firma **doğrulayamadım**.
- Genel dropshipping XML siteleri (nalburxmlbayi.com, bayilikxml.com, easytoptan.com.tr) elektrik kategorisi gösteriyor. Ancak bunlar tüketici ürünü ağırlıklı; elektrik müteahhidinin aldığı marka ve kalemlere uymuyor. Ayrıntılı incelemedim.
- Gerçekçi yol: bayi hesabıyla Excel ya da XML almak (Horoz B2B Excel indirme, Kablocu bayi girişi, Elektromarketim kurumsal satış). Bu da ARVEND kullanıcısı firmanın kendi bayi hesabına bağlanmak demek; herkese açık bir kaynak olmuyor.

## Öneri: önce bağlanacak 3 kaynak

1. **Hes Kablo + Öznur Kablo (tek ayrıştırıcı).** İki PDF'in düzeni neredeyse aynı (Kesit / Birim Fiyatı (TL/km) / Ambalaj) ve tipler aynı. Kablo, elektrik işinin en büyük kalemi.
   - *Sahibin yapması gereken:* İki firmaya kısa bir e-posta gönderip listeyi otomatik okuyacağını bildirmek ve onay istemek (yasak yok, ama ilişki açısından iyi olur). Hes adresinin `temp` klasöründe olduğunu bilmek.
2. **Makel 2026-2.** Anahtar-priz, sigorta ve kaçak akımı tek PDF'te kapsıyor; herkese açık, robots izin veriyor.
   - *Sahibin yapması gereken:* Makel bayisinden iskonto oranını öğrenip ARVEND'de varsayılan iskonto olarak tanımlamak. İsterse Makel'den yazılı onay almak.
3. **Viko (Panasonic).** Piyasada en yaygın anahtar-priz markası, ama liste formun arkasında.
   - *Sahibin yapması gereken:* Formu bir kez kendisi doldurmak ve Panasonic Life Solutions Türkiye'den listeyi otomatik indirmek için **yazılı izin** istemek. Daha iyisi, Viko bayisinden Excel ya da XML fiyat linki istemek. İzin gelmezse Viko eklenmez.

Yedek seçenek: piyasa (satış) fiyatı referansı gerekirse **Elektromarketim**. Teknik olarak kolay (sitemap ve JSON-LD), ama KDV dahil perakende fiyat. Önce Ümelsan'dan yazılı izin ya da XML istenmeli.
