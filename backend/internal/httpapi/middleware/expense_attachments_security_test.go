package middleware_test

// Genel masrafın görünürlüğü ve masraf fişi / belgesi (migration 0076) --
// izin kapıları GERÇEK router'a karşı:
//
//	GET /expenses/mine: kişinin genel (projesiz) masrafları da (is_general)
//	GET /expenses: finans okuyan "all" (toplamlarla); finans okuması olmayan
//	    onaylayıcı "approver" (kendi + karar verebilecekleri, toplam yok);
//	    diğerleri "mine"
//	belge: masrafı giren ve finance.manage ekler/siler (yalnızca bekleyen/
//	    reddedilen masrafta); okuma masrafı okuyabilene (onaylayıcı dahil);
//	    proje üyeliği projeli uçlarda; başka firma hiçbir şeye ulaşamaz

import (
	"bytes"
	"context"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func TestExpenseAttachmentsSecurity(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "expense-att-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgB := mustCreateReadyOrg(t, ctx, d, "expense-att-org-b")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, orgB.Organization.ID) })
	orgID := org.Organization.ID

	ownerBToken, err := d.issuer.IssueAccessToken(orgB.Owner.ID, domain.RoleAdmin, orgB.Organization.ID)
	if err != nil {
		t.Fatalf("B owner token üretilemedi: %v", err)
	}
	_, adminToken := mustCreateRoleUser(t, ctx, d, orgID, "eatt_admin", domain.OrgRoleAdmin)
	finUser, finToken := mustCreateRoleUser(t, ctx, d, orgID, "eatt_fin", domain.OrgRoleFinance)
	fieldUser, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "eatt_field", domain.OrgRoleField)
	field2User, field2Token := mustCreateRoleUser(t, ctx, d, orgID, "eatt_field2", domain.OrgRoleField)
	// Onaylayıcı, finans okuması yok: Saha rolü + kişiye özel onay izni.
	apprUser, apprToken := mustCreateRoleUser(t, ctx, d, orgID, "eatt_approver", domain.OrgRoleField)
	if _, err := d.pool.Exec(ctx, `INSERT INTO user_permission_overrides (user_id, organization_id, permission_code, effect)
		VALUES ($1, $2, $3, 'grant')`, apprUser.ID, orgID, domain.PermProjectsExpensesApprove); err != nil {
		t.Fatalf("onay izni verilemedi: %v", err)
	}

	pA := mustCreateProject(t, ctx, d, orgID, "Belge A (üye)")
	pB := mustCreateProject(t, ctx, d, orgID, "Belge B (üye değil)")
	for _, u := range []string{finUser.ID, fieldUser.ID, field2User.ID, apprUser.ID} {
		if _, err := d.authzSvc.AddProjectUser(ctx, pA.ID, orgID, service.ProjectUserInput{
			UserID: u, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik eklenemedi: %v", err)
		}
	}

	const body = `{"category":"food","description":"Yemek fişi","amount":320,"currency":"TRY","expense_date":"2026-10-28","vat_rate":10}`
	create := func(t *testing.T, path, token string) string {
		t.Helper()
		rec, b := rbacDo(t, d.router, http.MethodPost, path, token, body)
		if rec.Code != http.StatusCreated {
			t.Fatalf("masraf girilemedi (%s): %d %v", path, rec.Code, b)
		}
		return b["id"].(string)
	}
	png := func(seed byte) []byte {
		return append([]byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}, bytes.Repeat([]byte{seed}, 64)...)
	}
	upload := func(t *testing.T, path, token, name string, content []byte) (int, map[string]any) {
		t.Helper()
		var buf bytes.Buffer
		mw := multipart.NewWriter(&buf)
		fw, _ := mw.CreateFormFile("file", name)
		_, _ = fw.Write(content)
		_ = mw.Close()
		req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(buf.Bytes()))
		req.Header.Set("Content-Type", mw.FormDataContentType())
		req.AddCookie(&http.Cookie{Name: "access_token", Value: token})
		rr := httptest.NewRecorder()
		d.router.ServeHTTP(rr, req)
		var parsed map[string]any
		_ = json.Unmarshal(rr.Body.Bytes(), &parsed)
		return rr.Code, parsed
	}
	rows := func(b map[string]any) map[string]map[string]any {
		out := map[string]map[string]any{}
		list, _ := b["expenses"].([]any)
		for _, x := range list {
			m := x.(map[string]any)
			out[m["id"].(string)] = m
		}
		return out
	}

	generalID := create(t, "/api/v1/expenses/general", fieldToken)
	projectID := create(t, "/api/v1/projects/"+pA.ID+"/expenses", fieldToken)
	generalAtt := "/api/v1/expenses/general/" + generalID + "/attachments"
	projectAtt := "/api/v1/projects/" + pA.ID + "/expenses/" + projectID + "/attachments"

	t.Run("01_my_expenses_includes_general", func(t *testing.T) {
		rec, b := rbacDo(t, d.router, http.MethodGet, "/api/v1/expenses/mine", fieldToken, "")
		if rec.Code != http.StatusOK {
			t.Fatalf("Masraflarım: %d %v", rec.Code, b)
		}
		got := rows(b)
		g, ok := got[generalID]
		if !ok || g["is_general"] != true || g["project_id"] != "" || g["project_name"] != "" {
			t.Fatalf("genel masraf Masraflarım'da projesiz görünmeli: %v", g)
		}
		if att, ok := g["attachments"].([]any); !ok || len(att) != 0 {
			t.Errorf("liste satırı attachments: [] taşımalı: %v", g["attachments"])
		}
		if p, ok := got[projectID]; !ok || p["is_general"] != false {
			t.Errorf("projeli masraf da görünmeli: %v", p)
		}
	})

	var attID string
	t.Run("02_creator_uploads_and_reads", func(t *testing.T) {
		code, b := upload(t, generalAtt, fieldToken, "fis.png", png(1))
		if code != http.StatusCreated || b["mime_type"] != "image/png" || b["original_name"] != "fis.png" {
			t.Fatalf("giren fiş eklemeli: %d %v", code, b)
		}
		attID = b["id"].(string)
		if code, b := upload(t, generalAtt, fieldToken, "fis.png", png(1)); code != http.StatusOK || b["id"] != attID {
			t.Errorf("aynı içerik 200 + mevcut kayıt dönmeli: %d %v", code, b)
		}
		if code, b := upload(t, generalAtt, fieldToken, "not.txt", []byte("düz metin")); code != http.StatusBadRequest {
			t.Errorf("metin dosyası 400 olmalı: %d %v", code, b)
		}
		if code, _ := upload(t, projectAtt, fieldToken, "irsaliye.png", png(2)); code != http.StatusCreated {
			t.Errorf("projeli masrafa fiş eklenmeli: %d", code)
		}
		rec, b := rbacDo(t, d.router, http.MethodGet, generalAtt, fieldToken, "")
		if list, _ := b["attachments"].([]any); rec.Code != http.StatusOK || len(list) != 1 {
			t.Fatalf("belge listesi: %d %v", rec.Code, b)
		}
		rr, _ := rbacDo(t, d.router, http.MethodGet, generalAtt+"/"+attID+"/content", fieldToken, "")
		if rr.Code != http.StatusOK || rr.Header().Get("Content-Type") != "image/png" ||
			rr.Header().Get("X-Content-Type-Options") != "nosniff" || !bytes.Equal(rr.Body.Bytes(), png(1)) {
			t.Errorf("fiş indirilmeli: %d %s", rr.Code, rr.Header().Get("Content-Type"))
		}
		// Kimliksiz istek 401.
		if rr, _ := rbacDo(t, d.router, http.MethodGet, generalAtt+"/"+attID+"/content", "", ""); rr.Code != http.StatusUnauthorized {
			t.Errorf("oturumsuz indirme 401 olmalı: %d", rr.Code)
		}
		// Finans listesi belgeleri taşır.
		rec, b = rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/expenses", finToken, "")
		for _, x := range b["expenses"].([]any) {
			m := x.(map[string]any)
			if m["id"] == projectID {
				if list, _ := m["attachments"].([]any); len(list) != 1 {
					t.Errorf("Finans listesindeki masraf belgesini taşımalı: %v", m["attachments"])
				}
			}
		}
		if rec.Code != http.StatusOK {
			t.Errorf("finans listesi: %d", rec.Code)
		}
	})

	t.Run("03_others_cannot_read_or_write", func(t *testing.T) {
		// Başka saha çalışanı (masrafı okuyamaz): 404.
		if rr, _ := rbacDo(t, d.router, http.MethodGet, generalAtt+"/"+attID+"/content", field2Token, ""); rr.Code != http.StatusNotFound {
			t.Errorf("başkasının fişi 404 olmalı: %d", rr.Code)
		}
		if code, _ := upload(t, generalAtt, field2Token, "x.png", png(3)); code != http.StatusNotFound {
			t.Errorf("başkasının masrafına yükleme 404 olmalı: %d", code)
		}
		if rr, _ := rbacDo(t, d.router, http.MethodDelete, generalAtt+"/"+attID, field2Token, ""); rr.Code != http.StatusNotFound {
			t.Errorf("başkasının fişini silme 404 olmalı: %d", rr.Code)
		}
		// Üyesi olmadığı projenin URL'si: proje kapısı.
		pbPath := "/api/v1/projects/" + pB.ID + "/expenses/" + projectID + "/attachments"
		if rr, b := rbacDo(t, d.router, http.MethodGet, pbPath, fieldToken, ""); rr.Code != http.StatusForbidden || b["code"] != "project_access_denied" {
			t.Errorf("üye olmadığı proje: %d %v", rr.Code, b)
		}
		// Yönetici (üyelikten muaf) başka projenin URL'sinden açamaz: 404.
		if rr, _ := rbacDo(t, d.router, http.MethodGet, pbPath, adminToken, ""); rr.Code != http.StatusNotFound {
			t.Errorf("başka projenin URL'si 404 olmalı: %d", rr.Code)
		}
		// Başka firma.
		for _, p := range []string{generalAtt, generalAtt + "/" + attID + "/content"} {
			if rr, _ := rbacDo(t, d.router, http.MethodGet, p, ownerBToken, ""); rr.Code != http.StatusNotFound {
				t.Errorf("başka firma %s: %d", p, rr.Code)
			}
		}
		if code, _ := upload(t, generalAtt, ownerBToken, "x.png", png(4)); code != http.StatusNotFound {
			t.Errorf("başka firma yükleme: %d", code)
		}
		if rr, _ := rbacDo(t, d.router, http.MethodDelete, generalAtt+"/"+attID, ownerBToken, ""); rr.Code != http.StatusNotFound {
			t.Errorf("başka firma silme: %d", rr.Code)
		}
	})

	t.Run("04_approver_without_finance_read_sees_and_decides", func(t *testing.T) {
		rec, b := rbacDo(t, d.router, http.MethodGet, "/api/v1/expenses?status=pending", apprToken, "")
		if rec.Code != http.StatusOK || b["scope"] != "approver" || b["can_see_all"] != false {
			t.Fatalf("onaylayıcı kapsamı: %d %v", rec.Code, b)
		}
		if _, ok := b["totals"]; ok {
			t.Error("onaylayıcı kapsamında toplam dönmemeli")
		}
		got := rows(b)
		g, okG := got[generalID]
		_, okP := got[projectID]
		if !okG || !okP {
			t.Fatalf("onaylayıcı bekleyen genel ve projeli masrafı görmeli: %v", got)
		}
		if g["created_by_name"] == "" {
			t.Error("onaylayıcı masrafı kimin girdiğini görmeli")
		}
		if list, _ := g["attachments"].([]any); len(list) != 1 {
			t.Errorf("onaylayıcı fişi listede görmeli: %v", g["attachments"])
		}
		// Finans özeti/listesi yine kapalı.
		if rr, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/expenses", apprToken, ""); rr.Code != http.StatusForbidden {
			t.Errorf("onaylayıcıya Finans listesi açılmamalı: %d", rr.Code)
		}
		if rr, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+pA.ID+"/financial-summary", apprToken, ""); rr.Code != http.StatusForbidden {
			t.Errorf("onaylayıcıya finans özeti açılmamalı: %d", rr.Code)
		}
		// Karar vermeden fişi açar; başkasının masrafına belge ekleyemez.
		if rr, _ := rbacDo(t, d.router, http.MethodGet, generalAtt+"/"+attID+"/content", apprToken, ""); rr.Code != http.StatusOK {
			t.Errorf("onaylayıcı fişi açabilmeli: %d", rr.Code)
		}
		if code, _ := upload(t, generalAtt, apprToken, "x.png", png(5)); code != http.StatusConflict {
			t.Errorf("onaylayıcı başkasının masrafına belge ekleyememeli: %d", code)
		}
		if rr, b := rbacDo(t, d.router, http.MethodPost, "/api/v1/expenses/general/"+generalID+"/approve", apprToken, ""); rr.Code != http.StatusOK {
			t.Fatalf("onaylayıcı genel masrafı onaylamalı: %d %v", rr.Code, b)
		}
		// Onaylanmış masrafın belgesi donar.
		if code, _ := upload(t, generalAtt, fieldToken, "sonra.png", png(6)); code != http.StatusConflict {
			t.Errorf("onaylanmış masrafa belge eklenmemeli: %d", code)
		}
		if rr, _ := rbacDo(t, d.router, http.MethodDelete, generalAtt+"/"+attID, fieldToken, ""); rr.Code != http.StatusConflict {
			t.Errorf("onaylanmış masrafın belgesi silinmemeli: %d", rr.Code)
		}
	})

	t.Run("05_scopes_for_finance_and_field", func(t *testing.T) {
		_, b := rbacDo(t, d.router, http.MethodGet, "/api/v1/expenses", finToken, "")
		if b["scope"] != "all" || b["can_see_all"] != true {
			t.Errorf("finans okuyucusu kapsamı all olmalı: %v", b["scope"])
		}
		_, b = rbacDo(t, d.router, http.MethodGet, "/api/v1/expenses", field2Token, "")
		if b["scope"] != "mine" {
			t.Errorf("saha kapsamı mine olmalı: %v", b["scope"])
		}
		if _, ok := rows(b)[projectID]; ok {
			t.Error("saha başkasının masrafını görmemeli")
		}
		_, b = rbacDo(t, d.router, http.MethodGet, "/api/v1/expenses?mine=1", apprToken, "")
		if b["scope"] != "mine" {
			t.Errorf("mine=1 kapsamı mine olmalı: %v", b["scope"])
		}
	})

	t.Run("06_creator_and_finance_manage_delete_while_pending", func(t *testing.T) {
		rec, b := rbacDo(t, d.router, http.MethodGet, projectAtt, fieldToken, "")
		list, _ := b["attachments"].([]any)
		if rec.Code != http.StatusOK || len(list) != 1 {
			t.Fatalf("projeli masrafın belgesi: %d %v", rec.Code, b)
		}
		pid := list[0].(map[string]any)["id"].(string)
		if rr, _ := rbacDo(t, d.router, http.MethodDelete, projectAtt+"/"+pid, apprToken, ""); rr.Code != http.StatusConflict {
			t.Errorf("onaylayıcı başkasının belgesini silememeli: %d", rr.Code)
		}
		if rr, _ := rbacDo(t, d.router, http.MethodDelete, projectAtt+"/"+pid, fieldToken, ""); rr.Code != http.StatusOK {
			t.Errorf("giren bekleyen masrafın belgesini silebilmeli: %d", rr.Code)
		}
		if rr, _ := rbacDo(t, d.router, http.MethodGet, projectAtt+"/"+pid+"/content", fieldToken, ""); rr.Code != http.StatusNotFound {
			t.Errorf("silinen belge 404 olmalı: %d", rr.Code)
		}
		// Finans rolü finance.manage taşır: başkasının bekleyen masrafına ekler.
		if code, _ := upload(t, projectAtt, finToken, "muhasebe.png", png(7)); code != http.StatusCreated {
			t.Errorf("finans yöneticisi belge eklemeli: %d", code)
		}
	})
}
