# ARVEND — İnşaat Firmaları İçin İş Yönetim Sistemi

> Teklif hazırlamaktan şantiyedeki günlük rapora, taşeron hakedişinden
> depodaki çimentonun son kullanma tarihine kadar bir inşaat firmasının
> bütün işini tek yerde toplayan, web ve mobil (iOS / Android) çalışan
> çok-firmalı (SaaS) ERP.

*Durum: Ekim 2026 · canlıda `app.arvendyapi.com.tr` · mobil sürüm 1.5.19*

---

## 1. ARVEND ne çözer?

Küçük ve orta ölçekli inşaat, tadilat ve metal işleri firmalarında iş
genellikle Excel, WhatsApp grupları, defter ve muhasebe programı arasında
dağınık yürür:

- Teklif Excel'de hazırlanır, kabul edilince ayrıca bir yere "proje" olarak
  yazılır.
- Şantiyedeki masraf fişleri, taşeron ödemeleri ve tahsilatlar ay sonunda
  toparlanmaya çalışılır, projenin gerçekten kâr edip etmediği geç anlaşılır.
- Saha şefinin ne yaptığı, kimin geldiği, hangi malzemenin geldiği telefonda
  kalır.
- Taşeronlara ne kadar ödendiği, ne kadar borç kaldığı projeler arasında
  kaybolur.

ARVEND bunları tek bir akışa bağlar:

```
Müşteri ──► Teklif (metrajla) ──► Müşteri onayı ──► Proje
                                                     │
        ┌──────────────┬──────────────┬──────────────┼──────────────┬──────────────┐
        ▼              ▼              ▼              ▼              ▼              ▼
     Finans        Satın alma      Taşeronlar     Operasyon      Dokümanlar      Rapor
 (tahsilat,      (talep, teklif   (sözleşme,     (görev, ekip,   (dosya,        (kârlılık,
  masraf,         toplama,         hakediş,       planlama,       fotoğraf,      bütçe,
  fatura)         sipariş)         ödeme)         günlük rapor)   not)           ana sayfa)
```

---

## 2. Kimler kullanır?

| Rol | Tipik kişi | Ne görür / ne yapar |
|---|---|---|
| **Sahip** | Firma sahibi | Her şey. Silme ve onay kararları, yetki verme. |
| **Yönetici** | Genel müdür, ofis yöneticisi | Sahip ile aynı yetkiler (son sahip kaldırılamaz kuralı hariç). |
| **Proje Yöneticisi** | Proje / şantiye sorumlusu | Atandığı projelerde operasyon, görev, satın alma, taşeron sözleşmesi ve hakediş girişi; bütçeyi görür. Tahsilat ve ödeme yapmaz. |
| **Finans** | Muhasebe, finans | Tahsilat, ödeme, fatura, bütçe, satın alma onayı, hakediş onayı. |
| **Saha** | Saha şefi, usta başı | Görevler, fotoğraf, dosya, not, günlük rapor, masraf girişi (onaya düşer). Para tutarlarını görmez. |
| **Özel roller** | Satış, depo sorumlusu vb. | Firma, 68 izinden istediğini seçerek kendi rolünü tanımlar. |

Yetki sistemi üç katmanlıdır:

1. **Rol izinleri.** 14 kategoride 68 izin: Teklifler, Projeler, Finans,
   Operasyon, Görevler, Stok, Personel, Puantaj vb.
2. **Kişiye özel yetki.** Bir kişiye rolünün dışında izin eklenir ya da
   rolündeki bir izin ondan alınır.
3. **Proje erişim listesi.** Proje Yöneticisi, Finans ve Saha yalnızca
   eklendikleri projeleri görür.

Her istek sunucuda ayrıca denetlenir; uygulamadaki gizli düğmeler yalnızca
kolaylıktır, asıl güvenlik sınırı sunucudadır.

---

## 3. Modüller

### 3.1 Teklif

- Müşteriye bağlı teklif, kalem kalem fiyat ve KDV; otomatik teklif numarası.
- **Revizyonlar:** teklif değiştikçe yeni revizyon açılır, eski hali
  saklanır.
- **Metrajla kalem:** metraj hesaplama motorundan gelen ölçü ve miktarlar
  teklif kalemine anlık görüntüsüyle yazılır.
- **İç fiyatlandırma:** maliyet ve kâr oranı yalnızca yetkili kişilere
  görünür, müşteri görmez.
