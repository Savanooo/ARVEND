package service_test

// Bu dosya, çok-kiracılı (multi-tenant) izolasyonun servis katmanında
// gerçekten uygulandığını doğrulayan bir entegrasyon testidir: gerçek bir
// PostgreSQL bağlantısı gerektirir (DB_URL ortam değişkeninden ya da
// backend/.env'den okunur), yoksa test atlanır. Amaç: Firma A'nın
// oluşturduğu her kayıt türü için, Firma B'nin aynı kaydı ID'sini bilerek
// Get/Update/Delete/List üzerinden görebilip göremediğini/değiştirip
// değiştiremediğini kontrol etmek.

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/joho/godotenv"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/crypto"
	"github.com/Savanooo/ARVEND/backend/internal/platform/storage"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// testDBURL, .env'i (backend/.env, bu paketin iki üst dizini) yükleyip
// DB_URL'i döner -- config.Load() ile aynı mantık, ama go test'in çalışma
// dizini paket dizini olduğu için yol açıkça verilir.
func testDBURL(t *testing.T) string {
	t.Helper()
	_ = godotenv.Load("../../.env")
	url := os.Getenv("DB_URL")
	if url == "" {
		t.Skip("DB_URL ayarlanmamış -- tenant izolasyonu testi gerçek bir PostgreSQL bağlantısı gerektirir, atlanıyor")
	}
	return url
}

func testSecretBox(t *testing.T) *crypto.SecretBox {
	t.Helper()
	_ = godotenv.Load("../../.env")
	key := os.Getenv("SETTINGS_ENCRYPTION_KEY")
	if key == "" {
		t.Skip("SETTINGS_ENCRYPTION_KEY ayarlanmamış, atlanıyor")
	}
	box, err := crypto.NewSecretBox(key)
	if err != nil {
		t.Fatalf("SecretBox oluşturulamadı: %v", err)
	}
	return box
}

// cleanupOrganization, test organizasyonuna ait TÜM kayıtları FK sırasına
// uygun şekilde siler -- organizations tablosuna referans veren kolonların
// hiçbiri ON DELETE CASCADE olmadığından (bilinçli tercih: bir
// organizasyonun yanlışlıkla tüm verisiyle silinmesini zorlaştırmak),
// temizlik açıkça yapılmalı.
func cleanupOrganization(t *testing.T, pool *pgxpool.Pool, orgID string) {
	t.Helper()
	ctx := context.Background()
	stmts := []string{
		"DELETE FROM attendance_logs WHERE organization_id = $1",
		// projects, teklife/revizyona CASCADE'siz FK ile bağlıdır (kasıtlı:
		// bir projeye dayanak olan teklif silinememeli), bu yüzden
		// tekliflerden ÖNCE temizlenmeli.
		"DELETE FROM projects WHERE organization_id = $1",
		"DELETE FROM project_counters WHERE organization_id = $1",
		"DELETE FROM offers WHERE organization_id = $1",
		"DELETE FROM offer_counters WHERE organization_id = $1",
		"DELETE FROM customers WHERE organization_id = $1",
		"DELETE FROM employees WHERE organization_id = $1",
		"DELETE FROM products WHERE organization_id = $1",
		"DELETE FROM smtp_settings WHERE organization_id = $1",
		// calc_recipe_items -> calc_categories -> calc_groups, üçü de
		// organization_id'ye CASCADE'siz (RESTRICT) FK taşır -- diğer
		// tablolarla aynı "açıkça sırayla temizle" ilkesi.
		"DELETE FROM calc_recipe_items WHERE organization_id = $1",
		"DELETE FROM calc_categories WHERE organization_id = $1",
		"DELETE FROM calc_groups WHERE organization_id = $1",
		// organization_profile/organization_commercial_settings, organization_id'yi
		// doğrudan PRIMARY KEY olarak taşır (smtp_settings ile aynı desen) --
		// CASCADE'siz FK, organizations satırından ÖNCE açıkça silinmeli.
		"DELETE FROM organization_profile WHERE organization_id = $1",
		"DELETE FROM organization_commercial_settings WHERE organization_id = $1",
		// platform_audit_events.target_organization_id ON DELETE SET NULL'dır
		// (bkz. migration 0033) -- satır kaybolmasın diye organizasyon
		// silinirken otomatik NULL'a düşer, temizlik için ayrıca silmeye
		// GEREK YOK (aksi halde bu testin ürettiği audit kayıtları organization_
		// id=NULL ile sonsuza dek DB'de kalır; platform_service_test.go'daki
		// cleanupPlatformOrg bunu Super Admin akışları için açıkça siler).
		"DELETE FROM users WHERE organization_id = $1",
		"DELETE FROM organizations WHERE id = $1",
	}
	for _, stmt := range stmts {
		if _, err := pool.Exec(ctx, stmt, orgID); err != nil {
			t.Logf("temizlik uyarısı (%s): %v", stmt, err)
		}
	}
}

