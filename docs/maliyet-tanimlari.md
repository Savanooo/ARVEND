# Maliyet Tanımları

> Yol haritası adım 0 (2026-10). Uygulama: migration `0073_project_cost_basis`;
> satın almalar migration `0078_purchase_project_cost` (bkz. "Satın almalar").
> Tanımların tek kaynağı veritabanı görünümleridir: `project_cost_basis`
> (proje başına), `subcontract_cost_basis` (taşeron sözleşmesi başına) ve
> `project_cost_lines` (maliyete giren her satır, maliyet koduyla). Finans
> özeti, proje listesi, Ana Sayfa ve Maliyet Kontrolü bu görünümleri okur.
> Rakamları başka yerde yeniden toplamayın, görünüme kolon ekleyin.

## Neden değişti

Önceden "gerçekleşen maliyet" üç ayrı yerde (proje kârlılığı, proje listesi,
Ana Sayfa) ayrı ayrı ve **nakit esaslı** toplanıyordu:

- sözleşmeli taşeronun **onaylanmış ama henüz ödenmemiş** hakedişi maliyette
  görünmüyordu: iş yapılmış, borç doğmuş, kâr olduğundan yüksek görünüyordu;
- iş yapılmadan verilen **avans** maliyet sayılıyordu: kâr olduğundan düşük
  görünüyordu ve aynı para hakedişten mahsup edildiğinde iki kez sayılma
  riski vardı.

## Tanımlar

Bütün tutarlar KDV DAHİLDİR (girildiği gibi). KDV hariç karşılıkta
gerçekleşen maliyetin içindeki bilinen KDV düşülür (`realized_cost_vat`:
masraf satırının KDV'si + onaylı siparişlerin KDV'si; `domain.VATBasis` /
`CostNet`). Talep tahmininin KDV'si bilinmez, KDV oranı girilmemiş masraf
gibi tamamı maliyettir.

| Kavram | Alan | Tanım |
|---|---|---|
| **Gerçekleşen maliyet** | `realized_cost` | Masraflar (`expense_cost`) + **onaylı satın almalar** (`purchase_cost`) + basit taşeronun **iş** ödemeleri + sözleşmeli taşeronun **gerçekleşen işi** |
| **Masraflar (maliyet satırı)** | `expense_cost` | Onaylı masraflardan satın almaya ait OLMAYANLAR. Onaylı/kapatılmış bir siparişe bağlı masraf (alış faturası) satın almanın içindedir, burada sayılmaz. `total_expenses` bütün onaylı masraflardır (nakit) |
| **Satın almalar (onaylı)** | `purchase_cost` | Bkz. "Satın almalar". Maliyet koduna bağlı olmayan payı `purchase_cost_uncoded` |
| **Maliyete eklenmeyen satın almalar** | `purchase_excluded` | "Proje maliyetine eklensin mi?" sorusuna **Hayır** denmiş onaylı talep/siparişlerin tutarı. Maliyet değildir, bilgi |
| **Ödenen** | `paid_cost` | Onaylı masraflar + bütün taşeron ödemeleri (avans dahil). Nakit çıkışı. Ana Sayfa'daki "Proje nakit dengesi" = tahsilat − ödenen |
| **Açık avans** | `advance_open` | Henüz işe sayılmamış / hakedişten mahsup edilmemiş avans. **Maliyet değildir**, kalan taahhüdün içinde durur |
| **Taşerona ödenecek** | `new_subcontract_payable` | Onaylı hakedişlerin net ödenecek tutarı − o işe yapılan ödemeler |
| **Teminatta tutulan** | `new_subcontract_retention` | Onaylı hakedişlerden kesilen teminat. Maliyetin içindedir (iş yapıldı), ödenmemiştir |
| **Onay bekleyen** | `pending_cost` = `pending_expenses` + `new_subcontract_pending_claims` | Onay bekleyen masraflar ve onaya sunulmuş hakedişler. Maliyete girmez, ayrıca gösterilir |
| **Kalan taahhüt** | `subcontractor_remaining`, `new_subcontract_remaining` | Sözleşme başına, negatife düşmeden: basit taşeronda sözleşme − iş ödemesi; sözleşmeli taşeronda güncel değer − gerçekleşen iş |
| **Tahmini maliyet** | `committed_cost` | Gerçekleşen + kalan taahhüt |
| **Teslim alınmış, faturası gelmemiş** | `received_not_costed` | Maliyete eklenen siparişlerde kabul edilen malın KDV dahil değeri − o siparişe bağlı onaylı faturalar (sipariş başına, sıfırın altına inmez). Migration 0078'den beri sipariş tutarıyla **maliyetin içindedir**; "fatura bekleniyor" bilgisi olarak ayrıca gösterilir (migration 0074, `docs/procurement.md` §12) |

