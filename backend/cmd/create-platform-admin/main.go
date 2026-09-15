// create-platform-admin, ilk (veya ek bir) Super Admin hesabını oluşturur.
//
// TEK SEFERLİK bir araçtır -- kalıcı uygulama kodu değildir ve HTTP'den
// KESİNLİKLE erişilemez (Super Admin oluşturmanın tek yolu budur, herhangi
// bir platform endpoint'i üzerinden değil -- "Super Admin platform
// endpoint'leri normal organizasyon kullanıcıları tarafından tamamen
// erişilemez olmalı" kısıtı, self-servis Super Admin oluşturmayı da
// kapsar).
//
// Şifre KOMUT SATIRI BAYRAĞI OLARAK ALINMAZ (shell geçmişinde / `ps aux`
// çıktısında görünür olurdu) -- terminalden gizli (echo'suz) okunur.
//
// Kullanım:
//
//	DB_URL="postgres://.../arvend_dev" go run ./cmd/create-platform-admin \
//	  --username superadmin --fullname "Platform Yöneticisi"
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"

	"golang.org/x/term"

	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func main() {
	username := flag.String("username", "", "Super Admin kullanıcı adı (zorunlu)")
	fullName := flag.String("fullname", "Platform Yöneticisi", "Ad soyad")
	flag.Parse()

	if strings.TrimSpace(*username) == "" {
		fmt.Fprintln(os.Stderr, "kullanım: create-platform-admin --username <kullanıcı adı> [--fullname <ad soyad>]")
		os.Exit(1)
	}

	password, err := readPasswordTwice()
	if err != nil {
		log.Fatalf("şifre okunamadı: %v", err)
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

	q := sqlc.New(pool)
	userSvc := service.NewUserService(q)
	calcSvc := service.NewCalcService(q)
	productSvc := service.NewProductService(q)
	platformSvc := service.NewPlatformService(pool, q, userSvc, calcSvc, productSvc)

	user, err := platformSvc.CreateSuperAdmin(ctx, *username, password, *fullName)
	if err != nil {
		log.Fatalf("Super Admin oluşturulamadı: %v", err)
	}

	fmt.Printf("Super Admin oluşturuldu: %s (id=%s)\n", user.Username, user.ID)
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
