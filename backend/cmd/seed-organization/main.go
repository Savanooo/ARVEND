// seed-organization, yeni bir organizasyon (firma) ve ilk admin
// kullanıcısını atomik bir transaction'da oluşturur.
//
// TEK SEFERLİK bir araçtır -- kalıcı uygulama kodu değildir. Self-servis
// bir "firma kaydı" akışı bu pass'te yok; yeni firma onboarding'i şimdilik
// bu CLI ile yapılır.
//
// Kullanım:
//
//	DB_URL="postgres://.../arvend_dev" go run ./cmd/seed-organization \
//	  --name "Test Firma B" --slug test-firma-b \
//	  --admin-username testadmin --admin-password "GucluSifre123!" \
//	  --admin-fullname "Test Admin"
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

func main() {
	name := flag.String("name", "", "Firma adı (zorunlu)")
	slug := flag.String("slug", "", "Firma slug'ı, benzersiz (zorunlu)")
	adminUsername := flag.String("admin-username", "", "İlk admin kullanıcı adı (zorunlu)")
	adminPassword := flag.String("admin-password", "", "İlk admin şifresi (zorunlu, en az 8 karakter)")
	adminFullName := flag.String("admin-fullname", "Yönetici", "İlk admin ad soyad")
	flag.Parse()

	if *name == "" || *slug == "" || *adminUsername == "" || *adminPassword == "" {
		fmt.Fprintln(os.Stderr, "kullanım: seed-organization --name ... --slug ... --admin-username ... --admin-password ...")
		os.Exit(1)
	}
	if len(*adminPassword) < 8 {
		log.Fatal("admin şifresi en az 8 karakter olmalı")
	}

	dbURL := os.Getenv("DB_URL")
	if dbURL == "" {
		log.Fatal("DB_URL ortam değişkeni gerekli")
	}

	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		log.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	defer pool.Close()

	tx, err := pool.Begin(ctx)
	if err != nil {
		log.Fatalf("transaction başlatılamadı: %v", err)
	}
	defer tx.Rollback(ctx)
	q := sqlc.New(tx)

	org, err := q.CreateOrganization(ctx, sqlc.CreateOrganizationParams{Name: *name, Slug: *slug})
	if err != nil {
		log.Fatalf("organizasyon oluşturulamadı (slug zaten kullanılıyor olabilir): %v", err)
	}

	hash, err := auth.HashPassword(*adminPassword)
	if err != nil {
		log.Fatalf("şifre hash'lenemedi: %v", err)
	}
	user, err := q.CreateUser(ctx, sqlc.CreateUserParams{
		OrganizationID: org.ID,
		Username:       *adminUsername,
		PasswordHash:   hash,
		FullName:       *adminFullName,
		Role:           string(domain.RoleAdmin),
	})
	if err != nil {
		log.Fatalf("admin kullanıcı oluşturulamadı: %v", err)
	}

	if err := tx.Commit(ctx); err != nil {
		log.Fatalf("transaction commit edilemedi: %v", err)
	}

	fmt.Printf("Organizasyon oluşturuldu: %s (id=%s, slug=%s)\n", org.Name, org.ID.String(), org.Slug)
	fmt.Printf("Admin kullanıcı oluşturuldu: %s (id=%s)\n", user.Username, user.ID.String())
}
