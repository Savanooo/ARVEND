# ARVEND Mobil — Üretim Yayın Kontrol Listesi

Bu dosya, mobil uygulamanın Google Play / App Store'a yayınlanması için
gereken adımları ve mevcut durumu belgeler. **Hiçbir gerçek parola,
keystore, sertifika veya API sırrı bu repoda tutulmaz** — bu dosya
yalnızca ne yapılması gerektiğini ve nereden geleceğini anlatır.

Son denetim: bu commit ile (`chore(mobile): prepare production release
configuration`). Flutter 3.44.8 / Dart 3.12.2 / macOS geliştirme makinesi.

Yeniden doğrulandı (2026-09-22, FINAL mobil entegrasyon/production-hardening
fazı — süper admin/RBAC/onboarding/soft-delete backend değişikliklerinden
sonra): §1 (Android imzalama), §2 (kimlik/marka), §3 (API URL/HTTPS), §4
(iOS — Xcode hâlâ eksik kurulu, aynı ortam kısıtı), §11 (oturum güvenliği,
bkz. güncellenen madde) — hepsi AYNI, değişiklik gerekmedi. `flutter
analyze`/`flutter test`/`flutter build apk --debug`/`--release`/`appbundle
--release` bu fazda TEKRAR çalıştırıldı, hepsi temiz/başarılı.

---

## 1. Android Production Signing

**Durum (2026-10-02): upload anahtarı VAR, Play'e hazır AAB üretildi.**