### Sözleşmeli taşeronda "gerçekleşen iş"

```
onaylı iş       = SOV kalemi başına en son onaylı kümülatifin toplamı
                  (GetSubcontractCertifiedToDate ile aynı)
iş ödemesi      = hakedişe bağlı ödemeler
                + hakedişe bağlanmadan yapılıp sözleşmedeki avans tutarını AŞAN kısım
gerçekleşen iş  = max(onaylı iş, iş ödemesi)
açık avans      = max(min(bağlantısız ödeme, sözleşme avansı) − onaylı hakedişlerdeki avans mahsubu, 0)
ödenecek        = max(onaylı hakedişlerin net ödenecek toplamı − iş ödemesi, 0)
```

Hakedişe bağlanmadan yapılan ödeme, sözleşmedeki avans tutarına kadar
**avanstır** (taşeron modülünün tasarımı, bkz. `CreateSubcontractPayment`).
Avans tutarını aşan bağlantısız ödeme iş ödemesi sayılır ve gerçekleşen iş,
ödenen iş tutarından az gösterilmez.

Fesih edilmiş sözleşmenin güncel değeri onaylı iştir; kalan taahhüdü bu
yüzden 0'a iner. Maliyet Kontrolü'nün fesih taahhüdüyle aynıdır.

### Basit taşeron (projedeki "Taşeron Ödemeleri")

Ödeme girerken tür seçilir: **İş karşılığı** (varsayılan) ya da **Avans**.

- İş ödemesi gerçekleşen maliyettir.
- Avans ödenendir ama maliyet değildir. **İşe say** ile iş ödemesine döner ve
  o andan itibaren maliyete girer. Ne zaman ve kim tarafından sayıldığı tutulur
  (`offset_at`, `offset_by`). Bu işlem geri alınmaz; yanlış sayıldıysa ödeme
  iptal edilip yeniden girilir.
- Sözleşme bedeli sınırı (toplam ödeme ≤ sözleşme) avansı da kapsar.

### Proje dışı (taşeron kartına) ödeme

Tür: **Genel** (varsayılan) ya da **Avans**. Yalnızca bilgi içindir; proje
maliyetine hiçbir zaman girmez.

## Geçmiş kayıtlar

Sessizce yeniden sınıflandırma yapılmadı:

- Mevcut basit taşeron ödemelerinin hepsi **iş** olarak kaldı (eskisi gibi
  maliyettir).
- Mevcut proje dışı ödemelerin hepsi **genel** oldu.
- Sözleşmeli taşerondaki değişiklik bir tanım düzeltmesidir: onaylanmış ama
  ödenmemiş hakediş artık maliyette görünür; bağlantısız avans artık görünmez.
  Bu, mevcut verideki rakamları değiştirebilir. Deneme verisinde yalnızca bir
  proje etkilendi (+15.375 TL teminat).

## Satın almalar (migration 0078)

Ürün sahibi: "Satın almalar maliyet eklemiyor; proje bedeline eklerse yine
de burada 'proje dahil olsun mu olmasın' diye sorsun." Karar: satın alma
**talebi onaylanınca** maliyete girer; onaylarken "Proje maliyetine
eklensin mi?" diye sorulur (depo/stok ya da genel kullanım için **Hayır**).

Karar `include_in_project_cost` (talepte ve siparişte, varsayılan evet):
- Talep onayında verilir (`POST .../purchase-requests/{id}/approve`
  `{include_in_project_cost, cost_estimate}`; gövdesiz onay = evet).
- Talepten açılan sipariş talebin kararını devralır. Talep ya doğrudan
  (`purchase_request_id`) ya da kaynak RFQ'nun talebi üzerinden bağlanır.
