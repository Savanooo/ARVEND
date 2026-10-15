package middleware_test

// 2026-10 modülleri -- izin kapıları GERÇEK router'a karşı:
//
//	teklif silme talebi (0067): offers.delete direkt siler ve karar verir;
//	    offers.create/update talep açar; teklif izni olmayan hiçbirini yapamaz
//	genel masraf (0068): herkes girer; GET /expenses finans okuyanlara herkesi
//	    toplamlarla, diğerlerine yalnızca kendini döner; kararı yalnızca
//	    Sahip/Yönetici verir
//	Taşeronlar (0069): liste tedarikçi okuma, kart açma tedarikçi yönetme,
//	    ödeme defteri finans okuma, proje dışı ödeme finans yönetme
//	proje silme (0070): projects.delete (Sahip/Yönetici) direkt siler ve
//	    karar verir; projeyi düzenleyebilen (üyesi olduğu projede) talep açar
//
// Her biri başka firmanın kaydına dokunamaz.

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// mustCreateCustomRoleUser: verilen izinlerle özel (sistem dışı) bir rol ve o
// roldeki kullanıcıyı açar.
func mustCreateCustomRoleUser(t *testing.T, ctx context.Context, d *rbacTestDeps, orgID, username, roleCode string, perms []string) (*domain.User, string) {
	t.Helper()
	var roleID string
	if err := d.pool.QueryRow(ctx,
		`INSERT INTO organization_roles (organization_id, code, name, description, is_system)
		 VALUES ($1, $2, $3, '', false) RETURNING id::text`, orgID, roleCode, roleCode).Scan(&roleID); err != nil {
		t.Fatalf("özel rol açılamadı: %v", err)
	}
	for _, p := range perms {
		if _, err := d.pool.Exec(ctx,
			`INSERT INTO role_permissions (organization_role_id, permission_code) VALUES ($1, $2)`, roleID, p); err != nil {
			t.Fatalf("izin (%s) verilemedi: %v", p, err)
		}
	}
	return mustCreateRoleUser(t, ctx, d, orgID, username, roleCode)
}

