#!/usr/bin/env bash
# ARVEND mobil -- uzaktan güncelleme yayınlama (Store öncesi Android).
#
# Uygulama mağazalara çıkana kadar Android uygulaması kendini sunucudan
# günceller (eski BYZ uygulamasındaki yayinla.sh'nin ARVEND karşılığı).
# Ayrıntı ve tek seferlik sunucu kurulumu: mobile/RELEASE.md
# "Uzaktan güncelleme (Store öncesi)".
#
# Kullanım (mobile/ dizininde):
#   flutter build apk --release
#   ./scripts/yayinla.sh "sürüm notları" [--zorunlu] [--deneme] [--imza-degisti]
#
#   --zorunlu       Bu sürümün altındaki her cihaz güncellemeden devam
#                   edemez (min_build = bu build). Verilmezse daha önceki
#                   yayınların (durdurulanlar dahil) en yüksek min_build'i
#                   korunur (ilk yayında 0).
#   --deneme        Bütün kontrolleri yapar, sunucuda hiçbir şeyi
#                   DEĞİŞTİRMEZ (yalnızca okur).
#   --imza-degisti  APK'nın imza sertifikası yayındakinden farklıysa
#                   yayınlama reddedilir (Android kurmaz); bilerek anahtar
#                   değiştirildiyse bu bayrakla geçilir. RELEASE.md'ye bak.
#
# Hedef (kullanici@sunucu:/mutlak/dizin), şu sırayla:
#   1. ARVEND_YAYIN_HEDEFI ortam değişkeni
#   2. mobile/.yayin_hedefi dosyasının ilk satırı (git dışında)
#   3. szutech2@192.168.77.77:/var/lib/arvend/app-releases
# SSH yalnızca anahtarla (BatchMode): sunucuda sudo GEREKMEZ.
#
# Ne yapar:
#   1. Sürümü pubspec.yaml'dan okur (version: x.y.z+build), APK'yı aapt ile
#      karşılaştırır (paket adı, versionCode, versionName), imza
#      sertifikasını apksigner ile okur, SHA-256 + boyut hesaplar. aapt,
#      apksigner ya da Java bulunamazsa YAYINLAMAZ (kontrolsüz yayın yok).
#   2. Sunucudaki en yüksek build'den (latest.json, durdurulmuş
#      latest.json.* ve arvend-N.apk dosyaları) küçük/eşit bir build'i ve
#      kayıtlı imzadan farklı bir sertifikayı REDDEDER.
#   3. APK'yı ve latest.json'ı geçici adla yükler; sonra sunucuda TEK bir
#      kilitli adımda: APK özetini doğrular, latest.json'ın betiğin okuduğu
#      halinden değişmediğini kontrol eder (araya başka yayın girdiyse
#      hiçbir şey yapmadan durur), önce APK'yı sonra latest.json'ı rename
#      eder -- istemci hiçbir zaman olmayan bir APK'yı gösteren JSON görmez
#      -- ve en yeni 3 APK dışındakileri siler.
#   4. Herkese açık sürüm ucunu sorup yayının göründüğünü doğrular.
#
# API'yi yeniden başlatmak GEREKMEZ (uç latest.json'ı her istekte kontrol
# eder).
set -euo pipefail

MOBIL="$(cd "$(dirname "$0")/.." && pwd)"
PUBSPEC="$MOBIL/pubspec.yaml"
APK="$MOBIL/build/app/outputs/flutter-apk/app-release.apk"
HEDEF_DOSYA="$MOBIL/.yayin_hedefi"
VARSAYILAN_HEDEF="szutech2@192.168.77.77:/var/lib/arvend/app-releases"
API_TABANI="${ARVEND_API_TABANI:-https://app.arvendyapi.com.tr}"
PAKET_ADI="com.arvendyapi.arvend"
SAKLANACAK_APK=3
NOT_SINIRI=1000
# Uzaktan güncelleyiciyi (lib/core/update/) içeren ilk build. Daha eski
# kurulumlar sürüm ucunu hiç sormaz; bu build'e bir kez elle geçmeleri
# gerekir (RELEASE.md §15 "İlk dağıtım").
ILK_GUNCELLEYICI_BUILD=3
SSH_SECENEK=(-o BatchMode=yes -o ConnectTimeout=15)

hata() {
  echo "HATA: $*" >&2
  exit 1
}
uyari() { echo "UYARI: $*" >&2; }
adim() { echo "-> $*"; }

