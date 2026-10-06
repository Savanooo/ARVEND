package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"math"
	"regexp"
	"strings"
	"time"
	"unicode"

	"github.com/go-pdf/fpdf"
	"github.com/jackc/pgx/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/crypto"
	"github.com/Savanooo/ARVEND/backend/internal/platform/pdffont"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// OfferPDFService, teklifin müşteriye verilecek PDF'ini üretir: personel
// teklif detayından (GET /offers/{id}/pdf), müşteri paylaşım linkinden
// (GET /public/offers/{token}/pdf) indirir.
//
// GÜVENLİK SINIRI: PDF yalnızca müşteriye zaten gösterilen alanları basar
// (kalem adı, miktar, birim, birim fiyat, iskonto, tutar, toplamlar). İç
// taşeron maliyeti / fiyatlama modu / kâr oranı ve metraj hesabının
// ayrıntısı (calc_snapshot: fire, katsayı, katalog fiyatı) ASLA basılmaz.
type OfferPDFService struct {
	offers *OfferService
	q      *sqlc.Queries
	box    *crypto.SecretBox
}

func NewOfferPDFService(offers *OfferService, q *sqlc.Queries, box *crypto.SecretBox) *OfferPDFService {
	return &OfferPDFService{offers: offers, q: q, box: box}
}

// OfferPDF, üretilen dosya.
type OfferPDF struct {
	Filename string
	Content  []byte
}

// Render, personelin gördüğü teklifin (güncel revizyon) PDF'i.
func (s *OfferPDFService) Render(ctx context.Context, offerID, organizationID string) (*OfferPDF, error) {
	o, err := s.offers.Get(ctx, offerID, organizationID)
	if err != nil {
		return nil, err
	}
	return s.render(ctx, o)
}

// RenderShared, paylaşım linkindeki (müşteriye gönderilen, donmuş)
// revizyonun PDF'i. Link kuralları (iptal/süre/firma durumu) web sayfasıyla
// AYNI yoldan uygulanır: GetByShareLinkToken.
func (s *OfferPDFService) RenderShared(ctx context.Context, token, ip, userAgent string) (*OfferPDF, error) {
	o, _, err := s.offers.GetByShareLinkToken(ctx, token, ip, userAgent)
	if err != nil {
		return nil, err
	}
	return s.render(ctx, o)
}

// offerCompany, PDF başlığındaki firma ve alt kısımdaki koşul/banka bilgisi.
type offerCompany struct {
	Name, Address, Phone, Email, Website, TaxLine string
	PaymentTerms, DeliveryTerms, Footer           string
	BankName, AccountHolder, IBAN                 string
}

func (s *OfferPDFService) company(ctx context.Context, organizationID string) (offerCompany, error) {
	var c offerCompany
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return c, domain.ErrNotFound
	}
	org, err := s.q.GetOrganizationByID(ctx, orgID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return c, domain.ErrNotFound
		}
		return c, err
	}
	c.Name = org.Name

	// Kurulum adımları hiç doldurulmamış olabilir: eksik satır hata değil,
	// PDF yalnızca bilinen bilgiyle çıkar.
	if p, err := s.q.GetOrganizationProfile(ctx, orgID); err == nil {
		if strings.TrimSpace(p.LegalName) != "" {
			c.Name = strings.TrimSpace(p.LegalName)
		}
		addr := strings.TrimSpace(p.InvoiceAddress)
		place := joinNonEmpty(" / ", strings.TrimSpace(p.District), strings.TrimSpace(p.City))
		c.Address = joinNonEmpty(" ", addr, place)
		c.Phone = strings.TrimSpace(p.Phone)
		c.Email = strings.TrimSpace(p.Email)
		c.Website = strings.TrimSpace(p.Website)
		taxOffice, taxNo := strings.TrimSpace(p.TaxOffice), strings.TrimSpace(p.TaxNumber)
		switch {
		case taxOffice != "" && taxNo != "":
			c.TaxLine = fmt.Sprintf("%s V.D. · %s", taxOffice, taxNo)
		case taxNo != "":
			c.TaxLine = "VKN/TCKN: " + taxNo
		}
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return c, err
	}

	if cs, err := s.q.GetOrganizationCommercialSettings(ctx, orgID); err == nil {
		c.PaymentTerms = strings.TrimSpace(cs.DefaultPaymentTerms)
		c.DeliveryTerms = strings.TrimSpace(cs.DefaultDeliveryTerms)
		c.Footer = strings.TrimSpace(cs.DefaultOfferFooter)
		c.BankName = strings.TrimSpace(cs.BankName)
		c.AccountHolder = strings.TrimSpace(cs.AccountHolder)
		if s.box != nil && cs.IbanEnc != "" {
			// IBAN çözülemezse (ör. anahtar değişmiş) PDF yine çıkar, IBAN
			// satırı basılmaz -- yanlış IBAN basmaktan iyidir.
			if iban, err := s.box.Decrypt(cs.IbanEnc); err == nil {
				c.IBAN = formatIBAN(iban)
			}
		}
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return c, err
	}
	return c, nil
}

