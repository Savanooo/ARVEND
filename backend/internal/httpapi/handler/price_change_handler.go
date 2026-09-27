package handler

import (
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// Zam geçmişi uçları: GET /products/price-changes ve
// GET /products/price-changes/summary (products.read). Satış fiyatları
// products.read sahibine zaten açık; tedarikçi (kaynak) fiyatları yalnızca
// products.manage'e döner (bkz. canManageProducts).

type priceChangeJSON struct {
	ID          string `json:"id"`
	ProductID   string `json:"product_id"`
	ProductName string `json:"product_name"`
	Unit        string `json:"unit"`
	Category    string `json:"category"`
	// Source: tedarikçi kodu ("ulas", "demirprofil"); elle düzenlemede null.
	Source *string `json:"source"`
	// Reason: supplier | markup | manual.
	Reason       string  `json:"reason"`
	Note         string  `json:"note"`
	OldPrice     float64 `json:"old_price"`
	NewPrice     float64 `json:"new_price"`
	ChangeAmount float64 `json:"change_amount"`
	// ChangePercent: eski fiyat 0 ise null.
	ChangePercent *float64 `json:"change_percent"`
	// ChangedAt RFC3339Nano (mikrosaniye). Bir özet olayının satırları için
	// olayın from/to'su kullanılır (bkz. priceChangeEventJSON).
	ChangedAt string `json:"changed_at"`
	// Kaynak fiyatları: products.manage yoksa ya da kaydedilmemişse null.
	OldSourcePrice *float64 `json:"old_source_price"`
	NewSourcePrice *float64 `json:"new_source_price"`
}

func nullableSource(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// queryInt: parametre yoksa 0 (varsayılan uygulanır); varsa 1 veya daha
// büyük bir tam sayı olmalı.
func queryInt(q url.Values, name string) (int, bool) {
	raw := q.Get(name)
	if raw == "" {
		return 0, true
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 {
		return 0, false
	}
	return n, true
}

func parsePriceChangeRange(q url.Values) (from, to time.Time, err error) {
	if from, err = service.ParsePriceChangeTime(q.Get("from"), false); err != nil {
		return
	}
	to, err = service.ParsePriceChangeTime(q.Get("to"), true)
	return
}

func (h *PriceSourceHandler) ListPriceChanges(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	from, to, err := parsePriceChangeRange(q)
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	page, ok := queryInt(q, "page")
	if !ok {
		httpjson.Error(w, http.StatusBadRequest, "page 1 veya daha büyük bir tam sayı olmalıdır")
		return
	}
	limit, ok := queryInt(q, "limit")
	if !ok {
		httpjson.Error(w, http.StatusBadRequest, "limit 1 veya daha büyük bir tam sayı olmalıdır")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	res, err := h.svc.ListPriceChanges(r.Context(), orgID, service.PriceChangeFilter{
		From: from, To: to,
		Direction: q.Get("direction"), Reason: q.Get("reason"), Source: q.Get("source"),
		Category: q.Get("category"), Query: q.Get("q"), Sort: q.Get("sort"),
		Page: page, Limit: limit,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	showSourcePrices := canManageProducts(r)
	out := make([]priceChangeJSON, len(res.Changes))
	for i, c := range res.Changes {
		out[i] = priceChangeJSON{
			ID:            c.ID,
			ProductID:     c.ProductID,
			ProductName:   c.ProductName,
			Unit:          c.Unit,
			Category:      c.Category,
			Source:        nullableSource(c.Source),
			Reason:        c.Reason,
			Note:          c.Note,
			OldPrice:      c.OldPrice.InexactFloat64(),
			NewPrice:      c.NewPrice.InexactFloat64(),
			ChangeAmount:  c.ChangeAmount.InexactFloat64(),
			ChangePercent: decimalPtrToFloat(c.ChangePercent),
			ChangedAt:     c.ChangedAt.Format(time.RFC3339Nano),
		}
		if showSourcePrices {
			out[i].OldSourcePrice = decimalPtrToFloat(c.OldSourcePrice)
			out[i].NewSourcePrice = decimalPtrToFloat(c.NewSourcePrice)
		}
	}
	httpjson.Write(w, http.StatusOK, map[string]any{
		"changes": out, "total": res.Total, "page": res.Page, "limit": res.Limit,
	})
}

type priceChangeMaxIncreaseJSON struct {
	ProductID     string  `json:"product_id"`
	ProductName   string  `json:"product_name"`
	ChangePercent float64 `json:"change_percent"`
}

type priceChangeEventJSON struct {
	// ChangedAt: senkron/kâr oranı olayında o transaction'ın anı; elle
	// düzenlemelerde İstanbul gününün 00:00'ı (gün başına tek olay).
	ChangedAt string `json:"changed_at"`
	// From/To: olayın satırlarını getirmek için liste ucuna AYNEN verilecek
	// from/to (RFC3339Nano, to dahil); ayrıca reason, source ve
	// direction=all verilmelidir. Senkron/kâr oranı olayında ikisi de
	// changed_at; elle düzenlemede o gün (özetin aralığıyla kırpılmış).
	From               string   `json:"from"`
	To                 string   `json:"to"`
	Source             *string  `json:"source"`
	Reason             string   `json:"reason"`
	ChangeCount        int      `json:"change_count"`
	Increased          int      `json:"increased"`
	Decreased          int      `json:"decreased"`
	AvgChangePercent   *float64 `json:"avg_change_percent"`
	MaxIncreasePercent *float64 `json:"max_increase_percent"`
}

type priceChangeSummaryJSON struct {
	IncreasedCount     int                         `json:"increased_count"`
	DecreasedCount     int                         `json:"decreased_count"`
	ProductsIncreased  int                         `json:"products_increased"`
	AvgIncreasePercent *float64                    `json:"avg_increase_percent"`
	MaxIncrease        *priceChangeMaxIncreaseJSON `json:"max_increase"`
	Events             []priceChangeEventJSON      `json:"events"`
}

func (h *PriceSourceHandler) PriceChangeSummary(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	from, to, err := parsePriceChangeRange(q)
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	sum, err := h.svc.PriceChangeSummary(r.Context(), orgID, service.PriceChangeSummaryFilter{
		From: from, To: to, Reason: q.Get("reason"), Source: q.Get("source"),
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := priceChangeSummaryJSON{
		IncreasedCount:     sum.IncreasedCount,
		DecreasedCount:     sum.DecreasedCount,
		ProductsIncreased:  sum.ProductsIncreased,
		AvgIncreasePercent: decimalPtrToFloat(sum.AvgIncreasePercent),
		Events:             make([]priceChangeEventJSON, len(sum.Events)),
	}
	if m := sum.MaxIncrease; m != nil {
		out.MaxIncrease = &priceChangeMaxIncreaseJSON{ProductID: m.ProductID, ProductName: m.ProductName, ChangePercent: m.ChangePercent.InexactFloat64()}
	}
	for i, e := range sum.Events {
		out.Events[i] = priceChangeEventJSON{
			ChangedAt:          e.ChangedAt.Format(time.RFC3339Nano),
			From:               e.RangeFrom.Format(time.RFC3339Nano),
			To:                 e.RangeTo.Format(time.RFC3339Nano),
			Source:             nullableSource(e.Source),
			Reason:             e.Reason,
			ChangeCount:        e.ChangeCount,
			Increased:          e.Increased,
			Decreased:          e.Decreased,
			AvgChangePercent:   decimalPtrToFloat(e.AvgChangePercent),
			MaxIncreasePercent: decimalPtrToFloat(e.MaxIncreasePercent),
		}
	}
	httpjson.Write(w, http.StatusOK, out)
}
