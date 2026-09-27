package service

import (
	"context"
	"errors"
	"fmt"
	"log"
	"time"
	_ "time/tzdata" // Europe/Istanbul, sunucuda zoneinfo olmasa da çözülsün.
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/pricesource"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// PriceFetcher, bir tedarikçinin güncel fiyat listesini getirir. Üretimde
// UlasHTTPFetcher (paylaşımlı + kısa önbellekli, bkz. price_source_fetcher.go);
// testler sahte bir fonksiyon verir -- servis ağa KENDİSİ hiç çıkmaz.
type PriceFetcher func(ctx context.Context) ([]pricesource.Item, error)

// İki anahtarlı (int4, int4) advisory lock uzayı -- offer_service'in tek
// anahtarlı pg_advisory_xact_lock(hashtext(..)) kilitleriyle ÇAKIŞMAZ
// (PostgreSQL bu iki anahtar uzayını ayrı tutar). Sınıf numaraları
// migration 0045'ten.
const (
	priceSyncLockClass      int32 = 450045 // (firma, kaynak) başına senkron/kâr oranı güncellemesi
	priceSchedulerLockClass int32 = 450046 // gece işi: tüm API instance'ları arasında tek çalıştırıcı
	priceSchedulerLockKey   int32 = 1

	maxCategoryMarkups = 500
	maxLastErrorRunes  = 300
)

// PriceSourceService, tedarikçi fiyat listesi senkronunu (BYZ ulas_scraper
// + "Ulaş Güncelle" + gece 00:05 işi) firma bazında yönetir: kâr oranı
// ayarları, elle/otomatik senkron, kâr oranı değişince yeniden fiyatlama.
//
// Ürün eşleştirme kuralları (BYZ'nin farksal senkronuyla aynı ilke):
//   - YALNIZCA firmanın source='ulas' ürünleri adaydır; elle eklenen ürünler
//     aynı ada sahip olsa bile ASLA değişmez.
//   - Liste (ad, birim, kategori) ile tekilleşir; satırlar (ad, birim) ile,
//     boşluk farkları yok sayılarak eşleşir. Ad+birim listede birden çok
//     kategoride geçiyorsa satır kendi kategorisindekine gider, aksi hâlde
//     anahtarı paylaşan TÜM satırlar güncellenir (BYZ'den gelen tekrarlar),
//     bkz. matchSourceRows.
//   - Eşleşen satırın id/ad/birim/açıklaması KORUNUR (teklif/reçete
//     bağlantıları kopmaz; açıklama kullanıcıya aittir).
//   - Listeden düşen ürünler SİLİNMEZ (BYZ siliyordu -- reçete bağlantıları
//     kopuyordu); yalnızca "eksik" sayılır.
type PriceSourceService struct {
	pool      *pgxpool.Pool
	q         *sqlc.Queries
	fetchUlas PriceFetcher
	// nightlyOrgFilter yalnızca testlerde dolar (export_test.go): gece işi
	// testleri geliştirme veritabanındaki gerçek firmalara dokunmasın.
	nightlyOrgFilter func(pgtype.UUID) bool
}

// NewPriceSourceService: fetchUlas nil ise senkron her zaman hata döner
// (yanlışlıkla gerçek siteye giden bir test/yapılandırma olmasın diye
// varsayılan bir HTTP fetcher'a DÜŞÜLMEZ -- main.go açıkça verir).
func NewPriceSourceService(pool *pgxpool.Pool, q *sqlc.Queries, fetchUlas PriceFetcher) *PriceSourceService {
	if fetchUlas == nil {
		fetchUlas = func(context.Context) ([]pricesource.Item, error) {
			return nil, errors.New("fiyat kaynağı indiricisi yapılandırılmamış")
		}
	}
	return &PriceSourceService{pool: pool, q: q, fetchUlas: fetchUlas}
}

// ---------- Okuma ----------

// GetPriceSources, firmanın tüm fiyat kaynaklarının (şimdilik yalnızca
// Ulaş) ayarlarını ve özetini döner. Satır yoksa varsayılanlar.
func (s *PriceSourceService) GetPriceSources(ctx context.Context, organizationID string) ([]domain.PriceSourceOverview, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	ov, err := s.overview(ctx, s.q, orgID, domain.PriceSourceUlas)
	if err != nil {
		return nil, err
	}
	return []domain.PriceSourceOverview{*ov}, nil
}

func (s *PriceSourceService) overview(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID, source string) (*domain.PriceSourceOverview, error) {
	ov := &domain.PriceSourceOverview{
		Source:        source,
		MarkupPercent: domain.DefaultPriceSourceMarkup,
		LastStatus:    domain.PriceSyncStatusNever,
	}
	row, err := q.GetOrganizationPriceSource(ctx, sqlc.GetOrganizationPriceSourceParams{OrganizationID: orgID, Source: source})
	switch {
	case err == nil:
		ov.MarkupPercent = repository.NumericToDecimal(row.MarkupPercent)
		ov.AutoSync = row.AutoSync
		ov.LastSyncedAt = nullableTimestamptzPtr(row.LastSyncedAt)
		ov.LastStatus = row.LastStatus
		ov.LastError = row.LastError
		ov.LastResult = domain.PriceSyncResult{
			Total: int(row.LastTotal), Created: int(row.LastCreated), Updated: int(row.LastUpdated),
			Unchanged: int(row.LastUnchanged), Missing: int(row.LastMissing),
		}
		if ov.LastSyncedAt != nil {
			ov.LastResult.SyncedAt = *ov.LastSyncedAt
		}
		ov.UpdatedAt = nullableTimestamptzPtr(row.UpdatedAt)
	case errors.Is(err, pgx.ErrNoRows):
	default:
		return nil, err
	}

	markups, err := q.ListPriceSourceCategoryMarkups(ctx, sqlc.ListPriceSourceCategoryMarkupsParams{OrganizationID: orgID, Source: source})
	if err != nil {
		return nil, err
	}
	ov.CategoryMarkups = make([]domain.PriceSourceCategoryMarkup, len(markups))
	for i, m := range markups {
		ov.CategoryMarkups[i] = domain.PriceSourceCategoryMarkup{Category: m.Category, MarkupPercent: repository.NumericToDecimal(m.MarkupPercent)}
	}

	cats, err := q.ListSourceProductCategories(ctx, sqlc.ListSourceProductCategoriesParams{OrganizationID: orgID, Source: source})
	if err != nil {
		return nil, err
	}
	ov.Categories = make([]domain.PriceSourceCategory, len(cats))
	for i, c := range cats {
		ov.Categories[i] = domain.PriceSourceCategory{Category: c.Category, ProductCount: int(c.ProductCount)}
	}

	sum, err := q.SummarizeSourceProducts(ctx, sqlc.SummarizeSourceProductsParams{OrganizationID: orgID, Source: source})
	if err != nil {
		return nil, err
	}
	ov.ProductCount = int(sum.ProductCount)
	ov.MissingCount = int(sum.MissingCount)
	return ov, nil
}

func nullableTimestamptzPtr(ts pgtype.Timestamptz) *time.Time {
	if !ts.Valid {
		return nil
	}
	t := ts.Time
	return &t
}

// ---------- Ayarlar + yeniden fiyatlama ----------

type PriceSourceSettingsInput struct {
	MarkupPercent   decimal.Decimal
	AutoSync        bool
	CategoryMarkups []domain.PriceSourceCategoryMarkup
}

type PriceSourceUpdateResult struct {
	Overview domain.PriceSourceOverview
	// Recomputed, yeni oranlarla birim fiyatı DEĞİŞEN ürün sayısı.
	Recomputed int
}

// maxMarkupExponent: JSON'dan gelen decimal her int32 üssü kabul eder
// ("1e-2000000000"). Karşılaştırma/yuvarlama iki sayıyı ortak üsse
// getirirken 10^|üs|'lük bir big.Int kurar -- tek bir PUT dakikalarca CPU
// ve GB'larca bellek harcatabilirdi. Bu yüzden üs, HERHANGİ bir
// aritmetikten önce sınırlanır ("15.000" gibi fazladan sıfırlar geçer).
const maxMarkupExponent = 20

func validateMarkup(d decimal.Decimal, label string) error {
	if exp := d.Exponent(); exp < -maxMarkupExponent || exp > maxMarkupExponent {
		return fmt.Errorf("%s 0 ile 1000 arasında, en fazla iki ondalıklı bir sayı olmalıdır", label)
	}
	if d.IsNegative() || d.GreaterThan(domain.MaxPriceSourceMarkup) {
		return fmt.Errorf("%s 0 ile 1000 arasında olmalıdır", label)
	}
	if !d.Equal(d.Round(2)) {
		return fmt.Errorf("%s en fazla iki ondalık basamak içerebilir", label)
	}
	return nil
}

// normalize, girdiyi doğrular ve kategori adlarını senkronun yazdığı
// biçime (boşluklar tek boşluk, kırpılmış) getirir.
func (in PriceSourceSettingsInput) normalize() (PriceSourceSettingsInput, error) {
	if err := validateMarkup(in.MarkupPercent, "kâr oranı"); err != nil {
		return in, err
	}
	if len(in.CategoryMarkups) > maxCategoryMarkups {
		return in, fmt.Errorf("en fazla %d kategori oranı tanımlanabilir", maxCategoryMarkups)
	}
	out := PriceSourceSettingsInput{MarkupPercent: in.MarkupPercent, AutoSync: in.AutoSync}
	seen := map[string]bool{}
	for _, cm := range in.CategoryMarkups {
		cat := pricesource.CollapseSpaces(cm.Category)
		if cat == "" {
			return in, errors.New("kategori adı boş olamaz")
		}
		if utf8.RuneCountInString(cat) > pricesource.MaxCategoryLen {
			return in, fmt.Errorf("kategori adı en fazla %d karakter olabilir", pricesource.MaxCategoryLen)
		}
		if seen[cat] {
			return in, fmt.Errorf("%q kategorisi birden fazla kez verildi", cat)
		}
		seen[cat] = true
		if err := validateMarkup(cm.MarkupPercent, fmt.Sprintf("%q kategorisinin kâr oranı", cat)); err != nil {
			return in, err
		}
		out.CategoryMarkups = append(out.CategoryMarkups, domain.PriceSourceCategoryMarkup{Category: cat, MarkupPercent: cm.MarkupPercent})
	}
	return out, nil
}

// UpdatePriceSource, kâr oranı/otomatik senkron/kategori oranlarını
// kaydeder (kategori oranları TAMAMEN değiştirilir) ve AYNI transaction'da
// firmanın kaynak fiyatı bilinen ürünlerini yeni oranlarla yeniden
// fiyatlar -- fiyatı gerçekten değişen her ürün için fiyat geçmişi yazılır.
func (s *PriceSourceService) UpdatePriceSource(ctx context.Context, organizationID, source, actorID string, in PriceSourceSettingsInput) (*PriceSourceUpdateResult, error) {
	if !domain.ValidPriceSource(source) {
		return nil, domain.ErrUnknownPriceSource
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in, err = in.normalize()
	if err != nil {
		return nil, err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Senkronla AYNI kilit (bekleyerek): eşzamanlı bir senkron eski oranları
	// okuyup bu güncellemenin fiyatlarını ezemesin.
	if err := txq.PriceSourceXactLock(ctx, sqlc.PriceSourceXactLockParams{
		LockClass: priceSyncLockClass, LockKey: priceSyncLockKey(orgID, source),
	}); err != nil {
		return nil, err
	}

	if _, err := txq.UpsertOrganizationPriceSourceSettings(ctx, sqlc.UpsertOrganizationPriceSourceSettingsParams{
		OrganizationID: orgID,
		Source:         source,
		MarkupPercent:  repository.DecimalToNumeric(in.MarkupPercent),
		AutoSync:       in.AutoSync,
		UpdatedBy:      actorUUID(actorID),
	}); err != nil {
		return nil, err
	}
	if err := txq.DeletePriceSourceCategoryMarkups(ctx, sqlc.DeletePriceSourceCategoryMarkupsParams{OrganizationID: orgID, Source: source}); err != nil {
		return nil, err
	}
	if len(in.CategoryMarkups) > 0 {
		params := sqlc.InsertPriceSourceCategoryMarkupsParams{OrganizationID: orgID, Source: source}
		for _, cm := range in.CategoryMarkups {
			params.Categories = append(params.Categories, cm.Category)
			params.MarkupPercents = append(params.MarkupPercents, repository.DecimalToNumeric(cm.MarkupPercent))
		}
		if err := txq.InsertPriceSourceCategoryMarkups(ctx, params); err != nil {
			return nil, err
		}
	}

	rates := newMarkupRates(in.MarkupPercent, in.CategoryMarkups)
	rows, err := txq.ListSourceProductsForUpdate(ctx, sqlc.ListSourceProductsForUpdateParams{OrganizationID: orgID, Source: source})
	if err != nil {
		return nil, err
	}
	var changes priceChanges
	for _, r := range rows {
		if !r.SourcePrice.Valid {
			continue // BYZ'den aktarılmış, henüz hiç senkronlanmamış: kaynak fiyatı bilinmiyor.
		}
		newPrice := domain.ApplyMarkup(repository.NumericToDecimal(r.SourcePrice), rates.forCategory(r.Category))
		if old := repository.NumericToDecimal(r.UnitPrice); !old.Equal(newPrice) {
			changes.add(r.ID, old, newPrice)
		}
	}
	if len(changes.ids) > 0 {
		if _, err := txq.UpdateProductUnitPrices(ctx, sqlc.UpdateProductUnitPricesParams{
			OrganizationID: orgID, Source: source, Ids: changes.ids, UnitPrices: changes.newPrices,
		}); err != nil {
			return nil, err
		}
		if err := changes.writeHistory(ctx, txq, domain.PriceHistoryNoteUlasMarkup); err != nil {
			return nil, err
		}
	}

	if err := logOrgEvent(ctx, txq, orgID, domain.OrgEventPriceSourceUpdated, actorUUID(actorID), map[string]any{
		"source":           source,
		"markup_percent":   in.MarkupPercent.String(),
		"auto_sync":        in.AutoSync,
		"category_markups": len(in.CategoryMarkups),
		"recomputed":       len(changes.ids),
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	ov, err := s.overview(ctx, s.q, orgID, source)
	if err != nil {
		return nil, err
	}
	return &PriceSourceUpdateResult{Overview: *ov, Recomputed: len(changes.ids)}, nil
}

// ---------- Senkron ----------

// SyncUlas, Ulaş listesini indirir ve firmanın kataloğuna uygular ("Ulaş
// Güncelle" butonu). İndirme/ayrıştırma başarısızsa üründe HİÇBİR şey
// değişmez; hata organization_price_sources'a yazılır ve
// domain.ErrPriceSourceFetch döner.
func (s *PriceSourceService) SyncUlas(ctx context.Context, organizationID, actorID string) (*domain.PriceSyncResult, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	items, err := s.fetch(ctx)
	if err != nil {
		// İstek iptal edildiyse (istemci ayrıldı/sunucu kapanıyor) bu bir
		// tedarikçi hatası değildir -- "failed" diye kaydedilmez. last_error'a
		// yalnızca sabit metin gider (products.read ile herkes okur); ham
		// hata yalnızca loga.
		if ctx.Err() == nil {
			s.recordFailure(ctx, orgID, domain.PriceSourceUlas, pricesource.PublicErrorMessage(err))
		}
		log.Printf("fiyat senkronu: firma %s için Ulaş listesi alınamadı: %v", organizationID, err)
		return nil, fmt.Errorf("%w: %v", domain.ErrPriceSourceFetch, err)
	}
	return s.applyAndRecord(ctx, orgID, actorID, items)
}

// fetch, listeyi indirir ve ortak temizlikten geçirir; boş liste HATADIR
// (bozuk/boş bir sayfa "her şey listeden düştü" diye yorumlanmamalı).
func (s *PriceSourceService) fetch(ctx context.Context) ([]pricesource.Item, error) {
	items, err := s.fetchUlas(ctx)
	if err != nil {
		return nil, err
	}
	items = pricesource.Normalize(items)
	if len(items) == 0 {
		return nil, pricesource.ErrNoItems
	}
	return items, nil
}

// applyAndRecord, applyUlas'ı çalıştırır; meşgul (409) DIŞINDAKİ bir
// uygulama hatasını da "failed" olarak kaydeder (iç ayrıntı sızdırmadan).
func (s *PriceSourceService) applyAndRecord(ctx context.Context, orgID pgtype.UUID, actorID string, items []pricesource.Item) (*domain.PriceSyncResult, error) {
	res, err := s.applyUlas(ctx, orgID, actorID, items)
	if err != nil && !errors.Is(err, domain.ErrPriceSyncBusy) && ctx.Err() == nil {
		s.recordFailure(ctx, orgID, domain.PriceSourceUlas, "fiyat listesi kataloğa uygulanamadı (sunucu hatası)")
	}
	return res, err
}

// applyUlas, verilen (temizlenmiş) listeyi TEK transaction'da firmanın
// kataloğuna uygular. Aynı firma+kaynak için ikinci bir eşzamanlı çağrı
// beklemez, domain.ErrPriceSyncBusy döner.
func (s *PriceSourceService) applyUlas(ctx context.Context, orgID pgtype.UUID, actorID string, items []pricesource.Item) (*domain.PriceSyncResult, error) {
	const source = domain.PriceSourceUlas
	items = pricesource.Normalize(items)
	if len(items) == 0 {
		return nil, fmt.Errorf("%w: %v", domain.ErrPriceSourceFetch, pricesource.ErrNoItems)
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	locked, err := txq.TryPriceSourceXactLock(ctx, sqlc.TryPriceSourceXactLockParams{
		LockClass: priceSyncLockClass, LockKey: priceSyncLockKey(orgID, source),
	})
	if err != nil {
		return nil, err
	}
	if !locked {
		return nil, domain.ErrPriceSyncBusy
	}

	rates, err := loadMarkupRates(ctx, txq, orgID, source)
	if err != nil {
		return nil, err
	}
	rows, err := txq.ListSourceProductsForUpdate(ctx, sqlc.ListSourceProductsForUpdateParams{OrganizationID: orgID, Source: source})
	if err != nil {
		return nil, err
	}
	matched := matchSourceRows(items, rows)

	res := &domain.PriceSyncResult{Total: len(items)}
	upd := sqlc.UpdateSourceProductsParams{OrganizationID: orgID, Source: source}
	ins := sqlc.InsertSourceProductsParams{OrganizationID: orgID, Source: source}
	var history priceChanges
	for i, it := range items {
		srcPrice := repository.DecimalToNumeric(it.Price)
		unitPrice := domain.ApplyMarkup(it.Price, rates.forCategory(it.Category))
		matches := matched[i]
		if len(matches) == 0 {
			ins.Names = append(ins.Names, it.Name)
			ins.NormalizedNames = append(ins.NormalizedNames, domain.NormalizeName(it.Name))
			ins.Units = append(ins.Units, it.Unit)
			ins.UnitPrices = append(ins.UnitPrices, repository.DecimalToNumeric(unitPrice))
			ins.SourcePrices = append(ins.SourcePrices, srcPrice)
			ins.Categories = append(ins.Categories, it.Category)
			res.Created++
			continue
		}
		changed := false
		for _, m := range matches {
			oldUnit := repository.NumericToDecimal(m.UnitPrice)
			if !oldUnit.Equal(unitPrice) {
				history.add(m.ID, oldUnit, unitPrice)
				changed = true
			}
			if !m.SourcePrice.Valid || !repository.NumericToDecimal(m.SourcePrice).Equal(it.Price) || m.Category != it.Category {
				changed = true
			}
			// Değişmeyen satırlar da yazılır: source_synced_at "listede
			// görüldü" damgasıdır (eksik ürün hesabı buna dayanır).
			upd.Ids = append(upd.Ids, m.ID)
			upd.UnitPrices = append(upd.UnitPrices, repository.DecimalToNumeric(unitPrice))
			upd.SourcePrices = append(upd.SourcePrices, srcPrice)
			upd.Categories = append(upd.Categories, it.Category)
		}
		if changed {
			res.Updated++
		} else {
			res.Unchanged++
		}
	}

	if len(upd.Ids) > 0 {
		if _, err := txq.UpdateSourceProducts(ctx, upd); err != nil {
			return nil, err
		}
	}
	if len(ins.Names) > 0 {
		if _, err := txq.InsertSourceProducts(ctx, ins); err != nil {
			return nil, err
		}
	}
	if err := history.writeHistory(ctx, txq, domain.PriceHistoryNoteUlasSync); err != nil {
		return nil, err
	}

	missing, err := txq.CountSourceProductsNotSyncedNow(ctx, sqlc.CountSourceProductsNotSyncedNowParams{OrganizationID: orgID, Source: source})
	if err != nil {
		return nil, err
	}
	res.Missing = int(missing)

	syncedAt, err := txq.RecordPriceSourceSyncSuccess(ctx, sqlc.RecordPriceSourceSyncSuccessParams{
		OrganizationID: orgID, Source: source,
		Total: int32(res.Total), Created: int32(res.Created), Updated: int32(res.Updated),
		Unchanged: int32(res.Unchanged), Missing: int32(res.Missing),
	})
	if err != nil {
		return nil, err
	}
	res.SyncedAt = syncedAt.Time

	if err := logOrgEvent(ctx, txq, orgID, domain.OrgEventPriceSourceSynced, actorUUID(actorID), map[string]any{
		"source": source, "total": res.Total, "created": res.Created, "updated": res.Updated,
		"unchanged": res.Unchanged, "missing": res.Missing,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return res, nil
}

type sourceProductRow = sqlc.ListSourceProductsForUpdateRow

// matchSourceRows, listedeki her ürüne (items[i]) firmanın mevcut kaynak
// satırlarını atar; sonuç items ile aynı sıradadır ve her satır EN FAZLA
// bir ürüne gider. Anahtar (ad, birim), boşluk farkları yok sayılarak:
//
//   - Ad+birim listede TEK kategoride geçiyorsa, o anahtarı paylaşan TÜM
//     satırlar ona gider (BYZ'den gelen tekrarlar; Ulaş kategoriyi yeniden
//     adlandırsa bile eşleşme kopmaz).
//   - Birden çok kategoride geçiyorsa (aynı ürün iki kategoride listelenmiş
//     ya da aynı adlı FARKLI ürünler -- "Gazbeton Yapıştırıcısı" FİXA 130 TL
//     / GAZBETON 120 TL), satır kendi kategorisindeki ürüne gider: senkronlanmış
//     satırda products.category, hiç senkronlanmamış (BYZ'den aktarılmış)
//     satırda ayrıca açıklama (BYZ, Ulaş kategorisini oraya yazıyordu).
//     Kategorisi tutmayan satırlar sırayla henüz satırı olmayan ürünlere
//     (kategori yeniden adlandırılmış olabilir), o da yoksa ilk ürüne gider.
func matchSourceRows(items []pricesource.Item, rows []sourceProductRow) [][]sourceProductRow {
	itemsByKey := make(map[[2]string][]int, len(items))
	for i, it := range items {
		key := [2]string{it.Name, it.Unit}
		itemsByKey[key] = append(itemsByKey[key], i)
	}
	out := make([][]sourceProductRow, len(items))
	leftovers := map[[2]string][]sourceProductRow{} // çok kategorili anahtarda kategorisi tutmayanlar
	for _, r := range rows {
		key := [2]string{pricesource.CollapseSpaces(r.Name), pricesource.CollapseSpaces(r.Unit)}
		idxs := itemsByKey[key]
		switch {
		case len(idxs) == 0:
			continue // listede yok -> eksik
		case len(idxs) == 1:
			out[idxs[0]] = append(out[idxs[0]], r)
			continue
		}
		placed := false
		for _, i := range idxs {
			if rowInSourceCategory(r, items[i].Category) {
				out[i] = append(out[i], r)
				placed = true
				break
			}
		}
		if !placed {
			leftovers[key] = append(leftovers[key], r)
		}
	}
	// Anahtarlar birbirinden bağımsız: map sırası sonucu değiştirmez.
	for key, rs := range leftovers {
		idxs := itemsByKey[key]
		for _, r := range rs {
			target := idxs[0]
			for _, i := range idxs {
				if len(out[i]) == 0 {
					target = i
					break
				}
			}
			out[target] = append(out[target], r)
		}
	}
	return out
}

func rowInSourceCategory(r sourceProductRow, category string) bool {
	if pricesource.CollapseSpaces(r.Category) == category {
		return true
	}
	return !r.SourceSyncedAt.Valid && pricesource.CollapseSpaces(r.Description) == category
}

// recordFailure, başarısız denemeyi AYRI bir ifadeyle (geri alınan bir
// transaction'ın parçası olmadan) kaydeder. İstek iptal edilmiş olsa bile
// yazılabilsin diye iptalden bağımsız, kısa süreli bir context kullanır.
// message products.read sahibi herkese döner: yalnızca SABİT metin verilir
// (pricesource.PublicErrorMessage), ham Go hatası asla.
func (s *PriceSourceService) recordFailure(ctx context.Context, orgID pgtype.UUID, source, message string) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	if err := s.q.RecordPriceSourceSyncFailure(ctx, sqlc.RecordPriceSourceSyncFailureParams{
		OrganizationID: orgID, Source: source, LastError: shortError(message),
	}); err != nil {
		log.Printf("fiyat senkronu: firma %s için hata durumu kaydedilemedi: %v", orgID.String(), err)
	}
}

func shortError(msg string) string {
	msg = pricesource.CollapseSpaces(msg)
	if utf8.RuneCountInString(msg) > maxLastErrorRunes {
		msg = string([]rune(msg)[:maxLastErrorRunes-1]) + "…"
	}
	return msg
}

func priceSyncLockKey(orgID pgtype.UUID, source string) string {
	return orgID.String() + ":" + source
}

// PriceSyncAdvisoryLock, (firma, kaynak) senkron kilidinin anahtarlarını
// döner: SELECT pg_advisory_xact_lock($1, hashtext($2)). Tanı ve testler
// için -- servis kendi içinde aynı değerleri kullanır.
func PriceSyncAdvisoryLock(organizationID, source string) (classID int32, key string) {
	return priceSyncLockClass, organizationID + ":" + source
}

// markupRates: kategori oranı varsa o, yoksa varsayılan oran.
type markupRates struct {
	defaultRate decimal.Decimal
	byCategory  map[string]decimal.Decimal
}

func newMarkupRates(def decimal.Decimal, cms []domain.PriceSourceCategoryMarkup) markupRates {
	r := markupRates{defaultRate: def, byCategory: make(map[string]decimal.Decimal, len(cms))}
	for _, cm := range cms {
		r.byCategory[cm.Category] = cm.MarkupPercent
	}
	return r
}

func (r markupRates) forCategory(category string) decimal.Decimal {
	if rate, ok := r.byCategory[category]; ok {
		return rate
	}
	return r.defaultRate
}

func loadMarkupRates(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID, source string) (markupRates, error) {
	def := domain.DefaultPriceSourceMarkup
	row, err := q.GetOrganizationPriceSource(ctx, sqlc.GetOrganizationPriceSourceParams{OrganizationID: orgID, Source: source})
	switch {
	case err == nil:
		def = repository.NumericToDecimal(row.MarkupPercent)
	case !errors.Is(err, pgx.ErrNoRows):
		return markupRates{}, err
	}
	rows, err := q.ListPriceSourceCategoryMarkups(ctx, sqlc.ListPriceSourceCategoryMarkupsParams{OrganizationID: orgID, Source: source})
	if err != nil {
		return markupRates{}, err
	}
	cms := make([]domain.PriceSourceCategoryMarkup, len(rows))
	for i, m := range rows {
		cms[i] = domain.PriceSourceCategoryMarkup{Category: m.Category, MarkupPercent: repository.NumericToDecimal(m.MarkupPercent)}
	}
	return newMarkupRates(def, cms), nil
}

// priceChanges, toplu fiyat geçmişi yazımı için (ürün, eski, yeni) dizileri.
type priceChanges struct {
	ids       []pgtype.UUID
	oldPrices []pgtype.Numeric
	newPrices []pgtype.Numeric
}

func (c *priceChanges) add(id pgtype.UUID, oldPrice, newPrice decimal.Decimal) {
	c.ids = append(c.ids, id)
	c.oldPrices = append(c.oldPrices, repository.DecimalToNumeric(oldPrice))
	c.newPrices = append(c.newPrices, repository.DecimalToNumeric(newPrice))
}

func (c *priceChanges) writeHistory(ctx context.Context, q *sqlc.Queries, note string) error {
	if len(c.ids) == 0 {
		return nil
	}
	return q.InsertPriceHistoryBatch(ctx, sqlc.InsertPriceHistoryBatchParams{
		Note: note, ProductIds: c.ids, OldPrices: c.oldPrices, NewPrices: c.newPrices,
	})
}

// ---------- Gece işi ----------

// Gece senkronunun saati: her gün 00:05, Europe/Istanbul (BYZ ile aynı).
const (
	nightlySyncHour   = 0
	nightlySyncMinute = 5
	// Uzun uykular parçalanır: sistem saati değişirse/makine uyursa bile en
	// geç bu kadar sonra "vakit geldi mi" tekrar kontrol edilir.
	schedulerMaxSleep = 15 * time.Minute
)

var istanbulLocation = func() *time.Location {
	if loc, err := time.LoadLocation("Europe/Istanbul"); err == nil {
		return loc
	}
	return time.FixedZone("TRT", 3*60*60) // 2016'dan beri kalıcı UTC+3
}()

// NextPriceSyncRun, now'dan KESİNLİKLE sonraki ilk 00:05 (Europe/Istanbul)
// anını döner. Saf fonksiyon: takvim günü üzerinden time.Date ile kurulur,
// yaz saati geçişi olsa bile gün atlamaz/ikiye katlanmaz.
func NextPriceSyncRun(now time.Time) time.Time {
	t := now.In(istanbulLocation)
	next := time.Date(t.Year(), t.Month(), t.Day(), nightlySyncHour, nightlySyncMinute, 0, 0, istanbulLocation)
	if !next.After(t) {
		next = time.Date(t.Year(), t.Month(), t.Day()+1, nightlySyncHour, nightlySyncMinute, 0, 0, istanbulLocation)
	}
	return next
}

// PriceSyncRunReport, gece işinin tek bir çalıştırmasının özeti.
type PriceSyncRunReport struct {
	// SkippedLocked: başka bir API instance'ı kilidi tutuyordu -- bu
	// instance hiçbir şey yapmadı.
	SkippedLocked bool
	Organizations int
	Succeeded     int
	Failed        int
}

// RunNightly, her gece 00:05'te (Europe/Istanbul) SyncAutoOrganizations'ı
// çalıştıran zamanlayıcıdır; ctx iptal edilene kadar bloklar. Hiçbir hata
// (panik dahil) süreci düşürmez -- loglanır, bir sonraki geceye geçilir.
func (s *PriceSourceService) RunNightly(ctx context.Context) {
	next := NextPriceSyncRun(time.Now())
	log.Printf("fiyat senkronu zamanlayıcısı başladı; ilk çalışma %s", next.Format(time.RFC3339))
	for {
		wait := time.Until(next)
		if wait <= 0 {
			s.runNightlyPass(ctx, next)
			if ctx.Err() != nil {
				return
			}
			next = NextPriceSyncRun(time.Now())
			log.Printf("fiyat senkronu: sonraki çalışma %s", next.Format(time.RFC3339))
			continue
		}
		timer := time.NewTimer(min(wait, schedulerMaxSleep))
		select {
		case <-ctx.Done():
			timer.Stop()
			log.Printf("fiyat senkronu zamanlayıcısı durdu")
			return
		case <-timer.C:
		}
	}
}

func (s *PriceSourceService) runNightlyPass(ctx context.Context, scheduledAt time.Time) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("fiyat senkronu: gece işi panikledi (süreç devam ediyor): %v", r)
		}
	}()
	report, err := s.SyncAutoOrganizations(ctx, scheduledAt)
	if err != nil {
		log.Printf("fiyat senkronu: gece işi başarısız: %v", err)
		return
	}
	if report.SkippedLocked {
		log.Printf("fiyat senkronu: başka bir instance çalıştırıyor, bu instance atladı")
		return
	}
	log.Printf("fiyat senkronu: gece işi bitti -- %d firma, %d başarılı, %d başarısız",
		report.Organizations, report.Succeeded, report.Failed)
}

// SyncAutoOrganizations, gece işinin TEK bir çalıştırmasıdır: otomatik
// senkronu açık, active/trial ve silinmemiş firmaları bulur; en az bir
// tane varsa Ulaş'ı BİR KEZ indirir ve her birine uygular (işlem yapan
// kullanıcı yok -- NULL). syncedBefore: bu andan sonra zaten başarıyla
// senkronlanmış firmalar atlanır (aynı geceyi başka bir instance az önce
// işlediyse tekrar indirilmez).
//
// Birden çok API instance'ına karşı: ayrılmış bir bağlantıda oturum
// seviyesinde pg_try_advisory_lock alınır; alınamazsa hiçbir şey yapılmaz.
func (s *PriceSourceService) SyncAutoOrganizations(ctx context.Context, syncedBefore time.Time) (PriceSyncRunReport, error) {
	var report PriceSyncRunReport
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return report, err
	}
	var locked bool
	if err := conn.QueryRow(ctx, "SELECT pg_try_advisory_lock($1, $2)", priceSchedulerLockClass, priceSchedulerLockKey).Scan(&locked); err != nil {
		conn.Release()
		return report, err
	}
	if !locked {
		conn.Release()
		report.SkippedLocked = true
		return report, nil
	}
	defer func() {
		// Oturum kilidi bu bağlantıya aittir: bırakılamazsa bağlantı havuza
		// kilitli dönmesin, kapatılsın (kilit bağlantıyla birlikte düşer).
		unlockCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if _, err := conn.Exec(unlockCtx, "SELECT pg_advisory_unlock($1, $2)", priceSchedulerLockClass, priceSchedulerLockKey); err != nil {
			log.Printf("fiyat senkronu: zamanlayıcı kilidi bırakılamadı, bağlantı kapatılıyor: %v", err)
			_ = conn.Hijack().Close(unlockCtx)
			return
		}
		conn.Release()
	}()

	orgs, err := s.q.ListAutoSyncOrganizations(ctx, sqlc.ListAutoSyncOrganizationsParams{
		Source: domain.PriceSourceUlas, SyncedBefore: pgTimestamptz(syncedBefore),
	})
	if err != nil {
		return report, err
	}
	if s.nightlyOrgFilter != nil {
		kept := orgs[:0]
		for _, id := range orgs {
			if s.nightlyOrgFilter(id) {
				kept = append(kept, id)
			}
		}
		orgs = kept
	}
	report.Organizations = len(orgs)
	if len(orgs) == 0 {
		return report, nil
	}

	items, fetchErr := s.fetch(ctx)
	if fetchErr != nil {
		if ctx.Err() != nil {
			return report, ctx.Err() // kapanış: firmalara "failed" yazılmaz
		}
		log.Printf("fiyat senkronu: Ulaş listesi alınamadı (%d firma etkilendi): %v", len(orgs), fetchErr)
		for _, orgID := range orgs {
			s.recordFailure(ctx, orgID, domain.PriceSourceUlas, pricesource.PublicErrorMessage(fetchErr))
		}
		report.Failed = len(orgs)
		return report, nil
	}

	for _, orgID := range orgs {
		if ctx.Err() != nil {
			log.Printf("fiyat senkronu: iptal edildi, kalan firmalar atlandı")
			break
		}
		res, err := s.applyAndRecord(ctx, orgID, "", items)
		if err != nil {
			report.Failed++
			log.Printf("fiyat senkronu: firma %s: %v", orgID.String(), err)
			continue
		}
		report.Succeeded++
		log.Printf("fiyat senkronu: firma %s: %d ürün (%d yeni, %d güncellendi, %d aynı, %d listede yok)",
			orgID.String(), res.Total, res.Created, res.Updated, res.Unchanged, res.Missing)
	}
	return report, nil
}
