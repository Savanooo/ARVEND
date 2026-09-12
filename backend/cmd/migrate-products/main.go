// migrate-products, eski BYZ (Flask + MongoDB) sistemindeki "products"
// koleksiyonunu okuyup yeni ARVEND PostgreSQL şemasına aktarır.
//
// TEK SEFERLİK bir araçtır -- kalıcı uygulama kodu değildir. Kaynak
// (Mongo) veritabanına yalnızca OKUMA yapar, hiçbir şey yazmaz/silmez.
//
// Kullanım:
//
//	SOURCE_MONGO_URI="mongodb://..." SOURCE_MONGO_DB="erp_teklif_sistemi" \
//	  DB_URL="postgres://.../arvend_dev" \
//	  go run ./cmd/migrate-products
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
)

func main() {
	ctx := context.Background()

	sourceURI := os.Getenv("SOURCE_MONGO_URI")
	sourceDB := os.Getenv("SOURCE_MONGO_DB")
	pgURL := os.Getenv("DB_URL")
	if sourceURI == "" || sourceDB == "" || pgURL == "" {
		log.Fatal("SOURCE_MONGO_URI, SOURCE_MONGO_DB ve DB_URL ortam değişkenleri gerekli")
	}

	mongoClient, err := mongo.Connect(options.Client().ApplyURI(sourceURI))
	if err != nil {
		log.Fatalf("MongoDB'ye bağlanılamadı: %v", err)
	}
	defer mongoClient.Disconnect(ctx)
	if err := mongoClient.Ping(ctx, nil); err != nil {
		log.Fatalf("MongoDB ping başarısız: %v", err)
	}

	pool, err := repository.NewPool(ctx, pgURL)
	if err != nil {
		log.Fatalf("PostgreSQL'e bağlanılamadı: %v", err)
	}
	defer pool.Close()

	col := mongoClient.Database(sourceDB).Collection("products")
	cursor, err := col.Find(ctx, bson.M{})
	if err != nil {
		log.Fatalf("products koleksiyonu okunamadı: %v", err)
	}
	defer cursor.Close(ctx)

	var migrated, historyRows, skipped int
	for cursor.Next(ctx) {
		var doc bson.M
		if err := cursor.Decode(&doc); err != nil {
			log.Printf("UYARI: bir doküman decode edilemedi: %v", err)
			skipped++
			continue
		}

		name := strings.TrimSpace(toString(doc["name"]))
		if name == "" {
			skipped++
			continue
		}
		unit := strings.TrimSpace(toString(doc["unit"]))
		if unit == "" {
			unit = "adet"
		}
		unitPrice := toFloat(doc["unit_price"])
		description := toString(doc["description"])
		category := toString(doc["category"])
		source := toString(doc["source"])
		createdAt := toTimeOr(doc["created_at"], time.Now())
		updatedAt := toTimeOr(doc["updated_at"], createdAt)

		var newID string
		err := pool.QueryRow(ctx, `
			INSERT INTO products (name, normalized_name, unit, unit_price, description, category, source, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, NULLIF($7, ''), $8, $9)
			RETURNING id
		`, name, domain.NormalizeName(name), unit, repository.Float64ToNumeric(unitPrice),
			description, category, source, createdAt, updatedAt).Scan(&newID)
		if err != nil {
			log.Printf("UYARI: %q eklenemedi: %v", name, err)
			skipped++
			continue
		}
		migrated++

		if rawHistory, ok := doc["price_history"].(bson.A); ok {
			for _, rawEntry := range rawHistory {
				entry, ok := rawEntry.(bson.M)
				if !ok {
					continue
				}
				old := toFloat(entry["eski_fiyat"])
				yeni := toFloat(entry["yeni_fiyat"])
				changedAt := toTimeOr(entry["tarih"], createdAt)
				note := toString(entry["kaynak"])
				if _, err := pool.Exec(ctx, `
					INSERT INTO product_price_history (product_id, old_price, new_price, note, changed_at)
					VALUES ($1, $2, $3, $4, $5)
				`, newID, repository.Float64ToNumeric(old), repository.Float64ToNumeric(yeni), note, changedAt); err != nil {
					log.Printf("UYARI: %q için fiyat geçmişi eklenemedi: %v", name, err)
					continue
				}
				historyRows++
			}
		}
	}
	if err := cursor.Err(); err != nil {
		log.Fatalf("cursor hatası: %v", err)
	}

	fmt.Printf("\nAktarım tamamlandı: %d ürün taşındı, %d fiyat geçmişi kaydı, %d atlandı.\n",
		migrated, historyRows, skipped)
}

func toString(v any) string {
	s, _ := v.(string)
	return s
}

func toFloat(v any) float64 {
	switch n := v.(type) {
	case float64:
		return n
	case float32:
		return float64(n)
	case int32:
		return float64(n)
	case int64:
		return float64(n)
	case int:
		return float64(n)
	default:
		return 0
	}
}

func toTimeOr(v any, fallback time.Time) time.Time {
	switch t := v.(type) {
	case bson.DateTime:
		return t.Time()
	case time.Time:
		return t
	default:
		return fallback
	}
}
