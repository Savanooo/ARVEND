package service

import (
	"bytes"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

func sampleOfferForPDF(items int) *domain.Offer {
	valid := time.Date(2026, 10, 21, 0, 0, 0, 0, time.UTC)
	section := "Çatı İşleri"
	o := &domain.Offer{
		OfferNo: "TKL-2026-0042", OfferDate: time.Date(2026, 10, 6, 9, 0, 0, 0, time.UTC),
		Status: domain.OfferStatusGonderildi, RevisionNo: 1,
		CustomerName: "Şükrü Öztürk İnşaat Ltd. Şti.", CustomerPhone: "0532 000 00 00",
		CustomerEmail: "info@ornek.com.tr", CustomerAddress: "Bağdat Cd. No:12 Kadıköy / İstanbul",
		ValidUntil: &valid, Currency: "TRY", Notes: "Fiyatlara nakliye dahildir.\nMontaj 10 iş günü içinde yapılır.",
		DiscountType: domain.DiscountPercent, DiscountValue: 5, VatRate: 20,
	}
	for i := 0; i < items; i++ {
		it := domain.OfferItem{
			ProductName: "Kiremit sökümü ve yeni Marsilya kiremit döşemesi (izolasyon membranı dahil, çatı eğimi 30°)",
			Quantity:    61.67, UnitPrice: 450, Unit: "m²", LineTotal: 27751.5,
		}
		if i%3 == 0 {
			it.SectionLabel = &section
		}
		if i == 1 {
			it.DiscountType, it.DiscountValue, it.LineTotal = domain.DiscountPercent, 10, 24976.35
		}
		o.Subtotal += it.LineTotal
		o.Items = append(o.Items, it)
	}
	o.DiscountAmount = o.Subtotal * 0.05
	o.VatAmount = (o.Subtotal - o.DiscountAmount) * 0.2
	o.GrandTotal = o.Subtotal - o.DiscountAmount + o.VatAmount
	return o
}

func TestRenderOfferPDF(t *testing.T) {
	c := offerCompany{
		Name: "ARVEND Yapı", Address: "Şerefiye Mah. Kıbrıs Sk. No:29 D:3 Merkez / Düzce", Phone: "0380 000 00 00",
		Email: "info@arvendyapi.com.tr", TaxLine: "Düzce V.D. · 1234567890",
		PaymentTerms: "%50 peşin, kalan iş tesliminde.", DeliveryTerms: "Sipariş onayından itibaren 15 gün.",
		BankName: "Ziraat Bankası", AccountHolder: "ARVEND Yapı", IBAN: formatIBAN("TR330006100519786457841326"),
		Footer: "Teklifimizi değerlendirmenizi rica ederiz.",
	}
	now := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)

	short, err := renderOfferPDF(sampleOfferForPDF(3), c, now)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	if !bytes.HasPrefix(short, []byte("%PDF-")) {
		t.Fatal("PDF başlığı yok")
	}
	if n := bytes.Count(short, []byte("/Type /Page\n")); n != 1 {
		t.Fatalf("kısa teklif tek sayfa olmalı, %d sayfa", n)
	}

	long, err := renderOfferPDF(sampleOfferForPDF(40), c, now)
	if err != nil {
		t.Fatalf("render (uzun): %v", err)
	}
	if n := bytes.Count(long, []byte("/Type /Page\n")); n < 2 {
		t.Fatalf("40 kalem birden çok sayfaya taşmalı, %d sayfa", n)
	}

	// İsteğe bağlı görsel kontrol: OFFER_PDF_OUT=/tmp/x.pdf go test -run TestRenderOfferPDF
	if out := os.Getenv("OFFER_PDF_OUT"); out != "" {
		_ = os.WriteFile(out, short, 0o644)
		_ = os.WriteFile(strings.TrimSuffix(out, ".pdf")+"-uzun.pdf", long, 0o644)
	}
}

func TestOfferPDFFilename(t *testing.T) {
	o := &domain.Offer{OfferNo: "TKL/2026 Çatı-0042", RevisionNo: 2}
	if got := offerPDFFilename(o); got != "Teklif-TKL-2026-Cati-0042-R2.pdf" {
		t.Fatalf("dosya adı: %s", got)
	}
}
