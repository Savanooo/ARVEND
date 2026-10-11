package domain

import (
	"bytes"
	"encoding/json"
)

// calc_snapshot (offer_revision_items.calc_snapshot) KANONİK ŞEMASI.
//
// Metraj sonucundan teklife eklenen bir kalemin hesap ANINDAKİ dondurulmuş
// bilgisidir; istemciler yazar (web MetrajHesaplaPanel, mobil
// buildOfferItemsFromCalcResult). Eskiden sunucu bunu hiç yorumlamadan
// saklıyordu ve web ile mobil farklı anahtarlar yazıyordu (web: area /
// recipe_factor, pitch_deg; mobil: effective_area / factor, recipe_item_id,
// pitch_deg yok). Artık her kayıtta VE her okumada NormalizeCalcSnapshot
// ile bu şemaya getirilir. Tüm değerler metindir (sayılar /calculations/run
// yanıtındaki gibi string) ya da null (ör. çevre girilmedi, eğim yok);
// min_quantity/package_size yalnızca reçetede tanımlıysa bulunur:
//
//	area             etkin alan, m² (eğim uygulanmışsa eğim sonrası)
//	footprint_area   taban alan, m² (eğim öncesi)
//	perimeter        çevre, m
//	pitch_deg        uygulanan çatı eğimi, derece (null: eğim yok)
//	recipe_item_id   reçete kalemi
//	category_id      hesaplama kategorisi (kolondaki calc_category_id
//	                 kategori silinince NULL olur, bu kalır)
//	category_name    hesaplama kategorisinin adı
//	group_name       hesaplama grubunun adı (malzeme grubu DEĞİL)
//	calculation_type area_based | perimeter_based | fixed
//	recipe_factor    kullanılan katsayı (m² / metre başına ya da sabit)
//	waste_percent    fire yüzdesi
//	min_quantity     reçetedeki minimum miktar
//	package_size     bir paketin kapsadığı ham miktar (doluysa miktar
//	                 paket sayısıdır)
//	rounding_type    none | ceil | round
//	price_at_calc    hesap anındaki birim fiyat
//	price_source     product | reference | none
//
// Eski kayıtlar için eşlemeler: effective_area -> area, factor ->
// recipe_factor (eski mobil sürümler). Eski kayıtta bulunmayan anahtar
// (ör. eski mobilde pitch_deg) çıktıda da YOKTUR -- "eğim yoktu" (null)
// ile "bilinmiyor" (anahtar yok) karışmasın.
var calcSnapshotKeys = map[string]bool{
	"area": true, "footprint_area": true, "perimeter": true, "pitch_deg": true,
	"recipe_item_id": true, "category_id": true, "category_name": true, "group_name": true,
	"calculation_type": true, "recipe_factor": true, "waste_percent": true,
	"min_quantity": true, "package_size": true, "rounding_type": true,
	"price_at_calc": true, "price_source": true,
}

var calcSnapshotLegacyKeys = map[string]string{
	"effective_area": "area",
	"factor":         "recipe_factor",
}

// calcSnapshotMaxRunes: tek bir değerin en çok uzunluğu -- şema dışı
// anahtarlar atıldığı için snapshot'ın boyutu da böylece sınırlı kalır.
const calcSnapshotMaxRunes = 200

// NormalizeCalcSnapshot, istemcinin gönderdiği ya da veritabanındaki bir
// calc_snapshot'ı kanonik şemaya çevirir: eski anahtarları yeni adlarına
// taşır, şema dışı anahtarları ve metin/sayı/null olmayan değerleri atar,
// sayıları yazıldıkları gibi metne çevirir. Nesne olmayan, bozuk ya da
// boş kalan bir snapshot nil döner (kalem "metrajdan gelmemiş" sayılır --
// calc_category_id'nin sessizce NULL'a düşmesiyle aynı ilke).
func NormalizeCalcSnapshot(raw json.RawMessage) json.RawMessage {
	var in map[string]json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &in) != nil || in == nil {
		return nil
	}
	out := map[string]any{}
	put := func(key string, v json.RawMessage) {
		if val, ok := calcSnapshotValue(v); ok {
			out[key] = val
		}
	}
	for key, v := range in {
		if calcSnapshotKeys[key] {
			put(key, v)
		}
	}
	for legacy, key := range calcSnapshotLegacyKeys {
		if _, done := out[key]; done {
			continue
		}
		if v, ok := in[legacy]; ok {
			put(key, v)
		}
	}
	if len(out) == 0 {
		return nil
	}
	b, err := json.Marshal(out)
	if err != nil {
		return nil
	}
	return b
}

// calcSnapshotValue: metin olduğu gibi (sınırda kısaltılarak), sayı
// yazıldığı gibi metin, null null kalır; nesne/dizi/mantıksal değer atılır.
func calcSnapshotValue(v json.RawMessage) (any, bool) {
	dec := json.NewDecoder(bytes.NewReader(v))
	dec.UseNumber()
	var x any
	if err := dec.Decode(&x); err != nil {
		return nil, false
	}
	switch t := x.(type) {
	case nil:
		return nil, true
	case string:
		if r := []rune(t); len(r) > calcSnapshotMaxRunes {
			t = string(r[:calcSnapshotMaxRunes])
		}
		return t, true
	case json.Number:
		return t.String(), true
	}
	return nil, false
}