- Sonradan `projects.procurement.approve` izniyle değiştirilebilir
  (`POST .../purchase-requests/{id}/project-cost`,
  `POST .../purchase-orders/{id}/project-cost`): talep onaylıyken, sipariş
  açıkken (taslak/onaylı). Talepte değişen karar açık siparişlerine de
  uygulanır; kapatılmış sipariş kesinleşmiştir. Tamamlanmış/iptal edilmiş
  projede değiştirilemez (rakamları kilitli).

Bir satın almanın maliyete katkısı (yalnızca karar **evet** ise):

| Durum | Maliyete giren |
|---|---|
| Talep taslak / gönderilmiş / reddedilmiş / iptal | 0 |
| Onaylı talep, onaylı ya da kapatılmış siparişi yok | Talebin tahmini: onayda girilen `cost_estimate`, yoksa kalemlerin toplamı (`estimated_total`) |
| Talebin onaylı/kapatılmış siparişi var | Siparişler talebin **yerine** geçer (ikisi birden asla). Siparişlerin hepsi iptal edilirse, talep onaylı kaldıkça tahmine dönülür |
| Sipariş (talepten ya da talepsiz) | `max(sipariş tutarı, siparişe bağlı onaylı faturalar)` — kısmi fatura sipariş tutarının altına düşürmez, fiyat artışı yükseltir |
| Kısa kapatılmış sipariş (teslim kaydıyla kapatılmış) | Sipariş tutarı yerine teslim alınan değer: `Σ round(kabul × birim fiyat, 2)` + KDV — kapanışta taahhüdün indiği tutarla aynı |
| Taslak ya da iptal edilmiş sipariş | 0 |

