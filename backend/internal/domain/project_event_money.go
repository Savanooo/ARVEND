package domain

// ProjectEventMoneyKeys, project_events.metadata içinde TUTAR taşıyan
// anahtarlardır. GET /projects/{id}/events projects.read ile açılır (Saha
// ve Proje Yöneticisi de okur): olay listede kalır ama bu anahtarlar
// projects.finance.read izni olmayana düşürülür (bkz.
// WithoutMoneyMetadata, docs/authorization.md §11). Kural olay tipinden
// bağımsızdır -- bütçe/sipariş olaylarındaki tutarlar da finans iznine
// bağlıdır (mobil ve web aynı kuralı uygular).
//
// Bir olaya tutar yazan YENİ bir anahtar eklendiğinde buraya da eklenmeli:
// service/project_event_money_test.go servis kaynağındaki logProjectEvent
// çağrılarını tarayıp tutar adlı her anahtarın burada olduğunu zorlar.
var ProjectEventMoneyKeys = map[string]bool{
	"amount":          true, // tahsilat, masraf, fatura, ödemeler, bütçe kalemi/revizyonu, taahhüt
	"planned_amount":  true, // ödeme planı kalemi
	"contract_amount": true, // proje oluşturma (teklif toplamı), eski taşeron kaydı
	"grand_total":     true, // ek iş
	"total":           true, // satın alma siparişi
	"net_payable":     true, // taşeron hakedişi onayı
	"etc_amount":      true, // maliyet tahmini (kalan maliyet)
}

// WithoutMoneyMetadata, metadata'nın tutar anahtarları çıkarılmış bir
// KOPYASINI döner; girdi değiştirilmez. Tutar anahtarı yoksa girdinin
// kendisi döner (gereksiz kopya yok).
func WithoutMoneyMetadata(m map[string]any) map[string]any {
	hasMoney := false
	for k := range m {
		if ProjectEventMoneyKeys[k] {
			hasMoney = true
			break
		}
	}
	if !hasMoney {
		return m
	}
	out := make(map[string]any, len(m))
	for k, v := range m {
		if !ProjectEventMoneyKeys[k] {
			out[k] = v
		}
	}
	return out
}