kullanim() {
  cat <<'YARDIM'
Kullanım: ./scripts/yayinla.sh "sürüm notları" [--zorunlu] [--deneme] [--imza-degisti]

  Önce: flutter build apk --release   (pubspec.yaml'da +build her yayında artmalı)
  --zorunlu       eski cihazlar güncellemeden devam edemez (min_build = build)
  --deneme        yalnızca kontrol et, sunucuda hiçbir şeyi değiştirme
  --imza-degisti  imza sertifikası bilerek değiştirildiyse (bkz. RELEASE.md)

Hedef: ARVEND_YAYIN_HEDEFI, yoksa mobile/.yayin_hedefi, yoksa
       szutech2@192.168.77.77:/var/lib/arvend/app-releases
YARDIM
}

# ---------------------------------------------------------------- argümanlar
NOTLAR=""
NOT_VERILDI=0
ZORUNLU=0
DENEME=0
IMZA_DEGISTI=0
for arg in "$@"; do
  case "$arg" in
    --zorunlu) ZORUNLU=1 ;;
    --deneme) DENEME=1 ;;
    --imza-degisti) IMZA_DEGISTI=1 ;;
    -h | --help | --yardim)
      kullanim
      exit 0
      ;;
    -*) hata "bilinmeyen seçenek: $arg (bkz. --yardim)" ;;
    *)
      [ "$NOT_VERILDI" = 0 ] || hata "sürüm notları tek bir argüman olmalı -- tırnak içinde yaz"
      NOTLAR="$arg"
      NOT_VERILDI=1
      ;;
  esac
done
if [ -z "${NOTLAR//[[:space:]]/}" ]; then
  kullanim >&2
  hata "sürüm notları boş olamaz (kullanıcı güncelleme penceresinde bunu görür)"
fi
[ "${#NOTLAR}" -le "$NOT_SINIRI" ] || hata "sürüm notları en fazla $NOT_SINIRI karakter olabilir (${#NOTLAR})"

for arac in jq ssh scp curl; do
  command -v "$arac" >/dev/null 2>&1 || hata "'$arac' bulunamadı"
done

# ---------------------------------------------------------------- sürüm
[ -f "$PUBSPEC" ] || hata "pubspec.yaml yok: $PUBSPEC"
SURUM_SATIRI=$(sed -n 's/^version:[[:space:]]*//p' "$PUBSPEC" | head -n 1 | tr -d "[:space:]\"'")
case "$SURUM_SATIRI" in
  *+*) ;;
  *) hata "pubspec.yaml version 'x.y.z+build' biçiminde değil: '$SURUM_SATIRI'" ;;
esac
SURUM="${SURUM_SATIRI%%+*}"
BUILD="${SURUM_SATIRI##*+}"
printf '%s' "$SURUM" | grep -Eq '^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$' ||
  hata "sürüm x.y.z biçiminde olmalı (ön-sürüm eki yok): '$SURUM'"
printf '%s' "$BUILD" | grep -Eq '^[1-9][0-9]{0,8}$' ||
  hata "build pozitif bir tamsayı olmalı: '$BUILD'"

# ---------------------------------------------------------------- APK
[ -f "$APK" ] || hata "APK yok: $APK -- önce 'flutter build apk --release' çalıştır"
if [ "$PUBSPEC" -nt "$APK" ]; then
  # Sürüm numarası aşağıda aapt ile kesin olarak karşılaştırılır; bu
  # yalnızca sürüm dışı bir pubspec değişikliği (ör. bağımlılık) içindir.
  uyari "pubspec.yaml APK'dan daha yeni -- APK'yı yeniden derlemen gerekebilir"
fi

# flutter_ayari ANAHTAR: 'flutter config' ile kaydedilmiş bir ayar
# (android-sdk, jdk-dir); yoksa boş.
flutter_ayari() {
  local dosya deger
  for dosya in "${XDG_CONFIG_HOME:-$HOME/.config}/flutter/settings" "$HOME/.flutter_settings"; do
    [ -f "$dosya" ] || continue
    deger=$(jq -r --arg k "$1" '.[$k] // empty | strings' "$dosya" 2>/dev/null | head -n 1 || true)
    if [ -n "$deger" ]; then
      echo "$deger"
      return 0
    fi
  done
}

