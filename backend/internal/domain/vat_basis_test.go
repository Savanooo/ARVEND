package domain

import "testing"

// KDV hariç bedel/maliyet/kârın tek kuralı (finans özeti, proje listesi,
// Maliyet Kontrolü, ek iş kârlılığı aynı fonksiyonları kullanır).
func TestVATBasis(t *testing.T) {
	b := VATBasis{Value: 1200000, VAT: 200000, Known: true}
	if b.Net() != 1000000 {
		t.Fatalf("KDV hariç bedel: %v", b.Net())
	}
	costNet := CostNet(150000, 20000)
	if costNet != 130000 {
		t.Fatalf("KDV hariç maliyet: %v", costNet)
	}
	if got := b.ProfitNet(150000, costNet); got != 870000 {
		t.Errorf("KDV hariç kâr: %v", got)
	}

	// Bedelin KDV'si bilinmiyorsa kâr KDV dahil maliyetle: KDV dahil bedelden
	// KDV hariç maliyet çıkarmak kârı şişirirdi.
	unknown := VATBasis{Value: 1200000, Known: false}
	if got := unknown.ProfitNet(150000, costNet); got != 1050000 {
		t.Errorf("KDV bilinmiyorsa: %v", got)
	}

	// Eksiltme (negatif gelir etkisi) ve kuruş yuvarlaması.
	ded := VATBasis{Value: -12000, VAT: -2000, Known: true}
	if ded.Net() != -10000 || ded.ProfitNet(0, 0) != -10000 {
		t.Errorf("eksiltme: %v %v", ded.Net(), ded.ProfitNet(0, 0))
	}
	if CostNet(0.1+0.2, 0) != 0.3 || RoundKurus(286850.01+0.004) != 286850.01 {
		t.Errorf("kuruş yuvarlaması: %v %v", CostNet(0.1+0.2, 0), RoundKurus(286850.01+0.004))
	}
}
