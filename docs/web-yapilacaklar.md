# Web — yapılacaklar (mobilin gerisinde kalanlar)

2026-10-07 itibarıyla backend ve mobil bu özelliklerin hepsini yapıyor ve canlıda
(sunucu 19b7d75, şema 65; mobil 1.5.8). Web arayüzü henüz yapmıyor. Ürün sahibi
kararıyla web en sona bırakıldı. Her maddede davranışın kaynağı mobil ekran +
`mobile/API_CONTRACT.md`; web aynısını yapmalı (web = mobil).

## 1. Taşeron sözleşme modülü (en büyük iş)
- Web'de hiç ekranı yok. Uçlar: `backend/internal/httpapi/router.go` "Sprint 5:
  Taşeron Yönetimi" ve "Taşeron Ödemeleri"; kurallar `docs/subcontracts.md`.
- Sözleşme + SOV kalemleri; aktifleştir / tamamla / iptal / fesih; taşeron ek
  işleri (oluştur, gönder, onayla, reddet); hakediş (oluştur, gönder, onayla
  (certify), reddet); ödemeler (listele, ekle, iptal).
- Her adımın ayrı izni var (`projects.subcontracts.*`,
  `projects.subcontract_claims.*`, `projects.subcontract_payments.*`).
- Eski basit taşeron listesi (`/subcontractors`, FinanceSections.tsx) ayrı;
  ona dokunma.
- Taşeron bildirimleri şu an Finans sekmesini açıyor; yeni ekrana bağlanmalı.

## 2. Masraf: KDV ve düzenleme (`FinanceSections.tsx`)
- Formda KDV seçimi (Belirtilmedi / KDV yok %0 / %1 / %10 / %20) ve canlı
  "KDV hariç · KDV" önizlemesi. `vat_rate` YALNIZCA oran seçilince gönderilir.
- Tabloda/detayda oran, `vat_amount`, `net_amount`.
- Düzenleme: `PUT /projects/{id}/expenses/{expenseId}` satırı BÜTÜNÜYLE yeniden
  yazar; okunan her alan geri gönderilir (`vat_rate` gönderilmezse silinir,
  `change_order_id` dahil). Onaylı masrafı düzenlemeden önce onay sor; masraf
  "Onay bekliyor"a döner. Reddedilen masrafta ret nedeni görünsün.
- `FinanceSummary.tsx` / `ProfitabilitySection.tsx`: "Maliyet (KDV hariç)"
  (`realized_cost_net`, `forecast_cost_net`) brütten farklıysa göster.
- `lib/types.ts`: Expense ve FinancialSummary'ye yeni alanlar.

## 3. Bütçe revizyonu ve ek iş onayları
- Bütçe revizyonu (`CostControlSections.tsx`): onay/ret düğmeleri
  `projects.budget.approve` iznine bağlanmalı (şu an budget.manage); kişinin
  kendi revizyonunda gizle (Sahip hariç); 409 mesajını olduğu gibi göster.
- Ek iş (`ChangeOrderSections.tsx`): gönderilmiş ek işte "Müşteri onayladı /
  reddetti" + not penceresi →
  `POST /projects/{id}/change-orders/{id}/record-decision` `{decision, note}`,
  izin `projects.change_orders.approve`. Kimin işaretlediği ve not görünsün;
  `lib/events.ts`'te personel kararı (`source: "staff"`) ayrı etiketlensin.
- Bildirim linkleri: `/projeler/{id}/maliyet/revizyonlar` maliyet sekmesine
  gitmeli (şu an genel bakışa düşüyor); zile `budget_adjustment` girdisi.

## 4. Teklif
- `OfferForm.tsx`: KDV (şu an sabit 20) ve geçerlilik `GET /offers/defaults`'tan
  gelsin. Web boş geçerlilikte `valid_until: ""` gönderiyor ("süresiz") — firma
  varsayılanı web'de hiç uygulanmıyor. 0 TL satır için onay.
- Tutarlar teklifin para biriminde (`offer.currency`): liste, detay, revizyon,
  müşteri paylaşım sayfası.