sdk_adaylari() {
  local yerel="$MOBIL/android/local.properties"
  if [ -n "${ANDROID_HOME:-}" ]; then echo "$ANDROID_HOME"; fi
  if [ -n "${ANDROID_SDK_ROOT:-}" ]; then echo "$ANDROID_SDK_ROOT"; fi
  # APK'yı derleyen SDK: Flutter bunu android/local.properties'e yazar
  # (Java properties kaçışları, ör. '\:', çözülür).
  if [ -f "$yerel" ]; then
    sed -n 's/^sdk\.dir=//p' "$yerel" | head -n 1 | sed 's/\\\(.\)/\1/g'
  fi
  flutter_ayari android-sdk
  echo "$HOME/Library/Android/sdk"
  echo "/opt/homebrew/share/android-commandlinetools"
  echo "/usr/local/share/android-commandlinetools"
  echo "$HOME/Android/Sdk"
}

# build_tools_araci aapt|aapt2|apksigner: PATH'te, yoksa SDK'nın en yeni
# build-tools sürümünde arar.
build_tools_araci() {
  local ad="$1" sdk surum
  if command -v "$ad" >/dev/null 2>&1; then
    command -v "$ad"
    return 0
  fi
  while IFS= read -r sdk; do
    [ -n "$sdk" ] && [ -d "$sdk/build-tools" ] || continue
    for surum in $(ls -1 "$sdk/build-tools" 2>/dev/null | sort -t . -k 1,1nr -k 2,2nr -k 3,3nr); do
      if [ -x "$sdk/build-tools/$surum/$ad" ]; then
        echo "$sdk/build-tools/$surum/$ad"
        return 0
      fi
    done
  done < <(sdk_adaylari)
  return 1
}

# java_bul: apksigner bir Java programıdır; macOS'taki /usr/bin/java JDK
# yoksa yalnızca bir yönlendiricidir. Flutter'ın kendi sırasıyla dener:
# 'flutter config --jdk-dir', Android Studio'nun JDK'sı, JAVA_HOME.
java_bul() {
  local aday
  for aday in \
    "$(flutter_ayari jdk-dir)" \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
    "${JAVA_HOME:-}" \
    "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" \
    "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home"; do
    if [ -n "$aday" ] && [ -x "$aday/bin/java" ]; then
      echo "$aday"
      return 0
    fi
  done
  if [ -x /usr/libexec/java_home ] && /usr/libexec/java_home >/dev/null 2>&1; then
    /usr/libexec/java_home
    return 0
  fi
  return 1
}

SDK_IPUCU="Flutter'ın kullandığı SDK android/local.properties 'sdk.dir'de; ANDROID_HOME ile de verilebilir"

# Sürüm ve imza kontrolleri ZORUNLUDUR: bu betik yanlış makineden, yanlış
# anahtarla ya da eski bir APK ile yapılan yayını durdurmak için var.
# Kontrol yapılamıyorsa yayın da yapılmaz (özellikle --zorunlu ile yanlış
# bir APK, hiçbir cihazın geçemeyeceği bir güncelleme döngüsü demektir).
AAPT=$(build_tools_araci aapt || build_tools_araci aapt2 || true)
[ -n "$AAPT" ] ||
  hata "aapt bulunamadı (Android SDK build-tools) -- APK'nın versionCode/versionName'i pubspec ile karşılaştırılamaz, yayınlanmadı. $SDK_IPUCU."
