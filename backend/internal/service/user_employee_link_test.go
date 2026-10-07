package service_test

// "Kişi = tek kayıt": giriş hesabı açan yollar hesabı bir personel kaydına
// bağlar (bkz. service/user_employee_link.go). Sahadaki hata: "batu" hesabı
// ile "Batuhan İnci" personeli bağlı değildi; görev seçicisinde iki kişi
// göründü, personele atanan görevin bildirimi kimseye gitmedi.

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestUserEmployeeLink(t *testing.T) {
	dbURL := testDBURL(t)
	box := testSecretBox(t)
	ctx := context.Background()

	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	q := sqlc.New(pool)
	orgSvc := service.NewOrganizationService(q)
	userSvc := service.NewUserService(pool, q)
	employeeSvc := service.NewEmployeeService(pool, q)
	authzSvc := service.NewAuthorizationService(pool, q)
	settingsSvc := service.NewSettingsService(q, box)
	offerSvc := service.NewOfferService(pool, q, settingsSvc, "http://localhost:3000")
	projectSvc := service.NewProjectService(pool, q, mustTestStore(t), settingsSvc, "http://localhost:3000")
	attendanceSvc := service.NewAttendanceService(q)
	payrollSvc := service.NewSalaryPaymentService(q)

	orgA := mustCreateOrg(t, ctx, orgSvc, pool, "Kişi Tek Kayıt A", "person-link-a")
	orgB := mustCreateOrg(t, ctx, orgSvc, pool, "Kişi Tek Kayıt B", "person-link-b")
	for _, o := range []domain.Organization{orgA, orgB} {
		oid, _ := repository.StringToUUID(o.ID)
		if err := q.SeedSystemRolesForOrg(ctx, oid); err != nil {
			t.Fatalf("rol seed: %v", err)
		}
	}
	owner, err := userSvc.Create(ctx, orgA.ID, "pl_owner", "GeciciSifre123!", "Sahip Kişi", domain.RoleAdmin, domain.OrgRoleOwner)
	if err != nil {
		t.Fatalf("owner: %v", err)
	}

	manage := service.PersonnelOptions{CanManageEmployees: true}
	no := false
	yes := true

	newMember := func(t *testing.T, orgID, username, fullName string, opts service.PersonnelOptions) (*domain.User, *service.EmployeeLinkResult) {
		t.Helper()
		u, link, err := userSvc.CreateMember(ctx, orgID, owner.ID, username, "GeciciSifre123!", fullName, domain.OrgRoleField, opts)
		if err != nil {
			t.Fatalf("hesap %s: %v", username, err)
		}
		return u, link
	}
	newEmployee := func(t *testing.T, orgID, fullName string) *domain.Employee {
		t.Helper()
		e, err := employeeSvc.Create(ctx, orgID, service.EmployeeInput{FullName: fullName, Position: "Kalıpçı", IsActive: true})
		if err != nil {
			t.Fatalf("personel %s: %v", fullName, err)
		}
		return e
	}
	employeeOf := func(t *testing.T, orgID, userID string) (sqlc.Employee, bool) {
		t.Helper()
		oid, _ := repository.StringToUUID(orgID)
		uid, _ := repository.StringToUUID(userID)
		e, err := q.GetEmployeeByUserID(ctx, sqlc.GetEmployeeByUserIDParams{UserID: uid, OrganizationID: oid})
		if errors.Is(err, pgx.ErrNoRows) {
			return e, false
		}
		if err != nil {
			t.Fatalf("personel okunamadı: %v", err)
		}
		return e, true
	}
	countByName := func(t *testing.T, orgID, name string) int {
		t.Helper()
		var n int
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM employees WHERE organization_id = $1 AND full_name = $2", orgID, name).Scan(&n); err != nil {
			t.Fatalf("sayım: %v", err)
		}
		return n
	}
	usernameTaken := func(t *testing.T, username string) bool {
		t.Helper()
		var n int
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM users WHERE username = $1", username).Scan(&n); err != nil {
			t.Fatalf("sayım: %v", err)
		}
		return n > 0
	}

	t.Run("default_creates_and_links", func(t *testing.T) {
		u, link := newMember(t, orgA.ID, "pl_ayse", "Ayşe Yılmaz", manage)
		if link.Status != service.EmployeeLinkCreated {
			t.Fatalf("status = %q, want created", link.Status)
		}
		e, ok := employeeOf(t, orgA.ID, u.ID)
		if !ok {
			t.Fatal("hesap açıldı ama personel kaydı yok")
		}
		if e.FullName != "Ayşe Yılmaz" || e.Position != "" || !e.IsActive || e.Salary.Valid || e.DailyWage.Valid {
			t.Errorf("personel alanları beklenmedik: ad=%q görev=%q aktif=%v maaş=%v yevmiye=%v", e.FullName, e.Position, e.IsActive, e.Salary.Valid, e.DailyWage.Valid)
		}
		today := service.IstanbulToday()
		if !e.StartDate.Valid || !e.StartDate.Time.Equal(today) {
			t.Errorf("işe başlama bugün olmalı: %v, want %v", e.StartDate.Time, today)
		}
		if link.EmployeeID != e.ID.String() || u.LinkedEmployeeID == nil || *u.LinkedEmployeeID != e.ID.String() {
			t.Errorf("cevap bağlı personeli göstermiyor: link=%+v user=%v", link, u.LinkedEmployeeID)
		}
		// Kullanıcı detayı (GET /users/{id}) bağlı personeli JOIN'le döner.
		got, err := authzSvc.GetUserWithRole(ctx, u.ID, orgA.ID)
		if err != nil {
			t.Fatalf("get: %v", err)
		}
		if got.LinkedEmployeeID == nil || *got.LinkedEmployeeID != e.ID.String() || got.LinkedEmployeeName != "Ayşe Yılmaz" || !got.LinkedEmployeeActive {
			t.Errorf("GetUserWithRole bağlı personeli döndürmedi: %+v", got)
		}
	})

	t.Run("opt_out", func(t *testing.T) {
		u, link := newMember(t, orgA.ID, "pl_optout", "Ofis Kişi", service.PersonnelOptions{CreateEmployee: &no, CanManageEmployees: true})
		if link.Status != service.EmployeeLinkSkipped {
			t.Fatalf("status = %q, want skipped", link.Status)
		}
		if _, ok := employeeOf(t, orgA.ID, u.ID); ok {
			t.Fatal("create_employee=false iken personel oluştu")
		}
		if countByName(t, orgA.ID, "Ofis Kişi") != 0 {
			t.Fatal("create_employee=false iken personel oluştu")
		}
	})

	t.Run("no_employees_manage_permission", func(t *testing.T) {
		u, link := newMember(t, orgA.ID, "pl_noperm", "İzinsiz Kişi", service.PersonnelOptions{})
		if link.Status != service.EmployeeLinkNoPermission {
			t.Fatalf("status = %q, want no_permission", link.Status)
		}
		if _, ok := employeeOf(t, orgA.ID, u.ID); ok {
			t.Fatal("employees.manage yokken personel oluştu")
		}
		e := newEmployee(t, orgA.ID, "İzinsiz Bağlama")
		_, _, err := userSvc.CreateMember(ctx, orgA.ID, owner.ID, "pl_noperm2", "GeciciSifre123!", "X", domain.OrgRoleField,
			service.PersonnelOptions{EmployeeID: e.ID})
		if !errors.Is(err, service.ErrEmployeeLinkNotPermitted) {
			t.Fatalf("izinsiz açık bağlama reddedilmeli: %v", err)
		}
		if usernameTaken(t, "pl_noperm2") {
			t.Fatal("reddedilen istek hesabı yine de açtı (transaction geri alınmadı)")
		}
	})

	t.Run("link_existing_by_id", func(t *testing.T) {
		e := newEmployee(t, orgA.ID, "Mehmet Demir")
		u, link := newMember(t, orgA.ID, "pl_mehmet", "mehmet", service.PersonnelOptions{EmployeeID: e.ID, CanManageEmployees: true})
		if link.Status != service.EmployeeLinkLinked || link.EmployeeID != e.ID {
			t.Fatalf("link = %+v, want linked to %s", link, e.ID)
		}
		got, ok := employeeOf(t, orgA.ID, u.ID)
		if !ok || got.ID.String() != e.ID || got.FullName != "Mehmet Demir" {
			t.Fatalf("istenen personele bağlanmadı ya da adı değişti: %+v", got)
		}
		if countByName(t, orgA.ID, "mehmet") != 0 {
			t.Fatal("employee_id verilmişken yeni personel de açıldı")
		}
	})

	t.Run("same_name_auto_link", func(t *testing.T) {
		e := newEmployee(t, orgA.ID, "Batuhan İnci")
		u, link := newMember(t, orgA.ID, "pl_batu", "BATUHAN INCI", manage)
		if link.Status != service.EmployeeLinkSameName || link.EmployeeID != e.ID {
			t.Fatalf("aynı adlı personele bağlanmalıydı: %+v", link)
		}
		if !strings.Contains(link.Message(), "Batuhan İnci") {
			t.Errorf("mesaj hangi kayda bağlandığını söylemeli: %q", link.Message())
		}
		if got, _ := employeeOf(t, orgA.ID, u.ID); got.ID.String() != e.ID {
			t.Fatalf("bağ yanlış personelde: %s", got.ID.String())
		}
		if countByName(t, orgA.ID, "BATUHAN INCI") != 0 || countByName(t, orgA.ID, "Batuhan İnci") != 1 {
			t.Fatal("aynı kişi için ikinci personel kaydı açıldı")
		}
	})

	t.Run("same_name_ambiguous_links_nothing", func(t *testing.T) {
		newEmployee(t, orgA.ID, "Ali Kaya")
		newEmployee(t, orgA.ID, "Ali Kaya")
		u, link := newMember(t, orgA.ID, "pl_alikaya", "Ali Kaya", manage)
		if link.Status != service.EmployeeLinkAmbiguous || link.Candidates != 2 {
			t.Fatalf("iki aday varken tahmin edilmemeli: %+v", link)
		}
		if _, ok := employeeOf(t, orgA.ID, u.ID); ok {
			t.Fatal("belirsizken bir kayda bağlandı")
		}
		if countByName(t, orgA.ID, "Ali Kaya") != 2 {
			t.Fatal("belirsizken üçüncü aynı adlı kayıt açıldı")
		}
	})

	t.Run("link_same_name_false_creates_new", func(t *testing.T) {
		old := newEmployee(t, orgA.ID, "Zeynep Ak")
		u, link := newMember(t, orgA.ID, "pl_zeynep2", "Zeynep Ak", service.PersonnelOptions{LinkSameName: &no, CreateEmployee: &yes, CanManageEmployees: true})
		if link.Status != service.EmployeeLinkCreated || link.EmployeeID == old.ID {
			t.Fatalf("link_same_name=false yeni kayıt açmalıydı: %+v", link)
		}
		if got, _ := employeeSvc.Get(ctx, old.ID, orgA.ID); got.UserID != nil {
			t.Fatal("eski aynı adlı kayıt bağlanmamalıydı")
		}
		if _, ok := employeeOf(t, orgA.ID, u.ID); !ok {
			t.Fatal("yeni personel bağlanmadı")
		}
	})

	t.Run("never_steal_linked_record", func(t *testing.T) {
		first, _ := newMember(t, orgA.ID, "pl_fatma1", "Fatma Öz", manage)
		firstEmp, _ := employeeOf(t, orgA.ID, first.ID)

		// Açık istek: başka hesaba bağlı personel ASLA alınmaz, hesap da açılmaz.
		_, _, err := userSvc.CreateMember(ctx, orgA.ID, owner.ID, "pl_thief", "GeciciSifre123!", "Hırsız", domain.OrgRoleField,
			service.PersonnelOptions{EmployeeID: firstEmp.ID.String(), CanManageEmployees: true})
		if !errors.Is(err, service.ErrEmployeeHasOtherUser) {
			t.Fatalf("bağlı personel alınmamalı: %v", err)
		}
		if usernameTaken(t, "pl_thief") {
			t.Fatal("reddedilen istek hesabı açtı")
		}
		// Aynı adlı tek personel başkasına bağlıysa aday değildir -> yeni kayıt.
		second, link := newMember(t, orgA.ID, "pl_fatma2", "Fatma Öz", manage)
		if link.Status != service.EmployeeLinkCreated {
			t.Fatalf("bağlı aynı adlı kayıt aday sayılmamalı: %+v", link)
		}
		if got, _ := employeeOf(t, orgA.ID, first.ID); got.ID != firstEmp.ID {
			t.Fatal("ilk hesabın personeli değişti")
		}
		if got, _ := employeeOf(t, orgA.ID, second.ID); got.ID == firstEmp.ID {
			t.Fatal("ikinci hesap ilkinin personeline bağlandı")
		}
		// Pasif aynı adlı personel de otomatik aday değildir.
		archived := newEmployee(t, orgA.ID, "Kemal Pasif")
		if err := employeeSvc.Archive(ctx, archived.ID, orgA.ID); err != nil {
			t.Fatalf("archive: %v", err)
		}
		_, link = newMember(t, orgA.ID, "pl_kemal", "Kemal Pasif", manage)
		if link.Status != service.EmployeeLinkCreated || link.EmployeeID == archived.ID {
			t.Fatalf("pasif personel otomatik bağlanmamalı: %+v", link)
		}
	})

	t.Run("tenant_isolation", func(t *testing.T) {
		eB := newEmployee(t, orgB.ID, "Deniz Başka")
		_, _, err := userSvc.CreateMember(ctx, orgA.ID, owner.ID, "pl_cross", "GeciciSifre123!", "Deniz Başka", domain.OrgRoleField,
			service.PersonnelOptions{EmployeeID: eB.ID, CanManageEmployees: true})
		if !errors.Is(err, service.ErrLinkEmployeeNotFound) {
			t.Fatalf("başka firmanın personeli bulunamaz olmalı: %v", err)
		}
		if usernameTaken(t, "pl_cross") {
			t.Fatal("reddedilen istek hesabı açtı")
		}
		// Aynı ad başka firmada: aday değil, A'da yeni kayıt açılır.
		u, link := newMember(t, orgA.ID, "pl_cross2", "Deniz Başka", manage)
		if link.Status != service.EmployeeLinkCreated {
			t.Fatalf("başka firmanın aynı adlı personeli aday olmamalı: %+v", link)
		}
		if got, _ := employeeSvc.Get(ctx, eB.ID, orgB.ID); got.UserID != nil {
			t.Fatal("B firmasının personeli A'nın hesabına bağlandı")
		}
		if e, _ := employeeOf(t, orgA.ID, u.ID); e.OrganizationID.String() != orgA.ID {
			t.Fatal("personel yanlış firmada")
		}
	})

	t.Run("explicit_link_beats_untouched_auto_record", func(t *testing.T) {
		// "batu" hesabı açılırken "batu" personeli otomatik açıldı; yönetici
		// sonra hesabı asıl kayda ("Batuhan Asıl") bağlar: otomatik boş kayıt
		// yol verir.
		real := newEmployee(t, orgA.ID, "Batuhan Asıl")
		u, link := newMember(t, orgA.ID, "pl_batu2", "batu", manage)
		if link.Status != service.EmployeeLinkCreated {
			t.Fatalf("status = %q", link.Status)
		}
		autoID := link.EmployeeID
		uid := u.ID
		updated, err := employeeSvc.Update(ctx, real.ID, orgA.ID, service.EmployeeInput{FullName: real.FullName, Position: real.Position, IsActive: true, UserID: &uid})
		if err != nil {
			t.Fatalf("açık bağlama başarısız: %v", err)
		}
		if updated.UserID == nil || *updated.UserID != uid {
			t.Fatal("bağ kurulmadı")
		}
		if _, err := employeeSvc.Get(ctx, autoID, orgA.ID); !errors.Is(err, domain.ErrNotFound) {
			t.Fatalf("otomatik açılmış boş kayıt silinmeliydi: %v", err)
		}

		// Kullanılmış (mesai girilmiş) otomatik kayıt SİLİNMEZ; hata hangi
		// personele bağlı olduğunu söyler.
		u2, link2 := newMember(t, orgA.ID, "pl_used", "Kullanılmış Kayıt", manage)
		if _, err := attendanceSvc.Create(ctx, orgA.ID, service.AttendanceInput{EmployeeID: link2.EmployeeID, Date: service.IstanbulToday(), Status: domain.AttendanceGeldi, WorkHours: 8}); err != nil {
			t.Fatalf("mesai: %v", err)
		}
		other := newEmployee(t, orgA.ID, "Başka Kayıt")
		uid2 := u2.ID
		_, err = employeeSvc.Update(ctx, other.ID, orgA.ID, service.EmployeeInput{FullName: other.FullName, IsActive: true, UserID: &uid2})
		if !errors.Is(err, service.ErrEmployeeUserAlreadyLinked) || !strings.Contains(err.Error(), "Kullanılmış Kayıt") {
			t.Fatalf("kullanılmış kayıt korunmalı ve hata adını söylemeli: %v", err)
		}
		if _, err := employeeSvc.Get(ctx, link2.EmployeeID, orgA.ID); err != nil {
			t.Fatalf("kullanılmış kayıt silindi: %v", err)
		}

		// Elle açılıp bağlanmış (otomatik olmayan) kayıt da silinmez.
		manual, _ := newMember(t, orgA.ID, "pl_manual", "Elle Kayıt", service.PersonnelOptions{CreateEmployee: &no, CanManageEmployees: true})
		mid := manual.ID
		m1, err := employeeSvc.Create(ctx, orgA.ID, service.EmployeeInput{FullName: "Elle Kayıt", IsActive: true, UserID: &mid})
		if err != nil {
			t.Fatalf("elle bağlama: %v", err)
		}
		m2 := newEmployee(t, orgA.ID, "Elle Kayıt 2")
		if _, err := employeeSvc.Update(ctx, m2.ID, orgA.ID, service.EmployeeInput{FullName: m2.FullName, IsActive: true, UserID: &mid}); !errors.Is(err, service.ErrEmployeeUserAlreadyLinked) {
			t.Fatalf("elle bağlanmış kayıt yol vermemeli: %v", err)
		}
		if _, err := employeeSvc.Get(ctx, m1.ID, orgA.ID); err != nil {
			t.Fatalf("elle açılmış kayıt silindi: %v", err)
		}
	})

	t.Run("frozen_web_create_login_card_for_archived_employee", func(t *testing.T) {
		// Web "Giriş hesabı aç": önce POST /users (ad = personelin adı, yeni
		// alan yok), sonra PUT /employees/{id} user_id. Personel pasifse
		// otomatik eşleşme olmaz, hesapla yeni kayıt açılır; PUT yine
		// başarılı olmalı ve geride ikinci kayıt kalmamalı.
		archived := newEmployee(t, orgA.ID, "Arşivli Usta")
		if err := employeeSvc.Archive(ctx, archived.ID, orgA.ID); err != nil {
			t.Fatalf("archive: %v", err)
		}
		u, _ := newMember(t, orgA.ID, "pl_arsiv", "Arşivli Usta", manage)
		uid := u.ID
		if _, err := employeeSvc.Update(ctx, archived.ID, orgA.ID, service.EmployeeInput{FullName: "Arşivli Usta", Position: "Kalıpçı", IsActive: false, UserID: &uid}); err != nil {
			t.Fatalf("web akışının ikinci adımı başarısız: %v", err)
		}
		if n := countByName(t, orgA.ID, "Arşivli Usta"); n != 1 {
			t.Fatalf("aynı kişi için %d kayıt kaldı, want 1", n)
		}
	})

	t.Run("rename_syncs_only_equal_names", func(t *testing.T) {
		u, link := newMember(t, orgA.ID, "pl_can", "Can Er", manage)
		if _, err := userSvc.Update(ctx, u.ID, orgA.ID, owner.ID, "Can Eren", true); err != nil {
			t.Fatalf("update: %v", err)
		}
		if e, _ := employeeSvc.Get(ctx, link.EmployeeID, orgA.ID); e.FullName != "Can Eren" {
			t.Fatalf("aynı adlı personel yeni adı almalıydı: %q", e.FullName)
		}
		e := newEmployee(t, orgA.ID, "Hüseyin Tekin")
		u2, _ := newMember(t, orgA.ID, "pl_huso", "hüso", service.PersonnelOptions{EmployeeID: e.ID, CanManageEmployees: true})
		if _, err := userSvc.Update(ctx, u2.ID, orgA.ID, owner.ID, "Hüso T.", true); err != nil {
			t.Fatalf("update: %v", err)
		}
		if got, _ := employeeSvc.Get(ctx, e.ID, orgA.ID); got.FullName != "Hüseyin Tekin" {
			t.Fatalf("bilinçli farklı personel adı ezilmemeli: %q", got.FullName)
		}
	})

	var projectID string
	t.Run("assignees_one_entry_per_person", func(t *testing.T) {
		projectID = newLinkProject(t, ctx, offerSvc, projectSvc, orgA.ID)
		before := newEmployee(t, orgA.ID, "Seçici Kişi")
		newMember(t, orgA.ID, "pl_secici", "Seçici Kişi", manage)
		newMember(t, orgA.ID, "pl_yeni", "Yepyeni Kişi", manage)
		rows, err := projectSvc.ListAssignees(ctx, projectID, orgA.ID)
		if err != nil {
			t.Fatalf("assignees: %v", err)
		}
		count := map[string]int{}
		for _, r := range rows {
			count[r.FullName]++
			if r.FullName == "Seçici Kişi" && (r.ID != before.ID || !r.HasAccount) {
				t.Errorf("aynı adlı personel hesapla tek satır olmalı: %+v", r)
			}
			if r.FullName == "Yepyeni Kişi" && !r.HasAccount {
				t.Errorf("yeni hesabın personeli hesabıyla görünmeli: %+v", r)
			}
		}
		if count["Seçici Kişi"] != 1 || count["Yepyeni Kişi"] != 1 {
			t.Fatalf("kişi başına tek satır: %v", count)
		}
	})

	t.Run("deactivate_keeps_personnel_and_link", func(t *testing.T) {
		u, link := newMember(t, orgA.ID, "pl_pasif", "Pasif Hesap", manage)
		if _, err := userSvc.Update(ctx, u.ID, orgA.ID, owner.ID, "Pasif Hesap", false); err != nil {
			t.Fatalf("pasifleştir: %v", err)
		}
		e, err := employeeSvc.Get(ctx, link.EmployeeID, orgA.ID)
		if err != nil {
			t.Fatalf("personel silindi: %v", err)
		}
		if !e.IsActive || e.UserID == nil || *e.UserID != u.ID {
			t.Fatalf("personel aktif ve bağlı kalmalı: aktif=%v bağ=%v", e.IsActive, e.UserID)
		}
		if e.LoginUsername != "pl_pasif" || e.LoginActive {
			t.Errorf("personel bağlı hesabın pasif olduğunu göstermeli: %q aktif=%v", e.LoginUsername, e.LoginActive)
		}
		u2, link2 := newMember(t, orgA.ID, "pl_sil", "Silinen Hesap", manage)
		if err := userSvc.Deactivate(ctx, u2.ID, orgA.ID, owner.ID); err != nil {
			t.Fatalf("deactivate: %v", err)
		}
		if _, err := employeeSvc.Get(ctx, link2.EmployeeID, orgA.ID); err != nil {
			t.Fatalf("personel silindi: %v", err)
		}
		rows, err := projectSvc.ListAssignees(ctx, projectID, orgA.ID)
		if err != nil {
			t.Fatalf("assignees: %v", err)
		}
		for _, r := range rows {
			if (r.FullName == "Pasif Hesap" || r.FullName == "Silinen Hesap") && r.HasAccount {
				t.Errorf("pasif hesap 'uygulaması yok' sayılmalı: %+v", r)
			}
		}
	})

	t.Run("payroll_and_attendance_handle_wageless_personnel", func(t *testing.T) {
		_, link := newMember(t, orgA.ID, "pl_ucretsiz", "Ücretsiz Kişi", manage)
		if _, err := attendanceSvc.Create(ctx, orgA.ID, service.AttendanceInput{EmployeeID: link.EmployeeID, Date: service.IstanbulToday(), Status: domain.AttendanceGeldi, WorkHours: 8}); err != nil {
			t.Fatalf("ücretsiz personele mesai girilemedi: %v", err)
		}
		period := service.IstanbulNow(time.Now()).Format("2006-01")
		rows, err := payrollSvc.Summary(ctx, orgA.ID, period)
		if err != nil {
			t.Fatalf("maaş özeti: %v", err)
		}
		found := false
		for _, r := range rows {
			if r.EmployeeID != link.EmployeeID {
				continue
			}
			found = true
			if r.WageBasis != domain.WageBasisNone || r.Earned != 0 || r.WorkedDays != 1 {
				t.Errorf("ücret tanımsız satır: esas=%q hakediş=%v gün=%v", r.WageBasis, r.Earned, r.WorkedDays)
			}
		}
		if !found {
			t.Fatal("otomatik personel maaş listesinde yok")
		}
		if _, err := payrollSvc.Statement(ctx, orgA.ID, link.EmployeeID, period); err != nil {
			t.Fatalf("ücretsiz personelin dökümü alınamadı: %v", err)
		}
		if _, err := attendanceSvc.ListByMonth(ctx, orgA.ID, service.IstanbulToday()); err != nil {
			t.Fatalf("mesai listesi: %v", err)
		}
	})

	t.Run("link_suggestions_exact_unique_names_only", func(t *testing.T) {
		// Personelsiz hesaplar (bootstrap yolu personel açmaz).
		if _, err := userSvc.Create(ctx, orgA.ID, "pl_selin", "GeciciSifre123!", "Selin Ay", domain.RoleKullanici, domain.OrgRoleField); err != nil {
			t.Fatalf("user: %v", err)
		}
		if _, err := userSvc.Create(ctx, orgA.ID, "pl_kisa", "GeciciSifre123!", "batu kısa", domain.RoleKullanici, domain.OrgRoleField); err != nil {
			t.Fatalf("user: %v", err)
		}
		selinEmp := newEmployee(t, orgA.ID, "SELİN AY")
		newEmployee(t, orgA.ID, "Batu Uzun Ad")
		got, err := employeeSvc.LinkSuggestions(ctx, orgA.ID)
		if err != nil {
			t.Fatalf("suggestions: %v", err)
		}
		if len(got) != 1 || got[0].EmployeeID != selinEmp.ID || got[0].Username != "pl_selin" {
			t.Fatalf("yalnızca birebir aynı ad önerilmeli: %+v", got)
		}
		// Öneri bağlamaz.
		if e, _ := employeeSvc.Get(ctx, selinEmp.ID, orgA.ID); e.UserID != nil {
			t.Fatal("öneri listesi kendiliğinden bağladı")
		}
	})
}

