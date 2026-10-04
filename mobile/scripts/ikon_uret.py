#!/usr/bin/env python3
"""ARVEND logosundan Android uygulama ikonlarını ve giriş ekranı logosunu üretir.

Kaynak: frontend/public/logo.png (web'in kullandığı logo, 1254x1254, siyah
zemin üzerinde çatı + kuleler ve altında "ARVEND YAPI" yazısı).

    python3 mobile/scripts/ikon_uret.py      # depo kökünden ya da mobile/'dan

Ürettikleri:
  - android/.../mipmap-*/ic_launcher_foreground.png  adaptive ikon ön katmanı
  - android/.../mipmap-*/ic_launcher.png             Android 8 öncesi ikon
  - assets/icon/arvend_icon_master.png               1024 ana kopya
  - assets/brand/arvend_logo.png                     giriş ekranı (yazılı logo)
  - build/play_icon_512.png                          Play Store mağaza ikonu

İkonda YALNIZCA sembol (çatı + kuleler) var: 48dp'de "ARVEND YAPI" yazısı
okunmaz, uygulamanın adı zaten ikonun altında yazıyor. Yazılı tam logo giriş
ekranında.

Arka plan rengi values/ic_launcher_background.xml ile AYNI olmalı (BG) --
açılış ekranı da o rengi ve ön katmanı kullanıyor (drawable/launch_background).
Gerektirir: Pillow.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

MOBIL = Path(__file__).resolve().parent.parent
KAYNAK = MOBIL.parent / "frontend" / "public" / "logo.png"
RES = MOBIL / "android" / "app" / "src" / "main" / "res"

BG = (12, 12, 12)  # logonun kendi zemini (#0C0C0C), ölçülerek bulundu
SEMBOL = (451, 253, 788, 711)  # logo.png'de çatı+kuleler (yazı 760'tan başlar)
TUM_LOGO = (149, 117, 1099, 1067)  # sembol + yazı, kare, ortalı

# Adaptive ikon: 108dp tuval, maske ortadaki ~66dp'lik daireyi garanti eder.
# Sembol yüksekliği tuvalin %48'i -> en geniş köşesi (çatının alt uçları)
# merkezden ~32dp, daire maskesinde bile kesilmez.
ON_KATMAN_ORAN = 0.48
YOGUNLUK = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}


def sembol_tuvali(boyut: int, oran: float) -> Image.Image:
    """Düz BG zemin ortasına sembolü yerleştirir. Sembol kesitinin kenarları
    yumuşatılır: logonun zemini hafif dokulu, düz renge keskin yapıştırınca
    çerçevesi seçiliyordu."""
    logo = Image.open(KAYNAK).convert("RGB")
    pay = 40  # yumuşak gölgeler kesilmesin
    x0, y0, x1, y1 = SEMBOL
    kesit = logo.crop((x0 - pay, y0 - pay, x1 + pay, y1 + pay))
    olcek = (boyut * oran) / (y1 - y0)
    kesit = kesit.resize((round(kesit.width * olcek), round(kesit.height * olcek)), Image.LANCZOS)

    maske = Image.new("L", kesit.size, 0)
    kenar = max(2, round(pay * olcek * 0.8))
    ImageDraw.Draw(maske).rectangle((kenar, kenar, kesit.width - kenar, kesit.height - kenar), fill=255)
    maske = maske.filter(ImageFilter.GaussianBlur(kenar / 2))

    tuval = Image.new("RGB", (boyut, boyut), BG)
    tuval.paste(kesit, ((boyut - kesit.width) // 2, (boyut - kesit.height) // 2), maske)
    return tuval


def yuvarlak_kare(img: Image.Image, yaricap_oran: float = 0.22) -> Image.Image:
    maske = Image.new("L", img.size, 0)
    r = round(img.width * yaricap_oran)
    ImageDraw.Draw(maske).rounded_rectangle((0, 0, img.width - 1, img.height - 1), r, fill=255)
    out = img.convert("RGBA")
    out.putalpha(maske)
    return out


def main() -> None:
    ana = sembol_tuvali(1024, ON_KATMAN_ORAN)
    ana.save(MOBIL / "assets" / "icon" / "arvend_icon_master.png", optimize=True)

    for ad, k in YOGUNLUK.items():
        d = RES / f"mipmap-{ad}"
        ana.resize((round(108 * k),) * 2, Image.LANCZOS).save(d / "ic_launcher_foreground.png", optimize=True)
        # Eski launcher'lar maske uygulamaz: köşeleri kendimiz yuvarlarız,
        # sembol daha büyük (görünür alanın tamamı bizim).
        eski = sembol_tuvali(round(48 * k) * 4, 0.66).resize((round(48 * k),) * 2, Image.LANCZOS)
        yuvarlak_kare(eski).save(d / "ic_launcher.png", optimize=True)

    marka = MOBIL / "assets" / "brand"
    marka.mkdir(exist_ok=True)
    Image.open(KAYNAK).convert("RGB").crop(TUM_LOGO).resize((480, 480), Image.LANCZOS).save(
        marka / "arvend_logo.png", optimize=True
    )

    # Play Store mağaza ikonu: 512x512, köşeleri Play kendisi yuvarlar.
    (MOBIL / "build").mkdir(exist_ok=True)
    sembol_tuvali(512, 0.62).save(MOBIL / "build" / "play_icon_512.png", optimize=True)
    print("ikonlar üretildi")


if __name__ == "__main__":
    main()