func (s *OfferPDFService) render(ctx context.Context, o *domain.Offer) (*OfferPDF, error) {
	c, err := s.company(ctx, o.OrganizationID)
	if err != nil {
		return nil, err
	}
	content, err := renderOfferPDF(o, c, time.Now())
	if err != nil {
		return nil, err
	}
	return &OfferPDF{Filename: offerPDFFilename(o), Content: content}, nil
}

var unsafeFilenameChars = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

// offerPDFFilename: "Teklif-TKL-2026-0012.pdf" (revizyonda "-R2"). Yalnızca
// ASCII -- handler UTF-8 adı ayrıca filename* ile verir.
func offerPDFFilename(o *domain.Offer) string {
	no := strings.Trim(unsafeFilenameChars.ReplaceAllString(asciiFold(o.OfferNo), "-"), "-")
	if no == "" {
		no = "teklif"
	}
	if o.RevisionNo > 0 {
		no = fmt.Sprintf("%s-R%d", no, o.RevisionNo)
	}
	return "Teklif-" + no + ".pdf"
}

func asciiFold(s string) string {
	return strings.NewReplacer("ç", "c", "Ç", "C", "ğ", "g", "Ğ", "G", "ı", "i", "İ", "I",
		"ö", "o", "Ö", "O", "ş", "s", "Ş", "S", "ü", "u", "Ü", "U").Replace(s)
}

