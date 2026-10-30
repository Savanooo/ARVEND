# Web — yapılacaklar (mobilin gerisinde kalanlar)

> **Durum (2026-10-12):** Ürün sahibi kararıyla web EN SONA bırakıldı. Aşağıdaki
> maddelerin çoğu için hazır ama BİRLEŞTİRİLMEMİŞ dallar var (main@1129279'dan):
> `feat/web-taseron` (§1), `feat/web-masraf` (§2, §8), `feat/web-onay-gorev`
> (§3, §5), `feat/web-teklif` (§4, §9, §11), `feat/web-hesap` (§6, §7, §10).
> `feat/web-teklif` ve `feat/web-masraf` sonundaki "wip" commit'leri yarıda
> kesilen incelemeden; web sırası gelince bu dallar incelenip birleştirilir.
> Ek web eksikleri: KDV hariç `*_net` alanları (proje listesi, maliyet
> kontrolü, ek iş kârlılığı, ana sayfa) web'de henüz gösterilmiyor; metraj
> `calc_snapshot` web tarafı kanonik şemaya geçmeli (bkz. mobile/API_CONTRACT.md).

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

## 12. Proje fotoğrafları galerisi (mobil, 2026-10-29)
Şikâyet: "resimler sıra sıra kaymıyor, galeri değil". Mobilde fotoğrafa
dokununca tam ekran galeri açılıyor (`mobile/lib/features/projects/
presentation/project_photo_gallery.dart`); web'de (`projeler/[id]/
OperationSections.tsx` PhotosSection) her fotoğraf yeni sekmede tek başına
açılıyor.
- Tıklanan fotoğrafta açılan bir görüntüleyici (lightbox): önceki/sonraki
  (oklar + klavye ←/→), "3 / 12" sayacı, aşama · açıklama · tarih, Esc ile
  kapanma. Sıra ızgaranınki: önce → süreç → sonra, aşama içinde backend
  sırası (bütün aşamalar arasında gezilir).
- Paylaş/indir ve Sil o an görünen fotoğrafa; silince sıradaki gelir, son
  fotoğraf silinince kapanır (`projects.operations.manage`).
- Günlük rapordaki "O gün çekilen fotoğraflar" da aynı görüntüleyicide
  açılmalı (mobilde öyle).
- Küçük resimler §5'teki gibi doğrudan API adresinden yükleniyor; görüntüleyici
  de aynı oturum yenileme düzeltmesini kullanmalı.

## 13. Teklif kaleminde "Maliyet ve Kâr" sözcükleri (mobil, 2026-10-29)
Şikâyet: "Markup ve satış yerini kimse anlamıyor". API değerleri aynı
(`pricing_mode: markup|manual`, `internal_subcontract_cost`,
`markup_percent`); yalnızca etiketler ve canlı sonuç. Mobil kaynak:
`mobile/lib/features/offers/presentation/offer_internal_pricing.dart`.
- `OfferForm.tsx` ("İç Maliyet / Müşteri Görmez", "Taşeron Maliyeti",
  "Fiyatlama: Maliyet üzerine % / Satış fiyatını elle gir", "Marj (%)",
  "Müşteri Fiyatı", "Beklenen Kâr") mobille aynı olmalı:
  - Bölüm: "Maliyet ve Kâr" + "Müşteri görmez".
  - "Fiyat nasıl belirlensin?": "Satış fiyatını ben gireyim" (manual — "Müşteri
    fiyatını sen yazarsın; kârın hesaplanır"), "Kâr oranıyla hesapla" (markup —
    "Maliyetin üstüne kâr yüzdesi eklenir"), "Kullanma" (iç fiyat yok — "Bu
    kalemde maliyet ve kâr tutulmaz"). Yeni kalem "Satış fiyatını ben gireyim"
    açılır (web zaten manual açıyor); maliyet boşsa iç alan gönderilmez.
  - Alanlar: "Bize maliyeti (birim)", "Kâr oranı (%)".
  - Her iki modda canlı satır: "Müşteriye birim fiyat: X · Kârımız: Y (%Z)" ve
    "Kalem toplamı: A · Kârımız: B"; zararda "Zararımız" ve kırmızı. Oran
    maliyete göre (backend `EffectiveMarkupPercent`).
  - Kâr oranıyla hesaplanan kalemde Birim Fiyat kilitli ve hesaplanan fiyatı
    gösterir ("Birim Fiyat (otomatik)").
  - Doğrulama: "Maliyeti yaz; müşteri fiyatı bundan hesaplanır.", "Kâr oranını
    yaz (ör. 20).", "Kâr oranı -%100'den küçük olamaz.", "Kâr oranı en fazla
    %9.999,99 olabilir."
- Web önizlemesi `round2(cost * (1 + markup / 100))` kayan noktayla
  hesaplıyor; yarım kuruşta sunucudan 1 kuruş sapar (ör. 1,15 + %50: sunucu
  1,73, web 1,72). Mobil kuruş/tam sayıyla hesaplıyor (`previewMarkupUnitPrice`,
  `offerLineTotal`).
- Teklif detayı ve revizyon sayfasında (`teklifler/[id]`,
  `teklifler/[id]/revizyonlar/[revisionId]`) kalem özeti: "Bize maliyeti: X /
  birim", "Kâr oranı: %15 · fiyat bundan hesaplandı" ya da "Satış fiyatı elle
  girildi", "Beklenen kâr: Y / birim (%Z) · bu kalemde B" (zararda "Beklenen
  zarar").
- Backend hata metinleri hâlâ eski sözcüklerle ("marj yüzdesi girilmelidir",
  "iç taşeron maliyeti negatif olamaz", "geçersiz fiyatlama modu",
  `computeOfferTotals`); mobil bunları kayıttan önce kendi sözcükleriyle
  yakalıyor, web de yakalamalı. Backend metinleri ayrıca sadeleştirilebilir.

## 14. Genel masraf görünürlüğü ve masraf fişi / belgesi (migration 0076)
Şikâyetler: "Genel giren masraflar hiç gözükmüyor", "Masraf girme yerine resim
ve dosya ekleme gibi bir yer olsun". Kurallar: `mobile/API_CONTRACT.md`
"General expenses visible…" ve "Expense receipts / documents". Backend ve mobil
hazır; web eksikleri:
- Masraflarım (§8) yapılırken `GET /expenses/mine` artık genel (projesiz)
  masrafları da döndürüyor (`is_general: true`, proje alanları boş): satırda
  proje yerine "Genel masraf"; Düzenle/Geri çek `/expenses/general/{id}`
  uçlarına gitmeli.
- Web'de "Masraflar" (projeli + genel tek liste, `GET /expenses`) sayfası hiç
  yok. Yapılırken yanıttaki `scope`a göre: `all` toplamlarla, `approver`
  (finans okuması olmayan onaylayıcı: kendi + onay bekleyenler + son 30 günde
  karara bağlananlar) toplamsız ama "giren" sütunlu, `mine` yalnızca kendi.
- Bildirim linki `/diger/masraflar?durum=pending` (onay bekleyen masraf,
  genel ya da finans okuması olmayan onaylayıcı) `webHrefForActionTarget`'ta
  Masraflar sayfasına (onay bekleyenler süzgeciyle) eşlenmeli; şu an `null`.
- Fiş / belge: masraf formunda (Finans > Masraf Ekle, FinanceSections.tsx)
  fotoğraf/PDF seçme, kayıttan sonra `POST {base}/attachments` (multipart
  `file`) ile yükleme; masraf satırında ataş ve sayı (`attachments` dizisi
  listelerde geliyor), ayrıntıda küçük resimler (`GET …/content`, çerezle;
  `<img>` doğrudan kullanılabilir, uç `inline` döner) ve PDF'i yeni sekmede
  açma. Ekleme/silme yalnızca masrafı giren (bekleyen/reddedilen masrafında)
  ve `projects.finance.manage`; onaylı/iptal masrafta salt okunur (409).
  Onayla/Reddet'ten önce onaylayıcı fişi görmeli.

## 15. Firma Grubu (backend migration 0077, mobil)
Ürün sahibi: "Toplu mesaj kanalı olsun, grup mesajı gibi düşün" — firma başına
TEK grup, metin + fotoğraf, telefona bildirim. Backend ve mobil hazır; web'de
ekran yok. Kural ve uçlar: `mobile/API_CONTRACT.md` "Firma Grubu",
`backend/internal/service/organization_chat.go`.
- Uçlar `/organization/chat/*` (izin `organization.chat.use`, Taşeron hariç
  herkeste): `GET messages` (en yeni sayfa / `before` / `after` +
  `changed_since` ile yoklama), `POST messages`, `POST messages/photo`
  (multipart), `GET messages/{id}/photo`, `DELETE messages/{id}`,
  `GET status`, `POST read`, `PUT mute`.
- Web ekranı: mobil `features/chat/presentation/chat_screen.dart` ile aynı —
  alttan yukarı mesajlar, gün ayraçları, kendi mesajı sağda, fotoğraf
  küçük resmi (tıklayınca büyük), "Mesaj silindi", gönderilemeyen mesajda
  "Tekrar dene" (aynı `client_id`), sayfa açıkken ~5 sn'de bir yoklama,
  görünürken `POST read`, menüde "Bildirimleri sessize al". Menüde rozetli
  "Firma Grubu" girişi (`GET status`).
- Bildirim hedefi mobil yolu `/diger/firma-grubu`; `lib/dashboard.ts`
  `webHrefForActionTarget` bunu tanımıyor (zilde tıklanmaz) — web ekranı
  gelince eşlenmeli. Bildirim türü `organization_chat`, varlık `chat_message`.
- Roller ekranı yeni "İletişim" kategorisini API'den okur (değişiklik
  gerekmez); Taşeron rolü zaten kilitli.

## 16. Yapay zekâ görselleri (backend migration 0079, mobil sonraki sürüm)
- Web'de hiç ekranı yok. Uçlar ve kurallar: `mobile/API_CONTRACT.md` "Yapay zekâ görselleri".
- Proje fotoğraf listesinde `ai_generated`/`ai` alanlarına göre "Yapay zekâ" rozeti ve "Yapay zekâ ile üretildi · kaynak: <tarih>" (web şu an üretilmiş görseli gerçek şantiye fotoğrafı gibi gösterir — ilk yapılacak bu).
- Rol/izin ekranında yeni kategori "Yapay Zekâ" (`ai.images.use`) görünmeli; `frontend/lib/permissions.ts` etiketi.
- Proje hareketlerinde yeni olay `ai_photo_created` → "Yapay zekâ görseli eklendi" (`frontend/lib/events.ts`).
- İsteğe bağlı: galeride "Bitmiş halini göster" / "Fotoğrafı iyileştir", Dökümanlar'da "Yapay zekâ ile görsel oluştur" (iş açma 202 + yoklama), ilk kullanımda bilgilendirme, kalan hak ve Sahip/Yönetici için kişi kişi kullanım (`GET /ai/status`).

## 17. Satın almalar proje maliyetine girer (backend migration 0078, mobil)
Ürün sahibi: talep ONAYLANINCA maliyete girsin, onaylarken "proje maliyetine
eklensin mi" diye sorsun. Backend ve mobil hazır; web'de yok. Kural:
`docs/maliyet-tanimlari.md` "Satın almalar", uçlar `docs/procurement.md` §13.
- Talep onayı (web PR detay "Onayla"): mobil gibi karar penceresi —
  "Proje maliyetine eklensin mi?", "Evet, maliyete ekle" (varsayılan) /
  "Hayır (depo/stok ya da genel kullanım)", eklenecek tutar
  (`project_cost.potential`), fiyatsız talepte uyarı
  ("Bu talepte fiyat yok; maliyete 0 TL girer.") ve isteğe bağlı tahmini
  tutar alanı → `POST .../approve {include_in_project_cost, cost_estimate}`.
  Web bugün gövdesiz onaylıyor: geçerli, "evet" sayılır.
- Sipariş onayı: aynı karar (`{include_in_project_cost}`), varsayılan
  siparişin mevcut kararı (talepten devralınan).
- Talep/sipariş detayı: "Maliyete eklendi: X" ya da "Maliyete eklenmedi"
  (`project_cost.amount` / `included`) ve onay izniyle "Değiştir"
  (`POST .../project-cost`). Sipariş listesinde "Maliyeti girilmemiş X"
  ifadesi artık yanlış: "Faturası gelmemiş X" olmalı (tutar maliyetin içinde).
- Finans özeti / kârlılık (`ProfitabilitySection.tsx`, `FinanceSummary.tsx`):
  "Masraflar" satırı `total_expenses` yerine `expense_cost` olmalı ve
  altına "Satın almalar (onaylı)" `purchase_cost` eklenmeli; yoksa
  satırların toplamı gerçekleşen maliyeti vermez (siparişe bağlı faturalar
  `total_expenses`'te de var). `purchase_excluded > 0` ise "Maliyete
  eklenmeyen satın almalar" bilgi satırı; `received_not_costed` etiketi
  "Teslim alınmış, faturası gelmemiş". KPI kartı ipucu "Masraf X + taşeron Y"
  da `expense_cost` + `purchase_cost` ile güncellenmeli.
- Maliyet Kontrolü: Gerçekleşen artık satın almaları içeriyor
  (`purchase_actual_cost`); web "Gerçekleşen" sekmesi yalnızca masrafları
  listeliyor — not ya da satın alma satırları eklenmeli.
- Olay etiketleri: `purchase_request_cost_decision` ("Talebin maliyet kararı
  değişti"), `purchase_order_cost_decision` ("Siparişin maliyet kararı
  değişti") `lib/events.ts`'e.

## 18. Yapay Zekâ Stüdyo — backend (migration 0080)
- Web'de ekranı yok. Uçlar: `mobile/API_CONTRACT.md` "Yapay Zekâ Stüdyo (backend)" (`/ai/studio/*`).
- Proje galerisinde `ai.kind` artık `edit` de olabilir ("Düzenlenmiş fotoğraf"); web rozeti ve etiketi bu türü de tanımalı.
- `ai_photo_created` olayında yeni `studio_image_id` (stüdyodan "Projeye ekle") — hareket metni "Yapay Zekâ Stüdyo'dan eklendi" olabilir.
- İsteğe bağlı: web'de "Görsellerim" (Sahip/Yönetici için `scope=firm`), "Projeye ekle", kalemle bölge düzenleme (maske PNG, saydam = değişecek yer).

## Bilinen tutarsızlıklar (web + backend)
- Katalog fiyatı TL; teklifin para birimi TL değilse (firma varsayılanı
  USD/EUR) katalogdan seçilen fiyat çevrilmeden yazılıyor — web ve mobil
  aynı. Mobil önerilerin üstünde uyarıyor ("Katalog fiyatları TL; bu teklif
  USD…"); web hiç uyarmıyor. Kalıcı çözüm kur çevrimi.
- KDV hariç maliyet/kâr (2026-10-09, backend): finans özetinin kuralı tek
  yerde (`domain.VATBasis`/`CostNet`) ve proje listesi, Maliyet Kontrolü, ek
  iş kârlılığı, ana sayfa aynı kuralla `*_net` alanlarını da döndürüyor
  (bkz. mobile/API_CONTRACT.md "VAT-exclusive figures everywhere else").
  Anlamı değişen alan yok: eksiz alanlar her yerde KDV DAHİL kaldı. Ekranlar
  HENÜZ geçmedi — web proje listesi "Brüt Kâr"/"Gerç. Maliyet", Maliyet
  Kontrolü "Tahmini Kâr/Marj" ve ek iş "Kârlılık" KDV dahil değerleri
  gösteriyor (mobil Maliyet Kontrolü ve ek iş de); `*_net` + "KDV hariç"
  etiketine geçiş web ve mobilde birlikte yapılmalı.
