package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/pricesource"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Zam geçmişi (migration 0046): firmanın ürün fiyat değişikliklerini
// (tedarikçi listesi, kâr oranı, elle düzenleme) listeler ve özetler. Her
// sorgu firmaya products.organization_id üzerinden bağlanır.

const (
	PriceChangeDirectionUp   = "up"
	PriceChangeDirectionDown = "down"
	PriceChangeDirectionAll  = "all"

	PriceChangeReasonAll = "all"

	PriceChangeSortNewest          = "newest"
	PriceChangeSortLargestIncrease = "largest_increase"
	PriceChangeSortLargestDecrease = "largest_decrease"

	defaultPriceChangeRange = 30 * 24 * time.Hour
	defaultPriceChangeLimit = 50
	maxPriceChangeLimit     = 200
	// maxPriceChangePage: OFFSET'i makul tutar (200 x 100000 = 20M satır).
	maxPriceChangePage = 100000
	// maxPriceChangeEvents: özet en yeni bu kadar olayı döner (bir yıl
	// iki kaynağın gece senkronu ~730 olay).
	maxPriceChangeEvents = 1000
	maxPriceChangeQuery  = 100
)

// PriceChangeFilter, zam geçmişi listesinin filtresidir. From/To sıfırsa
// varsayılan: son 30 gün. Aralık [From, To): To HARİÇ (bkz.
// ParsePriceChangeTime).
type PriceChangeFilter struct {
	From      time.Time
	To        time.Time
	Direction string // up (varsayılan) | down | all
	Reason    string // supplier (varsayılan) | markup | manual | all
	Source    string // "" = hepsi
	Category  string // ürünün ŞİMDİKİ kategorisi, birebir
	Query     string // ürün adında arama
	Sort      string // newest (varsayılan) | largest_increase | largest_decrease
	Page      int    // 1'den başlar
	Limit     int    // varsayılan 50, en fazla 200
}

// PriceChangeSummaryFilter, özetin filtresidir (yön/kategori/arama yok).
type PriceChangeSummaryFilter struct {
	From   time.Time
	To     time.Time
	Reason string
	Source string
}

type PriceChangeListResult struct {
	Changes []domain.PriceChange
	Total   int64
	Page    int
	Limit   int
}

// PriceChangeValidationError: istemcinin düzeltebileceği filtre hatası (400).
type PriceChangeValidationError struct{ msg string }

func (e *PriceChangeValidationError) Error() string { return e.msg }

func invalidPriceChange(format string, args ...any) error {
	return &PriceChangeValidationError{msg: fmt.Sprintf(format, args...)}
}

// ParsePriceChangeTime, from/to sorgu parametresini çözer:
//   - "2026-09-01" -> İstanbul günü: from için günün 00:00'ı, to için ERTESİ
//     günün 00:00'ı (gün DAHİL);
//   - RFC3339 ("2026-09-27T00:05:00+03:00") -> tam an; to için 1 µs
//     eklenir (an DAHİL -- from=to=bir olayın changed_at'i o olayı döner).
//
// Boş değer sıfır zaman döner (varsayılan uygulanır).
func ParsePriceChangeTime(value string, isEnd bool) (time.Time, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return time.Time{}, nil
	}
	if d, err := time.ParseInLocation("2006-01-02", value, istanbulLocation); err == nil {
		if isEnd {
			d = d.AddDate(0, 0, 1)
		}
		return d, nil
	}
	t, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}, invalidPriceChange("geçersiz tarih %q (YYYY-AA-GG ya da RFC3339 bekleniyor)", value)
	}
	if isEnd {
		t = t.Add(time.Microsecond)
	}
	return t, nil
}

func resolvePriceChangeRange(from, to time.Time) (time.Time, time.Time, error) {
	if to.IsZero() {
		to = time.Now().Add(time.Microsecond)
	}
	if from.IsZero() {
		from = to.Add(-defaultPriceChangeRange)
	}
	if !from.Before(to) {
		return from, to, invalidPriceChange("başlangıç tarihi bitiş tarihinden önce olmalıdır")
	}
	return from, to, nil
}

func normalizeReason(reason string) (string, error) {
	switch reason {
	case "":
		return domain.PriceChangeReasonSupplier, nil
	case domain.PriceChangeReasonSupplier, domain.PriceChangeReasonMarkup, domain.PriceChangeReasonManual, PriceChangeReasonAll:
		return reason, nil
	}
	return "", invalidPriceChange("geçersiz reason %q (supplier, markup, manual ya da all)", reason)
}

func normalizeSourceFilter(source string) (string, error) {
	if source == "" || domain.ValidPriceSource(source) {
		return source, nil
	}
	return "", invalidPriceChange("geçersiz source %q", source)
}