ROZET=$("$AAPT" dump badging "$APK" 2>/dev/null | sed -n '1p' || true)
APK_PAKET=$(printf '%s\n' "$ROZET" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
APK_KOD=$(printf '%s\n' "$ROZET" | sed -n "s/.* versionCode='\([^']*\)'.*/\1/p")
APK_AD=$(printf '%s\n' "$ROZET" | sed -n "s/.* versionName='\([^']*\)'.*/\1/p")
[ -n "$APK_PAKET" ] || hata "APK okunamadı ($AAPT dump badging başarısız): $APK"
[ "$APK_PAKET" = "$PAKET_ADI" ] || hata "APK paket adı '$APK_PAKET', beklenen '$PAKET_ADI'"
[ "$APK_KOD" = "$BUILD" ] ||
  hata "APK versionCode=$APK_KOD ama pubspec build=$BUILD -- APK'yı yeniden derle (flutter build apk --release)"
[ "$APK_AD" = "$SURUM" ] ||
  hata "APK versionName=$APK_AD ama pubspec sürümü=$SURUM -- APK'yı yeniden derle"

APKSIGNER=$(build_tools_araci apksigner || true)
[ -n "$APKSIGNER" ] ||
  hata "apksigner bulunamadı (Android SDK build-tools) -- imza sertifikası kontrol edilemez, yayınlanmadı. $SDK_IPUCU."
JDK=$(java_bul || true)
[ -n "$JDK" ] ||
  hata "Java (JDK) bulunamadı -- apksigner çalışamaz, yayınlanmadı. JAVA_HOME ver ya da 'flutter config --jdk-dir=<JDK>'"
if ! IMZA_CIKTI=$(JAVA_HOME="$JDK" PATH="$JDK/bin:$PATH" "$APKSIGNER" verify --print-certs "$APK" 2>&1); then
  printf '%s\n' "$IMZA_CIKTI" >&2
  hata "APK imzası doğrulanamadı -- Android bu dosyayı kurmaz"
fi
IMZA=$(printf '%s\n' "$IMZA_CIKTI" | sed -n 's/^Signer #1 certificate SHA-256 digest: \([0-9a-f]\{64\}\)$/\1/p' | head -n 1)
IMZA_DN=$(printf '%s\n' "$IMZA_CIKTI" | sed -n 's/^Signer #1 certificate DN: //p' | head -n 1)
if [ -z "$IMZA" ]; then
  printf '%s\n' "$IMZA_CIKTI" >&2
  hata "apksigner çıktısında imza sertifikası özeti ('Signer #1 certificate SHA-256 digest') bulunamadı -- imza kontrol edilemedi, yayınlanmadı"
fi

if command -v shasum >/dev/null 2>&1; then
  OZET=$(shasum -a 256 "$APK" | cut -d ' ' -f 1)
else
  OZET=$(sha256sum "$APK" | cut -d ' ' -f 1)
fi
printf '%s' "$OZET" | grep -Eq '^[0-9a-f]{64}$' || hata "SHA-256 hesaplanamadı"
BOYUT=$(wc -c <"$APK" | tr -d '[:space:]')
APK_ADI="arvend-$BUILD.apk"

# ---------------------------------------------------------------- hedef
if [ -n "${ARVEND_YAYIN_HEDEFI:-}" ]; then
  HEDEF="$ARVEND_YAYIN_HEDEFI"
  HEDEF_KAYNAGI="ARVEND_YAYIN_HEDEFI"
elif [ -f "$HEDEF_DOSYA" ]; then
  HEDEF=$(sed -n '1p' "$HEDEF_DOSYA" | tr -d '[:space:]')
  HEDEF_KAYNAGI="mobile/.yayin_hedefi"
else
  HEDEF="$VARSAYILAN_HEDEF"
  HEDEF_KAYNAGI="varsayılan"
fi
case "$HEDEF" in
  *:/*) ;;
  *) hata "hedef 'kullanici@sunucu:/mutlak/dizin' biçiminde olmalı: '$HEDEF' ($HEDEF_KAYNAGI)" ;;
esac
SUNUCU="${HEDEF%%:*}"
DEPO="${HEDEF#*:}"
DEPO="${DEPO%/}"
# Uzak kabuğa giden her değer bu iki desenden geçer: tırnak/boşluk/;
# taşıyamaz.
printf '%s' "$SUNUCU" | grep -Eq '^([A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+$' || hata "geçersiz sunucu: '$SUNUCU'"
printf '%s' "$DEPO" | grep -Eq '^/[A-Za-z0-9._/-]+$' || hata "geçersiz dizin: '$DEPO'"
case "$DEPO" in
  *..*) hata "dizin '..' içeremez: '$DEPO'" ;;
esac
DIZIN="$DEPO/android"

uzak() { ssh "${SSH_SECENEK[@]}" "$SUNUCU" "$@"; }
# uzak_betik ARG...: betiği stdin'den okuyup sunucuda bash ile çalıştırır.
# ARG'ler ssh ile tek bir komut satırına birleşir: hepsi yukarıdaki ya da
# aşağıdaki desenlerden geçmiş, boş olmayan değerler olmalı.
uzak_betik() { ssh "${SSH_SECENEK[@]}" "$SUNUCU" bash -s -- "$@"; }

# ---------------------------------------------------------------- sunucu (salt okuma)
adim "$SUNUCU: $DIZIN kontrol ediliyor..."
DURUM=$(uzak_betik "$DIZIN" <<'UZAK'
set -eu
if [ ! -d "$1" ]; then echo dizin_yok; exit 0; fi
if [ ! -w "$1" ]; then echo yazilamaz; exit 0; fi
echo tamam
UZAK
) || hata "sunucuya bağlanılamadı ($SUNUCU) -- 'ssh $SUNUCU' parolasız (anahtarla) çalışmalı"
case "$DURUM" in
  tamam) ;;
  dizin_yok) hata "$SUNUCU:$DIZIN yok -- tek seferlik sunucu kurulumu için mobile/RELEASE.md 'Uzaktan güncelleme (Store öncesi)'" ;;
  yazilamaz) hata "$SUNUCU:$DIZIN bu kullanıcıya yazılamaz -- mobile/RELEASE.md'deki tek seferlik kurulumu kontrol et" ;;
  *) hata "beklenmeyen sunucu yanıtı: $DURUM" ;;
esac

# Sunucunun durumu tek seferde okunur: latest.json'ın özeti (yayına alma
# adımında "araya başka yayın girdi mi" karşılaştırması için), en yüksek
# arvend-N.apk, kayıtlı imza, latest.json ve durdurulmuş latest.json.*
# dosyaları (acil durdurma, RELEASE.md "Geri alma"). Özet, içerikle AYNI
# okumadan hesaplanır.
RAPOR=$(uzak_betik "$DIZIN" <<'UZAK'
set -eu
cd "$1"
ozet_al() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d ' ' -f 1; else shasum -a 256 | cut -d ' ' -f 1; fi
}
icerik=""
if [ -f latest.json ]; then
  icerik=$(cat latest.json)
  printf '@@ozet %s\n' "$(printf '%s' "$icerik" | ozet_al)"
else
  echo "@@ozet yok"
fi
enbuyuk=$(ls -1 | { grep -E '^arvend-[0-9]+\.apk$' || true; } | sed -E 's/^arvend-0*([0-9]+)\.apk$/\1/' | sort -n | tail -n 1)
echo "@@apk ${enbuyuk:-0}"
if [ -f imza.sha256 ]; then
  printf '@@imza %s\n' "$(tr -d '[:space:]' <imza.sha256)"
else
  echo "@@imza"
fi
echo "@@latest"
if [ -n "$icerik" ]; then printf '%s\n' "$icerik"; fi
echo "@@durduruldu"
for f in latest.json.*; do
  if [ -f "$f" ]; then
    cat "$f"
    echo
  fi
done
echo "@@son"
UZAK
) || hata "sunucudaki yayın durumu okunamadı ($SUNUCU:$DIZIN)"

rapor_satiri() { printf '%s\n' "$RAPOR" | sed -n "s/^@@$1 \{0,1\}//p" | head -n 1; }
rapor_bolumu() { printf '%s\n' "$RAPOR" | awk -v b="@@$1" '$0 == b { on = 1; next } /^@@/ { on = 0 } on'; }

MEVCUT_OZET=$(rapor_satiri ozet)
printf '%s' "$MEVCUT_OZET" | grep -Eq '^([0-9a-f]{64}|yok)$' || hata "beklenmeyen sunucu yanıtı (latest.json özeti): '$MEVCUT_OZET'"
APK_TABAN=$(rapor_satiri apk)
printf '%s' "$APK_TABAN" | grep -Eq '^[0-9]{1,10}$' || hata "beklenmeyen sunucu yanıtı (APK listesi): '$APK_TABAN'"
MEVCUT_IMZA=$(rapor_satiri imza)
if [ -n "$MEVCUT_IMZA" ] && ! printf '%s' "$MEVCUT_IMZA" | grep -Eq '^[0-9a-f]{64}$'; then
  hata "sunucudaki imza.sha256 bozuk -- elle bak: ssh $SUNUCU cat $DIZIN/imza.sha256"
fi
MEVCUT_JSON=$(rapor_bolumu latest)
DURDURULAN_JSON=$(rapor_bolumu durduruldu)

MEVCUT_BUILD=0
MEVCUT_SURUM="-"
MEVCUT_MIN_BUILD=0
if [ -n "${MEVCUT_JSON//[[:space:]]/}" ]; then
  MEVCUT_BUILD=$(printf '%s' "$MEVCUT_JSON" |
    jq -er '.build | select(type == "number" and . == floor and . >= 0)' 2>/dev/null) ||
    hata "sunucudaki latest.json bozuk -- elle bak: ssh $SUNUCU cat $DIZIN/latest.json"
  MEVCUT_SURUM=$(printf '%s' "$MEVCUT_JSON" | jq -r '.version // "?"')
  MEVCUT_MIN_BUILD=$(printf '%s' "$MEVCUT_JSON" |
    jq -r '.min_build | if type == "number" and . == floor and . >= 0 then . else 0 end')
fi

# Acil durdurulmuş yayınlar (latest.json.durduruldu vb.): build tabanı ve
# zorunlu taban (min_build) onlarla birlikte kaybolmaz.
DURDURULAN_BUILD=0
DURDURULAN_MIN_BUILD=0
if [ -n "${DURDURULAN_JSON//[[:space:]]/}" ]; then
  DURDURULAN_BUILD=$(printf '%s' "$DURDURULAN_JSON" |
    jq -se '[.[] | .build | select(type == "number" and . == floor and . >= 0)] | max // 0' 2>/dev/null) ||
    hata "sunucudaki durdurulmuş latest.json.* dosyalarından biri bozuk -- elle bak: ssh $SUNUCU ls -la $DIZIN"
  DURDURULAN_MIN_BUILD=$(printf '%s' "$DURDURULAN_JSON" |
    jq -s '[.[] | .min_build | select(type == "number" and . == floor and . >= 0)] | max // 0')
fi

TABAN_BUILD="$MEVCUT_BUILD"
TABAN_KAYNAGI="yayındaki latest.json, v$MEVCUT_SURUM"
if [ "$APK_TABAN" -gt "$TABAN_BUILD" ]; then
  TABAN_BUILD="$APK_TABAN"
  TABAN_KAYNAGI="sunucudaki arvend-$APK_TABAN.apk"
fi
if [ "$DURDURULAN_BUILD" -gt "$TABAN_BUILD" ]; then
  TABAN_BUILD="$DURDURULAN_BUILD"
  TABAN_KAYNAGI="durdurulmuş latest.json.*"
fi
if [ "$BUILD" -le "$TABAN_BUILD" ]; then
  hata "build $BUILD, sunucudaki en yüksek build'den ($TABAN_BUILD: $TABAN_KAYNAGI) büyük değil -- pubspec.yaml'da +build'i artırıp APK'yı yeniden derle"
fi

if [ -n "$MEVCUT_IMZA" ] && [ "$IMZA" != "$MEVCUT_IMZA" ] && [ "$IMZA_DEGISTI" = 0 ]; then
  hata "APK'nın imza sertifikası yayındakinden FARKLI ($MEVCUT_IMZA -> $IMZA).
      Android bu güncellemeyi kurulu uygulamanın üstüne KURMAZ -- her cihaz 60 MB
      indirip kurulumda hata alır. Yanlış makinede/anahtarla mı derledin?
      Bilerek anahtar değiştirdiysen: --imza-degisti (bkz. RELEASE.md)."
fi
if [ -z "$MEVCUT_IMZA" ] && [ "$TABAN_BUILD" -gt 0 ]; then
  uyari "sunucuda imza.sha256 yok ama önceki yayın(lar) var -- imzanın cihazlardakiyle aynı olduğu
       KONTROL EDİLEMEDİ; bu APK'nın imzası kayda geçecek."
fi

if [ "$ZORUNLU" = 1 ]; then
  MIN_BUILD="$BUILD"
else
  # Zorunlu bir sürüm hiç yayınlanmamış gibi olmasın: taban düşmez --
  # arada acil durdurma olsa bile.
  MIN_BUILD="$MEVCUT_MIN_BUILD"
  if [ "$DURDURULAN_MIN_BUILD" -gt "$MIN_BUILD" ]; then
    MIN_BUILD="$DURDURULAN_MIN_BUILD"
  fi
fi

# ---------------------------------------------------------------- özet
echo
echo "  Sürüm      : v$SURUM (build $BUILD)$([ "$ZORUNLU" = 1 ] && echo '  [ZORUNLU]')"
echo "  min_build  : $MIN_BUILD"
echo "  Yayındaki  : v$MEVCUT_SURUM (build $MEVCUT_BUILD)"
if [ "$TABAN_BUILD" != "$MEVCUT_BUILD" ]; then
  echo "  Taban build: $TABAN_BUILD ($TABAN_KAYNAGI)"
fi
echo "  APK        : $APK ($(awk -v b="$BOYUT" 'BEGIN { printf "%.1f MB", b / 1048576 }'))"
echo "  SHA-256    : $OZET"
echo "  İmza       : $IMZA_DN"
echo "               $IMZA"
echo "  Hedef      : $SUNUCU:$DIZIN/$APK_ADI ($HEDEF_KAYNAGI)"
echo "  Notlar     : $NOTLAR"
echo
case "$IMZA_DN" in
  *"CN=Android Debug"*)
    uyari "APK DEBUG anahtarıyla imzalı (android/key.properties yok). Güncellemeler yalnızca
       AYNI anahtarla imzalıysa kurulur: hep bu Mac'te derle (~/.android/debug.keystore).
       Gerçek keystore'a geçişte her cihazda bir kerelik kaldır/kur gerekir (RELEASE.md)."
    ;;
esac
if [ "$BUILD" = "$ILK_GUNCELLEYICI_BUILD" ]; then
  uyari "build $BUILD uzaktan güncelleyiciyi içeren İLK sürüm: cihazlardaki eski kurulumlar
       (build $((ILK_GUNCELLEYICI_BUILD - 1)) ve öncesi) sürüm ucunu hiç sormaz, bu yayını GÖRMEZ.
       Bu APK'yı her cihaza bir kez elle kur; sonraki build'ler uzaktan gelir (RELEASE.md §15)."
fi

if [ "$DENEME" = 1 ]; then
  echo "Deneme: kontroller tamam, sunucuda hiçbir şey değiştirilmedi."
  exit 0
fi

if [ -t 0 ]; then
  read -r -p "Yayınlansın mı? Güncelleyiciyi içeren uygulamalar bir sonraki açılışta görecek. [e/H] " CEVAP
  case "$CEVAP" in
    e | E | evet | Evet | EVET) ;;
    *)
      echo "Vazgeçildi."
      exit 1
      ;;
  esac
fi

# ---------------------------------------------------------------- yükleme
GECICI_APK=".$APK_ADI.yukleniyor.$$"
GECICI_JSON=".latest.json.yukleniyor.$$"
YEREL_JSON=$(mktemp "${TMPDIR:-/tmp}/arvend-latest.XXXXXX")
temizle() {
  rm -f "$YEREL_JSON"
  # Yarım kalan geçici dosyalar desene (arvend-N.apk / latest.json)
  # uymadığı için API onları zaten görmez; yine de bırakılmaz.
  uzak "rm -f $DIZIN/$GECICI_APK $DIZIN/$GECICI_JSON" >/dev/null 2>&1 || true
}
trap temizle EXIT

adim "APK yükleniyor ($APK_ADI)..."
scp "${SSH_SECENEK[@]}" "$APK" "$SUNUCU:$DIZIN/$GECICI_APK"

jq -n \
  --argjson build "$BUILD" \
  --arg version "$SURUM" \
  --arg sha256 "$OZET" \
  --argjson size "$BOYUT" \
  --arg notes "$NOTLAR" \
  --argjson min_build "$MIN_BUILD" \
  --arg file "$APK_ADI" \
  --arg published_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{build: $build, version: $version, sha256: $sha256, size: $size, notes: $notes,
    min_build: $min_build, file: $file, published_at: $published_at}' >"$YEREL_JSON"
uzak "cat > $DIZIN/$GECICI_JSON" <"$YEREL_JSON"

# Yayına alma TEK bir uzak adımdır ve kilit altında çalışır. Yukarıdaki
# kontroller (build tabanı, min_build, imza) latest.json'ın okunduğu
# haline göre yapıldı; arada onay beklendi ve ~60 MB yüklendi. latest.json
# o arada değiştiyse (paralel bir yayın, acil durdurma) HİÇBİR ŞEY
# değiştirilmeden durulur -- eski bir karar yeni bir yayının üstüne yazmaz.
adim "Sunucuda doğrulanıp yayına alınıyor..."
uzak_betik "$DIZIN" "$GECICI_APK" "$APK_ADI" "$OZET" "$BOYUT" "$GECICI_JSON" "$MEVCUT_OZET" "$IMZA" "$SAKLANACAK_APK" <<'UZAK' ||
set -eu
dizin=$1 gecici_apk=$2 apk=$3 ozet=$4 boyut=$5 gecici_json=$6 beklenen=$7 imza=$8 sakla=$9
cd "$dizin"
ozet_al() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d ' ' -f 1; else shasum -a 256 | cut -d ' ' -f 1; fi
}

gercek=$(ozet_al <"$gecici_apk")
boy=$(wc -c <"$gecici_apk" | tr -d '[:space:]')
if [ "$gercek" != "$ozet" ] || [ "$boy" != "$boyut" ]; then
  echo "HATA: sunucuya inen APK bozuk (özet/boyut tutmuyor) -- hiçbir şey değiştirilmedi" >&2
  exit 1
fi

# Aynı anda tek yayın. flock (Linux/util-linux) süreç ölünce kilidi kendisi
# bırakır; yoksa mkdir kilidi.
if command -v flock >/dev/null 2>&1; then
  exec 9>>.yayin.kilit
  if ! flock -n 9; then
    echo "HATA: şu anda başka bir yayın sürüyor -- bitince betiği yeniden çalıştır" >&2
    exit 1
  fi
else
  if ! mkdir .yayin.kilit.d 2>/dev/null; then
    echo "HATA: şu anda başka bir yayın sürüyor (takılı kaldıysa: rmdir $dizin/.yayin.kilit.d)" >&2
    exit 1
  fi
  trap 'rmdir "$dizin/.yayin.kilit.d" 2>/dev/null || true' EXIT
fi

if [ -f latest.json ]; then
  simdiki=$(printf '%s' "$(cat latest.json)" | ozet_al)
else
  simdiki=yok
fi
if [ "$simdiki" != "$beklenen" ]; then
  echo "HATA: latest.json betik okuduktan sonra değişti (araya başka bir yayın ya da acil durdurma girdi)." >&2
  echo "      Hiçbir şey değiştirilmedi; betiği yeniden çalıştır (kontroller güncel duruma göre yapılır)." >&2
  exit 1
fi
if [ -e "$apk" ]; then
  echo "HATA: $apk sunucuda zaten var -- build numarasını artır. Hiçbir şey değiştirilmedi." >&2
  exit 1
fi

chmod 644 "$gecici_apk" "$gecici_json"
# Önce APK, sonra imza kaydı, EN SON latest.json (yayının görünür olduğu an).
mv -f "$gecici_apk" "$apk"
printf '%s\n' "$imza" >".imza.sha256.yukleniyor.$$"
chmod 644 ".imza.sha256.yukleniyor.$$"
mv -f ".imza.sha256.yukleniyor.$$" imza.sha256
mv -f "$gecici_json" latest.json
echo "yayında: $apk"

# En yeni $sakla APK dışındakiler silinir; yayındaki asla.
ls -1 | { grep -E '^arvend-[0-9]+\.apk$' || true; } |
  sed -E 's/^arvend-([0-9]+)\.apk$/\1 &/' | sort -n |
  awk -v k="$sakla" '{ b[NR] = $2 } END { for (i = 1; i <= NR - k; i++) print b[i] }' |
  while IFS= read -r eski; do
    if [ "$eski" != "$apk" ]; then
      rm -f "$eski"
      echo "eski APK silindi: $eski"
    fi
  done
UZAK
  hata "sunucuda yayına alınamadı (neden yukarıda). 'yayında:' satırı görünmediyse latest.json değişmedi."

echo
echo "Yayınlandı: v$SURUM (build $BUILD)$([ "$ZORUNLU" = 1 ] && echo ' [ZORUNLU]')"
echo "SHA-256   : $OZET"

# ---------------------------------------------------------------- doğrulama
URL="$API_TABANI/api/v1/mobile/app-version?platform=android"
adim "Herkese açık sürüm ucu: $URL"
if ! YANIT=$(curl -fsS --max-time 20 "$URL"); then
  hata "sürüm ucu okunamadı -- dosyalar yüklendi ama API'den doğrulanamadı"
fi
printf '%s\n' "$YANIT" | jq . 2>/dev/null || printf '%s\n' "$YANIT"
if [ "$(printf '%s' "$YANIT" | jq -r '.build' 2>/dev/null)" = "$BUILD" ] &&
  [ "$(printf '%s' "$YANIT" | jq -r '.sha256' 2>/dev/null)" = "$OZET" ]; then
  echo "Doğrulandı: sürüm ucu v$SURUM (build $BUILD) gösteriyor. Uzaktan güncelleyiciyi içeren"
  echo "uygulamalar (build $ILK_GUNCELLEYICI_BUILD ve sonrası) bir sonraki açılışta görecek; daha eski kurulumlar"
  echo "sürüm ucunu hiç sormaz, bir kez elle güncellenmeli (RELEASE.md §15 'İlk dağıtım')."
else
  hata "API yeni sürümü göstermiyor. Backend bu özelliği içeren sürüme güncel mi? API'nin
      APP_RELEASES_DIR'ı $DEPO mu? Sunucu logunda 'uygulama sürümü' uyarısına bak
      (journalctl -u arvend-api)."
fi
