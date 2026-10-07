// reset-platform-admin-password, bir Super Admin'in şifresini değiştirir.
//
// Super Admin'in web'de/API'de kendi şifresini değiştireceği bir yer yok
// (Profilim firma kabuğunda; /users/me/password firma ister). Bu araç
// create-platform-admin'in eşidir: HTTP'den erişilemez, sunucuda çalıştırılır.
//
// Şifre KOMUT SATIRI BAYRAĞI OLARAK ALINMAZ (shell geçmişinde / `ps aux`
// çıktısında görünürdü) -- terminalden gizli (echo'suz) iki kez okunur.
// Eski şifreyle açılmış bütün oturumlar kapanır.
//
// Kullanım:
//
//	DB_URL="postgres://..." reset-platform-admin-password --username platform_admin
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"

	"golang.org/x/term"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func main() {
	username := flag.String("username", "", "Super Admin kullanıcı adı (zorunlu)")
	flag.Parse()

	if strings.TrimSpace(*username) == "" {
		fmt.Fprintln(os.Stderr, "kullanım: reset-platform-admin-password --username <kullanıcı adı>")
		os.Exit(1)
	}

	dbURL := os.Getenv("DB_URL")
	if dbURL == "" {
		log.Fatal("DB_URL ortam değişkeni gerekli")
	}

	fmt.Fprintf(os.Stderr, "%s için YENİ şifre (en az %d karakter; yazarken görünmez)\n", *username, domain.MinPasswordLength)
	password, err := readPasswordTwice()
	if err != nil {
		log.Fatalf("şifre okunamadı: %v", err)
	}

	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		log.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	defer pool.Close()

	q := sqlc.New(pool)
	userSvc := service.NewUserService(pool, q)
	calcSvc := service.NewCalcService(q)
	productSvc := service.NewProductService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, calcSvc, productSvc)

	switch err := platformSvc.ResetSuperAdminPassword(ctx, *username, password); {
	case errors.Is(err, domain.ErrNotFound):
		log.Fatalf("%q adında bir Super Admin yok", *username)
	case errors.Is(err, domain.ErrPasswordTooShort):
		log.Fatalf("şifre en az %d karakter olmalı", domain.MinPasswordLength)
	case err != nil:
		log.Fatalf("şifre değiştirilemedi: %v", err)
	}
	fmt.Printf("TAMAM: %s şifresi değişti, eski oturumlar kapandı.\n", *username)
}

// readPasswordTwice, terminalden (echo kapalı) şifreyi iki kez okuyup
// eşleştiği doğrular -- seed-organization CLI'ının "en az 8 karakter" kuralı
// PlatformService.CreateSuperAdmin içinde zaten uygulanıyor, burada tekrar
// edilmiyor.
func readPasswordTwice() (string, error) {
	fd := int(os.Stdin.Fd())
	if term.IsTerminal(fd) {
		fmt.Fprint(os.Stderr, "Şifre: ")
		pw1, err := term.ReadPassword(fd)
		if err != nil {
			return "", err
		}
		fmt.Fprint(os.Stderr, "\nŞifre (tekrar): ")
		pw2, err := term.ReadPassword(fd)
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return "", err
		}
		if string(pw1) != string(pw2) {
			return "", fmt.Errorf("şifreler eşleşmiyor")
		}
		return string(pw1), nil
	}
	// Terminal değil (ör. testte/otomasyonda stdin bir pipe) -- echo'suz
	// okuma mümkün değil, düz satır okunur. TEK bir bufio.Reader iki
	// okuma arasında PAYLAŞILIR -- her çağrıda yeni bir bufio.Reader
	// oluşturmak (önceki bir tasarım hatası) os.Stdin'den zaten
	// arabelleğe alınmış ama henüz tüketilmemiş baytları (ör. ikinci
	// satırı) kaybettirir, çünkü bufio.Reader alttaki akıştan büyük
	// parçalar halinde okur.
	reader := bufio.NewReader(os.Stdin)
	fmt.Fprint(os.Stderr, "Şifre: ")
	pw1, err := readLine(reader)
	if err != nil {
		return "", err
	}
	fmt.Fprint(os.Stderr, "\nŞifre (tekrar): ")
	pw2, err := readLine(reader)
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return "", err
	}
	if pw1 != pw2 {
		return "", fmt.Errorf("şifreler eşleşmiyor")
	}
	return pw1, nil
}

func readLine(r *bufio.Reader) (string, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}