func (f PriceChangeFilter) normalize() (PriceChangeFilter, error) {
	var err error
	if f.From, f.To, err = resolvePriceChangeRange(f.From, f.To); err != nil {
		return f, err
	}
	switch f.Direction {
	case "":
		f.Direction = PriceChangeDirectionUp
	case PriceChangeDirectionUp, PriceChangeDirectionDown, PriceChangeDirectionAll:
	default:
		return f, invalidPriceChange("geçersiz direction %q (up, down ya da all)", f.Direction)
	}
	if f.Reason, err = normalizeReason(f.Reason); err != nil {
		return f, err
	}
	if f.Source, err = normalizeSourceFilter(f.Source); err != nil {
		return f, err
	}
	switch f.Sort {
	case "":
		f.Sort = PriceChangeSortNewest
	case PriceChangeSortNewest, PriceChangeSortLargestIncrease, PriceChangeSortLargestDecrease:
	default:
		return f, invalidPriceChange("geçersiz sort %q (newest, largest_increase ya da largest_decrease)", f.Sort)
	}
	// Geçersiz UTF-8 ya da NUL baytı PostgreSQL metin parametresi olarak
	// reddedilir (SQLSTATE 22021) -- 500 yerine burada 400 olsun.
	if !validQueryText(f.Category) || !validQueryText(f.Query) {
		return f, invalidPriceChange("arama/kategori metni geçersiz karakter içeriyor")
	}
	f.Category = pricesource.CollapseSpaces(f.Category)
	f.Query = strings.TrimSpace(f.Query)
	if utf8.RuneCountInString(f.Query) > maxPriceChangeQuery || utf8.RuneCountInString(f.Category) > pricesource.MaxCategoryLen {
		return f, invalidPriceChange("arama/kategori metni çok uzun")
	}
	switch {
	case f.Page == 0:
		f.Page = 1
	case f.Page < 0 || f.Page > maxPriceChangePage:
		return f, invalidPriceChange("geçersiz page (1-%d)", maxPriceChangePage)
	}
	switch {
	case f.Limit == 0:
		f.Limit = defaultPriceChangeLimit
	case f.Limit < 0:
		return f, invalidPriceChange("geçersiz limit")
	case f.Limit > maxPriceChangeLimit:
		f.Limit = maxPriceChangeLimit
	}
	return f, nil
}

func validQueryText(s string) bool {
	return utf8.ValidString(s) && !strings.ContainsRune(s, 0)
}

// ListPriceChanges, firmanın fiyat değişikliklerini filtreler/sıralar/
// sayfalar. Kaynak fiyatlarını da döner -- yalnızca products.manage'e
// gösterilmesi handler'ın işidir.
func (s *PriceSourceService) ListPriceChanges(ctx context.Context, organizationID string, f PriceChangeFilter) (*PriceChangeListResult, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if f, err = f.normalize(); err != nil {
		return nil, err
	}
	search := domain.NormalizeName(f.Query)
	rows, err := s.q.ListPriceChanges(ctx, sqlc.ListPriceChangesParams{
		OrganizationID: orgID, FromTime: pgTimestamptz(f.From), ToTime: pgTimestamptz(f.To),
		Direction: f.Direction, Reason: f.Reason, Source: f.Source, Category: f.Category,
		Search: search, Sort: f.Sort,
		PageLimit: int32(f.Limit), PageOffset: int64(f.Page-1) * int64(f.Limit),
	})
	if err != nil {
		return nil, err
	}
	total, err := s.q.CountPriceChanges(ctx, sqlc.CountPriceChangesParams{
		OrganizationID: orgID, FromTime: pgTimestamptz(f.From), ToTime: pgTimestamptz(f.To),
		Direction: f.Direction, Reason: f.Reason, Source: f.Source, Category: f.Category, Search: search,
	})
	if err != nil {
		return nil, err
	}
	out := &PriceChangeListResult{Changes: make([]domain.PriceChange, len(rows)), Total: total, Page: f.Page, Limit: f.Limit}
	for i, r := range rows {
		old, cur := repository.NumericToDecimal(r.OldPrice), repository.NumericToDecimal(r.NewPrice)
		out.Changes[i] = domain.PriceChange{
			ID:             r.ID.String(),
			ProductID:      r.ProductID.String(),
			ProductName:    r.ProductName,
			Unit:           r.Unit,
			Category:       r.Category,
			Source:         derefString(r.Source),
			Reason:         r.Reason,
			Note:           r.Note,
			OldPrice:       old,
			NewPrice:       cur,
			ChangeAmount:   cur.Sub(old),
			ChangePercent:  changePercent(old, cur),
			ChangedAt:      r.ChangedAt.Time,
			OldSourcePrice: repository.NumericToDecimalPtr(r.OldSourcePrice),
			NewSourcePrice: repository.NumericToDecimalPtr(r.NewSourcePrice),
		}
	}
	return out, nil
}

// changePercent: (yeni - eski) / eski x 100, 2 ondalığa yuvarlanmış; eski
// fiyat 0 (ya da negatif) ise tanımsız -> nil.
func changePercent(old, cur decimal.Decimal) *decimal.Decimal {
	if !old.IsPositive() {
		return nil
	}
	p := cur.Sub(old).Mul(decimal.NewFromInt(100)).DivRound(old, 2)
	return &p
}