func TestNewModulesSecurity(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "new-modules-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgB := mustCreateReadyOrg(t, ctx, d, "new-modules-org-b")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, orgB.Organization.ID) })
	orgID := org.Organization.ID

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatal(err)
	}
	ownerBToken, err := d.issuer.IssueAccessToken(orgB.Owner.ID, domain.RoleAdmin, orgB.Organization.ID)
	if err != nil {
		t.Fatal(err)
	}
	_, adminToken := mustCreateRoleUser(t, ctx, d, orgID, "nm_admin", domain.OrgRoleAdmin)
	finUser, finToken := mustCreateRoleUser(t, ctx, d, orgID, "nm_fin", domain.OrgRoleFinance)
	_, legacyToken := mustCreateRoleUser(t, ctx, d, orgID, "nm_legacy", domain.OrgRoleLegacyUser)
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, orgID, "nm_pm", domain.OrgRoleProjectManager)
	fieldUser, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "nm_field", domain.OrgRoleField)
	_, salesToken := mustCreateCustomRoleUser(t, ctx, d, orgID, "nm_sales", "satis",
		[]string{domain.PermOffersRead, domain.PermOffersCreate, domain.PermOffersUpdate})

	newOffer := func(t *testing.T) string {
		t.Helper()
		o, err := d.offerSvc.Create(ctx, service.CreateOfferInput{
			OrganizationID: orgID, CustomerName: "Müşteri",
			Items: []service.OfferItemInput{{ProductName: "Kalem", Quantity: 1, UnitPrice: 100}},
		})
		if err != nil {
			t.Fatal(err)
		}
		return o.ID
	}
	member := func(t *testing.T, projectID string, userIDs ...string) {
		t.Helper()
		for _, u := range userIDs {
			if _, err := d.authzSvc.AddProjectUser(ctx, projectID, orgID, service.ProjectUserInput{
				UserID: u, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
			}); err != nil {
				t.Fatalf("üyelik eklenemedi: %v", err)
			}
		}
	}
	status := func(t *testing.T, method, path, token, body string, want int) map[string]any {
		t.Helper()
		rec, resp := rbacDo(t, d.router, method, path, token, body)
		if rec.Code != want {
			t.Errorf("%s %s: %d (beklenen %d) %v", method, path, rec.Code, want, resp)
		}
		return resp
	}

	t.Run("teklif_silme_talebi", func(t *testing.T) {
		o := newOffer(t)
		base := "/api/v1/offers/" + o
		// Teklif izni olmayan hiçbir şey yapamaz.
		status(t, http.MethodPost, base+"/delete-request", fieldToken, `{}`, http.StatusForbidden)
		status(t, http.MethodPost, base+"/delete-request", pmToken, `{}`, http.StatusForbidden)
		// Satış (create/update, delete yok): talep açar, direkt silemez, karar veremez.
		status(t, http.MethodDelete, base, salesToken, "", http.StatusForbidden)
		status(t, http.MethodPost, base+"/delete-request", salesToken, `{"reason":"yanlış"}`, http.StatusCreated)
		status(t, http.MethodPost, base+"/delete-request/approve", salesToken, "", http.StatusForbidden)
		status(t, http.MethodGet, "/api/v1/offers/delete-requests", salesToken, "", http.StatusForbidden)
		// Yetkili listede görür, detayda talep gelir.
		list := status(t, http.MethodGet, "/api/v1/offers/delete-requests", ownerToken, "", http.StatusOK)
		if rows, _ := list["data"].([]any); len(rows) == 0 {
			t.Errorf("onay listesi boş: %v", list)
		}
		detail := status(t, http.MethodGet, base, ownerToken, "", http.StatusOK)
		if detail["delete_request"] == nil {
			t.Errorf("detayda bekleyen talep yok: %v", detail)
		}
		// Başka firma karar veremez.
		rec, _ := rbacDo(t, d.router, http.MethodPost, base+"/delete-request/approve", ownerBToken, "")
		if rec.Code == http.StatusOK {
			t.Error("başka firmanın sahibi talebi onaylayabildi")
		}
		status(t, http.MethodPost, base+"/delete-request/approve", adminToken, "", http.StatusOK)
		status(t, http.MethodGet, base, ownerToken, "", http.StatusNotFound)
		// Eski Sistem rolü (offers.delete) direkt siler -- ürün sahibinin kararı.
		o2 := newOffer(t)
		status(t, http.MethodDelete, "/api/v1/offers/"+o2, legacyToken, "", http.StatusOK)
	})

	t.Run("genel_masraf_ve_masraflar_listesi", func(t *testing.T) {
		const body = `{"category":"transport","description":"Yakıt","amount":1200,"expense_date":"2026-10-15","vat_rate":20}`
		created := status(t, http.MethodPost, "/api/v1/expenses/general", fieldToken, body, http.StatusCreated)
		id, _ := created["id"].(string)
		if created["project_id"] != "" || created["approval_status"] != domain.ExpenseApprovalPending || created["currency"] != "TRY" {
			t.Fatalf("genel masraf alanları: %v", created)
		}
		// Proje bağı reddedilir.
		status(t, http.MethodPost, "/api/v1/expenses/general", ownerToken,
			strings.Replace(body, `"vat_rate":20`, `"vat_rate":20,"cost_code_id":"00000000-0000-0000-0000-000000000001"`, 1),
			http.StatusBadRequest)
		// Saha yalnızca kendi masraflarını, toplamsız görür.
		mine := status(t, http.MethodGet, "/api/v1/expenses", fieldToken, "", http.StatusOK)
		if mine["can_see_all"] != false || mine["totals"] != nil {
			t.Errorf("saha toplam/hepsini görmemeli: %v", mine)
		}
		for _, r := range mine["expenses"].([]any) {
			if r.(map[string]any)["created_by"] != fieldUser.ID {
				t.Errorf("başkasının masrafı göründü: %v", r)
			}
		}
		// Finans herkesi toplamlarla görür.
		all := status(t, http.MethodGet, "/api/v1/expenses?kind=general", finToken, "", http.StatusOK)
		if all["can_see_all"] != true || all["totals"] == nil {
			t.Errorf("finans hepsini toplamla görmeli: %v", all)
		}
		found := false
		for _, r := range all["expenses"].([]any) {
			if r.(map[string]any)["id"] == id {
				found = true
			}
		}
		if !found {
			t.Error("finans sahanın genel masrafını görmeli")
		}
		status(t, http.MethodGet, "/api/v1/expenses?kind=zzz", finToken, "", http.StatusBadRequest)
		// Başkası düzeltemez; kendisi düzeltir.
		other := status(t, http.MethodPost, "/api/v1/expenses/general", pmToken, body, http.StatusCreated)
		status(t, http.MethodPut, "/api/v1/expenses/general/"+other["id"].(string), fieldToken, body, http.StatusConflict)
		status(t, http.MethodPut, "/api/v1/expenses/general/"+id, fieldToken,
			strings.Replace(body, `"amount":1200`, `"amount":1300`, 1), http.StatusOK)
		// Karar: saha ve finans veremez, yönetici verir; başka firma bulamaz.
		status(t, http.MethodPost, "/api/v1/expenses/general/"+id+"/approve", fieldToken, "", http.StatusForbidden)
		status(t, http.MethodPost, "/api/v1/expenses/general/"+id+"/approve", finToken, "", http.StatusForbidden)
		status(t, http.MethodPost, "/api/v1/expenses/general/"+id+"/approve", ownerBToken, "", http.StatusNotFound)
		status(t, http.MethodPost, "/api/v1/expenses/general/"+id+"/approve", adminToken, "", http.StatusOK)
		// Genel masraf proje uçlarından açılmaz.
		pA := mustCreateProject(t, ctx, d, orgID, "Masraf Projesi")
		status(t, http.MethodPost, "/api/v1/projects/"+pA.ID+"/expenses/"+id+"/approve", ownerToken, "", http.StatusNotFound)
	})

	t.Run("taseronlar", func(t *testing.T) {
		// Saha tedarikçi okuyamaz; PM okur ama toplam görmez, kart açamaz.
		status(t, http.MethodGet, "/api/v1/subcontractors", fieldToken, "", http.StatusForbidden)
		pmList := status(t, http.MethodGet, "/api/v1/subcontractors", pmToken, "", http.StatusOK)
		if pmList["can_see_totals"] != false {
			t.Errorf("PM toplam görmemeli: %v", pmList)
		}
		status(t, http.MethodPost, "/api/v1/subcontractors", pmToken, `{"legal_name":"PM Usta"}`, http.StatusForbidden)
		card := status(t, http.MethodPost, "/api/v1/subcontractors", finToken, `{"legal_name":"Elektrikçi Hasan"}`, http.StatusCreated)
		cardID, _ := card["id"].(string)
		if card["is_subcontractor"] != true || !strings.HasPrefix(card["code"].(string), "TSR-") {
			t.Fatalf("kart: %v", card)
		}
		// Defter finans okuma ister; ödeme finans yönetme.
		status(t, http.MethodGet, "/api/v1/subcontractors/"+cardID+"/ledger", pmToken, "", http.StatusForbidden)
		status(t, http.MethodGet, "/api/v1/subcontractors/"+cardID+"/ledger", finToken, "", http.StatusOK)
		const pay = `{"amount":1500,"paid_date":"2026-10-15","description":"Depo","idempotency_key":"nm-dp-1"}`
		status(t, http.MethodPost, "/api/v1/subcontractors/"+cardID+"/payments", pmToken, pay, http.StatusForbidden)
		p := status(t, http.MethodPost, "/api/v1/subcontractors/"+cardID+"/payments", finToken, pay, http.StatusCreated)
		status(t, http.MethodPost, "/api/v1/subcontractors/"+cardID+"/payments/"+p["id"].(string)+"/void", pmToken, `{}`, http.StatusForbidden)
		// Başka firma kartı göremez, ödeme giremez.
		status(t, http.MethodGet, "/api/v1/subcontractors/"+cardID+"/ledger", ownerBToken, "", http.StatusNotFound)
		status(t, http.MethodPost, "/api/v1/subcontractors/"+cardID+"/payments", ownerBToken,
			strings.Replace(pay, "nm-dp-1", "nm-dp-2", 1), http.StatusNotFound)
		// Projede karttan taşeron: kart bağlanır, ad karttan gelir.
		pT := mustCreateProject(t, ctx, d, orgID, "Taşeron Projesi")
		member(t, pT.ID, finUser.ID)
		sub := status(t, http.MethodPost, "/api/v1/projects/"+pT.ID+"/subcontractors", finToken,
			`{"supplier_id":"`+cardID+`","contract_amount":5000,"currency":"TRY"}`, http.StatusCreated)
		if sub["supplier_id"] != cardID || sub["name"] != "Elektrikçi Hasan" {
			t.Errorf("proje taşeronu karta bağlanmalı: %v", sub)
		}
		ledger := status(t, http.MethodGet, "/api/v1/subcontractors/"+cardID+"/ledger", ownerToken, "", http.StatusOK)
		if eng, _ := ledger["engagements"].([]any); len(eng) != 1 {
			t.Errorf("defterde projedeki iş görünmeli: %v", ledger["engagements"])
		}
		// Listede kalan borç yalnızca finans okuyana.
		finList := status(t, http.MethodGet, "/api/v1/subcontractors", finToken, "", http.StatusOK)
		for _, r := range finList["subcontractors"].([]any) {
			c := r.(map[string]any)
			if c["id"] == cardID && c["remaining_totals"] == nil {
				t.Errorf("finans kalan borcu görmeli: %v", c)
			}
		}
		for _, r := range status(t, http.MethodGet, "/api/v1/subcontractors", pmToken, "", http.StatusOK)["subcontractors"].([]any) {
			if c := r.(map[string]any); c["remaining_totals"] != nil || c["paid_totals"] != nil {
				t.Errorf("PM tutar görmemeli: %v", c)
			}
		}
	})

	t.Run("gunluk_rapor", func(t *testing.T) {
		pR := mustCreateProject(t, ctx, d, orgID, "Rapor Projesi")
		pOther := mustCreateProject(t, ctx, d, orgID, "Rapor Projesi (üye değil)")
		member(t, pR.ID, fieldUser.ID, pmUser.ID, finUser.ID)
		card := status(t, http.MethodPost, "/api/v1/subcontractors", finToken, `{"legal_name":"Kalıpçı Veli"}`, http.StatusCreated)
		cardID, _ := card["id"].(string)
		today := service.IstanbulToday().Format("2006-01-02")
		base := "/api/v1/projects/" + pR.ID + "/daily-reports"
		body := `{"weather":"sunny","temperature_c":21,"own_workers":4,"work_done":"Kalıp","subcontractors":[{"supplier_id":"` + cardID + `","workers":3}]}`

		// Operasyon izni olmayan (finans, satış) göremez/yazamaz; üye olmayan saha da.
		status(t, http.MethodGet, base, finToken, "", http.StatusForbidden)
		status(t, http.MethodPut, base+"/"+today, finToken, body, http.StatusForbidden)
		status(t, http.MethodGet, base, salesToken, "", http.StatusForbidden)
		status(t, http.MethodGet, "/api/v1/projects/"+pOther.ID+"/daily-reports/"+today, fieldToken, "", http.StatusForbidden)
		// Yazılmamış gün 200 + exists=false; tarih biçimi ve ileri tarih 400.
		empty := status(t, http.MethodGet, base+"/"+today, fieldToken, "", http.StatusOK)
		if empty["exists"] != false {
			t.Errorf("yazılmamış gün: %v", empty)
		}
		status(t, http.MethodGet, base+"/15.10.2026", fieldToken, "", http.StatusBadRequest)
		status(t, http.MethodPut, base+"/2099-01-01", fieldToken, body, http.StatusBadRequest)
		status(t, http.MethodPut, base+"/"+today, fieldToken, `{"weather":`, http.StatusBadRequest)
		// Saha yazar ve gönderir; ikinci gönderim 409.
		saved := status(t, http.MethodPut, base+"/"+today, fieldToken, body, http.StatusOK)
		if saved["exists"] != true || saved["status"] != "draft" {
			t.Fatalf("kayıt: %v", saved)
		}
		if subs, _ := saved["subcontractors"].([]any); len(subs) != 1 {
			t.Errorf("taşeron satırı: %v", saved["subcontractors"])
		}
		// Saha tedarikçi listesini okuyamaz; seçici rapordaki seçeneklerden dolar.
		again := status(t, http.MethodGet, base+"/"+today, fieldToken, "", http.StatusOK)
		if opts, _ := again["subcontractor_options"].([]any); len(opts) != 1 {
			t.Errorf("sahaya taşeron seçenekleri gelmeli: %v", again["subcontractor_options"])
		}
		status(t, http.MethodPost, base+"/"+today+"/submit", fieldToken, "", http.StatusOK)
		status(t, http.MethodPost, base+"/"+today+"/submit", pmToken, "", http.StatusConflict)
		list := status(t, http.MethodGet, base, pmToken, "", http.StatusOK)
		if rows, _ := list["reports"].([]any); len(rows) != 1 {
			t.Errorf("liste: %v", list)
		}
		// PDF.
		rec, _ := rbacDo(t, d.router, http.MethodGet, base+"/"+today+"/pdf", pmToken, "")
		if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "application/pdf" || !strings.HasPrefix(rec.Body.String(), "%PDF") {
			t.Errorf("PDF: %d %s", rec.Code, rec.Header().Get("Content-Type"))
		}
		// Başka firma hiçbir şeye ulaşamaz.
		for _, c := range []struct{ method, path, body string }{
			{http.MethodGet, base, ""},
			{http.MethodGet, base + "/" + today, ""},
			{http.MethodPut, base + "/" + today, body},
			{http.MethodGet, base + "/" + today + "/pdf", ""},
		} {
			if rec, _ := rbacDo(t, d.router, c.method, c.path, ownerBToken, c.body); rec.Code == http.StatusOK {
				t.Errorf("başka firma %s %s: 200", c.method, c.path)
			}
		}
		// Başka firmanın kartı rapora eklenemez.
		cardB := status(t, http.MethodPost, "/api/v1/subcontractors", ownerBToken, `{"legal_name":"B Usta"}`, http.StatusCreated)
		status(t, http.MethodPut, base+"/"+today, fieldToken,
			strings.Replace(body, cardID, cardB["id"].(string), 1), http.StatusNotFound)
		// Taşeronun sayfasında sahada çalıştığı gün.
		ledger := status(t, http.MethodGet, "/api/v1/subcontractors/"+cardID+"/ledger", finToken, "", http.StatusOK)
		days, _ := ledger["site_days"].([]any)
		if len(days) != 1 || days[0].(map[string]any)["report_date"] != today {
			t.Errorf("sahadaki günler: %v", ledger["site_days"])
		}
	})

	t.Run("proje_silme", func(t *testing.T) {
		pA := mustCreateProject(t, ctx, d, orgID, "Silinecek A")
		pB := mustCreateProject(t, ctx, d, orgID, "Silinecek B (üye değil)")
		member(t, pA.ID, pmUser.ID, fieldUser.ID)
		base := "/api/v1/projects/" + pA.ID
		// Saha projeyi düzenleyemez -> talep açamaz; PM üyesi olmadığı projede açamaz.
		status(t, http.MethodPost, base+"/delete-request", fieldToken, `{}`, http.StatusForbidden)
		status(t, http.MethodPost, "/api/v1/projects/"+pB.ID+"/delete-request", pmToken, `{}`, http.StatusForbidden)
		// PM: direkt silemez, karar veremez, talep açar.
		status(t, http.MethodDelete, base, pmToken, "", http.StatusForbidden)
		status(t, http.MethodPost, base+"/delete-request", pmToken, `{"reason":"yanlış"}`, http.StatusCreated)
		status(t, http.MethodPost, base+"/delete-request/approve", pmToken, "", http.StatusForbidden)
		status(t, http.MethodGet, "/api/v1/projects/delete-requests", pmToken, "", http.StatusForbidden)
		// Eski Sistem rolü projects.delete almaz.
		status(t, http.MethodDelete, "/api/v1/projects/"+pB.ID, legacyToken, "", http.StatusForbidden)
		detail := status(t, http.MethodGet, base, ownerToken, "", http.StatusOK)
		if detail["delete_request"] == nil {
			t.Errorf("detayda bekleyen talep yok: %v", detail)
		}
		status(t, http.MethodGet, "/api/v1/projects/delete-requests", ownerToken, "", http.StatusOK)
		status(t, http.MethodPost, base+"/delete-request/approve", ownerBToken, "", http.StatusNotFound)
		status(t, http.MethodPost, base+"/delete-request/approve", adminToken, "", http.StatusOK)
		status(t, http.MethodGet, base, ownerToken, "", http.StatusNotFound)

		// Masrafı olan proje silinmez (409, neden yazılı).
		pC := mustCreateProject(t, ctx, d, orgID, "Masraflı Proje")
		status(t, http.MethodPost, "/api/v1/projects/"+pC.ID+"/expenses", ownerToken,
			`{"category":"material","description":"Çimento","amount":500,"expense_date":"2026-10-15"}`, http.StatusCreated)
		resp := status(t, http.MethodDelete, "/api/v1/projects/"+pC.ID, ownerToken, "", http.StatusConflict)
		if msg, _ := resp["error"].(string); !strings.Contains(msg, "masraf") {
			t.Errorf("409 nedeni söylemeli: %v", resp)
		}
		// Boş proje yöneticiyle direkt silinir; başka firma silemez.
		status(t, http.MethodDelete, "/api/v1/projects/"+pB.ID, ownerBToken, "", http.StatusNotFound)
		status(t, http.MethodDelete, "/api/v1/projects/"+pB.ID, adminToken, "", http.StatusOK)
	})
}