// newLinkProject, teklif -> kabul -> proje akışıyla bir proje açar
// (ListAssignees projeyi doğrular).
func newLinkProject(t *testing.T, ctx context.Context, offerSvc *service.OfferService, projectSvc *service.ProjectService, orgID string) string {
	t.Helper()
	o, err := offerSvc.Create(ctx, service.CreateOfferInput{
		OrganizationID: orgID,
		CustomerName:   "Musteri",
		Items:          []service.OfferItemInput{{ProductName: "Is", Quantity: 1, UnitPrice: 1000}},
	})
	if err != nil {
		t.Fatalf("offer: %v", err)
	}
	if _, err := offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, ""); err != nil {
		t.Fatalf("send: %v", err)
	}
	link, err := offerSvc.CreateShareLink(ctx, o.ID, orgID, "", nil)
	if err != nil {
		t.Fatalf("link: %v", err)
	}
	if _, err := offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
		t.Fatalf("accept: %v", err)
	}
	p, err := projectSvc.CreateFromOffer(ctx, o.ID, orgID, service.CreateProjectInput{Name: "Seçici Projesi"})
	if err != nil {
		t.Fatalf("project: %v", err)
	}
	return p.ID
}

// TestPlatformProvisionCreatesPersonnel: Süper Admin'in firmaya kullanıcı
// eklemesi de aynı kuralı izler (dondurulmuş web hiçbir yeni alan
// göndermeden personel kaydını alır); ilk Sahip (Yeni Firma) BİLEREK
// personel açmaz.
func TestPlatformProvisionCreatesPersonnel(t *testing.T) {
	dbURL := testDBURL(t)
	ctx := context.Background()
	pool, err := repository.NewPool(ctx, dbURL)
	if err != nil {
		t.Fatalf("db: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	q := sqlc.New(pool)
	platformSvc, _ := newPlatformTestServices(q, pool)

	const slug = "platform-person-link"
	usernames := []string{"ppl_owner", "ppl_field", "ppl_office"}
	cleanupPlatformSlug(t, ctx, pool, slug, usernames)
	created, err := platformSvc.CreateOrganizationWithOwner(ctx, service.CreateOrganizationInput{
		Name: "Platform Kişi", Slug: slug,
		OwnerUsername: "ppl_owner", OwnerPassword: "GecicSifre123!", OwnerFullName: "Firma Sahibi",
	})
	if err != nil {
		t.Fatalf("org: %v", err)
	}
	orgID := created.Organization.ID
	t.Cleanup(func() { cleanupPlatformOrg(t, pool, orgID) })
	oid, _ := repository.StringToUUID(orgID)

	hasEmployee := func(userID string) bool {
		uid, _ := repository.StringToUUID(userID)
		_, err := q.GetEmployeeByUserID(ctx, sqlc.GetEmployeeByUserIDParams{UserID: uid, OrganizationID: oid})
		return err == nil
	}
	if hasEmployee(created.Owner.ID) {
		t.Error("ilk Sahip için personel açılmamalı (bilinçli kapsam dışı)")
	}

	u, link, err := platformSvc.ProvisionOrganizationUser(ctx, service.ProvisionOrganizationUserInput{
		OrganizationID: orgID, Username: "ppl_field", FullName: "Saha Kişisi", TemporaryPassword: "GecicSifre123!", RoleCode: domain.OrgRoleField,
	})
	if err != nil {
		t.Fatalf("provision: %v", err)
	}
	if link.Status != service.EmployeeLinkCreated || !hasEmployee(u.ID) {
		t.Fatalf("varsayılan personel açmalı: %+v", link)
	}
	no := false
	u2, link2, err := platformSvc.ProvisionOrganizationUser(ctx, service.ProvisionOrganizationUserInput{
		OrganizationID: orgID, Username: "ppl_office", FullName: "Ofis Kişisi", TemporaryPassword: "GecicSifre123!", RoleCode: domain.OrgRoleFinance,
		Personnel: service.PersonnelOptions{CreateEmployee: &no},
	})
	if err != nil {
		t.Fatalf("provision: %v", err)
	}
	if link2.Status != service.EmployeeLinkSkipped || hasEmployee(u2.ID) {
		t.Fatalf("create_employee=false personel açmamalı: %+v", link2)
	}
}

func cleanupPlatformSlug(t *testing.T, ctx context.Context, pool *pgxpool.Pool, slug string, usernames []string) {
	t.Helper()
	var existingID string
	if err := pool.QueryRow(ctx, "SELECT id FROM organizations WHERE slug = $1", slug).Scan(&existingID); err == nil {
		cleanupPlatformOrg(t, pool, existingID)
	}
	_, _ = pool.Exec(ctx, "DELETE FROM users WHERE username = ANY($1::text[])", usernames)
}
