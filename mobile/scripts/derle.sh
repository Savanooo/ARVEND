#!/usr/bin/env bash
# ARVEND mobil -- üretim derlemesi (Google Play AAB'si ya da sideload APK'sı).
#
# Kullanım (mobile/ dizininde):
#   ./scripts/derle.sh play        # Google Play'e yüklenecek AAB
#   ./scripts/derle.sh sideload    # sunucudan dağıtılan APK (sonra scripts/yayinla.sh)
#   ./scripts/derle.sh saha        # sideload APK, SAHADAKİ kurulumlarla aynı (debug)
#                                  # anahtarla -- Play yayına çıkana kadar sahaya
#                                  # giden tek yol (RELEASE.md §16)
#
# Neden elle `flutter build` değil: üç şey birbirinden ayrı düştüğünde sessizce
# yanlış bir paket çıkıyor ve bu betik üçünü tek argümana bağlıyor:
#   1. Gradle flavor'ı ile --dart-define=DISTRIBUTION aynı olmalı. play
#      flavor'ı REQUEST_INSTALL_PACKAGES'ı düşürür; dart-define sideload kalırsa
#      uygulama olmayan bir izinle kendini güncellemeye kalkar (ve Play
#      politikasını çiğner).
#   2. İmza: upload anahtarının parolası macOS Keychain'den okunur, hiçbir
#      dosyaya yazılmaz. Gradle anahtar bulamazsa debug'a düşebiliyordu --
#      sunucudaki arvend-4.apk bu yüzden debug imzalı çıktı. Bu betik derleme
#      SONRASI çıktının sertifikasını keystore'dakiyle karşılaştırır.
#   3. play paketinde REQUEST_INSTALL_PACKAGES olmadığı da derleme sonrası
#      doğrulanır.
#
# Ayrıntı: mobile/RELEASE.md «Android Production Signing» ve «Google Play».
set -euo pipefail

KEYSTORE="${ARVEND_UPLOAD_STORE_FILE:-$HOME/.arvend/secrets/arvend-upload.jks}"
KEY_ALIAS="${ARVEND_UPLOAD_KEY_ALIAS:-arvend}"
KEYCHAIN_ACCOUNT="arvend"
KEYCHAIN_SERVICE="arvend-upload-keystore"
API_BASE_URL="${API_BASE_URL:-https://app.arvendyapi.com.tr}"

MOBIL="$(cd "$(dirname "$0")/.." && pwd)"
hata() { printf '\n!!! HATA: %s\n' "$*" >&2; exit 1; }

kanal="${1:-}"
case "$kanal" in
  play|sideload|saha) ;;
  *) echo "Kullanım: $0 {play|sideload|saha}" >&2; exit 2 ;;
esac
# saha: sideload flavor'ı, ama upload anahtarı YOK -> build.gradle.kts debug
# anahtarına düşer. Sahadaki 1.3.0 (build 4) ve öncesi bu Mac'in debug
# anahtarıyla imzalı; upload anahtarlı bir APK onların üzerine kurulmaz ve
# sonra Play'e geçerken ikinci kez kaldır/kur gerekir (RELEASE.md §16).
flavor="$kanal"
if [ "$kanal" = "saha" ]; then
  flavor="sideload"
  KEYSTORE="$HOME/.android/debug.keystore"
  KEY_ALIAS="androiddebugkey"
  unset ARVEND_UPLOAD_STORE_FILE ARVEND_UPLOAD_KEY_ALIAS ARVEND_UPLOAD_STORE_PASSWORD ARVEND_UPLOAD_KEY_PASSWORD
fi

# --- Araçlar (yayinla.sh ile aynı arama sırası) -----------------------------
jdk_bul() {
  local aday
  for aday in \
    "$(flutter config --list 2>/dev/null | sed -n 's/^ *jdk-dir: *//p' | head -n1)" \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
    "${JAVA_HOME:-}" \
    "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" \
    "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home"; do
    [ -n "$aday" ] && [ -x "$aday/bin/keytool" ] && { echo "$aday"; return 0; }
  done
  return 1
}
apksigner_bul() {
  local sdk surum
  command -v apksigner >/dev/null 2>&1 && { command -v apksigner; return 0; }
  for sdk in "${ANDROID_HOME:-}" \
    "$(sed -n 's/^sdk\.dir=//p' "$MOBIL/android/local.properties" 2>/dev/null | head -n1)" \
    "$HOME/Library/Android/sdk" /opt/homebrew/share/android-commandlinetools; do
    [ -n "$sdk" ] && [ -d "$sdk/build-tools" ] || continue
    for surum in $(ls -1 "$sdk/build-tools" | sort -t . -k 1,1nr -k 2,2nr -k 3,3nr); do
      [ -x "$sdk/build-tools/$surum/apksigner" ] && { echo "$sdk/build-tools/$surum/apksigner"; return 0; }
    done
  done
  return 1
}

JDK=$(jdk_bul) || hata "JDK bulunamadı (keytool gerekli). JAVA_HOME verin."
KEYTOOL="$JDK/bin/keytool"