func mustCreateOrg(t *testing.T, ctx context.Context, orgSvc *service.OrganizationService, pool *pgxpool.Pool, name, slug string) domain.Organization {
	t.Helper()
	// Önceki başarısız/yarım kalmış bir test çalışmasından kalıntı olabilir --
	// aynı slug'la temiz başlamak için önce kaldır.
	row := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug)
	var existingID string
	if err := row.Scan(&existingID); err == nil {
		cleanupOrganization(t, pool, existingID)
	}

	org, err := orgSvc.Create(ctx, name, slug)
	if err != nil {
		t.Fatalf("organizasyon oluşturulamadı: %v", err)
	}
	t.Cleanup(func() { cleanupOrganization(t, pool, org.ID) })
	return *org
}

// TestTenantIsolation, Faz 1'in temel güvenlik garantisini doğrular: Firma
// B, Firma A'nın hiçbir kaydına -- ID'sini bilse bile -- Get/Update/
// Delete/List üzerinden erişemez veya onu değiştiremez.
func TestTenantIsolation(t *testing.T) {
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("veritabanına bağlanılamadı: %v", err)
	}
	// t.Cleanup (LIFO), plain defer'dan SONRA çalışır -- havuzu kapatmayı da
	// t.Cleanup ile, org temizliğinden ÖNCE (yani LIFO'da en son çalışacak
	// şekilde) kaydetmek gerekir; aksi halde org temizliği kapalı bir
	// havuzla çalışmaya çalışır.
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	productSvc := service.NewProductService(q)
	employeeSvc := service.NewEmployeeService(q)
	attendanceSvc := service.NewAttendanceService(q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	userSvc := service.NewUserService(q)
	customerSvc := service.NewCustomerService(q)

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "İzolasyon Test Firma A", "izolasyon-test-firma-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "İzolasyon Test Firma B", "izolasyon-test-firma-b")

	// --- Firma A'da her tür kayıttan bir tane oluştur ---
	product, err := productSvc.Create(ctx, orgA.ID, "İzolasyon Test Ürün", "adet", 100, "", "")
	if err != nil {
		t.Fatalf("ürün oluşturulamadı: %v", err)
	}

	employee, err := employeeSvc.Create(ctx, orgA.ID, service.EmployeeInput{FullName: "İzolasyon Test Çalışan"})
	if err != nil {
		t.Fatalf("personel oluşturulamadı: %v", err)
	}

	customer, err := customerSvc.Create(ctx, orgA.ID, service.CustomerInput{Name: "İzolasyon Test Müşteri Kartı", Phone: "555"})
	if err != nil {
		t.Fatalf("müşteri oluşturulamadı: %v", err)
	}

	attendance, err := attendanceSvc.Create(ctx, orgA.ID, service.AttendanceInput{
		EmployeeID: employee.ID,
		Date:       time.Now(),
		Status:     domain.AttendanceGeldi,
	})
	if err != nil {
		t.Fatalf("mesai kaydı oluşturulamadı: %v", err)
	}

	offer, err := offerSvc.Create(ctx, service.CreateOfferInput{
		OrganizationID: orgA.ID,
		CustomerName:   "İzolasyon Test Müşteri",
		Items: []service.OfferItemInput{
			{ProductName: "Kalem", Quantity: 1, UnitPrice: 50},
		},
	})
	if err != nil {
		t.Fatalf("teklif oluşturulamadı: %v", err)
	}

	testUser, err := userSvc.Create(ctx, orgA.ID, "izolasyon_test_kullanici_a", "GucluSifre123!", "İzolasyon Test Kullanıcı", domain.RoleKullanici)
	if err != nil {
		t.Fatalf("kullanıcı oluşturulamadı: %v", err)
	}
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "DELETE FROM users WHERE id = (SELECT id FROM users WHERE username = 'izolasyon_test_kullanici_a')")
	})

	if _, err := settingsSvc.UpdateSmtp(ctx, orgA.ID, service.UpdateSmtpInput{
		Host: "smtp.example.com", Port: 587, FromEmail: "a@example.com", FromName: "Firma A",
	}); err != nil {
		t.Fatalf("SMTP ayarı kaydedilemedi: %v", err)
	}

	// --- Firma B'nin bu ID'leri bilerek erişmeye çalışması: hepsi ErrNotFound dönmeli ---

	t.Run("product Get", func(t *testing.T) {
		if _, err := productSvc.Get(ctx, product.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın ürününü görebildi: err=%v", err)
		}
	})
	t.Run("product Update", func(t *testing.T) {
		if _, err := productSvc.Update(ctx, product.ID, orgB.ID, "HACKED", "adet", 1, "", ""); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın ürününü güncelleyebildi: err=%v", err)
		}
	})
	t.Run("product Delete", func(t *testing.T) {
		if err := productSvc.Delete(ctx, product.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın ürününü silebildi: err=%v", err)
		}
	})
	t.Run("product List does not leak", func(t *testing.T) {
		res, err := productSvc.List(ctx, orgB.ID, "", 1, 200)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		for _, p := range res.Products {
			if p.ID == product.ID {
				t.Errorf("Firma B'nin ürün listesinde Firma A'nın ürünü göründü")
			}
		}
	})

	t.Run("employee Get/Update/Archive", func(t *testing.T) {
		if _, err := employeeSvc.Get(ctx, employee.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın personelini görebildi: err=%v", err)
		}
		if _, err := employeeSvc.Update(ctx, employee.ID, orgB.ID, service.EmployeeInput{FullName: "HACKED"}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın personelini güncelleyebildi: err=%v", err)
		}
		if err := employeeSvc.Archive(ctx, employee.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın personelini arşivleyebildi: err=%v", err)
		}
	})

	t.Run("attendance Get/Update/Delete", func(t *testing.T) {
		if _, err := attendanceSvc.Get(ctx, attendance.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın mesai kaydını görebildi: err=%v", err)
		}
		if _, err := attendanceSvc.Update(ctx, attendance.ID, orgB.ID, service.AttendanceInput{Status: domain.AttendanceGelmedi}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın mesai kaydını güncelleyebildi: err=%v", err)
		}
		if err := attendanceSvc.Delete(ctx, attendance.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın mesai kaydını silebildi: err=%v", err)
		}
	})
	t.Run("attendance cannot reference other org's employee", func(t *testing.T) {
		if _, err := attendanceSvc.Create(ctx, orgB.ID, service.AttendanceInput{
			EmployeeID: employee.ID, // Firma A'nın personeli
			Date:       time.Now(),
			Status:     domain.AttendanceGeldi,
		}); err == nil {
			t.Errorf("Firma B, Firma A'nın personeline mesai kaydı oluşturabildi")
		}
	})

	t.Run("offer Get/UpdateStatus/TogglePassive/Delete", func(t *testing.T) {
		if _, err := offerSvc.Get(ctx, offer.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın teklifini görebildi: err=%v", err)
		}
		if _, err := offerSvc.UpdateStatus(ctx, offer.ID, orgB.ID, domain.OfferStatusGonderildi, ""); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın teklifinin durumunu değiştirebildi: err=%v", err)
		}
		if err := offerSvc.TogglePassive(ctx, offer.ID, orgB.ID, ""); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın teklifini pasife alabildi: err=%v", err)
		}
		if err := offerSvc.Delete(ctx, offer.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın teklifini silebildi: err=%v", err)
		}
	})
	t.Run("offer List does not leak", func(t *testing.T) {
		res, err := offerSvc.List(ctx, orgB.ID, false, 1, 200)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		for _, o := range res.Offers {
			if o.ID == offer.ID {
				t.Errorf("Firma B'nin teklif listesinde Firma A'nın teklifi göründü")
			}
		}
	})
	t.Run("offer item cannot reference other org's product", func(t *testing.T) {
		productIDStr := product.ID
		created, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgB.ID,
			CustomerName:   "Sizin",
			Items: []service.OfferItemInput{
				{ProductID: &productIDStr, ProductName: "Sizin Ürününüz", Quantity: 1, UnitPrice: 1},
			},
		})
		if err != nil {
			t.Fatalf("teklif oluşturulamadı: %v", err)
		}
		t.Cleanup(func() { _ = offerSvc.Delete(ctx, created.ID, orgB.ID) })
		if len(created.Items) != 1 {
			t.Fatalf("beklenmeyen kalem sayısı: %d", len(created.Items))
		}
		if created.Items[0].ProductID != nil {
			t.Errorf("Firma B'nin teklifi, Firma A'nın product_id'sine referans veriyor: %v", *created.Items[0].ProductID)
		}
	})

	t.Run("user Get/Update/Deactivate/List", func(t *testing.T) {
		if _, err := userSvc.Get(ctx, testUser.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın kullanıcısını görebildi: err=%v", err)
		}
		if _, err := userSvc.Update(ctx, testUser.ID, orgB.ID, "HACKED", domain.RoleAdmin, true); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın kullanıcısını güncelleyebildi (rol yükseltme dahil): err=%v", err)
		}
		if err := userSvc.Deactivate(ctx, testUser.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın kullanıcısını pasifleştirebildi: err=%v", err)
		}
		list, err := userSvc.List(ctx, orgB.ID, 1, 200)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		for _, u := range list.Users {
			if u.ID == testUser.ID {
				t.Errorf("Firma B'nin kullanıcı listesinde Firma A'nın kullanıcısı göründü")
			}
		}
	})

	t.Run("smtp settings isolated", func(t *testing.T) {
		s, err := settingsSvc.GetSmtp(ctx, orgB.ID)
		if err != nil {
			t.Fatalf("ayarlar alınamadı: %v", err)
		}
		if s.Configured {
			t.Errorf("Firma B, Firma A'nın SMTP ayarını görüyor")
		}
	})

	t.Run("customer Get/Update/Archive/List", func(t *testing.T) {
		if _, err := customerSvc.Get(ctx, customer.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın müşterisini görebildi: err=%v", err)
		}
		if _, err := customerSvc.Update(ctx, customer.ID, orgB.ID, service.CustomerInput{Name: "HACKED"}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın müşterisini güncelleyebildi: err=%v", err)
		}
		if err := customerSvc.Archive(ctx, customer.ID, orgB.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın müşterisini arşivleyebildi: err=%v", err)
		}
		list, err := customerSvc.List(ctx, orgB.ID, "", nil)
		if err != nil {
			t.Fatalf("liste alınamadı: %v", err)
		}
		for _, c := range list {
			if c.ID == customer.ID {
				t.Errorf("Firma B'nin müşteri listesinde Firma A'nın müşterisi göründü")
			}
		}
	})

	t.Run("offer cannot reference other org's customer_id", func(t *testing.T) {
		customerIDStr := customer.ID
		if _, err := offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgB.ID,
			CustomerID:     &customerIDStr,
			Items:          []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 1}},
		}); err == nil {
			t.Errorf("Firma B, Firma A'nın müşteri kartına referans veren bir teklif oluşturabildi")
		}
	})

	t.Run("offer Update isolated and respects draft-only rule", func(t *testing.T) {
		if _, err := offerSvc.Update(ctx, offer.ID, orgB.ID, service.UpdateOfferInput{
			CustomerName: "HACKED",
			Items:        []service.OfferItemInput{{ProductName: "X", Quantity: 1, UnitPrice: 1}},
		}); !errors.Is(err, domain.ErrNotFound) {
			t.Errorf("Firma B, Firma A'nın teklifini düzenleyebildi: err=%v", err)
		}

		// Aynı org'da düzenleme: taslak durumundaki teklif düzenlenebilmeli,
		// toplamlar sunucu tarafında yeniden hesaplanmalı.
		updated, err := offerSvc.Update(ctx, offer.ID, orgA.ID, service.UpdateOfferInput{
			CustomerName: "Güncellenmiş Müşteri",
			Items:        []service.OfferItemInput{{ProductName: "Yeni Kalem", Quantity: 2, UnitPrice: 25}},
		})
		if err != nil {
			t.Fatalf("aynı org içinde taslak teklif düzenlenemedi: %v", err)
		}
		if updated.Subtotal != 50 || updated.GrandTotal != 60 {
			t.Errorf("toplamlar yeniden hesaplanmadı: subtotal=%v grand_total=%v", updated.Subtotal, updated.GrandTotal)
		}

		// Taslak olmayan bir teklif düzenlenemez.
		if _, err := offerSvc.UpdateStatus(ctx, offer.ID, orgA.ID, domain.OfferStatusGonderildi, ""); err != nil {
			t.Fatalf("durum güncellenemedi: %v", err)
		}
		if _, err := offerSvc.Update(ctx, offer.ID, orgA.ID, service.UpdateOfferInput{
			CustomerName: "Tekrar Değiştir",
			Items:        []service.OfferItemInput{{ProductName: "X", Quantity: 1, UnitPrice: 1}},
		}); !errors.Is(err, service.ErrOfferNotEditable) {
			t.Errorf("gönderilmiş teklif yine de düzenlenebildi: err=%v", err)
		}
	})
}

// mustTestStore, testler için geçici bir dosya deposu açar (her test kendi
// dizinini alır, test bitince silinir).
func mustTestStore(t *testing.T) storage.Store {
	t.Helper()
	s, err := storage.NewLocalStore(t.TempDir())
	if err != nil {
		t.Fatalf("test dosya deposu açılamadı: %v", err)
	}
	return s
}