func derefString(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// PriceChangeSummary: aralıktaki zam/indirim sayıları, zam gelen (tekil)
// ürün sayısı, ortalama/en yüksek zam ve olay listesi (bir senkron ya da
// kâr oranı güncellemesi = tek olay; elle düzenlemeler gün başına).
func (s *PriceSourceService) PriceChangeSummary(ctx context.Context, organizationID string, f PriceChangeSummaryFilter) (*domain.PriceChangeSummary, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if f.From, f.To, err = resolvePriceChangeRange(f.From, f.To); err != nil {
		return nil, err
	}
	if f.Reason, err = normalizeReason(f.Reason); err != nil {
		return nil, err
	}
	if f.Source, err = normalizeSourceFilter(f.Source); err != nil {
		return nil, err
	}
	from, to := pgTimestamptz(f.From), pgTimestamptz(f.To)

	sum, err := s.q.SummarizePriceChanges(ctx, sqlc.SummarizePriceChangesParams{
		OrganizationID: orgID, FromTime: from, ToTime: to, Reason: f.Reason, Source: f.Source,
	})
	if err != nil {
		return nil, err
	}
	out := &domain.PriceChangeSummary{
		IncreasedCount:     int(sum.IncreasedCount),
		DecreasedCount:     int(sum.DecreasedCount),
		ProductsIncreased:  int(sum.ProductsIncreased),
		AvgIncreasePercent: repository.NumericToDecimalPtr(sum.AvgIncreasePercent),
		Events:             []domain.PriceChangeEvent{},
	}

	maxRows, err := s.q.GetMaxPriceIncrease(ctx, sqlc.GetMaxPriceIncreaseParams{
		OrganizationID: orgID, FromTime: from, ToTime: to, Reason: f.Reason, Source: f.Source,
	})
	if err != nil {
		return nil, err
	}
	if len(maxRows) > 0 {
		out.MaxIncrease = &domain.PriceChangeMaxIncrease{
			ProductID:     maxRows[0].ProductID.String(),
			ProductName:   maxRows[0].ProductName,
			ChangePercent: repository.NumericToDecimal(maxRows[0].ChangePercent),
		}
	}

	events, err := s.q.ListPriceChangeEvents(ctx, sqlc.ListPriceChangeEventsParams{
		OrganizationID: orgID, FromTime: from, ToTime: to, Reason: f.Reason, Source: f.Source,
		MaxEvents: maxPriceChangeEvents,
	})
	if err != nil {
		return nil, err
	}
	for _, e := range events {
		rangeFrom, rangeTo := eventRange(e.EventAt.Time, e.Reason, f.From, f.To)
		out.Events = append(out.Events, domain.PriceChangeEvent{
			ChangedAt:          e.EventAt.Time,
			RangeFrom:          rangeFrom,
			RangeTo:            rangeTo,
			Source:             derefString(e.Source),
			Reason:             e.Reason,
			ChangeCount:        int(e.ChangeCount),
			Increased:          int(e.Increased),
			Decreased:          int(e.Decreased),
			AvgChangePercent:   repository.NumericToDecimalPtr(e.AvgChangePercent),
			MaxIncreasePercent: repository.NumericToDecimalPtr(e.MaxIncreasePercent),
		})
	}
	return out, nil
}

// eventRange, bir özet olayının satırlarını liste ucunda süzecek KAPALI
// aralığı döner (to an dahil, bkz. ParsePriceChangeTime). Senkron/kâr oranı
// olayı tek bir andır. Elle düzenleme olayı bir İstanbul günüdür; özet
// [from, to) ile sorgulandığı için gün bu aralıkla kırpılır -- aksi hâlde
// listede özetin saymadığı satırlar da görünürdü.
func eventRange(at time.Time, reason string, from, to time.Time) (time.Time, time.Time) {
	if reason != domain.PriceChangeReasonManual {
		return at, at
	}
	d := at.In(istanbulLocation)
	start := time.Date(d.Year(), d.Month(), d.Day(), 0, 0, 0, 0, istanbulLocation)
	end := time.Date(d.Year(), d.Month(), d.Day()+1, 0, 0, 0, 0, istanbulLocation)
	if start.Before(from) {
		start = from
	}
	if end.After(to) {
		end = to
	}
	// Dahil üst sınır: veritabanı anları mikrosaniye hassasiyetindedir
	// (pgx da parametreyi mikrosaniyeye keser).
	return start.Truncate(time.Microsecond), end.Truncate(time.Microsecond).Add(-time.Microsecond)
}

// IsPriceChangeValidationError, handler'ın 400 ayrımı içindir.
func IsPriceChangeValidationError(err error) bool {
	var v *PriceChangeValidationError
	return errors.As(err, &v)
}