# --- Anahtar ------------------------------------------------------------------
[ -f "$KEYSTORE" ] || hata "keystore yok: $KEYSTORE (bkz. RELEASE.md «Android Production Signing»)"
if [ "$kanal" = "saha" ]; then
  PW=android  # Android debug keystore'unun herkesçe bilinen sabit parolası
else
  PW=$(security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null) \
    || hata "keystore parolası Keychain'de yok (servis: $KEYCHAIN_SERVICE). Anahtar Zinciri Erişimi'nde arayın ya da yedeğinizden geri yükleyin."
fi

# Beklenen sertifika özeti (apksigner'ın 'certificate SHA-256 digest' biçimi:
# DER sertifikanın SHA-256'sı, küçük harf, ayraçsız).
BEKLENEN=$("$KEYTOOL" -exportcert -alias "$KEY_ALIAS" -keystore "$KEYSTORE" -storepass "$PW" 2>/dev/null \
  | shasum -a 256 | cut -d' ' -f1) || hata "keystore açılamadı (parola ya da alias yanlış)"
[ -n "$BEKLENEN" ] || hata "keystore'dan sertifika okunamadı"

if [ "$kanal" != "saha" ]; then
  export ARVEND_UPLOAD_STORE_FILE="$KEYSTORE"
  export ARVEND_UPLOAD_KEY_ALIAS="$KEY_ALIAS"
  export ARVEND_UPLOAD_STORE_PASSWORD="$PW"
fi
unset PW

SURUM=$(sed -n 's/^version: *//p' "$MOBIL/pubspec.yaml" | head -n1)
BUILD="${SURUM##*+}"

echo "Kanal      : $kanal"
echo "Sürüm      : $SURUM"
echo "API adresi : $API_BASE_URL"
echo "Anahtar    : $KEYSTORE ($KEY_ALIAS)"
echo

cd "$MOBIL"
DEFINES=(--dart-define=API_BASE_URL="$API_BASE_URL" --dart-define=DISTRIBUTION="$flavor")

if [ "$kanal" = "play" ]; then
  flutter build appbundle --release --flavor play "${DEFINES[@]}"
  CIKTI="build/app/outputs/bundle/playRelease/app-play-release.aab"
else
  flutter build apk --release --flavor "$flavor" "${DEFINES[@]}"
  CIKTI="build/app/outputs/flutter-apk/app-sideload-release.apk"
fi
unset ARVEND_UPLOAD_STORE_PASSWORD

[ -f "$CIKTI" ] || hata "beklenen çıktı yok: $CIKTI"

# --- Derleme sonrası doğrulama --------------------------------------------------
echo
echo "=== Doğrulama ==="
if [ "$kanal" = "play" ]; then
  # AAB jarsigner ile imzalanır; keytool -printcert -jarfile okur.
  GERCEK=$("$KEYTOOL" -printcert -jarfile "$CIKTI" 2>/dev/null \
    | sed -n 's/^[[:space:]]*SHA256: *//p' | head -n1 | tr -d ':' | tr 'A-F' 'a-f')
  MANIFEST=$(unzip -p "$CIKTI" base/manifest/AndroidManifest.xml | strings)
  if echo "$MANIFEST" | grep -q REQUEST_INSTALL_PACKAGES; then
    hata "play paketinde REQUEST_INSTALL_PACKAGES var -- Play politikası ihlali, yüklemeyin"
  fi
  echo "REQUEST_INSTALL_PACKAGES : yok (doğru)"
else
  APKSIGNER=$(apksigner_bul) || hata "apksigner bulunamadı (Android SDK build-tools)"
  GERCEK=$(JAVA_HOME="$JDK" PATH="$JDK/bin:$PATH" "$APKSIGNER" verify --print-certs "$CIKTI" 2>/dev/null \
    | sed -n 's/^Signer #1 certificate SHA-256 digest: *//p' | head -n1)
fi

[ -n "$GERCEK" ] || hata "çıktının imza sertifikası okunamadı"
if [ "$GERCEK" != "$BEKLENEN" ]; then
  hata "çıktı beklenen anahtarla ($KEYSTORE) imzalanmamış!
    beklenen: $BEKLENEN
    bulunan : $GERCEK
  -- bu paketi YAYINLAMAYIN."
fi
if [ "$kanal" = "saha" ]; then
  echo "İmza                     : debug anahtarı, sahadakiyle aynı (${GERCEK:0:16}…) -- doğru"
else
  echo "İmza                     : upload anahtarı (${GERCEK:0:16}…) -- doğru"
fi
echo "versionCode              : $BUILD"
echo
echo "Çıktı: $MOBIL/$CIKTI ($(du -h "$CIKTI" | cut -f1))"
if [ "$kanal" = "play" ]; then
  echo "Sıradaki: Play Console > Test ve yayınlama > bir kanal > Yeni sürüm > bu AAB'yi yükleyin."
else
  echo "Sıradaki: ./scripts/yayinla.sh \"sürüm notları\""
fi
