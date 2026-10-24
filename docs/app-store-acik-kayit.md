# App Store'da herkese açık yayın: açık kayıt planı

> Durum: karar bekliyor (ürün sahibi "en son karar verelim" dedi, 2026-10-25). Kod yazılmadı.

## Sorun

Apple 1.5.15'i (2026-10-17) **Guideline 3.2 (Business)** ile reddetti: uygulama "belirli bir firmaya özel" sayıldı. Sebep: App Store'dan indiren biri hiçbir şey yapamıyor, firmayı yalnızca platform (super admin) açabiliyor; kendi kendine kayıt yok.

Şu an iOS kullanıcıları TestFlight'ta. Unlisted (listelenmeyen) dağıtım ayrı bir seçenek; ürün sahibi **herkese açık** yayın istiyor.

## Plan (onaylanırsa, sürüm 1.5.22)

1. **Açık kayıt:** giriş ekranında "Firma hesabı oluştur". Herhangi bir firma kendi hesabını açar.
   - Kararlar: onay yok, **14 gün deneme** (2026-10-25).
   - Sunucu: herkese açık `POST /auth/register`. `PlatformService.CreateOrganizationWithOwner`'ı `trial` + 14 gün ile kullanır, sahip `must_change_password=false`, kayıttan sonra doğrudan oturum açılır. Slug firma adından üretilir. IP başına istek sınırı (`login_limiter.go` deseni). Gizlilik/KVKK onayı zorunlu, audit'e yazılır.
   - Mobil: kayıt formu (firma adı, ad soyad, kullanıcı adı, şifre, gizlilik onayı), ardından mevcut kurulum sihirbazı.
2. **Hesap silme (Apple 5.1.1(v)):** bugün firmanın tek sahibi kendini silemiyor (`DeleteOwnAccount` → `ErrLastOwner`, 409). Yeni yol: "Firmamı kapat ve hesabımı sil". Firma `cancelled` olur, veriler hemen silinmez (platform sonra temizler).
3. **Uygulamada fiyat/ödeme yok:** deneme bitince ücretlendirme uygulama dışında (3.1.3 kurumsal hizmet). Uygulama içi satın alma IAP zorunluluğu getirir.
4. **Apple:** 3.2'nin 5 sorusuna cevap (çok kiracılı sistem, her firma kayıt olabilir, taşeronlar da kendi hesabıyla girer, ödeme firmayla uygulama dışında). İnceleme notuna demo hesap + "kayıt açık" yazılır. Yeni sürüm App Store incelemesine.

## Tahmin

Kayıt + silme + testler yaklaşık bir iş günü; Apple incelemesi genelde 1-3 gün.
