import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Production release signing -- bkz. mobile/RELEASE.md "Android Production Signing".
// `android/key.properties`, GİT'E ASLA COMMIT EDİLMEZ (zaten android/.gitignore'da) --
// yalnızca geliştiricinin kendi makinesinde veya güvenli bir CI secret store'unda
// bulunur, gerçek keystore de repo DIŞINDA tutulur. Dosya yoksa release build
// DEBUG anahtarıyla imzalanır (yerel doğrulama/CI için ÇALIŞMAYA devam eder) ama
// Play Store'a YÜKLENEMEZ -- bu durum aşağıda her release build'de AÇIKÇA
// loglanır, sessizce "production" gibi davranılmaz.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
val keystoreProperties = Properties()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

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

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
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

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
