package repository_test

// NewPool'un oturum saat dilimini Europe/Istanbul'a sabitlediğini GERÇEK
// bir PostgreSQL bağlantısıyla doğrular (ana sayfa spec'i B0 / D20).
// Bağlantı adresine bilinçli olarak farklı yazımlarla timezone=UTC eklenir:
// varsayılanı zaten İstanbul olan bir geliştirme veritabanında test
// kendiliğinden geçmesin, NewPool'un adresteki değerin ÜZERİNE yazdığı
// kanıtlansın.

import (
	"context"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/joho/godotenv"

	"github.com/Savanooo/ARVEND/backend/internal/repository"
)

func TestNewPoolSessionTimeZoneIsIstanbul(t *testing.T) {
	_ = godotenv.Load("../../.env")
	dbURL := os.Getenv("DB_URL")
	if dbURL == "" {
		t.Skip("DB_URL ayarlanmamış -- gerçek bir PostgreSQL bağlantısı gerektirir, atlanıyor")
	}
	sep := "?"
	if strings.Contains(dbURL, "?") {
		sep = "&"
	}
	// pgx adres anahtarlarının harfini korur, PostgreSQL ise GUC adlarını
	// harf duyarsız okur: "TimeZone"/"TIMEZONE" da ezilmeli.
	for _, key := range []string{"timezone", "TimeZone", "TIMEZONE"} {
		t.Run(key, func(t *testing.T) {
			ctx := context.Background()
			pool, err := repository.NewPool(ctx, dbURL+sep+key+"=UTC")
			if err != nil {
				t.Fatalf("havuz açılamadı: %v", err)
			}
			t.Cleanup(pool.Close)

			// Başlangıç parametrelerinde TEK bir saat dilimi anahtarı kalmalı;
			// iki anahtar kalırsa hangisinin kazanacağı map sırasına bağlıdır
			// (bağlantıların bir kısmı UTC'ye düşer).
			for k, v := range pool.Config().ConnConfig.RuntimeParams {
				if strings.EqualFold(k, "timezone") && (k != "timezone" || v != repository.SessionTimeZone) {
					t.Fatalf("başlangıç parametresinde artık saat dilimi kaldı: %q=%q", k, v)
				}
			}

			assertIstanbulSessions(t, ctx, pool)
		})
	}
}

// assertIstanbulSessions: aynı anda birden çok bağlantı açtırıp HER
// birinde SHOW timezone ve CURRENT_DATE'i doğrular.
func assertIstanbulSessions(t *testing.T, ctx context.Context, pool *pgxpool.Pool) {
	t.Helper()
	const conns = 4
	var wg sync.WaitGroup
	errs := make(chan string, conns)
	for range conns {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c, err := pool.Acquire(ctx)
			if err != nil {
				errs <- "bağlantı alınamadı: " + err.Error()
				return
			}
			defer c.Release()
			var tz string
			if err := c.QueryRow(ctx, "SHOW timezone").Scan(&tz); err != nil {
				errs <- "SHOW timezone okunamadı: " + err.Error()
				return
			}
			if tz != repository.SessionTimeZone {
				errs <- "oturum saat dilimi = " + tz + ", beklenen " + repository.SessionTimeZone
				return
			}
			// CURRENT_DATE de İstanbul takvim gününü vermeli
			// (CountProjectTaskStats/ListMyTasks bu ifadeye dayanır).
			var same bool
			if err := c.QueryRow(ctx,
				"SELECT CURRENT_DATE = (now() AT TIME ZONE 'Europe/Istanbul')::date").Scan(&same); err != nil {
				errs <- "CURRENT_DATE karşılaştırılamadı: " + err.Error()
				return
			}
			if !same {
				errs <- "CURRENT_DATE İstanbul takvim gününden farklı"
			}
		}()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		t.Error(e)
	}
}
