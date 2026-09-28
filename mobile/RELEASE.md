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

**Durum: yapılandırma hazır, gerçek keystore/parola YOK (kasıtlı olarak
üretilmedi).**

`android/app/build.gradle.kts`, artık `android/key.properties` dosyasını
okuyacak şekilde güncellendi:

- Dosya **varsa**: `release` build type o dosyadaki gerçek üretim
  anahtarıyla imzalanır.
- Dosya **yoksa**: `release` build type debug anahtarıyla imzalanır
  (yerel `flutter build apk --release` çalışmaya devam eder) AMA Gradle
  build çıktısında AÇIKÇA bir uyarı basılır — bu APK/AAB Play Store'a
  YÜKLENEMEZ.

`android/key.properties` hem `android/.gitignore` (proje şablonundan
zaten vardı) hem de `mobile/.gitignore`'da (bu görevde eklendi, ikinci
güvenlik katmanı) hariç tutulur. `*.jks`/`*.keystore`/`*.p12` de aynı
şekilde.

### Kullanıcının yapması gerekenler

1. **Keystore üretin** (yalnızca siz, kendi makinenizde — bu ajan/oturum
   sizin adınıza üretmez):
   ```bash
   keytool -genkey -v -keystore /güvenli/yol/arvend-release.jks \
     -keyalg RSA -keysize 2048 -validity 10000 -alias arvend
   ```
   `/güvenli/yol/` bu reponun DIŞINDA olmalı (ör. şifreli bir parola
   kasası/yedek diski). **Bu dosyayı kaybederseniz Play Store'daki
   uygulamayı bir daha ASLA güncelleyemezsiniz** — App Signing by Google
   Play kullanmıyorsanız bu geri dönüşü olmayan bir kayıptır.
2. `mobile/android/key.properties.example` dosyasını
   `mobile/android/key.properties` olarak kopyalayıp gerçek
   `storeFile`/`storePassword`/`keyAlias`/`keyPassword` değerlerini girin.
3. Doğrulayın: `git status` bu dosyayı GÖSTERMEMELİ (ignore'lanmış
   olmalı). Gösteriyorsa commit ETMEDEN durun ve `.gitignore`'u kontrol
   edin.
4. CI/CD kullanıyorsanız bu dört değeri (+ keystore dosyasının kendisini
   base64 olarak) CI'ın kendi secret store'una (GitHub Actions secrets
   vb.) koyun — asla repoya değil.

---

## 2. Android Kimlik / Marka

| Alan | Değer | Durum |
|---|---|---|
| Application ID | `com.arvendyapi.arvend` | Zaten geçerli bir üretim kimliği (dev/example paket adı DEĞİL) — **değiştirilmedi**, bilinçli karar. Play Store'a yüklendikten sonra bu ID KALICIDIR. |
| Uygulama etiketi (launcher) | `ARVEND` | Zaten uygun, değiştirilmedi. |
| `version` (pubspec.yaml) | `1.1.0+2` | 2026-09-28: yeni Ana Sayfa (dashboard) için küçük sürüm artışı (bkz. §9 Versiyonlama). |
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

Mevcut: `pubspec.yaml` → `version: 1.1.0+2` (`1.1.0` = semantik sürüm,
`2` = build numarası — Android `versionCode`/iOS `CFBundleVersion` bu
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
- Örnek bir sonraki sürüm: `1.0.1+2` (hata düzeltmesi) veya `1.1.0+2`
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

**Mobilde SMTP kodu/sırrı YOK — doğrulandı.**

- Teklif e-postaları backend'den gönderilir
  (`backend/internal/platform/mailer/mailer.go`,
  `backend/internal/config/config.go`'daki `SMTP_*` env değişkenleri).
- Mobil kod tabanında (`mobile/lib/`) `smtp`/`mailer` ile ilgili hiçbir
  paket veya kod YOK — `grep -rn "smtp" mobile/lib/` boş sonuç döner.
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

## 9. Yasal / Gizlilik — YAYIN ENGELİ

**Repoda şu an Gizlilik Politikası / KVKK Aydınlatma Metni / Kullanım
Koşulları YOK.** Bu görev bu metinleri UYDURMADI — hukuki bağlayıcılığı
olan içerik bu ajan tarafından yazılamaz.

**Bu, hem Google Play hem App Store için SERT BİR YAYIN ENGELİDİR:**
her iki mağaza da gönderim formunda geçerli bir Gizlilik Politikası
URL'i ZORUNLU kılar; ARVEND kişisel veri işlediği (kullanıcı kimliği,
müşteri verisi, fotoğraflar — bkz. §10) için KVKK kapsamında da bir
aydınlatma metni gereklidir.

Yapılması gerekenler (kullanıcı/hukuk ekibi tarafından):
1. Gerçek bir Gizlilik Politikası + KVKK Aydınlatma Metni yazdırılmalı
   (avukat/hukuk danışmanı önerilir).
2. Bu metin backend'in web sitesinde (`app.arvendyapi.com.tr` altında
   veya ayrı bir statik sayfada) yayınlanıp KALICI bir URL almalı.
3. O URL, Play Console'un "App content → Privacy policy" alanına ve App
   Store Connect'in "App Privacy → Privacy Policy URL" alanına girilir.
4. **Mobil uygulama içi bağlantı**: gerçek URL netleşene kadar mobile
   HİÇBİR link EKLENMEDİ (talimat gereği — yanlışlıkla üretime çıkabilecek
   sahte/placeholder bir link riske girilmedi). URL netleştiğinde,
   "Diğer > Hakkında" ekranına (`lib/features/profile/presentation/about_screen.dart`)
   tek bir `url_launcher` linki eklemek yeterli olur (paket zaten
   bağımlılıklarda mevcut).

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
- [ ] Gizlilik Politikası URL'i Play Console'a girildi (§9).
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
