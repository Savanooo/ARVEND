import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Production (upload) imzalama -- bkz. mobile/RELEASE.md "Android Production Signing".
//
// İki kaynak, bu sırayla:
//   1. Ortam değişkenleri ARVEND_UPLOAD_STORE_FILE / ARVEND_UPLOAD_KEY_ALIAS /
//      ARVEND_UPLOAD_STORE_PASSWORD (anahtar parolası ayrıca verilmezse aynısı).
//      scripts/derle.sh parolayı macOS Keychain'den okuyup bunları verir --
//      parola hiçbir dosyaya yazılmaz.
//   2. android/key.properties -- GİT'E ASLA COMMIT EDİLMEZ (android/.gitignore'da);
//      CI ya da Keychain'siz makineler için.
// İkisi de yoksa release build DEBUG anahtarıyla imzalanır (yerel doğrulama
// için çalışmaya devam eder) AMA `play` flavor'ında build REDDEDİLİR (aşağıda
// taskGraph kontrolü): 2026-10-02'de sunucudaki arvend-4.apk tam bu yoldan,
// sessizce debug imzalı çıktı. Bir paket bir kez debug imzayla dağıtılırsa,
// gerçek anahtara geçildiği gün o kurulumların hepsi güncellenemez hale gelir.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val releaseStoreFile: String? =
    System.getenv("ARVEND_UPLOAD_STORE_FILE") ?: keystoreProperties.getProperty("storeFile")
val releaseKeyAlias: String? =
    System.getenv("ARVEND_UPLOAD_KEY_ALIAS") ?: keystoreProperties.getProperty("keyAlias")
val releaseStorePassword: String? =
    System.getenv("ARVEND_UPLOAD_STORE_PASSWORD") ?: keystoreProperties.getProperty("storePassword")
val releaseKeyPassword: String? =
    System.getenv("ARVEND_UPLOAD_KEY_PASSWORD")
        ?: System.getenv("ARVEND_UPLOAD_STORE_PASSWORD")
        ?: keystoreProperties.getProperty("keyPassword")
val hasReleaseKeystore =
    listOf(releaseStoreFile, releaseKeyAlias, releaseStorePassword, releaseKeyPassword)
        .all { !it.isNullOrBlank() }

android {
    namespace = "com.arvendyapi.arvend"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Play Store kimliği KALICIDIR -- yayınlandıktan sonra değiştirilemez.
        // com.arvendyapi.arvend zaten geçerli bir üretim kimliği (dev/example
        // paket adı DEĞİL), bilinçli olarak değiştirilmedi.
        applicationId = "com.arvendyapi.arvend"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Dağıtım kanalı. applicationId ikisinde de aynı (Play kimliği kalıcı).
    //   play     -> Google Play (AAB). Kendi kendini güncelleme YOK: Play'in
    //               Device and Network Abuse politikası Play dışı güncellemeyi ve
    //               REQUEST_INSTALL_PACKAGES'ın bu amaçla kullanımını yasaklıyor.
    //               İzin src/play/AndroidManifest.xml'de düşürülür, denetim Dart
    //               tarafında AppConfig.isPlayBuild ile kapanır.
    //   sideload -> mağaza öncesi, sunucudan kendini güncelleyen APK
    //               (scripts/yayinla.sh).
    // Flavor + eşleşen --dart-define=DISTRIBUTION çiftini scripts/derle.sh
    // verir; ayrı düşerlerse play paketi olmayan bir izinle güncellemeye kalkar.
    flavorDimensions += "distribution"
    productFlavors {
        create("play") { dimension = "distribution" }
        create("sideload") { dimension = "distribution" }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Play Store'a YÜKLENEMEYECEK bir imza -- yalnızca yerel
                // doğrulama/CI'nin `flutter build apk --release` çalıştırmaya
                // devam edebilmesi için. bkz. mobile/RELEASE.md.
                signingConfig = signingConfigs.getByName("debug")
                // `logger.warn` `flutter build`'in varsayılan (--verbose
                // OLMAYAN) özet çıktısında GÖRÜNMÜYOR (doğrulandı) -- bu
                // yüzden `logger.error` kullanılıyor: build'i BAŞARISIZ
                // KILMAZ (yalnızca bir log seviyesidir, exception ATMAZ),
                // ama Flutter'ın normal `flutter build apk --release`
                // çıktısında da AÇIKÇA görünür.
                logger.error(
                    "\n⚠️  UYARI: android/key.properties bulunamadı.\n" +
                        "   Bu release build DEBUG anahtarıyla imzalandı -- Play Store'a YÜKLENEMEZ.\n" +
                        "   Production imzalama kurulumu için bkz. mobile/RELEASE.md «Android Production Signing».\n"
                )
            }
        }
    }
}

// Play'e giden bir paket ASLA debug imzayla üretilmez. Yukarıdaki debug
// geri dönüşü yerel doğrulama içindir; play release görevleri istenmişse ve
// gerçek anahtar yoksa burada durulur -- uyarı loglamak yetmedi, uyarıya
// rağmen debug imzalı bir APK yayına çıktı.
gradle.taskGraph.whenReady {
    if (!hasReleaseKeystore && allTasks.any { it.name.contains("PlayRelease") }) {
        throw GradleException(
            "play release için upload anahtarı yok.\n" +
                "scripts/derle.sh play ile derleyin (parolayı Keychain'den okur) ya da\n" +
                "android/key.properties oluşturun. bkz. mobile/RELEASE.md «Android Production Signing»."
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