- Siparişe bağlı onaylı faturalar **ayrıca masraf olarak sayılmaz**
  (`expense_cost`'a girmez): satın almanın içindedir. Siparişi iptal
  edilmiş faturalar normal masraf olarak sayılır.
- Karar **hayır** olan satın alma ve faturaları hiç maliyete girmez;
  `purchase_excluded`'da görünür. Nakit (`paid_cost`) yine bütün onaylı
  masraflardır.
- **KDV:** sipariş toplamı (KDV dahil) ve içindeki KDV (`tax`) bilinir;
  faturalar siparişi aşınca faturaların KDV'si geçerlidir. Talep tahmininin
  KDV'si bilinmez (tamamı maliyet, KDV hariçte de aynı).
- **Para birimi:** sipariş her zaman projenin para birimiyle açılır; görünüm
  yalnızca proje para birimindeki siparişi sayar (döviz çevirisi uydurulmaz).
- **İade:** ayrı bir iade kaydı yok. Teslimde reddedilen miktar kabul
  edilmez; sipariş kapatılınca yalnızca kabul edilen kısım maliyette kalır.
  Kabulden sonraki iade için teslim kaydı (sipariş açıkken) iptal edilir.
- Satın alma onaylanınca tamamıyla gerçekleşendedir; finans özetinin kalan
  taahhüdüne ayrıca eklenmez (`committed_cost` = gerçekleşen + taşeron kalan).
  Maliyet Kontrolü'ndeki sipariş taahhüdü (`project_commitments`) bütçe
  takibi için aynen kalır.
- Fiyatsız talep: maliyete 0 girer. Onay ekranı ve onay yanıtı uyarır
  (`project_cost.warning` = "Bu talepte fiyat yok; maliyete 0 TL girer.");
  onaylayan tahmini tutar girebilir.

**Örnek.** 10 × 1.000 + 5 × 200 = 11.000 TL'lik talep onaylanır → maliyet
11.000. Talepten 12.000 + %20 KDV = 14.400 TL'lik sipariş onaylanır →
maliyet 14.400 (11.000 düşer; KDV hariç 12.000). Siparişe 6.000 TL fatura
bağlanır → maliyet yine 14.400 (fatura ayrıca sayılmaz; nakit 6.000).
İkinci fatura 10.000 TL gelir → faturalar 16.000 > 14.400, maliyet 16.000
(KDV hariç 16.000 − 2.666,67). Sipariş iptal edilseydi maliyet talebin
tahmini 11.000'e dönerdi; talepte "Hayır" deseydi hiçbiri girmezdi.

Talep/sipariş başına katkı `purchase_request_cost_basis` /
`purchase_order_cost_basis` görünümlerindedir; talep ve sipariş yanıtları
`project_cost` (`amount` bugün giren, `potential` eklenseydi girecek,
`source` estimate|orders|order|invoices|none, `warning`) taşır.

### Mevcut kayıtlar

Ürün sahibinin kararıyla mevcut onaylı talep ve siparişlerin hepsi
"maliyete eklensin" (evet) sayıldı; mevcut siparişler kaynak RFQ'nun
talebine bağlandı. **Satın alması olan projelerin gerçekleşen maliyeti
onaylı satın almaları kadar artar, kârı o kadar düşer** — onaylı ama
siparişi olmayan talepler tahminleriyle, onaylı siparişler tutarlarıyla
(faturası girilmiş kısım zaten sayılıyordu, ikinci kez sayılmaz).

Geliştirme veritabanının kopyasında (2026-10-29, 9 proje) 2 proje etkilendi:
- PRJ-2026-0001: 81.355,06 → 90.355,06 TL (+9.000: siparişsiz onaylı talep).
- PRJ-2026-0002: 4.701.150 → 7.057.710 TL (+2.356.560: talepsiz iki onaylı
  sipariş 1.864.800 + 59.760 ve siparişsiz onaylı talep 432.000).
Onay bekleyen (gönderilmiş) talepler girmedi. Depo/stok ya da genel kullanım
için alınmış eski satın almalar talep ya da sipariş ekranından "Maliyete
eklenmesin" yapılmalıdır.

## Maliyet Kontrolü ile mutabakat

Maliyet Kontrolü bir **bütçe takip** ekranıdır ve "Gerçekleşen"i
(`actual_cost`) daha dar tanımlar: yalnızca **bütçe kalemine/maliyet koduna
bağlı** satırlar. Satırlar finans özetiyle aynı kaynaktan
(`project_cost_lines`): onaylı masraflar + onaylı satın almalar (talep
kalemleri, sipariş kalemleri ya da siparişi aşan faturalar; satın almanın
içindeki fatura iki kez sayılmaz). `purchase_actual_cost` bunun satın alma
payıdır. Taşeron işi orada **taahhüt** olarak izlenir. İki ekranın
gerçekleşeni şöyle bağlanır:

```
Proje kârlılığı realized_cost
  = Maliyet Kontrolü actual_cost        (kodlu masraflar + kodlu satın almalar)
  + kodsuz masraflar
  + kodsuz satın almalar                 (purchase_cost_uncoded; ör. kodsuz talep kalemi)
  + basit taşeronun iş ödemeleri         (Maliyet Kontrolü'ne hiç girmez)
  + sözleşmeli taşeronun gerçekleşen işi (Maliyet Kontrolü'nde taahhüt tarafında)
```

Sipariş kalemleri maliyet koduna zorunlu bağlıdır; KDV kalem başına
dağıtılır (yuvarlama farkı ilk kaleme), kalemlerin toplamı siparişin
tutarıdır. Onayda girilen talep tahmini, talebin bütün kalemleri aynı koda
bağlıysa o koda, değilse kodsuz yazılır.

"Tahmini" bölümünde bütçe varsa Maliyet Kontrolü'nün EAC'si kullanılır ve
basit taşeron (iş ödemesi + kalan taahhüt) ile kodsuz satın almalar ayrıca
eklenir. Açık avans kalan taahhüdün içinde olduğu için iki kez eklenmez.

## Bilerek ertelenenler

- **Kodsuz masraf bütçe bazlı tahmine eklenmez** (kodsuz satın alma eklenir,
  migration 0078). Eski davranış korunuyor; ayrı bir kararla eşitlenmeli.
- **Stok sarfı proje maliyetine girmez.** Stok Takibi projeden bağımsızdır.
  Depo/stok için alınan malzeme satın alma onayında "Maliyete eklenmesin"
  ile proje maliyetinin dışında tutulur (migration 0078).
  Fişteki proje seçimi yalnızca bilgidir. Satın alma teslim alma akışı
  (adım 1) kurulunca, stoktan sarf mı yoksa doğrudan teslim mi maliyet
  olacağına ürün sahibi karar verecek. Aynı malzeme iki kez sayılmamalı.
- **Maliyet Kontrolü "Gerçekleşen"ine onaylı hakedişi eklemek.** Mutabakat
  yukarıdaki gibi belgelendi. Maliyet Kontrolü'nün kendi tanımı ayrı bir
  kararla değiştirilecek.
- **Sözleşmeli taşerona ödeme türü seçimi.** Avans hâlâ "hakedişe bağlanmamış
  ödeme" kuralıyla belirlenir.
