package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/pricesource"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Tedarikçi sitesi çöktüğünde son bilinen listeyle devam (sahada 2026-10:
// Ulaş'ın flist.asp sayfası HTTP 500 dönüyordu, hiç başarılı senkron
// yapmamış firmanın kataloğu boş kalıyordu).
//
// Sıra: canlı site -> (Ulaş için) Wayback Machine'deki son kopya -> bu
// sunucuda saklanan son başarılı liste. Canlı ya da arşivden alınan her
// başarılı liste price_source_snapshots'a yazılır (yalnızca daha yeniyse).
// Yedeklerden VERİ tarihi (AsOf) en yeni olan döner; firmanın elindeki
// fiyatlardan yeni değilse PriceSourceService onu UYGULAMAZ (bkz.
// staleFallbackError) -- arşivdeki Haziran listesi, canlıdan alınmış
// Eylül fiyatlarını geri almasın.

// PriceSnapshotStore, kaynak başına son başarılı listenin kalıcı deposu.
type PriceSnapshotStore interface {
	// Load: saklı liste yoksa ok=false (hata değil).
	Load(ctx context.Context, source string) (list pricesource.List, ok bool, err error)
	Save(ctx context.Context, source string, list pricesource.List) error
}

// snapshotItem: jsonb'deki tek ürün (pricesource.Item'ın kalıcı biçimi --
// fiyat kayıpsız olsun diye metin).
type snapshotItem struct {
	Name        string `json:"name"`
	Unit        string `json:"unit"`
	Category    string `json:"category"`
	Description string `json:"description,omitempty"`
	Price       string `json:"price"`
}

type dbPriceSnapshotStore struct{ q *sqlc.Queries }

// NewDBPriceSnapshotStore, price_source_snapshots tablosunu kullanan depo.
func NewDBPriceSnapshotStore(q *sqlc.Queries) PriceSnapshotStore { return &dbPriceSnapshotStore{q: q} }

func (s *dbPriceSnapshotStore) Load(ctx context.Context, source string) (pricesource.List, bool, error) {
	row, err := s.q.GetPriceSourceSnapshot(ctx, source)
	if errors.Is(err, pgx.ErrNoRows) {
		return pricesource.List{}, false, nil
	}
	if err != nil {
		return pricesource.List{}, false, err
	}
	var raw []snapshotItem
	if err := json.Unmarshal(row.Items, &raw); err != nil {
		return pricesource.List{}, false, fmt.Errorf("saklı liste okunamadı: %w", err)
	}
	items := make([]pricesource.Item, 0, len(raw))
	for _, it := range raw {
		price, err := decimal.NewFromString(it.Price)
		if err != nil {
			continue
		}
		items = append(items, pricesource.Item{
			Name: it.Name, Unit: it.Unit, Category: it.Category, Description: it.Description, Price: price,
		})
	}
	if len(items) == 0 {
		return pricesource.List{}, false, nil
	}
	return pricesource.List{
		Items:  items,
		Label:  snapshotLabel(row.Label, row.AsOf.Time),
		Origin: pricesource.OriginSnapshot,
		AsOf:   row.AsOf.Time,
	}, true, nil
}

func (s *dbPriceSnapshotStore) Save(ctx context.Context, source string, list pricesource.List) error {
	if len(list.Items) == 0 || list.Origin == pricesource.OriginSnapshot {
		return nil // saklı kopyanın kendisi yeniden yazılmaz
	}
	raw := make([]snapshotItem, len(list.Items))
	for i, it := range list.Items {
		raw[i] = snapshotItem{
			Name: it.Name, Unit: it.Unit, Category: it.Category, Description: it.Description, Price: it.Price.String(),
		}
	}
	body, err := json.Marshal(raw)
	if err != nil {
		return err
	}
	origin := "live"
	if list.Origin == pricesource.OriginArchive {
		origin = "archive"
	}
	return s.q.UpsertPriceSourceSnapshot(ctx, sqlc.UpsertPriceSourceSnapshotParams{
		Source:    source,
		Origin:    origin,
		AsOf:      pgtype.Timestamptz{Time: list.AsOf, Valid: true},
		Label:     list.Label,
		Items:     body,
		ItemCount: int32(len(raw)),
	})
}

// snapshotLabel: saklı listenin dönemi + nereden geldiği belli olsun
// ("Eylül 2026 · kayıtlı kopya (06.10.2026)").
func snapshotLabel(label string, asOf time.Time) string {
	suffix := "kayıtlı kopya (" + asOf.In(istanbul()).Format("02.01.2006") + ")"
	if label == "" {
		return "Son " + suffix
	}
	return label + " · " + suffix
}

// priceFallbackFetcher: canlı -> arşiv (varsa) -> saklı liste. Canlı
// başarılıysa (AsOf = şimdi) saklanır ve döner. Canlı başarısızsa
// yedeklerden VERİ tarihi en yeni olan döner, uyarısında canlının neden
// alınamadığı yazar; hiçbir yedek yoksa canlının hatası döner (davranış
// eskisiyle aynı: firmaya "failed" yazılır, ürünler değişmez).
func priceFallbackFetcher(source string, live, archive PriceFetcher, store PriceSnapshotStore, now func() time.Time) PriceFetcher {
	return func(ctx context.Context) (pricesource.List, error) {
		list, liveErr := live(ctx)
		if liveErr == nil {
			if list.AsOf.IsZero() {
				list.AsOf = now()
			}
			saveSnapshot(ctx, store, source, list)
			return list, nil
		}
		if ctx.Err() != nil {
			return pricesource.List{}, liveErr
		}

		var best *pricesource.List
		consider := func(l pricesource.List) {
			if len(l.Items) == 0 || l.AsOf.IsZero() {
				return
			}
			if best == nil || l.AsOf.After(best.AsOf) {
				c := l
				best = &c
			}
		}
		if archive != nil {
			a, err := archive(ctx)
			if err == nil {
				consider(a)
				// Saklı listeden yeniyse kalıcılaştır (Save yalnızca daha
				// yeniyi yazar).
				saveSnapshot(ctx, store, source, a)
			} else {
				log.Printf("fiyat senkronu: %s arşiv kopyası da alınamadı: %v", source, err)
			}
		}
		if store != nil {
			if saved, ok, err := store.Load(ctx, source); err != nil {
				log.Printf("fiyat senkronu: %s saklı listesi okunamadı: %v", source, err)
			} else if ok {
				consider(saved)
			}
		}
		if best == nil {
			return pricesource.List{}, liveErr
		}
		best.Warnings = append(best.Warnings, fmt.Sprintf("canlı liste alınamadı (%v); %s kullanıldı", liveErr, best.Label))
		best.LiveErr = liveErr
		return *best, nil
	}
}

func saveSnapshot(ctx context.Context, store PriceSnapshotStore, source string, list pricesource.List) {
	if store == nil {
		return
	}
	// İstek iptal edilse de kayıt tamamlansın; kısa süreli.
	sctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	l := list
	l.Items = pricesource.Normalize(list.Items)
	if err := store.Save(sctx, source, l); err != nil {
		log.Printf("fiyat senkronu: %s listesi saklanamadı: %v", source, err)
	}
}