- Metraj paneli (`components/calc/MetrajHesaplaPanel.tsx`): satır başına
  `price_source` / `price_warning` (eski/0 fiyat) + özet uyarı; `price_source`
  `calc_snapshot`'a kopyalansın.
- Kurulumdaki "Varsayılan Para Birimi" serbest metin → TRY / USD / EUR seçimi.
- Mükerrer müşteri: 409'da "Mevcut müşteriyi aç / Yine de kaydet
  (`allow_duplicate`) / Vazgeç" penceresi (mobildeki gibi).

## 5. Görevler
- Görev notu ("Bilgi Ver"): `GET/POST /projects/{id}/tasks/{taskId}/updates`;
  görev detayında not akışı.
- Görev düzenleme: `PUT /projects/{id}/tasks/{taskId}` (erişimi olmayan kişi
  atanamaz → 400 mesajı; kapalı projede kilit).
- Fotoğraf küçük resimleri doğrudan API adresinden yükleniyor; oturum
  yenilenince (15 dk) kırılıyor. İndirmelerdeki düzeltmenin aynısı uygulanmalı.

## 6. Deneme süresi
- Super Admin firma listesinde deneme rozeti (kalan gün / bitti).
- Firma Sahibi/Yöneticisine web'de de günlük kapatılabilir uyarı (mobildeki
  gibi; son gün "bugün bitiyor").

## 7. Yenilikler penceresi
- Mobildeki gibi: güncellemeden sonraki ilk girişte bir kez çıkan kısa
  "Yenilikler" penceresi + menüde tekrar açma.

## 8. Masrafı herkes girer, onayı yalnızca Sahip/Yönetici verir (migration 0066)
Kurallar: `mobile/API_CONTRACT.md` "Expense entry for everyone". Backend ve
mobil hazır; web şu an çalışmaya devam ediyor ama aşağıdakiler eksik.
- "Masraf Ekle" düğmesi `projects.finance.manage` yerine
  `projects.expenses.create` iznine bağlanmalı (`FinanceSections.tsx`, hızlı
  işlemler `lib/dashboard.ts`). Finans sekmesini göremeyen kişi için proje
  sayfasında ayrı bir giriş gerekir. finance.manage yoksa formda Ek İş /
  Bütçe Kalemi / Maliyet Kodu gösterilmez (sunucu doluysa 403 döner).
- Ana sayfa hızlı işlemleri (`lib/dashboard.ts`, mobil `QuickActionKey` ile
  aynı sıra): "Masraf Gir"den hemen sonra "Masraf Takibi" (Masraflarım'ı açar,
  `projects.expenses.create`); mobil 1.5.10'dan beri böyle.
- "Masraflarım" sayfası: `GET /expenses/mine` (projeler arası, isteğe bağlı
  `?project_id=`); durum rozeti (Onay bekliyor / Onaylandı / Reddedildi + ret
  nedeni / Geri çekildi), kendi bekleyen/reddedilen masrafta Düzenle ve
  Geri çek (`POST .../void`). Yalnızca kendi masrafı, toplam yok.
- Onayla/Reddet kişinin kendi masrafında (`created_by` = oturumdaki kişi)
  gizlenmeli, Sahip hariç; kısa not: "Bu masrafı sen girdin; başka bir
  yöneticinin onaylaması gerekir." Sunucu 409 ile reddediyor, mesajı olduğu
  gibi göster.
- Onay düğmeleri `projects.expenses.approve` ile görünür; Finans rolünde
  artık yok (kişiye özel verilmediyse).
- Bildirim linki: `/diger/masraflarim?masraf={id}` (finans göremeyen kişinin
  masraf kararı bildirimi) `webHrefForActionTarget`'ta Masraflarım'a
  eşlenmeli; şu an `null` döner, bildirim web'de tıklanmaz.
- `lib/types.ts` Expense: `project_id`, `created_by`, `voided_by`.

## Bilinen tutarsızlıklar (web + backend)
- Maliyet kontrol gerçekleşenleri, proje listesi kârı, ek iş kârlılığı ve ana
  sayfa hâlâ masrafları KDV DAHİL topluyor; yalnızca finans özeti KDV'yi
  çıkarıyor.
