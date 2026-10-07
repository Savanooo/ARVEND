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

## Bilinen tutarsızlıklar (web + backend)
- Maliyet kontrol gerçekleşenleri, proje listesi kârı, ek iş kârlılığı ve ana
  sayfa hâlâ masrafları KDV DAHİL topluyor; yalnızca finans özeti KDV'yi
  çıkarıyor.