- **Gönderme ve onay:**
  - **PDF** çıktısı.
  - **E-posta** ile gönderim (firmanın kendi SMTP'si).
  - **Paylaşım linki:** müşteri teklifi tarayıcıda açar, *kabul* ya da
    *red* eder. Açıldığında ve karar verildiğinde firmaya bildirim gider.
- **Geçmiş:** kim ne zaman ne yaptı (oluşturma, gönderme, görüntülenme,
  karar).
- **Silme:** Sahip ve Yönetici doğrudan siler, diğerleri silme talebi açar
  ve onay bekler.
- **Projeye dönüştürme:** kabul edilen teklif tek adımda proje olur;
  sözleşme bedeli, müşteri bilgisi ve kalemler projeye taşınır.

### 3.2 Metraj Hesaplama

- Firmanın kendi **metraj reçeteleri**: gruplar, kategoriler ve reçete
  kalemleri (ör. "alçıpan bölme duvar: m² başına profil, vida, levha").
- Ölçü girilince malzeme miktarı ve tutar hesaplanır, sonuç teklife aktarılır.

### 3.3 Projeler

Proje sayfası dört gruba ayrılır.

**Özet**
- Durum, tarihler, sözleşme bedeli, tahsilat oranı, kârlılık.
- Bölümlere kısayollar ve hızlı işlemler.

**Finans**
- **Kârlılık:** KDV dahil ve KDV hariç kâr, gerçekleşen ve tahmini maliyet.
- **Masraflar:** kategori, KDV oranı, maliyet kodu. Girilen masraf
  yöneticinin **onayına** düşer; onaylanmadan toplamlara girmez.
- **Tahsilatlar** ve **ödeme planı:** vadesi geçen taksit uyarısı.
- **Faturalar:** satış ve alış; faturadan tahsilat.
- **Sözleşme:** taslak → aktif → tamamlandı / feshedildi / iptal. Aktif
  olunca ticari şartlar kilitlenir.
- **Ek işler (değişiklik emri):** müşteriye link ile gönderilir, müşteri
  onaylar ya da reddeder; onaylanan ek iş sözleşme bedeline eklenir.
- **Bütçe ve maliyet kontrolü:**
  - WBS (iş kırılımı) ve **maliyet kodları**.
  - Bütçe kalemleri; bütçe revizyonları onaylı yapılır.
  - Taahhüt, gerçekleşen, tamamlanma tahmini (EAC) ve sapma.
- **Taşeron ödemeleri:** basit taşeron kaydı (iş tanımı, bedel) ve ödemeleri.

**Operasyon**
- **Taşeron sözleşmeleri:**
  - Sözleşme, kalemler ve değişiklik emirleri.
  - **Hakediş:** taşeron hakedişi girilir, yetkili onaylar.
  - Ödeme ve kalan bakiye.
- **Satın alma:**
  - Talep → onay → tedarikçilerden teklif toplama (RFQ) → **teklif
    karşılaştırma** → **sipariş**.
  - Onaylanan sipariş bütçede taahhüt olarak görünür.
- **Görevler:**
  - Kişiye atama, öncelik, son tarih.
  - Görev notları ile ilerleme yazışması.
  - Gecikenler ana sayfada uyarı olarak çıkar.
- **Günlük şantiye raporu:**
  - Hava, kendi ekibimiz (o günün puantajından önerilir), sahadaki
    taşeronlar ve kişi sayıları.
  - Yapılan işler, sorunlar, gelen malzeme.
  - O gün tamamlanan görevler ve çekilen fotoğraflar kendiliğinden eklenir.
  - "Gönder" ile yöneticilere bildirim gider; rapor **PDF** olarak paylaşılır.
- **Planlama:** iş programı aşamaları, sorumlu, gecikme takibi.
- **Ekip:** projede çalışan personel (puantajla bağlantılı).
- **Proje erişimi:** uygulama kullanıcılarının projeye eklenmesi.

**Dokümanlar**
- **Dosyalar ve fotoğraflar:** aşamaya göre (başlangıç, ilerleme, teslim)
  şantiye fotoğrafları; WhatsApp, e-posta ve Drive ile paylaşım.
- **Notlar.**

**Diğer**
- **Aktivite geçmişi:** projede kim ne yaptı.
- **Silme:** para hareketi olmayan proje silinir. Hareketi olan proje
  silinmez, iptal edilir. Sahip ve Yönetici dışındakiler silme talebi açar.

### 3.4 Taşeronlar

- Taşeron **bir kez** kart olarak açılır (TSR-0001…), projelerde listeden
  seçilir.
- Taşeronun sayfasında:
  - bütün projelerdeki işleri (sözleşme, ödenen, kalan);
  - **bütün ödemeler**: projeli ve proje dışı, iptaller dahil;
  - günlük raporlardan **sahada çalıştığı günler** ve adam-gün toplamı.
- Listede taşeron başına **ödenen** ve **kalan borç** görünür.
- Proje dışı ödeme doğrudan karta yazılır. Telefon numarasına dokununca arar.

### 3.5 Masraflar

- **Projeli** ve **genel (projesiz)** masraflar tek listede: ofis, yakıt,
  genel gider.
- Herkes masraf girebilir, masraf yöneticinin onayına düşer. Kişi kendi
  masraflarını izler, finans hepsini toplamlarla görür.

### 3.6 Stok Takibi

- **Depolar:** "Merkez Depo" kendiliğinden açılır, istenen kadar depo
  eklenir.
- **Malzeme kartları:** kod, **barkod**, birim, kategori, minimum stok;
  istenirse ürün kataloğuna bağlanır.
- **Son kullanma tarihi (SKT):** parti bazında; raf ömrü girilirse üretim
  tarihinden hesaplanır. SKT geçince malzemeye göre davranır:
  - **Engelle** (ör. çimento): SKT'si geçen parti çıkış yapamaz, yalnızca
    fire olarak düşülür.
  - **Uyar** (ör. silikon, köpük): çıkışa izin verir ama her seferinde
    uyarır.
- **Fişler:**
  - **Giriş:** tedarikçi, irsaliye no ve irsaliye fotoğrafı.
  - **Çıkış:** kime, isteğe bağlı olarak hangi projeye.
  - **Depolar arası aktarım.**
  - **Fire:** hasar, SKT geçti, kesim, kayıp.
  - **Sayım:** fark kendiliğinden düzeltilir.
- **Önce bozulacak önce çıkar:** parti seçilmezse SKT'si en yakın parti
  düşülür.
- **Değişmez kayıt:** fiş kaydedildikten sonra değişmez, yanlışı iptal
  fişiyle geri alınır. Stok eksiye düşmez.
- **Maliyet:** hareketli ağırlıklı ortalama, KDV hariç; stok değeri
  yetkiliye görünür.
- **Barkod / QR okutma:** telefon kamerasıyla malzeme bulunur.
- **Her sabah uyarı:** SKT'si geçen ya da yaklaşan ve azalan malzeme için
  bildirim gider.

### 3.7 Personel, Puantaj ve Maaş

- **Personel kartları:** ücret geçmişi ve uygulama kullanıcısıyla bağlantı.
- **Puantaj (mesai):** günlük durum (geldi, yarım gün, gelmedi, izinli) ve
  saat.
- **Maaş:** aylık hakediş, avans ve ödemeler; personel başına **maaş
  dökümü PDF**. Maaş bilgisi ayrı bir yetkiyle korunur.

### 3.8 Müşteriler, Ürünler, Tedarikçiler

- **Müşteriler:** iletişim bilgileri, teklifleri ve projeleri.
- **Ürünler:** firmanın fiyat kataloğu. Kâr oranıyla satış fiyatı
  hesaplanır.
- **Tedarikçi fiyat kaynakları:** **Ulaş** ve **Demir Profil** fiyat
  listeleri çekilir, **zam geçmişi** tutulur (hangi ürün ne zaman yüzde
  kaç arttı).
- **Tedarikçiler:** satın alma ve taşeronlar için ortak katalog. IBAN
  şifreli saklanır.
- **Maliyet kodları:** bütçe ve masrafları sınıflandırmak için firma geneli
  kodlar.

### 3.9 Ana Sayfa ve Bildirimler

- **Kişiye göre ana sayfa:** herkes yalnızca yetkisi olan bölümleri görür.
  - **Dikkat Gerektirenler:** onay bekleyen masraf, vadesi geçen tahsilat,
    geciken görev, bütçe aşımı, onay bekleyen satın alma ve hakediş, silme
    talepleri vb. "Senin sıran" ve "Takipte" olarak ayrılır.
  - Göstergeler, nakit akışı, **Görevlerim**, son hareketler.
  - **Hızlı işlemler:** Teklif Oluştur, Masraf Gir, Tahsilat Gir, Günlük
    Rapor, Görev Ekle, Mesai Gir…
- **Bildirimler:** uygulama içinde ve **telefona anlık bildirim**. Bildirime
  dokununca ilgili ekran açılır; art arda gelenler gruplanır.
- **Duyuru** (firma içi), **Öneri Gönder** (geliştiriciye geri bildirim),
  güncellemeden sonra **Yenilikler** ekranı.

---

## 4. Platform (çok firmalı yapı)

ARVEND tek kurulumda birçok firmaya hizmet verir. Her firmanın verisi
ayrıdır; bir firma başka firmanın kaydına hiçbir yoldan ulaşamaz. Bu,
testlerle sürekli denetlenir.

**Süper Admin konsolu (web)** firmalardan ayrı, kendi güvenlik sınırı
olan bir yönetim katmanıdır:

- Firma açma ve ilk kurulum (sahip kullanıcısı, şifre belirleme, kurulum
  sihirbazı).
- Firma yaşam döngüsü: **askıya alma**, **iptal**, **silme**. Silme
  yumuşaktır, veri fiziksel olarak silinmez.
- Planlar, platform duyuruları, firmalardan gelen öneriler, denetim kaydı.

**Hesap güvenliği:**
- Oturum, tarayıcıdan okunamayan çerezlerle tutulur.
- Yenileme jetonları dönerek değişir.
- Kullanıcı uygulama içinden **hesabını silebilir** (App Store kuralı).

---

## 5. Uygulamalar

| | Web | Mobil (iOS / Android) |
|---|---|---|
| Teklif, müşteri, proje, finans, satın alma, sözleşme, bütçe | ✓ | ✓ |
| Personel, puantaj ve maaş, kullanıcı/rol yönetimi, ürünler, metraj reçeteleri | ✓ | ✓ |
| Süper Admin konsolu | ✓ | — (bilinçli olarak yok) |
| Taşeronlar, Masraflar listesi, Günlük Rapor, Stok Takibi | sırada | ✓ |
| Barkod okutma, telefona bildirim, kamera ile fotoğraf / irsaliye | — | ✓ |

- Mobil uygulama **Google Play** ve **App Store** üzerinden dağıtılır.
  Play sürümü güncellemeyi uygulama içinden önerir.
- Yeni modüller önce mobile gelir (şantiyede kullanılan taraf), web sonra
  eşitlenir.

---

## 6. Teknik mimari

```
 Flutter (iOS/Android) ─┐
                        ├──► Caddy ──► Go API (chi) ──► PostgreSQL
 Next.js web ───────────┘        └──► Next.js (SSR)
                                        Dosya deposu (fotoğraf, belge, irsaliye)
```

| Katman | Teknoloji |
|---|---|
| Sunucu (API) | Go, chi router, pgx + sqlc (tip güvenli SQL), golang-migrate |
| Veritabanı | PostgreSQL; 72 numaralı migration, her kayıt firmaya (organization) bağlı |
| Web | Next.js (App Router), Tailwind CSS |
| Mobil | Flutter, Riverpod, go_router, Material 3 |
| Bildirim | Firebase Cloud Messaging (telefon), uygulama içi bildirim tablosu |
| PDF | Sunucuda üretilir (teklif, maaş dökümü, günlük rapor) |
| Barkod | mobile_scanner (iOS'ta Apple Vision, Android'de ML Kit; cihaz üstünde) |

**Önemli tasarım ilkeleri:**

- **Kural sunucuda:** onaylar, kilitler, eksi stok yasağı, yetki ve proje
  üyeliği her istekte sunucuda denetlenir.
- **Para doğru sayılır:**
  - Tutarlar veritabanında ondalık (numeric) tipte, hesaplar SQL'de.
  - Aynı para iki kez sayılmaz: taşeron ödemesi masraf olarak girilemez,
    stok çıkışı proje maliyetine ayrıca yazılmaz.
- **Geçmiş silinmez:**
  - Olay kayıtları (teklif ve proje geçmişi) değiştirilemez.
  - Ödemeler ve fişler iptal edilir, silinmez.
  - Firmalar ve kullanıcılar yumuşak silinir.
- **Çift kayıt koruması:** tahsilat, ödeme, masraf ve stok fişi gibi para
  ve miktar işlemleri, çift dokunma ya da ağ tekrarında ikinci kaydı açmaz.

**Test:**
- Sunucuda gerçek veritabanına karşı çalışan entegrasyon testleri: iş
  kuralları, yetki matrisi, firma izolasyonu.
- Mobilde yaklaşık 2.000 test: ekran akışları ve görüntü (golden) testleri.

**Dağıtım:**
- Tek sunucu: Caddy ters vekil, Cloudflare tüneli, systemd servisleri.
- Her sürüm doğrulanmış bir paket olarak kurulur. Kurulumdan önce
  veritabanı, ikili ve kaynak yedeği alınır; kurulumdan sonra uç kontrolleri
  yapılır; her paketin geri alma betiği vardır.

---

## 7. Yol haritası

- **Web eşitleme:** Taşeronlar, Masraflar, Günlük Rapor ve Stok Takibi
  ekranlarının web karşılıkları.
- **Stok 2. aşama:**
  - Alet / demirbaş zimmeti.
  - QR etiket basma.
  - Satın alma siparişinden "Teslim Al".
  - e-İrsaliye entegrasyonu.
  - Muhasebeciye Excel çıktısı.
- Ana Sayfa "Dikkat Gerektirenler" bölümüne stok uyarıları.

---

*Daha ayrıntılı teknik dokümanlar:*
- `docs/teklif-modulu.md`
- `docs/contracts.md`
- `docs/cost-control.md`
- `docs/procurement.md`
- `docs/subcontracts.md`
- `mobile/API_CONTRACT.md`
- `HANDOFF.md`
