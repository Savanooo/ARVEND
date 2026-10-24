# Taşeron Paneli

> Durum: aşama 1 tamam (backend 0075, mobil 1.5.21; 2026-10-24), aşama 2-4 plan. Ürün sahibinin kararları 2026-10-24.
> Uç sözleşmesi: `mobile/API_CONTRACT.md` "Taşeron Paneli".

Taşeron firmalar kendi hesaplarıyla ARVEND'e girer:
- kendi işlerini ve paralarını görür;
- ödeme talebi, masraf ve hakediş gönderir.

Firma bunları iki aşamada onaylar. Onaylanan talep ödeme sürecine girer.

## Kararlar (2026-10-24)

| Konu | Karar |
|---|---|
| Hesap | Firma açar: Taşeronlar > kart > **Giriş aç**, kullanıcı adı + geçici şifre. Taşeron ilk girişte şifresini değiştirir. Bir taşerona birden çok kişi açılabilir. |
| Proje izni | Firma, taşeronun hangi projelerde işlem yapacağını **ayrıca seçer**. Taşeron yalnızca izin verilen projeleri görür. İzin geri alınabilir. |
| Görünürlük | İzinli projelerde kendi kayıtlarının **hepsi**: iş/sözleşme bedeli, onaylı hakediş, ödenen, ödenecek, teminat, kalan alacak, ekstre. |
| Onay | İki aşama: önce **proje yöneticisi** ("iş/harcama doğru"), sonra **finans** (parayı onaylar). Her adımda gerekçeli ret var ve taşerona bildirim gider. |
| Masraf | Taşeronun proje için **kendi cebinden** yaptığı harcama. Onaylanınca **proje masrafı** olur ve aynı tutar **taşerona borç** yazılır; firma ödeyince kapanır. |

## En önemli kural: taşeron yalnızca kendini görür

Bugünkü roller firma çalışanları içindir; "Saha" rolü bile projenin görevlerini, fotoğraflarını ve belgelerini görür. Taşeron hesabı bu uçların **hiçbirine** giremez. Aşağıdakilerin hepsi zorunludur ve testle kilitlenir.

1. **Varsayılan ret.** Taşeron hesabı (`users.supplier_id` dolu) yalnızca şu uçlara girebilir. Diğer bütün uçlarda, o ucun izin kontrolüne bakılmaksızın oturum kapısında (`RequireOnboarded` / `RequireActiveUser`) 403 alır.
   - `/auth/*`
   - kendi şifresi ve hesabı (`/users/me/*`)
   - bildirimler
   - telefon kaydı
   - `/portal/*`
2. **İzin yok.** Taşeronun organizasyon rolü (`subcontractor`) yalnızca `subcontractor.portal` ve `notifications.read` taşır. Kapı bir gün atlansa bile işletme uçları izin kontrolünde reddeder.
3. **Veri her zaman hesaptan türer.** `/portal/*` uçları taşeronu istekten değil, oturumdaki kullanıcının `supplier_id`'sinden bulur. Proje filtresi `subcontractor_project_access`'tir. İstekteki bir kimlik başka bir taşeronun ya da izinsiz projenin kaydına ulaşamaz.
4. **Görünmezler.** Müşteri, teklif ve satış fiyatı, kâr, proje finansı, diğer taşeronlar, görevler, belgeler ve fotoğraflar portalda hiç sorgulanmaz.

## Veri modeli (migration 0075)

| Yapı | Ne için |
|---|---|
| `users.supplier_id` | Hesabın bağlı olduğu taşeron kartı (`suppliers`, `is_subcontractor`). Dolu ise hesap taşeron hesabıdır. |
| Sistem rolü `subcontractor` ("Taşeron") | Her firmaya seed edilir. Rol seçicide görünmez; yalnızca "Giriş aç" ile atanır. |
| İzin `subcontractor.portal` | Yalnızca taşeron rolünde. Mobil, `permissions` boş olunca "her şeye izin" sayan eski kontrollere düşmesin diye izin kümesi boş bırakılmaz. |
| `subcontractor_project_access (supplier_id, project_id)` | Firmanın verdiği proje izni. `project_users`'tan bilerek ayrıdır: proje üyeliği proje uçlarını açar, bu açmaz. |

## Aşamalar

| Aşama | Kapsam | Durum |
|---|---|---|
| **1. Hesap + görüntüleme** | Firma: Giriş aç / sıfırla / pasifleştir, proje izinleri. Taşeron: İşlerim (proje başına iş, bedel, onaylı hakediş, ödenen, ödenecek, teminat, kalan), Ödemeler (ekstre), toplam alacak. Varsayılan ret + izolasyon testleri. | Tamam (canlıya çıkmadı) |
| 2. Ödeme talebi | Tutar, açıklama, fatura/fotoğraf; iş mi avans mı. PY ön onayı → finans onayı → "Ödenecekler" → ödeme kaydına bağlanır → taşeronda "Ödendi". | Plan |
| 3. Masraf | Taşeronun cebinden yaptığı proje harcaması, aynı iki aşamalı onay. Onayda proje masrafı ve taşerona borç oluşur; ödeme borcu kapatır. Masraf ile borcun aynı tutarı iki kez maliyete sokmaması (`project_cost_basis`) tasarlanacak. | Plan |
| 4. Hakediş talebi | Sözleşmeli taşeron bu dönemin işini kalem kalem girer (taslak → gönder). Firma mevcut hakediş ekranından inceler ve onaylar (certify). | Plan |
| Sonra | Puantaj, günlük rapor, fotoğraf, web portalı. | — |

## Açık konular

- Taşeron kullanıcıları firmanın "Kullanıcılar" listesinde ayrı bir başlıkla mı, yoksa yalnızca taşeron kartında mı görünsün? Aşama 1'de kartta yönetilir; kullanıcı listesinde rol adı "Taşeron" görünür, oradan rol/izin değiştirmek sunucuda 409 döner.
- Aşama 3'teki borç kaydının ödeme tarafındaki karşılığı ödeme talebiyle birlikte tasarlanacak.
- Taşeron hesabına bildirim üretilmiyor (uçlar açık, kaynak yok). İlk bildirimler aşama 2'de: talep onaylandı / reddedildi / ödendi.
- Web'de taşeron paneli yok; taşeron yalnızca mobilden girer (web işi en son).
