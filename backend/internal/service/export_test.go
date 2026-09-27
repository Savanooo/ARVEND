package service

import (
	"time"

	"github.com/jackc/pgx/v5/pgtype"
)

// SetNightlyOrgFilterForTest, gece işini (SyncAutoOrganizations) yalnızca
// verilen firmalarla sınırlar -- geliştirme veritabanında otomatik senkronu
// açık GERÇEK bir firma varsa testin sahte fiyat listesi ona uygulanmasın.
// Yalnızca bu paketin testlerinde derlenir.
func SetNightlyOrgFilterForTest(s *PriceSourceService, organizationIDs ...string) {
	allowed := make(map[string]bool, len(organizationIDs))
	for _, id := range organizationIDs {
		allowed[id] = true
	}
	s.nightlyOrgFilter = func(id pgtype.UUID) bool { return allowed[id.String()] }
}

// NewSharedFetcherForTest, paylaşımlı/önbellekli fetcher'ı (bkz.
// UlasHTTPFetcher) sahte bir saatle kurar.
func NewSharedFetcherForTest(fetch PriceFetcher, okTTL, failTTL time.Duration, now func() time.Time) PriceFetcher {
	return newSharedFetcher(fetch, okTTL, failTTL, now)
}
