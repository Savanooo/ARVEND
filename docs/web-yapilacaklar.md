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

## 9. Teklif kaleminde katalogdan ürün seçme (mobil 1.5.11)
Backend `GET /products?q=` artık kelime bazlı (bkz. `mobile/API_CONTRACT.md`
"Products"): her kelime adda, kategoride ya da tedarikçide geçmeli; "demir"
Demir Profil ürünlerini, "kutu 40" 40'lı kutu profilleri, "40x40" "40×40"ı
bulur; ad eşleşmesi önce sıralanır. Ürünler sayfasındaki arama da bu
kuralla çalışır (web değişmeden faydalanır).
- `OfferForm.tsx`: ürün adı `<datalist>`ten seçiliyor ve tüm katalog
  (~4000 ürün, 40 sayfa) form açılırken çekiliyor. Tarayıcının datalist
  süzmesi tek alt dize ve yalnızca adda: "demir" ya da "kutu 40" yine bir
  şey bulmuyor — şikâyetin web tarafı bu. Mobildeki gibi: 2+ karakterde,
  300 ms beklemeli `GET /products?q=…&limit=6` önerileri (ad, kategori ·
  tedarikçi, fiyat / birim); tüm kataloğu çekme kalkar.
- Seçim yalnızca `product_id` ve `unit_price` dolduruyor; formda birim alanı
  yok, kalem birimsiz kaydediliyor (metraj satırları hariç). Mobil seçimde
  birimi de dolduruyor.
- Eşleşme tam adla (`p.name === name`): aynı adlı iki üründen hep ilki
  bağlanıyor. Öneri kimlikle (id) seçilmeli; ad sonra değiştirilirse
  `product_id` düşmeli (mobil böyle).

## 10. Kişi = tek kayıt (giriş hesabı + personel)
Kurallar: `mobile/API_CONTRACT.md` "Person = one record". Backend varsayılanı
web değişmeden çalışıyor: web'in "Yeni Kullanıcı" formu artık personel kaydı da
açıyor (ya da aynı adlı tek bağlantısız personele bağlıyor). Eksikler:
- "Yeni Kullanıcı" (`admin/kullanicilar/yeni/NewUserForm.tsx`): mobildeki gibi
  "Personel kaydı da oluştur" anahtarı (`create_employee`) + bağlantısız
  personel seçimi (`employee_id`; aynı adlı varsa o önceden seçili; "yeni kayıt
  aç" seçilirse `link_same_name:false`). Cevaptaki `employee_link.message`
  gösterilmeli (ör. "Aynı adlı mevcut personel kaydına bağlandı").
- "Giriş hesabı aç" (`components/permissions/CreateLoginCard.tsx`): `POST /users`
  gövdesine `employee_id: employee.id` eklenmeli; ardından gelen
  `PUT /employees/{id}` gereksizleşir. Şu an da çalışıyor (backend aynı adlı
  personele bağlıyor ya da hesapla açtığı boş kaydı bağlamada siliyor), ama
  aynı adlı İKİ bağlantısız personel varken gereksiz bir tur atıyor.
- "Yeni Personel + Yeni giriş hesabı" (`admin/personel/yeni/NewEmployeeForm.tsx`):
  `POST /users`'a `create_employee: false` eklenmeli (personeli form kendisi
  açıyor). Eklenmezse: aynı adlı bağlantısız personel varsa hesap ona bağlanır
  ve form ikinci kaydı açarken 409 alır ("…zaten "X" personel kaydına bağlı")
  — mükerrer kayıt yine oluşmaz ama form hata gösterir.
- Kullanıcı listesi/detayı: `employee_id`/`employee_full_name` ile bağlı
  personel (link) ya da "Personel kaydı yok" + oluştur/bağla.
- Personel listesi/detayı: `user_username` / `user_is_active` ile bağlı hesap.
- Süper Admin "Kullanıcı ekle" (`super-admin/[id]/UsersTab.tsx`): aynı alanlar
  (`create_employee` vb.) ve sonucun gösterimi; şu an varsayılan uygulanıyor.
- İsteğe bağlı: `GET /employees/link-suggestions` önerilerini Personel
  sayfasında "Bağla" düğmesiyle göstermek.

## 11. Taslak teklifin linkini paylaşırken gönder (mobil 1.5.12)
Şikâyet: "teklif atıyoruz, link vb., teklif kabul etme yok" — taslak teklifin
linkinde müşteri Kabul Et / Reddet görmüyor. Kural: `mobile/API_CONTRACT.md`
"Share links" (`mark_sent`).
- `teklifler/[id]/ShareOfferCard.tsx`: teklif `taslak`ken link oluşturmadan önce
  mobildeki soruyu sormalı: "Gönder ve link oluştur" (`mark_sent: true`,
  `offers.approve` ister) / "Yalnızca önizleme linki" / "Vazgeç"; izni yoksa
  yalnızca önizleme + kısa not. Sonra teklif ve geçmiş tazelenmeli. Şu an web
  durumu değiştirmeyen önizleme linki oluşturuyor (eski davranış).
- Müşteri sayfası (`paylas/[token]`) taslak linkte artık "Bu teklif henüz onaya
  açılmadı…" notunu gösteriyor (yapıldı).

## Bilinen tutarsızlıklar (web + backend)
- Katalog fiyatı TL; teklifin para birimi TL değilse (firma varsayılanı
  USD/EUR) katalogdan seçilen fiyat çevrilmeden yazılıyor — web ve mobil
  aynı. Mobil önerilerin üstünde uyarıyor ("Katalog fiyatları TL; bu teklif
  USD…"); web hiç uyarmıyor. Kalıcı çözüm kur çevrimi.
- Maliyet kontrol gerçekleşenleri, proje listesi kârı, ek iş kârlılığı ve ana
  sayfa hâlâ masrafları KDV DAHİL topluyor; yalnızca finans özeti KDV'yi
  çıkarıyor.
