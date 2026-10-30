package service

// EXIF yönü (2026-10-30): telefon fotoğrafı çoğu zaman sensörün yönünde
// kaydedilir, "nasıl gösterileceği" EXIF Orientation etiketindedir. Flutter
// (uygulama) fotoğrafı bu etiketi UYGULAYARAK çözer ve kalem maskesini o
// boyutta çizer; Go'nun image/jpeg'i etiketi yok sayar -- 90° döndürülmüş
// bir fotoğrafta genişlik/yükseklik yer değiştirmiş görünür, maske tutmaz,
// OpenAI'ye de yan yatmış fotoğraf gider. Bu yüzden yönlü JPEG, sunucuda
// ölçülmeden ve gönderilmeden ÖNCE dik hale getirilir (normalizeJPEGOrientation).

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/draw"
	"image/jpeg"
)

// jpegOrientation: EXIF Orientation (1-8); etiket yoksa ya da okunamazsa 1.
func jpegOrientation(data []byte) int {
	if len(data) < 4 || data[0] != 0xFF || data[1] != 0xD8 {
		return 1
	}
	i := 2
	for i+4 <= len(data) {
		if data[i] != 0xFF {
			return 1
		}
		marker := data[i+1]
		switch {
		case marker == 0xFF: // dolgu baytı
			i++
			continue
		case marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7):
			i += 2
			continue
		case marker == 0xDA || marker == 0xD9: // görüntü verisi başladı: başlık bitti
			return 1
		}
		size := int(data[i+2])<<8 | int(data[i+3])
		if size < 2 || i+2+size > len(data) {
			return 1
		}
		seg := data[i+4 : i+2+size]
		if marker == 0xE1 && len(seg) > 6 && string(seg[:6]) == "Exif\x00\x00" {
			return tiffOrientation(seg[6:])
		}
		i += 2 + size
	}
	return 1
}

// tiffOrientation: EXIF'in TIFF gövdesinde IFD0'daki 0x0112 (SHORT).
func tiffOrientation(t []byte) int {
	if len(t) < 8 {
		return 1
	}
	var bo binary.ByteOrder
	switch string(t[:2]) {
	case "II":
		bo = binary.LittleEndian
	case "MM":
		bo = binary.BigEndian
	default:
		return 1
	}
	if bo.Uint16(t[2:4]) != 42 {
		return 1
	}
	off := int(bo.Uint32(t[4:8]))
	if off < 8 || off+2 > len(t) {
		return 1
	}
	n := int(bo.Uint16(t[off : off+2]))
	for k := 0; k < n; k++ {
		e := off + 2 + k*12
		if e+12 > len(t) {
			return 1
		}
		if bo.Uint16(t[e:e+2]) != 0x0112 {
			continue
		}
		if bo.Uint16(t[e+2:e+4]) != 3 { // SHORT değilse güvenme
			return 1
		}
		if v := int(bo.Uint16(t[e+8 : e+10])); v >= 1 && v <= 8 {
			return v
		}
		return 1
	}
	return 1
}

// orientedSize: görselin GÖSTERİLDİĞİ boyut (JPEG'de EXIF yönü uygulanmış:
// 5-8 genişlik ve yüksekliği değiştirir) -- uygulamanın maskeyi çizdiği boyut.
func orientedSize(data []byte) (int, int, error) {
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return 0, 0, err
	}
	if o := jpegOrientation(data); o >= 5 && o <= 8 {
		return cfg.Height, cfg.Width, nil
	}
	return cfg.Width, cfg.Height, nil
}

// applyOrientation: EXIF yönüne göre döndürülmüş/aynalanmış kopya. Hedef
// (x, y) pikselinin kaynaktaki karşılığı; w, h kaynağın boyutu.
func applyOrientation(src image.Image, orientation int) image.Image {
	if orientation < 2 || orientation > 8 {
		return src
	}
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	dw, dh := w, h
	if orientation >= 5 {
		dw, dh = h, w
	}
	// Kaynak RGBA'ya bir kez çevrilir: piksel başına At() renk dönüşümü
	// 12 MP'de yavaş kalırdı.
	rgba, ok := src.(*image.RGBA)
	if !ok || b.Min != (image.Point{}) {
		rgba = image.NewRGBA(image.Rect(0, 0, w, h))
		draw.Draw(rgba, rgba.Bounds(), src, b.Min, draw.Src)
	}
	dst := image.NewRGBA(image.Rect(0, 0, dw, dh))
	for y := 0; y < dh; y++ {
		for x := 0; x < dw; x++ {
			var sx, sy int
			switch orientation {
			case 2: // yatay ayna
				sx, sy = w-1-x, y
			case 3: // 180°
				sx, sy = w-1-x, h-1-y
			case 4: // dikey ayna
				sx, sy = x, h-1-y
			case 5: // köşegen ayna (transpose)
				sx, sy = y, x
			case 6: // 90° saat yönünde
				sx, sy = y, h-1-x
			case 7: // ters köşegen (transverse)
				sx, sy = w-1-y, h-1-x
			case 8: // 90° saat yönünün tersine
				sx, sy = w-1-y, x
			}
			si := rgba.PixOffset(sx, sy)
			di := dst.PixOffset(x, y)
			copy(dst.Pix[di:di+4], rgba.Pix[si:si+4])
		}
	}
	return dst
}

// normalizeJPEGOrientation: yönlü JPEG'i dik hale getirip yeniden kodlar
// (EXIF'siz); yönsüz ya da çözülemeyen JPEG olduğu gibi döner (bozuk dosyayı
// burada reddetmek OpenAI'nin Türkçe hata akışını değiştirirdi).
func normalizeJPEGOrientation(data []byte) []byte {
	o := jpegOrientation(data)
	if o == 1 {
		return data
	}
	img, err := jpeg.Decode(bytes.NewReader(data))
	if err != nil {
		return data
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, applyOrientation(img, o), &jpeg.Options{Quality: 92}); err != nil {
		return data
	}
	return buf.Bytes()
}