| | |
|---|---|
| Keystore | `~/.arvend/secrets/arvend-upload.jks` (PKCS12, RSA 4096, 2054'e kadar) |
| Alias | `arvend` |
| Parola | macOS Keychain, servis `arvend-upload-keystore`, hesap `arvend` |
| Sertifika SHA-256 | `E2:0C:0B:18:B8:7D:31:39:0A:48:93:AC:AF:D0:6C:BB:EE:D5:48:8E:23:44:CC:AC:C0:E3:CD:4F:32:DC:42:F4` |

Derleme **her zaman** `scripts/derle.sh` ile:

```bash
./scripts/derle.sh play        # Google Play AAB'si
./scripts/derle.sh sideload    # sunucudan dağıtılan APK (sonra scripts/yayinla.sh)
```

Betik parolayı Keychain'den okur (hiçbir dosyaya yazmaz), Gradle flavor'ı ile
`--dart-define=DISTRIBUTION`'ı aynı argümandan verir ve derleme SONRASI
çıktının sertifikasını keystore'dakiyle karşılaştırır — eşleşmezse paketi
reddeder. Parolayı okumak için:

```bash
security find-generic-password -a arvend -s arvend-upload-keystore -w
```

**Debug imzaya düşme artık play'de imkânsız.** `build.gradle.kts` anahtar
bulamazsa release'i debug ile imzalamaya devam ediyor (yerel doğrulama için),
ama `play` flavor'ının release görevleri istenmişse build **reddedilir**.
Sebep somut: 2026-10-02'de sunucuda yayında olan `arvend-4.apk` (1.3.0) bu
yoldan, uyarıya rağmen debug imzalı çıktı. Uyarı loglamak yetmedi.

**Yedek — bugün yapılmalı.** Keystore dosyasını ve Keychain'deki parolayı
makine dışına (parola yöneticisi + şifreli yedek) kopyalayın. Play App
Signing kullanılıyorsa (§16) bu anahtar yalnızca *upload* anahtarıdır ve
kaybı Google desteğiyle sıfırlanabilir — ama bu birkaç gün sürer ve o sürede
güncelleme yüklenemez.

**Neden parola kabuk değişkeninde değil:** RestoFlow'un ilk production
anahtarının parolası `openssl rand` ile üretilip yalnızca o kabukta tutuldu;
kabuk kapanınca anahtar kalıcı olarak açılamaz hâle geldi. Burada parola
anahtar üretilmeden ÖNCE Keychain'e yazıldı ve geri okunabildiği doğrulandı.

`android/key.properties` hâlâ desteklenir (CI ya da Keychain'siz makine
için; `key.properties.example`'a bakın) ve git'e girmez. Ortam değişkenleri
(`ARVEND_UPLOAD_STORE_FILE`, `ARVEND_UPLOAD_KEY_ALIAS`,
`ARVEND_UPLOAD_STORE_PASSWORD`) varsa önceliklidir.

---

## 2. Android Kimlik / Marka

| Alan | Değer | Durum |
|---|---|---|
| Application ID | `com.arvendyapi.arvend` | Zaten geçerli bir üretim kimliği (dev/example paket adı DEĞİL) — **değiştirilmedi**, bilinçli karar. Play Store'a yüklendikten sonra bu ID KALICIDIR. |
| Uygulama etiketi (launcher) | `ARVEND` | Zaten uygun, değiştirilmedi. |
| `version` (pubspec.yaml) | `1.4.0+5` | 2026-09-29: web proje sayfasının kalan bölümleri mobile geldi — Sözleşme (taslak/aktifleştir/tamamla/feshet), Ek İşler (oluştur/düzenle/gönder/mail/revize/iptal), Ödeme Planı, Faturalar, Maliyet Kontrolü yönetimi (bütçe, WBS, revizyonlar, taahhütler, tahmin, gerçekleşen), Planlama (iş programı), Proje Ekibi, Proje Erişimi, Taşeron Ödemeleri (legacy taşeron kaydı + ödemeler), masraf/tahsilat ayrıntısı ve gerekçeli iptali, masraf bağlantıları (ek iş, bütçe kalemi, maliyet kodu), tahsilatın ödeme planı kalemine bağlanması, proje Aktivite Geçmişi (tutarlar yalnızca finans izniyle) ve teklif Aktivite / Mail Geçmişi — yeni özellik, küçük sürüm artışı (bkz. §5 Versiyonlama). Önceki: `1.3.0+4` (yönetim modülleri). |
| compileSdk / minSdk / targetSdk | 36 / 24 / 36 | Flutter 3.44.8'in kendi varsayılanları (`flutter.compileSdkVersion` vb. üzerinden), Play Store'un güncel targetSdk şartını karşılıyor. minSdk 24 = Android 7.0+. |
| Launcher ikonu (adaptive) | `android/app/src/main/res/mipmap-*/ic_launcher*.png` | **Hazır** — gerçek ARVEND "AY" monogramı (gold #D89A22, adaptive foreground) + navy (#111827) arka plan. Placeholder DEĞİL. |
| Açılış ekranı (splash) | `android/app/src/main/res/drawable/launch_background.xml` | **Hazır** — navy zemin + ARVEND monogramı, marka diliyle tutarlı. |

Bu fazda marka/görsel yeniden tasarım YAPILMADI (talimat gereği) — yukarıdakiler zaten önceki fazlarda doğru kurulmuştu, yalnızca doğrulandı.

---

## 3. Production API Yapılandırması

**Durum: zaten doğru, değişiklik gerekmedi.**

`lib/core/config/app_config.dart`:
```dart
static const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://app.arvendyapi.com.tr',
);
```

- Varsayılan (hiçbir `--dart-define` verilmediğinde) **zaten** üretim
  alan adı, **zaten** HTTPS. `docs/production-deployment-plan-szutech2.md`
  ile birebir aynı domain — mobil ve backend production planı tutarlı.
- Yerel geliştirme için: `flutter run --dart-define=API_BASE_URL=http://localhost:8080`
  (veya emulator/simulator'a göre `10.0.2.2`/gerçek LAN IP'si) —
  bu değer yalnızca geliştiricinin kendi `flutter run` komutunda kalır,
  hiçbir zaman derlenmiş release binary'sine GÖMÜLMEZ (release
  build'lerde bu flag'i açıkça vermediğiniz sürece varsayılan üretim
  URL'i kullanılır).
- Repoda hardcoded localhost/emulator IP/geçici tünel adresi
  **bulunmadı**.
- API taban URL'i bir "sır" DEĞİLDİR (backend'in genel adresi) — bu
  yüzden `--dart-define` ile yönetilmesi yeterlidir, ayrı bir secrets
  mekanizması gerekmez.

### HTTPS / Ağ Güvenliği

- `AndroidManifest.xml`: `android:usesCleartextTraffic="false"` —
  cleartext HTTP TAMAMEN kapalı, hiçbir debug-only istisna YOK, özel bir
  `network_security_config.xml` da YOK (platformun kendi varsayılan
  ATS-eşdeğeri davranışına güveniliyor).
- iOS `Info.plist`: `NSAppTransportSecurity` anahtarı hiç YOK — bu,
  iOS'un varsayılan (yalnızca HTTPS, TLS 1.2+) App Transport Security
  politikasının AYNEN geçerli olduğu, hiçbir istisna eklenmediği
  anlamına gelir.
- Hiçbir yerde sertifika doğrulamasını atlayan/bypass eden kod
  (`badCertificateCallback`, custom `HttpClient` trust-all, vb.)
  **bulunmadı**.

---

## 4. iOS Platform

**Durum: `ios/` dizini bu görevde oluşturuldu (`flutter create --platforms=ios --org com.arvendyapi .`). Derleme DOĞRULANMADI çünkü bu makinede Xcode eksik kurulu (`flutter doctor`: "Xcode installation is incomplete").**

`flutter build ios --no-codesign` denendi (kanıt için) ve beklendiği gibi
başarısız oldu: `Application not configured for iOS`. Kök neden Xcode'un
eksik kurulumu — proje dosyalarının KENDİSİ (Info.plist, bundle
identifier, `project.pbxproj`) doğrudan dosya incelemesiyle AYRI AYRI
doğrulandı ve doğru/eksiksiz. Xcode tam kurulduğunda bu komutun
başarıyla tamamlanması beklenir.

| Alan | Değer |
|---|---|
| Bundle Identifier | `com.arvendyapi.arvend` — Android `applicationId` ile BİREBİR aynı (bilinçli, `--org com.arvendyapi` ile üretildi). |
| Görünen ad (`CFBundleDisplayName`) | `ARVEND` — Android launcher etiketiyle aynı olacak şekilde şablon değerinden ("Arvend") güncellendi. |
| Deployment target | iOS 13.0 (Flutter 3.44.8'in kendi şablon varsayılanı, değiştirilmedi). |
| App Icon | **Eksik — bkz. §8 Store Varlıkları.** Şu an Flutter'ın jenerik placeholder logosu duruyor, ARVEND markası DEĞİL. |
| Launch Screen | **Eksik — bkz. §8.** Şu an Flutter'ın jenerik şablonu, ARVEND markası DEĞİL. |
| Kamera izni (`NSCameraUsageDescription`) | Eklendi — yalnızca gerçekten kullanılan `image_picker` kamera akışı için (bkz. "Fotoğraf Çek", proje detay ekranı). |
| Galeri izni (`NSPhotoLibraryUsageDescription`) | Eklendi — yalnızca gerçekten kullanılan `image_picker` galeri akışı için. |
| Dosya seçici (`file_picker`) | İzin metni GEREKMEZ — iOS'un kendi sistem doküman seçicisini (`UIDocumentPickerViewController`) kullanır. |
| Dosya açma (`open_filex`) | İzin metni GEREKMEZ — iOS'un kendi doküman etkileşim/önizleme arayüzünü kullanır. |
| Konum/kişi/mikrofon/reklam kimliği | Hiçbiri kullanılmıyor — ilgili hiçbir izin metni EKLENMEDİ (var olmayan bir yeteneği İCAT ETMEMEK için). |
| Bildirim izni | Uygulanabilir DEĞİL — mobil yalnızca UYGULAMA İÇİ bildirim kullanıyor, OS push/APNs YOK (bkz. §6). |
| Derin bağlantı / URL scheme | Kullanılmıyor — `CFBundleURLTypes` şablonun ürettiği varsayılan dışında hiçbir şey eklenmedi. |

### Kullanıcının yapması gerekenler (Apple tarafı)

Bu ajan/oturum bunların HİÇBİRİNİ üretemez/varsayamaz:

1. Apple Developer Program üyeliği (yıllık ücretli).
2. Bir Apple Team ID.
3. App Store Connect'te Bundle ID (`com.arvendyapi.arvend`) kaydı.
4. Xcode ile gerçek bir imzalama sertifikası + provisioning profile
   (veya Xcode'un "Automatically manage signing" özelliği, Team seçili
   olduğunda).
5. Xcode'un TAM kurulumu (bu makinede yalnızca CocoaPods var, Xcode
   eksik) — `sudo xcode-select --switch /Applications/Xcode.app/...` +
   `sudo xcodebuild -runFirstLaunch`.

Xcode kurulduktan sonra, imzalama olmadan statik bir derleme kontrolü:
```bash
flutter build ios --no-codesign
```
Gerçek Store dağıtımı için (Apple kimlik bilgileri hazır olduğunda):
```bash
flutter build ipa
```

---

## 5. Versiyonlama Kuralları

Mevcut: `pubspec.yaml` → `version: 1.4.0+5` (`1.4.0` = semantik sürüm,
`5` = build numarası — Android `versionCode`/iOS `CFBundleVersion` bu
build numarasından TÜRETİLİR, ayrıca elle senkronize EDİLMEZ).

Gelecek sürümler için kural:
- **Semantik sürüm** (`x.y.z`): `x` = yıkıcı/büyük değişiklik,
  `y` = yeni özellik, `z` = hata düzeltmesi. Store'daki kullanıcıya
  görünen sürümdür.
- **Build numarası** (`+N`): HER Play Store / App Store yüklemesinde
  KESİNLİKLE artan tamsayı olmalı (aynı sürüm için bile). İki platform
  AYNI build numarasını paylaşır — Android `versionCode` ve iOS
  `CFBundleVersion` `flutter build`'in `--build-number` bayrağıyla (veya
  pubspec'teki `+N`'den) AYNI kaynaktan gelir, elle ayrı ayrı
  YÖNETİLMEZ.
- Örnek bir sonraki sürüm: `1.4.1+6` (hata düzeltmesi) veya `1.5.0+6`
  (yeni özellik).

---

## 6. Bildirimler — Yayın Durumu

**Uygulama İÇİ bildirim VAR. OS push (FCM/APNs) YOK.**

- Backend: `notifications` tablosu + `GET /notifications`, `POST
  /notifications/{id}/read` vb. — kullanıcı uygulamayı AÇIKKEN görür.
- Mobil: `lib/features/notifications/` — zil ikonu + liste, cihaz token
  kaydı YOK, `firebase_messaging`/`flutter_local_notifications` gibi
  hiçbir push paketi pubspec.yaml'da YOK.
- **Bu görev push bildirim EKLEMEDİ** (kapsam dışı, talimat gereği).
  Play Store Data Safety / App Store Privacy formlarında "push
  notification" YETENEĞİ İDDİA EDİLMEMELİDİR — yalnızca uygulama-içi
  bildirim doğrudur.
- İleride push eklenirse: ayrı bir ürün kararı + ayrı bir gizlilik
  değerlendirmesi gerekir (FCM/APNs cihaz kimliği toplar).

---

## 7. E-posta / SMTP

**Mobilde SMTP gönderim kodu/sırrı YOK — doğrulandı.**

- Teklif ve Ek İş e-postaları backend'den gönderilir (1.4.0+5'ten beri
  Ek İş detayındaki "Mail Gönder" yalnızca `POST .../send-email` çağırır;
  alıcı ve mesaj istek gövdesindedir)
  (`backend/internal/platform/mailer/mailer.go`,
  `backend/internal/config/config.go`'daki `SMTP_*` env değişkenleri).
- Mobilde mail gönderen paket/kod YOK. 1.3.0+4'ten beri yalnızca bir
  YÖNETİM ekranı var: Diğer > E-posta Ayarları
  (`lib/features/settings/`, web `/admin/ayarlar` karşılığı) firmanın
  SMTP ayarlarını backend'in `GET/PUT /settings/smtp` ve
  `POST /settings/smtp/test` uçlarıyla okur/yazar (Sahip/Yönetici +
  `organization.settings.*`). Backend kayıtlı parolayı ASLA döndürmez;
  ekran yalnızca "Kayıtlı / Kayıtlı değil" gösterir. Yöneticinin yazdığı
  yeni parola yalnızca PUT gövdesinde gider, cihazda saklanmaz.
- Backend dağıtımında gereken (bu repo tarafından yönetilmez, sunucu
  operatörünün işi): gerçek SMTP host/port/kullanıcı/parola,
  `docs/production-deployment-plan-szutech2.md`'deki env dosyası
  düzenine göre `/etc/arvend/backend.env`'e yazılmalı.

---

## 8. Store Varlıkları Envanteri

### Repoda HAZIR olanlar
- Android adaptive launcher ikonu (marka ile tutarlı).
- Android açılış ekranı (marka ile tutarlı).
- Uygulama adı/paket kimliği (her iki platformda tutarlı).

### Repoda EKSİK / bu fazda ÜRETİLMEDİ (bilinçli — gerçek tasarım varlığı gerektirir)
- **iOS App Icon seti** — şu an Flutter'ın jenerik logosu duruyor.
  Android'deki "AY" monogramından türetilmeli ama iOS ikonları
  şeffaflık İÇEREMEZ (App Store reddeder) — Android'in adaptive
  foreground'undaki saydam zemin dolgulu (navy `#111827`) bir sürüme
  çevrilmeli, sonra 1024×1024'ten tüm gerekli boyutlara indirgenmeli.
- **iOS Launch Screen** — aynı şekilde jenerik, ARVEND monogramıyla
  güncellenmeli (`ios/Runner/Base.lproj/LaunchScreen.storyboard`).

### Store-console'da hazırlanması gereken (bu repoda TUTULMAZ)
Android (Play Console):
- Feature graphic (1024×500).
- Telefon ekran görüntüleri (min. 2, önerilen 4-8).
- Kısa açıklama (80 karakter) + tam açıklama.
- Gizlilik politikası URL'i (bkz. §9 — HENÜZ YOK).
- Destek e-postası/iletişim.
- Data Safety formu (bkz. §10 envanteri — bu form için veri sağlandı).

iOS (App Store Connect):
- Cihaz sınıfı başına ekran görüntüleri (6.7", 6.5", 5.5" iPhone +
  gerekirse iPad).
- Alt başlık, açıklama, anahtar kelimeler.
- Destek URL'i, gizlilik politikası URL'i (bkz. §9).
- App Privacy anketi (bkz. §10 envanteri).

---

## 9. Yasal / Gizlilik

**Durum (2026-10-06): yayında.** Gizlilik Politikası + KVKK aydınlatma metni
`https://app.arvendyapi.com.tr/gizlilik` (kaynak:
`frontend/app/gizlilik/page.tsx`, giriş istemez -- `proxy.ts` matcher'ında
yok). Hesap silme bölümü `#hesap-silme` (Play'in "hesap silme URL'si").
Yayınlayan: ARVEND Yapı, iletişim info@arvendyapi.com.tr.

- İçerik §10'daki veri envanterine dayanır. Yeni bir veri türü eklenince
  (ör. push bildirimi cihaz kimliği) sayfa, §10 ve Play "Veri güvenliği"
  formu BİRLİKTE güncellenir.
- Uygulama içi bağlantı (mağazalar ister): giriş ekranının altı ve
  Diğer > Hakkında; adres `AppConfig.privacyPolicyUrl` (1.5.5+11).
- Metin bir hukuk danışmanına gösterilmedi; avukat kontrolü önerilir.

---

## 10. Veri / Gizlilik Envanteri (fiili koda dayalı, fazla tahmin YOK)

Bu envanter Play Data Safety / App Privacy / KVKK formlarını doldururken
kaynak olarak kullanılabilir.

### Mobil uygulamanın işlediği veriler
| Veri | Nerede | Not |
|---|---|---|
| Kimlik doğrulama (kullanıcı adı/şifre) | Giriş ekranı → backend | Şifre asla cihazda saklanmaz; oturum HttpOnly çerezle tutulur (bkz. §11). |
| Kullanıcı kimliği/rolü/organizasyon | `/auth/me` yanıtı | Uygulama içi yetkilendirme için. |
| Müşteri verisi (ad/telefon/e-posta/adres/vergi bilgisi) | Müşteri modülü | Kullanıcının KENDİ organizasyonunun ticari verisi. |
| Proje/teklif finansal verisi | Proje/Teklif/Taşeron/Hakediş modülleri | Tutarlar, sözleşme değerleri — ticari veri, backend'de saklanır. |
| Fotoğraflar (kamera/galeri) | Şantiye fotoğrafları | Kullanıcı AÇIKÇA seçtiği/çektiği fotoğraflar, backend'e yüklenir. |
| Yüklenen dosyalar | Proje dosyaları | Kullanıcının yüklediği belgeler (PDF/vb.), backend'e yüklenir. |
| Devam/mesai kayıtları | Attendance modülü | Elle girilen, GPS'siz kayıtlar (bkz. aşağı). |
| Personel kaydı (ad, telefon, görev, başlangıç tarihi, maaş/yevmiye) | Diğer > Personel (1.3.0+4) | Maaş/yevmiye backend'den YALNIZCA `employees.manage` sahibine döner, diğerlerinde hiç gelmez. |
| Kullanıcı hesapları (kullanıcı adı, ad, rol, kişiye özel yetkiler) | Diğer > Kullanıcılar, Roller & Yetkiler (1.3.0+4, yalnız Sahip/Yönetici) | Yeni hesap / şifre sıfırlama parolası yalnızca istek gövdesinde backend'e gider, cihazda saklanmaz. |
| Tedarikçi verisi (unvan, vergi no/dairesi, iletişim, adres) | Diğer > Tedarikçiler (1.3.0+4) | Ticari veri. IBAN yalnızca yazılır; okunamaz, ekranda yalnızca "IBAN kayıtlı / değil". |
| Proje ekibi ve proje erişimi (personel adı/görevi, kullanıcı adı, proje rolü) | Proje > Operasyon > Ekip / Erişim (1.4.0+5) | Kullanıcı seçici (`/users`) yalnızca `projects.access.manage` ile, "Erişim Ver" açılınca çekilir. Maaş/yevmiye bu ekranlarda hiç yoktur. |
| Ek İş / teklif mail alıcıları (müşteri e-postası) | Ek İş detayı "Mail Gönder", teklif "Mail Geçmişi" (1.4.0+5) | Alıcı adresi müşteri kaydından önerilir; cihazda saklanmaz. |
| Uygulama içi bildirimler | Bildirim modülü | Yalnızca uygulama içinde, cihaz push token'ı YOK. |

### Mobil uygulamanın TOPLAMADIĞI veriler (doğrulandı, tahmin değil)
- **Hassas/arka plan konum** — `geolocator`/`location` gibi hiçbir paket
  YOK, `AndroidManifest.xml`'de `ACCESS_FINE_LOCATION`/
  `ACCESS_BACKGROUND_LOCATION` YOK.
- **Kişiler** — kişi listesine erişim YOK.
- **Reklam kimliği** — hiçbir reklam/analytics SDK'sı YOK (bkz. §13).
- **Mikrofon** — ses kaydı özelliği YOK, `RECORD_AUDIO` izni YOK.
- **Push/cihaz token'ı** — bkz. §6.

---

## 11. Production API / Oturum Güvenliği

- **Oturum**: access/refresh token'lar HttpOnly çerez olarak backend
  tarafından yönetilir (`PersistCookieJar`, `cookie_jar` +
  `dio_cookie_manager`) — token DEĞERİ hiçbir zaman Dart tarafına
  çıkarılmaz, yalnızca çerez header'ı olarak taşınır.
- **Refresh**: tek-uçuş (single-flight) 401→refresh→retry akışı,
  backend'in tek-kullanımlık rotasyonlu refresh token'ıyla uyumlu
  (`lib/core/api/api_client.dart`).
- **Oturum sona erme**: sınıflandırılamayan bir 401/403 refresh
  başarısızlığında `onSessionExpired` çağrılır, `AuthController` oturumu
  temizler, router `/giris`'e yönlendirir. AYRICA (FINAL entegrasyon fazı,
  2026-09-22): organizasyon askıya alınmış/iptal edilmiş/silinmiş VEYA
  kullanıcı pasif/silinmiş olduğu için gelen 403 -- refresh SIRASINDA veya
  SIRADAN herhangi bir API çağrısında -- merkezi olarak sınıflandırılır
  (`classifyAccountAccessIssue`, bkz. API_CONTRACT.md#account-access-
  issues), oturum AYNI tek yetkili yoldan temizlenir ve kullanıcı duruma
  göre özel bir "hesap erişimi kapalı" ekranına ya da bilgilendirilmiş
  giriş ekranına yönlendirilir -- hiçbir ekran tenant API'lerini tekrar
  tekrar ÇAĞIRMAZ (istek fırtınası koruması, bkz. ApiClient
  `_accountBlockNotified`).
- **Loglama**: `_RedactingLogInterceptor`, YALNIZCA
  `!const bool.fromEnvironment('dart.vm.product')` iken (yani
  yalnızca debug/profile build'lerde) eklenir — **release build'de bu
  interceptor hiç DERLENMEZ** (Dart derleyicisi bu dalı sabit-katlama
  ile eler). `flutter build ... --release` çıktısında hiçbir `print()`
  YOKTUR.
- Kod tabanı genelinde (`mobile/lib/`) bu interceptor DIŞINDA hiçbir
  `print()`/`debugPrint()` çağrısı bulunmadı (tüm ağaç tarandı).

---

## 12. Build-Time Bayraklar / Geliştirici Araçları

- `debugShowCheckedModeBanner` özel olarak kapatılmamış — Flutter'ın
  KENDİ mekanizması zaten `--release`/`--profile` build'lerde bu
  bandı OTOMATİK gizler (yalnızca debug build'de görünür,
  App Store/Play Store'a giden build bu bayrağı asla taşımaz).
- Sahte veri/demo modu/sandbox endpoint anahtarı YOK — tek bir
  `apiBaseUrl` kaynağı var (bkz. §3), koşullu "demo" dalı YOK.
- Analytics/crash/telemetry paketi YOK (bkz. §13).

---

## 13. Crash / Analytics

**Şu an hiçbir telemetri/analytics/crash-reporting servisi entegre
DEĞİL** (`pubspec.yaml`'da `firebase_*`/`sentry_flutter`/benzeri hiçbir
paket yok — doğrulandı).

Bu bir EKSİKLİK olarak işaretlenmiyor, yalnızca bir GELECEK ÖNERİSİ
olarak not ediliyor: üretimde crash görünürlüğü isteniyorsa (ör. Sentry
veya Firebase Crashlytics), bu AYRI, açık bir ürün kararı olmalı —
üçüncü taraf bir servise cihaz/hata verisi göndermek gizlilik
politikasını ve Data Safety/App Privacy formlarını DEĞİŞTİRİR. Bu görev
kapsamında hiçbir telemetri paketi EKLENMEDİ.

---

## 14. Sürüm Sonrası Kontrol Listesi (özet)

### Android
- [ ] Production keystore üretildi ve GÜVENLİ bir yerde yedeklendi (§1).
- [ ] `android/key.properties` yerel/CI'da mevcut (repoda DEĞİL).
- [ ] Play Console'da uygulama kaydı + `com.arvendyapi.arvend` bundle.
- [ ] `flutter build appbundle --release` gerçek imzayla üretildi.
- [x] Gizlilik Politikası URL'i hazır (§9); Play Console'a girildi.
- [ ] Data Safety formu dolduruldu (§10 envanterini kullanın).
- [ ] Store varlıkları (feature graphic, ekran görüntüleri, açıklamalar) hazır (§8).

### iOS
- [ ] Apple Developer Program üyeliği aktif.
- [ ] Xcode tam kurulu, `flutter build ios --no-codesign` başarılı.
- [ ] App Store Connect'te Bundle ID (`com.arvendyapi.arvend`) kaydı.
- [ ] İmzalama sertifikası + provisioning profile (veya otomatik imzalama).
- [ ] iOS App Icon + Launch Screen gerçek ARVEND markasıyla güncellendi (§8).
- [ ] `flutter build ipa` gerçek imzayla üretildi.
- [ ] Gizlilik Politikası URL'i + App Privacy anketi (§9, §10).
- [ ] Store varlıkları (ekran görüntüleri, açıklama, anahtar kelimeler) hazır (§8).

### Backend
- [ ] `docs/production-deployment-plan-szutech2.md`'deki plan uygulandı
      (durumu bu dosyada "HENÜZ UYGULANMADI" olarak işaretli).
- [ ] `app.arvendyapi.com.tr` HTTPS ile canlı ve mobilin varsayılan
      `apiBaseUrl`'iyle eşleşiyor.
- [ ] Veritabanı yedekleme stratejisi kurulu.
- [ ] SMTP üretim kimlik bilgileri backend env'ine girildi (§7).
- [ ] Migration'lar production DB'de çalıştırıldı.
- [ ] `JWT_SECRET`/`SETTINGS_ENCRYPTION_KEY`/DB parolası gibi sırlar
      yalnızca sunucu env dosyasında, repoda DEĞİL.

### Mobil
- [ ] Production API URL'i doğrulandı (§3 — zaten doğru).
- [ ] Versiyon/build numarası politikaya göre güncellendi (§5).
- [ ] Android imzalama tamamlandı (§1).
- [ ] iOS ikon/splash gerçek marka varlıklarıyla güncellendi (§8).
- [ ] Gizlilik Politikası linki (gerçek URL hazır olduğunda) Hakkında
      ekranına eklendi (§9).
- [ ] `flutter analyze` / `flutter test` temiz.
- [ ] Play Store'a yüklemeden ÖNCE uzaktan güncelleme kapatıldı:
      `REQUEST_INSTALL_PACKAGES` izni ve mağaza dışı güncelleme denetimi
      kaldırıldı (Google Play ikisini de yasaklar, bkz. §15).

---

## 15. Uzaktan güncelleme (Store öncesi)

Uygulama mağazalara çıkana kadar Android uygulaması kendini bizim
sunucumuzdan günceller — eski BYZ uygulamasının yaptığının aynısı
(`byz-app`: `/api/app-version`, `/api/app-download`, `mobile/yayinla.sh`).
iOS'ta mağaza dışı kurulum olmadığı için bu yalnızca Android içindir.

### Nasıl çalışır

1. Geliştirici bu Mac'te APK'yı derleyip `mobile/scripts/yayinla.sh` ile
   yayınlar; betik APK'yı ve `latest.json`'ı sunucuda
   `/var/lib/arvend/app-releases/android/` altına yazar.
2. Uygulama `GET /api/v1/mobile/app-version?platform=android` ucunu sorar
   (herkese açık, giriş ekranından da). Sunucudaki `build` kurulu build'den
   (`PackageInfo.buildNumber` = pubspec'teki `+N`) büyükse güncelleme
   önerilir; kurulu build `min_build`'den küçükse güncelleme zorunludur.
3. "Güncelle" denince APK `GET /api/v1/mobile/app-download?platform=android`
   ucundan oturum çereziyle iner (yarıda kalırsa istemci baştan indirir;
   sunucu Range'i destekler ama istemci şimdilik kullanmıyor),
   SHA-256'sı doğrulanır ve Android'in kurulum ekranı açılır. İstem
   açıkken yeni bir sürüm yayınlandıysa istemci bunu indirme yanıtının
   `ETag`'inden (= özet) gövdeyi indirmeden anlar, sürüm bilgisini yeniden
   sorar ve güncel sürümle baştan başlar. İlk seferde kullanıcı Android'in
   "Bu kaynaktan izin ver" ayarını bir kez açar (`REQUEST_INSTALL_PACKAGES`).
   İstemci kodu: `lib/core/update/`.

**İlk dağıtım (bir kerelik, elle):** uzaktan güncelleyici ilk kez
**1.2.0+3**'te var. Cihazlardaki 1.1.0+2 ve öncesi sürüm ucunu hiç sormaz;
betikle yapılan hiçbir yayını görmez. 1.2.0+3 APK'sı her cihaza bir kez,
eskisi gibi elle kurulur (AYNI anahtarla imzalı olduğu için verisiyle
birlikte eskisinin üstüne kurulur). Build 4 ve sonrası (ilki `1.3.0+4`)
uzaktan gelir.
1.2.0+3'ü betikle yayınlamak da zararsızdır (betik bu durumda uyarır), ama
eski kurulumlara ulaşmaz.

**Üç katmanlı güvenlik (BYZ ile aynı model):**

1. APK yalnızca oturum açmış bir firma kullanıcısına iner
   (`requireAuth` + `requireTenant`; askıya alınmış firma da indiremez).
   İndirme adresi `.apk` ile bitmez ve `Cache-Control: private, no-store`
   döner — Cloudflare `.apk` uzantısını varsayılan olarak önbelleğe aldığı
   için bu bilinçli; dosya hiçbir kenar önbellekten oturumsuz birine
   sunulmaz.
2. Uygulama inen dosyanın SHA-256'sını sürüm ucundaki özetle karşılaştırır;
   tutmazsa kurulum ekranını hiç açmaz. Sunucu da her yeni yayında diskteki
   APK'nın boyutunu ve SHA-256'sını `latest.json` ile karşılaştırır;
   tutarsız, eksik ya da bozuk bir yayını hiç önermez (`build: 0` döner,
   logda `UYARI: uygulama sürümü ...`).
3. Android güncellemeyi yalnızca kurulu uygulamayla AYNI anahtarla
   imzalanmışsa kurar (aşağıdaki imza uyarısına bak).

**Sunucu tarafı:** API dizini YALNIZCA okur (systemd `ProtectSystem=strict`
okumayı engellemez; `ReadWritePaths` değişikliği GEREKMEZ). Dizin
`APP_RELEASES_DIR` ile verilir; verilmezse `STORAGE_ROOT`'un kardeşi
`app-releases` kullanılır — üretimde `STORAGE_ROOT=/var/lib/arvend/uploads`
olduğu için `/var/lib/arvend/app-releases`, yani env değişikliği de
gerekmez. API `latest.json`'ı her istekte kontrol eder (dosyalar
değişmedikçe önbellekten), yayından sonra yeniden başlatma gerekmez.

İndirme ucu önbelleğe alınamadığı için her indirme ~60 MB'ı sunucunun kendi
hattından çeker. Bu yüzden aynı anda kullanıcı başına en fazla 3, toplamda
en fazla 20 indirme akar; fazlası `429` + `Retry-After: 30` alır (uygulama
"biraz sonra tekrar deneyin" gösterir). Yazma süresi ilerlemeye bağlıdır:
okumaya devam eden yavaş bir hat bitirir (en fazla 1 saat), okumayı bırakan
bir bağlantı ~2 dakikada kesilir.

```
/var/lib/arvend/                     root:arvend      755  (arvend YAZAMAZ -- aşağıdaki kuruluma bak)
└── app-releases/                    szutech2:arvend  755
    └── android/                     szutech2:arvend  755
        ├── latest.json              644  API'nin okuduğu tek kayıt
        ├── arvend-<build>.apk       644  en yeni 3'ü saklanır
        ├── imza.sha256              644  son yayının imza sertifikası (yalnızca betik okur)
        └── .yayin.kilit             betiğin kilidi (aynı anda tek yayın)
```

`latest.json` (betik yazar, elle düzenlenmez):

```json
{"build":3,"version":"1.2.0","sha256":"<64 küçük harf onaltılık>","size":62418702,
 "notes":"Yeni ana sayfa","min_build":0,"file":"arvend-3.apk",
 "published_at":"2026-09-28T10:00:00Z"}
```

Sunucu şunları doğrular: `file` tam olarak `arvend-<build>.apk` (yol
geçişi yok, sembolik bağ kabul edilmez), `version` `x.y.z`, `sha256` 64
küçük harf onaltılık, `size` ve SHA-256 diskteki dosyayla birebir,
`0 <= min_build <= build`, `published_at` RFC3339. Biri tutmazsa yayın yok
sayılır — istemciye asla 500 dönmez.

### Tek seferlik sunucu kurulumu (sudo, yalnızca bir kez)

Önce backend bu özelliği içeren sürüme güncellenmiş olmalı:
`curl -s 'https://app.arvendyapi.com.tr/api/v1/mobile/app-version?platform=android'`
→ `{"platform":"android","build":0}` (eski backend 404 döner).

Sonra szutech2'de (sudo parolası gerekir; yayınlamanın kendisi sudo
GEREKTİRMEZ):

```bash
ssh szutech2@192.168.77.77

# 1. Üst dizin arvend'e YAZILAMAZ olmalı. Dağıtım planı /var/lib/arvend'i
#    arvend:arvend yaptı (chown -R). Linux'ta bir dizini aynı üst dizin
#    içinde yeniden adlandırmak yalnızca ÜST dizine yazma izni ister. Yani
#    arvend kullanıcısıyla çalışan herhangi bir süreç (API'nin sandbox'ı
#    dışında, ör. deploy sırasında 'sudo -u arvend npm ci'nin bir bağımlılık
#    betiği) app-releases'i kenara taşıyıp kendi latest.json'ını ve APK'sını
#    koyabilirdi. Sonuç: her cihazda kapatılamayan, sahte notlu bir zorunlu
#    güncelleme. Android yabancı imzalı APK'yı yine kurmaz (3. katman), ama
#    kullanıcılar kilitli kalır.
#    Önce /var/lib/arvend'in DOĞRUDAN içine arvend olarak yazan bir şey var
#    mı bak. Beklenen içerik: uploads/, backups/. Alt dizinlere yazmak bu
#    değişiklikten etkilenmez; deploy.sh/rollback.sh sudo ile çalışır.
sudo ls -la /var/lib/arvend
sudo chown root:arvend /var/lib/arvend
sudo chmod 755 /var/lib/arvend        # uploads/ kendi 750'siyle kapalı kalır

# 2. Dizinler: sahibi yayını yapan szutech2, grubu API'yi çalıştıran arvend
#    (arvend yalnızca okur: 755/644).
sudo install -d -o szutech2 -g arvend -m 755 \
  /var/lib/arvend/app-releases /var/lib/arvend/app-releases/android

# 3. Doğrulama. 'namei' zincirinde /var/lib/arvend'den android/'e kadar
#    hiçbir bileşen arvend'in sahibi olduğu ya da arvend grubuna yazılabilir
#    (drwxrwx...) bir dizin olmamalı. szutech2 android/'e yazabilmeli, arvend
#    okuyabilmeli ama yazamamalı.
namei -l /var/lib/arvend/app-releases/android
touch /var/lib/arvend/app-releases/android/.deneme && rm /var/lib/arvend/app-releases/android/.deneme
sudo -u arvend ls -la /var/lib/arvend/app-releases/android
for d in /var/lib/arvend /var/lib/arvend/app-releases /var/lib/arvend/app-releases/android; do
  sudo -u arvend test -w "$d" && echo "SORUN: arvend $d'e yazabiliyor -- adım 1/2'ye bak" || echo "tamam: $d"
done
```

`docs/production-deployment-plan-szutech2.md` §2'deki `chown -R arvend:arvend
/var/lib/arvend` yeniden uygulanırsa (yeni sunucu kurulumu) adım 1
tekrarlanmalı.

Mac tarafında `ssh szutech2@192.168.77.77 true` parola sormadan çalışmalı
(betik `BatchMode=yes` kullanır, anahtar yoksa hemen hata verir). Başka bir
hedef için `ARVEND_YAYIN_HEDEFI=kullanici@sunucu:/dizin` ya da
`mobile/.yayin_hedefi` dosyası (ilk satır; git dışında).

### Yayınlama (her sürümde)

```bash
cd mobile
# 1. pubspec.yaml: version: x.y.z+N  -- N HER yayında artmalı (§5).
# 2. Bu Mac'te derle (imza uyarısına bak):
flutter build apk --release
# 3. Önce kontrol -- sunucuda hiçbir şeyi değiştirmez:
./scripts/yayinla.sh "Yeni ana sayfa ve hata düzeltmeleri" --deneme
# 4. Yayınla (terminalde onay sorar):
./scripts/yayinla.sh "Yeni ana sayfa ve hata düzeltmeleri"
# Eski sürümün artık çalışmadığı bir değişiklikse (ör. API kırılması):
./scripts/yayinla.sh "Önemli güncelleme" --zorunlu
```

Betik yayınlamadan önce şunları yapar:
- Sürümü pubspec'ten okur (`x.y.z+N`; ön-sürüm eki kabul edilmez).
- `aapt` (yoksa `aapt2`) ile APK'nın paket adını, `versionCode`'unu ve
  `versionName`'ini pubspec'le karşılaştırır. Eski bir APK'yı yeni numarayla
  yayınlamak mümkün olmaz.
- `apksigner` ile imza sertifikasını okur ve sunucudaki `imza.sha256` ile
  karşılaştırır.
- Bu kontroller **zorunludur**: `aapt`, `apksigner` ya da Java
  bulunamazsa, ya da imza okunamazsa betik yayınlamaz. Kontrolsüz bir yayın
  özellikle `--zorunlu` ile tehlikelidir: yanlış anahtarlı ya da eski bir
  APK, hiçbir cihazın geçemeyeceği bir zorunlu güncelleme döngüsü demektir.
- Araçları şu sırayla arar: `ANDROID_HOME`/`ANDROID_SDK_ROOT`, Flutter'ın
  yazdığı `android/local.properties` `sdk.dir`, `flutter config
  --android-sdk`, bilinen SDK yolları. JDK için sıra: `flutter config
  --jdk-dir`, Android Studio'nun JDK'sı, `JAVA_HOME`.
- Sunucudaki en yüksek build'den (yayındaki `latest.json`, durdurulmuş
  `latest.json.*` ve `arvend-N.apk` dosyaları) küçük ya da ona eşit bir
  build'i reddeder.

Yayına alma:
1. APK ve `latest.json` geçici adlarla yüklenir.
2. Sunucuda TEK bir kilitli adım çalışır (`flock`; aynı anda tek yayın):
   - APK'nın özeti doğrulanır.
   - `latest.json`'ın betiğin okuduğu halinden değişmediği kontrol edilir.
     Onay beklerken ya da yükleme sırasında araya başka bir yayın ya da
     acil durdurma girdiyse **hiçbir şey değiştirilmeden** durulur; betiği
     yeniden çalıştırmak yeterlidir.
   - Önce APK, sonra `latest.json` yerine taşınır. İstemci hiçbir zaman
     olmayan bir APK'yı gösteren JSON görmez.
   - En yeni 3 APK dışındakiler silinir.
3. Son olarak herkese açık sürüm ucu sorulur ve yayının göründüğü
   doğrulanır.

`--zorunlu` verilmezse önceki yayınların (durdurulanlar dahil) en yüksek
`min_build`'i korunur: zorunlu bir sürüm, arkasından gelen normal bir
sürümle "unutulmaz".

**Geri alma:** Android daha düşük `versionCode`'u kurulu sürümün üstüne
kuramaz; hatalı bir sürümü geri almak = önceki kodu YENİ (daha büyük) bir
build numarasıyla derleyip yayınlamak. Acil durumda öneriyi durdurmak için
`latest.json` kaldırılır (sürüm ucu `build: 0` döner, zaten güncellemiş
cihazlar etkilenmez):
`ssh szutech2@192.168.77.77 'mv /var/lib/arvend/app-releases/android/latest.json /var/lib/arvend/app-releases/android/latest.json.durduruldu'`.
Betik durdurulan dosyayı (`latest.json.*`) ve APK'ları okumaya devam eder:
sonraki yayının build'i durdurulan sürümünkinden büyük olmak zorundadır.
Zorunlu taban (`min_build`) de korunur; `--zorunlu`'yu yeniden vermek
gerekmez. Durdurmayı geri almak (aynı sürümü yeniden önermek) için dosya
eski adına taşınır. Durdurulan dosyayı silmek, onun zorunlu tabanını da
unutturur.

**Sorun giderme:** sunucuda `journalctl -u arvend-api | grep 'uygulama sürümü'`
— her yeni yayın `v<sürüm> (build N) yayında` satırıyla, reddedilen yayın
nedeniyle (`SHA-256 özeti latest.json ile tutmuyor`, `file ... desenine
uymuyor` vb.) loglanır.

### İmza uyarısı (ÖNEMLİ)

Android bir güncellemeyi yalnızca kurulu uygulamayla **aynı anahtarla**
imzalanmışsa kurar. Bugün `android/key.properties` olmadığı için release
APK'lar bu Mac'teki **debug anahtarıyla** (`~/.android/debug.keystore`)
imzalanıyor (§1). Sonuçları:

- **Hep bu Mac'te derle.** Başka bir makinenin debug anahtarı farklıdır;
  oradan yayınlanan APK'yı hiçbir cihaz kuramaz ("Uygulama yüklenmedi").
  Betik bunu yakalar: imza sertifikası sunucudaki `imza.sha256`'dan
  farklıysa yayınlamayı reddeder. `~/.android/debug.keystore`'u güvenli bir
  yere yedekle — kaybı, bu kanal için keystore kaybıyla aynıdır.
- **Gerçek keystore'a geçiş (§1) bir kerelik yeniden kurulum demektir.**
  Yeni anahtarla imzalı APK eski kurulumun üstüne kurulamaz. Anahtar
  değişikliğini uzaktan güncelleyiciyle dağıtma (her cihaz ~60 MB indirip
  kurulumda hata alır): cihazlarda uygulamayı kaldırıp yeni APK'yı bir kez
  elle kurdur (veriler sunucuda; yalnızca yeniden giriş gerekir) ya da
  doğrudan mağazaya geç. Yeni anahtarla ilk uzaktan yayında betiğe
  `--imza-degisti` verilir; sonrası normal akış.
- **Play Store'a geçerken** uzaktan güncelleme kapatılmalı: Google Play,
  `REQUEST_INSTALL_PACKAGES` iznini ve uygulamanın kendini mağaza dışından
  güncellemesini yasaklar. Bu artık `play` flavor'ında otomatik — bkz. §16.

---

## 16. Google Play

### Dağıtım kanalları (flavor)

| | `play` | `sideload` |
|---|---|---|
| Çıktı | AAB (Play yalnızca bunu kabul eder) | APK |
| Derleme | `./scripts/derle.sh play` | `./scripts/derle.sh sideload` |
| Kendini güncelleme | **yok** | var (`scripts/yayinla.sh`) |
| `REQUEST_INSTALL_PACKAGES` | manifest birleşmesinde düşürülür | var |
| `applicationId` | `com.arvendyapi.arvend` | aynı |

Play'in Device and Network Abuse politikası, Play'den dağıtılan bir
uygulamanın kendini Play dışında güncellemesini ve
`REQUEST_INSTALL_PACKAGES`'ın bu amaçla kullanımını yasaklıyor. İki katman:
`android/app/src/play/AndroidManifest.xml` izni `tools:node="remove"` ile
düşürür (eklenti manifest'lerinden geleni de), `AppConfig.isPlayBuild` ise
`updateSupportedProvider`'ı kapatır — Play sürümü sunucuya sürüm sormaz, APK
indirmez. `derle.sh play` derleme sonrası AAB'de iznin olmadığını doğrular.

**Play sürümünde zorunlu-güncelleme yok.** `min_build` barajı uzaktan
güncellemeyle birlikte kapanıyor; Play'deki karşılığı In-App Updates API
(henüz eklenmedi).

### Play App Signing — KARAR (2026-10-04): Google yeni anahtar üretir

Seçilen: aşağıdaki **1. seçenek**. `arvend-upload.jks` yalnızca upload
anahtarı; Play'den kurulan uygulama Google'ın anahtarıyla imzalı olacak.

**Bunun sonucu — Play yayına çıkana kadar sideload ile UPLOAD ANAHTARLI
sürüm yayınlanmaz.** Upload anahtarıyla imzalı bir sideload APK, ne sahadaki
debug imzalı kurulumların üzerine kurulabilir ne de sonradan Play'den
güncellenebilir; o kişiler iki kez kaldırıp kurmak zorunda kalır.

O arada sahaya güncelleme **`./scripts/derle.sh saha`** ile gider: sideload
flavor'ı, sahadaki kurulumlarla AYNI (bu Mac'in debug) anahtarıyla imzalı,
betik bunu derleme sonrası doğrular. Telefonlar uygulama içinden günceller,
kaldır/kur gerekmez; Play'e geçişteki tek seferlik kaldır/kur zaten
kaçınılmazdı, buna bir yenisi eklenmez. Sonra her zamanki gibi
`./scripts/yayinla.sh "notlar"` (`--imza-degisti` VERİLMEZ). `yayinla.sh` bunu zaten
engelliyor (yayındaki debug sertifikasından farklı imzayı `--imza-degisti`
verilmeden reddeder) — o bayrağı Play yayına çıkmadan VERMEYİN. Tek istisna,
Play sayfası yayına çıktıktan sonra sahadakilere "kaldırıp Play'den kurun"
diyen son sürüm.

Seçenekler (kayıt için):

Play Console ilk AAB yüklenirken uygulama imzalama anahtarını sorar:

1. **Google yeni anahtar üretsin (varsayılan, önerilen).** `arvend-upload.jks`
   yalnızca *upload* anahtarı olur; kaybolursa Google desteği sıfırlar.
   Sonuç: Play'den kurulan uygulama Google'ın anahtarıyla imzalıdır, yani
   sideload APK'larıyla imza uyuşmaz — Play yayına çıkınca sideload kanalı
   bırakılır.
2. **Kendi anahtarımı kullan** (`arvend-upload.jks`'i PEPK aracıyla
   yükle). Play ve sideload aynı imzayı taşır; o arada sideload ile 1.4.0
   kurmuş biri sonradan Play'den sorunsuz güncelleme alır. Karşılığı: Google
   önerisi upload ve imzalama anahtarlarının ayrı olması.

**Her iki durumda da** sahadaki debug imzalı kurulumlar (1.3.0 / build 4 ve
öncesi) Play'den güncelleme ALAMAZ — bir kereliğine kaldırılıp Play'den
kurulmalı. Play sayfası yayına çıkınca, sideload kanalından bu yönergeyi
taşıyan son bir sürüm (`yayinla.sh --imza-degisti`, notlarında Play linki)
o kullanıcılara ulaşmanın tek yolu.

### Play Console kontrol listesi

- [ ] **Geliştirici hesabı.** 13 Kasım 2023 sonrası açılan *kişisel* hesaplar
      production'dan önce **12 test kullanıcısıyla kesintisiz 14 gün** kapalı
      test ister; *kurumsal* hesaplar (D-U-N-S numarası gerekir) muaf.
      Şirket adına kurumsal hesap haftalar kazandırır.
- [ ] **Gizlilik Politikası + KVKK metni URL'si** — §9, SERT ENGEL.
- [ ] **Data safety formu** — §10'daki envanter (fiili koda dayalı) birebir
      kullanılabilir.
- [ ] **İnceleme için demo hesabı** — uygulama girişsiz hiçbir şey
      göstermiyor; inceleme ekibine kalıcı bir test kullanıcısı verilmeli.
- [ ] **Mağaza varlıkları** — §8 (512×512 ikon, feature graphic, ekran
      görüntüleri, açıklamalar).
- [ ] **İçerik derecelendirmesi, hedef kitle, reklam beyanı** (reklam yok).
- [ ] **İzin gerekçeleri:** `CAMERA` (proje fotoğrafları).
- [ ] İlk AAB: `build/app/outputs/bundle/playRelease/app-play-release.aab`
      → önce *Dahili test* kanalına yükleyip kendi cihazınızda deneyin.