// formatIBAN: "TR330006100519786457841326" -> "TR33 0006 1005 1978 6457 8413 26".
func formatIBAN(iban string) string {
	compact := strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(iban), " ", ""))
	var b strings.Builder
	for i, r := range compact {
		if i > 0 && i%4 == 0 {
			b.WriteByte(' ')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// formatAmount: 13912.5 -> "13.912,50" (eksi işaret korunur).
func formatAmount(v float64) string {
	return strings.TrimSuffix(FormatTL(v), " TL")
}

func currencyLabel(code string) string {
	switch strings.ToUpper(strings.TrimSpace(code)) {
	case "", "TRY", "TL":
		return "TL"
	default:
		return strings.ToUpper(strings.TrimSpace(code))
	}
}

// formatQuantity: 12 -> "12", 61.67 -> "61,67", 2.5 -> "2,5".
func formatQuantity(v float64) string {
	s := strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.2f", math.Round(v*100)/100), "0"), ".")
	return strings.ReplaceAll(s, ".", ",")
}

func formatPercent(v float64) string {
	return "%" + formatQuantity(v)
}

// renderOfferPDF, A4 dikey teklif belgesi.
func renderOfferPDF(o *domain.Offer, c offerCompany, now time.Time) ([]byte, error) {
	const (
		left   = 15.0
		width  = 180.0
		bottom = 18.0
	)
	cur := currencyLabel(o.Currency)
	money := func(v float64) string { return formatAmount(v) + " " + cur }

	pdf := fpdf.New("P", "mm", "A4", "")
	pdf.AddUTF8FontFromBytes(pdffont.Family, "", pdffont.Regular)
	pdf.AddUTF8FontFromBytes(pdffont.Family, "B", pdffont.Bold)
	pdf.SetMargins(left, 15, 15)
	pdf.SetAutoPageBreak(false, bottom)
	pdf.AliasNbPages("{nb}")
	pdf.SetTitle(fmt.Sprintf("Teklif %s", o.OfferNo), true)
	pdf.SetAuthor(c.Name, true)
	_, pageH := pdf.GetPageSize()

	font := func(size float64, bold bool) {
		style := ""
		if bold {
			style = "B"
		}
		pdf.SetFont(pdffont.Family, style, size)
	}
	ink := func() { pdf.SetTextColor(25, 25, 25) }
	muted := func() { pdf.SetTextColor(110, 110, 110) }

	pdf.SetFooterFunc(func() {
		pdf.SetY(-12)
		font(7.5, false)
		muted()
		pdf.CellFormat(0, 5, fmt.Sprintf("%s · Teklif %s · sayfa %d/{nb}", c.Name, o.OfferNo, pdf.PageNo()), "", 0, "C", false, 0, "")
	})
	pdf.AddPage()

	// ---- Başlık: firma (sol) + belge bilgisi (sağ)
	top := pdf.GetY()
	font(14, true)
	ink()
	pdf.MultiCell(width*0.58, 6.5, c.Name, "", "L", false)
	font(8.5, false)
	muted()
	for _, line := range []string{c.Address, joinNonEmpty(" · ", c.Phone, c.Email), c.Website, c.TaxLine} {
		if line != "" {
			pdf.MultiCell(width*0.58, 4.4, line, "", "L", false)
		}
	}
	leftBottom := pdf.GetY()

	pdf.SetXY(left+width*0.6, top)
	font(15, true)
	ink()
	pdf.CellFormat(width*0.4, 7, "FİYAT TEKLİFİ", "", 2, "R", false, 0, "")
	if o.Status == domain.OfferStatusTaslak {
		font(8, true)
		pdf.SetTextColor(190, 60, 40)
		pdf.CellFormat(width*0.4, 4.5, "TASLAK -- müşteriye gönderilmedi", "", 2, "R", false, 0, "")
	}
	meta := [][2]string{{"Teklif No", o.OfferNo}}
	if o.RevisionNo > 0 {
		meta = append(meta, [2]string{"Revizyon", fmt.Sprintf("R%d", o.RevisionNo)})
	}
	meta = append(meta, [2]string{"Tarih", o.OfferDate.In(istanbul()).Format("02.01.2006")})
	if o.ValidUntil != nil {
		meta = append(meta, [2]string{"Geçerlilik", o.ValidUntil.In(istanbul()).Format("02.01.2006") + " tarihine kadar"})
	}
	for _, kv := range meta {
		pdf.SetX(left + width*0.6)
		font(8.5, false)
		muted()
		pdf.CellFormat(width*0.4-46, 5, kv[0], "", 0, "R", false, 0, "")
		font(8.5, true)
		ink()
		pdf.CellFormat(46, 5, kv[1], "", 1, "R", false, 0, "")
	}
	y := math.Max(leftBottom, pdf.GetY()) + 3
	pdf.SetDrawColor(200, 160, 60)
	pdf.SetLineWidth(0.6)
	pdf.Line(left, y, left+width, y)
	pdf.SetY(y + 4)

	// ---- Müşteri
	font(8, true)
	muted()
	pdf.CellFormat(width, 4.5, "MÜŞTERİ", "", 1, "L", false, 0, "")
	font(10.5, true)
	ink()
	pdf.MultiCell(width, 5.5, nonEmpty(o.CustomerName, "—"), "", "L", false)
	font(8.5, false)
	muted()
	for _, line := range []string{o.CustomerAddress, joinNonEmpty(" · ", o.CustomerPhone, o.CustomerEmail)} {
		if strings.TrimSpace(line) != "" {
			pdf.MultiCell(width, 4.4, strings.TrimSpace(line), "", "L", false)
		}
	}
	pdf.Ln(4)

	// ---- Kalemler
	hasDiscount := false
	for _, it := range o.Items {
		if it.DiscountType != "" && it.DiscountType != domain.DiscountNone && it.DiscountValue > 0 {
			hasDiscount = true
			break
		}
	}
	type col struct {
		title string
		w     float64
		align string
	}
	cols := []col{{"#", 8, "C"}, {"Açıklama", 0, "L"}, {"Miktar", 18, "R"}, {"Birim", 15, "C"}, {"Birim Fiyat", 27, "R"}}
	if hasDiscount {
		cols = append(cols, col{"İskonto", 18, "R"})
	}
	cols = append(cols, col{"Tutar", 30, "R"})
	fixed := 0.0
	for _, c := range cols {
		fixed += c.w
	}
	cols[1].w = width - fixed

	const lineH = 4.6
	header := func() {
		font(8, true)
		pdf.SetFillColor(245, 240, 228)
		pdf.SetTextColor(70, 60, 40)
		pdf.SetDrawColor(225, 215, 195)
		pdf.SetLineWidth(0.2)
		pdf.SetX(left)
		for _, c := range cols {
			pdf.CellFormat(c.w, 7, c.title, "B", 0, c.align, true, 0, "")
		}
		pdf.Ln(-1)
	}
	ensure := func(h float64) {
		if pdf.GetY()+h > pageH-bottom-2 {
			pdf.AddPage()
			header()
		}
	}
	header()

	var section string
	for i, it := range o.Items {
		if it.SectionLabel != nil && strings.TrimSpace(*it.SectionLabel) != section {
			section = strings.TrimSpace(*it.SectionLabel)
			if section != "" {
				ensure(7 + lineH)
				font(8.5, true)
				ink()
				pdf.SetX(left)
				pdf.CellFormat(width, 6.5, section, "", 1, "L", false, 0, "")
			}
		}
		font(8.5, false)
		lines := pdf.SplitText(nonEmpty(strings.TrimSpace(it.ProductName), "—"), cols[1].w-2)
		rowH := math.Max(1, float64(len(lines)))*lineH + 2
		ensure(rowH)
		discount := ""
		if it.DiscountValue > 0 {
			switch it.DiscountType {
			case domain.DiscountPercent:
				discount = formatPercent(it.DiscountValue)
			case domain.DiscountFixed:
				discount = formatAmount(it.DiscountValue)
			}
		}
		values := []string{
			fmt.Sprintf("%d", i+1),
			"",
			formatQuantity(it.Quantity),
			strings.TrimSpace(it.Unit),
			formatAmount(it.UnitPrice),
		}
		if hasDiscount {
			values = append(values, discount)
		}
		values = append(values, formatAmount(it.LineTotal))

		rowY := pdf.GetY()
		x := left
		ink()
		for ci, c := range cols {
			pdf.SetXY(x, rowY+1)
			if ci == 1 {
				for li, line := range lines {
					pdf.SetXY(x+1, rowY+1+float64(li)*lineH)
					pdf.CellFormat(c.w-2, lineH, line, "", 0, "L", false, 0, "")
				}
			} else {
				pdf.CellFormat(c.w, lineH, values[ci], "", 0, c.align, false, 0, "")
			}
			x += c.w
		}
		pdf.SetDrawColor(235, 235, 235)
		pdf.SetLineWidth(0.2)
		pdf.Line(left, rowY+rowH, left+width, rowY+rowH)
		pdf.SetY(rowY + rowH)
	}
	if len(o.Items) == 0 {
		font(8.5, false)
		muted()
		pdf.CellFormat(width, 8, "Bu teklifte kalem yok.", "", 1, "C", false, 0, "")
	}

	// ---- Toplamlar (sağa yaslı)
	type total struct {
		label, value string
		strong       bool
	}
	totals := []total{{"Ara Toplam", money(o.Subtotal), false}}
	if o.DiscountAmount > 0 {
		label := "İskonto"
		if o.DiscountType == domain.DiscountPercent {
			label = "İskonto (" + formatPercent(o.DiscountValue) + ")"
		}
		totals = append(totals, total{label, "-" + money(o.DiscountAmount), false})
	}
	totals = append(totals,
		total{"KDV (" + formatPercent(o.VatRate) + ")", money(o.VatAmount), false},
		total{"GENEL TOPLAM", money(o.GrandTotal), true},
	)
	ensure(float64(len(totals))*6.5 + 6)
	pdf.Ln(3)
	for _, t := range totals {
		pdf.SetX(left + width - 85)
		if t.strong {
			pdf.SetFillColor(245, 240, 228)
			font(10.5, true)
			ink()
			pdf.CellFormat(45, 8, t.label, "", 0, "L", true, 0, "")
			pdf.CellFormat(40, 8, t.value, "", 1, "R", true, 0, "")
			continue
		}
		font(9, false)
		muted()
		pdf.CellFormat(45, 6, t.label, "", 0, "L", false, 0, "")
		ink()
		pdf.CellFormat(40, 6, t.value, "", 1, "R", false, 0, "")
	}
	pdf.Ln(4)

	// ---- Notlar, koşullar, banka
	block := func(title, body string) {
		body = strings.TrimSpace(body)
		if body == "" {
			return
		}
		font(8.5, false)
		var lines []string
		for _, para := range strings.Split(body, "\n") {
			if strings.TrimSpace(para) == "" {
				lines = append(lines, "")
				continue
			}
			lines = append(lines, pdf.SplitText(para, width)...)
		}
		ensure(6 + float64(len(lines))*4.4)
		if title != "" {
			font(8, true)
			muted()
			pdf.SetX(left)
			pdf.CellFormat(width, 5, strings.ToUpperSpecial(unicode.TurkishCase, title), "", 1, "L", false, 0, "")
		}
		font(8.5, false)
		ink()
		for _, line := range lines {
			ensure(4.4)
			pdf.SetX(left)
			pdf.CellFormat(width, 4.4, line, "", 1, "L", false, 0, "")
		}
		pdf.Ln(2.5)
	}
	block("Notlar", o.Notes)
	block("Ödeme Koşulları", c.PaymentTerms)
	block("Teslim Koşulları", c.DeliveryTerms)
	if c.IBAN != "" {
		bank := joinNonEmpty("\n",
			joinNonEmpty(" · ", c.BankName, c.AccountHolder),
			"IBAN: "+c.IBAN)
		block("Banka Bilgileri", bank)
	}
	block("", c.Footer)

	font(7.5, false)
	muted()
	ensure(6)
	pdf.SetX(left)
	pdf.CellFormat(width, 5, "Oluşturulma: "+now.In(istanbul()).Format("02.01.2006 15:04"), "", 1, "R", false, 0, "")

	var buf bytes.Buffer
	if err := pdf.Output(&buf); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func nonEmpty(s, fallback string) string {
	if strings.TrimSpace(s) == "" {
		return fallback
	}
	return s
}
