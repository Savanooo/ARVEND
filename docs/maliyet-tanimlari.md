# Maliyet Tanımları

> Yol haritası adım 0 (2026-10). Uygulama: migration `0073_project_cost_basis`.
> Tanımların tek kaynağı iki veritabanı görünümüdür: `project_cost_basis`
> (proje başına) ve `subcontract_cost_basis` (taşeron sözleşmesi başına).
> Finans özeti, proje listesi ve Ana Sayfa bu görünümleri okur. Rakamları
> başka yerde yeniden toplamayın, görünüme kolon ekleyin.

## Neden değişti

Önceden "gerçekleşen maliyet" üç ayrı yerde (proje kârlılığı, proje listesi,
Ana Sayfa) ayrı ayrı ve **nakit esaslı** toplanıyordu:

- sözleşmeli taşeronun **onaylanmış ama henüz ödenmemiş** hakedişi maliyette
  görünmüyordu: iş yapılmış, borç doğmuş, kâr olduğundan yüksek görünüyordu;
- iş yapılmadan verilen **avans** maliyet sayılıyordu: kâr olduğundan düşük
  görünüyordu ve aynı para hakedişten mahsup edildiğinde iki kez sayılma
  riski vardı.

## Tanımlar

Bütün tutarlar KDV DAHİLDİR (girildiği gibi). KDV hariç karşılıklar
değişmedi: yalnızca onaylı masrafların içindeki KDV düşülür
(`domain.VATBasis` / `CostNet`).

| Kavram | Alan | Tanım |
|---|---|---|
| **Gerçekleşen maliyet** | `realized_cost` | Onaylı masraflar + basit taşeronun **iş** ödemeleri + sözleşmeli taşeronun **gerçekleşen işi** |
| **Ödenen** | `paid_cost` | Onaylı masraflar + bütün taşeron ödemeleri (avans dahil). Nakit çıkışı. Ana Sayfa'daki "Proje nakit dengesi" = tahsilat − ödenen |
| **Açık avans** | `advance_open` | Henüz işe sayılmamış / hakedişten mahsup edilmemiş avans. **Maliyet değildir**, kalan taahhüdün içinde durur |
| **Taşerona ödenecek** | `new_subcontract_payable` | Onaylı hakedişlerin net ödenecek tutarı − o işe yapılan ödemeler |
| **Teminatta tutulan** | `new_subcontract_retention` | Onaylı hakedişlerden kesilen teminat. Maliyetin içindedir (iş yapıldı), ödenmemiştir |
| **Onay bekleyen** | `pending_cost` = `pending_expenses` + `new_subcontract_pending_claims` | Onay bekleyen masraflar ve onaya sunulmuş hakedişler. Maliyete girmez, ayrıca gösterilir |
| **Kalan taahhüt** | `subcontractor_remaining`, `new_subcontract_remaining` | Sözleşme başına, negatife düşmeden: basit taşeronda sözleşme − iş ödemesi; sözleşmeli taşeronda güncel değer − gerçekleşen iş |
| **Tahmini maliyet** | `committed_cost` | Gerçekleşen + kalan taahhüt |
| **Teslim alınmış, maliyeti girilmemiş** | `received_not_costed` | Siparişten kabul edilen malın KDV dahil değeri − o siparişe bağlı onaylı masraflar (sipariş başına, sıfırın altına inmez). Maliyete girmez, kaybolmasın diye ayrıca gösterilir (migration 0074, `docs/procurement.md` §12) |

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

## Maliyet Kontrolü ile mutabakat

Maliyet Kontrolü bir **bütçe takip** ekranıdır ve "Gerçekleşen"i
(`actual_cost`) daha dar tanımlar: yalnızca **bütçe kalemine/maliyet koduna
bağlı onaylı masraflar**. Taşeron işi orada **taahhüt** olarak izlenir.
İki ekranın gerçekleşeni şöyle bağlanır:

```
Proje kârlılığı realized_cost
  = Maliyet Kontrolü actual_cost        (kodlu onaylı masraflar)
  + kodsuz onaylı masraflar
  + basit taşeronun iş ödemeleri         (Maliyet Kontrolü'ne hiç girmez)
  + sözleşmeli taşeronun gerçekleşen işi (Maliyet Kontrolü'nde taahhüt tarafında)
```

"Tahmini" bölümünde bütçe varsa Maliyet Kontrolü'nün EAC'si kullanılır ve
basit taşeron (iş ödemesi + kalan taahhüt) ayrıca eklenir. Açık avans kalan
taahhüdün içinde olduğu için iki kez eklenmez.

## Bilerek ertelenenler

- **Stok sarfı proje maliyetine girmez.** Stok Takibi projeden bağımsızdır.
  Fişteki proje seçimi yalnızca bilgidir. Satın alma teslim alma akışı
  (adım 1) kurulunca, stoktan sarf mı yoksa doğrudan teslim mi maliyet
  olacağına ürün sahibi karar verecek. Aynı malzeme iki kez sayılmamalı.
- **Maliyet Kontrolü "Gerçekleşen"ine onaylı hakedişi eklemek.** Mutabakat
  yukarıdaki gibi belgelendi. Maliyet Kontrolü'nün kendi tanımı ayrı bir
  kararla değiştirilecek.
- **Sözleşmeli taşerona ödeme türü seçimi.** Avans hâlâ "hakedişe bağlanmamış
  ödeme" kuralıyla belirlenir.
