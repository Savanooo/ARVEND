package middleware_test

import (
	"bytes"
	"context"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

// Firma Grubu (migration 0077) -- gerçek bir PostgreSQL bağlantısı
// gerektirir. Uçların izin kapısı, firma sınırı, silme kuralı ve hata
// kodları. Taşeron hesabının bütün /organization/chat uçlarında 403
// portal_only aldığını subcontractor_portal_security_test.go'nun rota
// taraması doğrular.

var chatTestPNG = []byte{
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
	0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
	0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
	0x00, 0x03, 0x01, 0x01, 0x00, 0xc9, 0xfe, 0x92, 0xef, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
	0x44, 0xae, 0x42, 0x60, 0x82,
}

func TestOrganizationChatSecurity(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "chat-sec-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	other := mustCreateReadyOrg(t, ctx, d, "chat-sec-org-b")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, other.Organization.ID) })
	orgID := org.Organization.ID

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatal(err)
	}
	otherOwnerToken, err := d.issuer.IssueAccessToken(other.Owner.ID, domain.RoleAdmin, other.Organization.ID)
	if err != nil {
		t.Fatal(err)
	}
	_, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "chat_sec_field", domain.OrgRoleField)
	finance, financeToken := mustCreateRoleUser(t, ctx, d, orgID, "chat_sec_finance", domain.OrgRoleFinance)
	const base = "/api/v1/organization/chat"

	cid := uuid.NewString()
	rec, body := rbacDo(t, d.router, http.MethodPost, base+"/messages", fieldToken, `{"text":"Merhaba ekip","client_id":"`+cid+`"}`)
	if rec.Code != http.StatusCreated || body["text"] != "Merhaba ekip" || body["is_own"] != true || body["can_delete"] != true {
		t.Fatalf("saha mesaj yazabilmeli: %d %v", rec.Code, body)
	}
	fieldMsgID := body["id"].(string)
	if rec, again := rbacDo(t, d.router, http.MethodPost, base+"/messages", fieldToken, `{"text":"Merhaba ekip","client_id":"`+cid+`"}`); rec.Code != http.StatusOK || again["id"] != fieldMsgID {
		t.Fatalf("tekrar deneme 200 ve aynı mesaj olmalı: %d %v", rec.Code, again)
	}
	rec, body = rbacDo(t, d.router, http.MethodPost, base+"/messages", ownerToken, `{"text":"Sahibin mesajı"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("sahip yazabilmeli: %d %v", rec.Code, body)
	}
	ownerMsgID := body["id"].(string)

	t.Run("list_flags_per_viewer", func(t *testing.T) {
		flags := func(token string) map[string][2]any {
			t.Helper()
			rec, body := rbacDo(t, d.router, http.MethodGet, base+"/messages", token, "")
			if rec.Code != http.StatusOK {
				t.Fatalf("liste: %d %v", rec.Code, body)
			}
			out := map[string][2]any{}
			for _, raw := range body["messages"].([]any) {
				m := raw.(map[string]any)
				out[m["id"].(string)] = [2]any{m["is_own"], m["can_delete"]}
			}
			if _, ok := body["server_time"].(string); !ok {
				t.Errorf("server_time dönmeli: %v", body)
			}
			return out
		}
		if f := flags(financeToken); f[fieldMsgID] != [2]any{false, false} || f[ownerMsgID] != [2]any{false, false} {
			t.Errorf("finans başkasının mesajını silemez: %v", f)
		}
		if f := flags(ownerToken); f[fieldMsgID] != [2]any{false, true} || f[ownerMsgID] != [2]any{true, true} {
			t.Errorf("sahip herkesinkini siler: %v", f)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, base+"/messages?before=5&after=1", fieldToken, ""); rec.Code != http.StatusBadRequest {
			t.Errorf("before+after 400 olmalı: %d", rec.Code)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, base+"/messages?after=abc", fieldToken, ""); rec.Code != http.StatusBadRequest {
			t.Errorf("sayı olmayan imleç 400 olmalı: %d", rec.Code)
		}
	})

	t.Run("cross_tenant_is_404", func(t *testing.T) {
		if rec, body := rbacDo(t, d.router, http.MethodGet, base+"/messages", otherOwnerToken, ""); rec.Code != http.StatusOK || len(body["messages"].([]any)) != 0 {
			t.Errorf("başka firma A'nın mesajlarını görmemeli: %d %v", rec.Code, body)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodDelete, base+"/messages/"+fieldMsgID, otherOwnerToken, ""); rec.Code != http.StatusNotFound {
			t.Errorf("başka firmanın mesajını silmek 404: %d", rec.Code)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, base+"/messages/"+fieldMsgID+"/photo", otherOwnerToken, ""); rec.Code != http.StatusNotFound {
			t.Errorf("başka firmanın fotoğrafı 404: %d", rec.Code)
		}
	})

	t.Run("delete_rules", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodDelete, base+"/messages/"+ownerMsgID, fieldToken, "")
		if rec.Code != http.StatusForbidden || body["code"] == "permission_denied" {
			t.Errorf("saha başkasının mesajını silemez (403, izin tazeleme kodu olmadan): %d %v", rec.Code, body)
		}
		rec, body = rbacDo(t, d.router, http.MethodDelete, base+"/messages/"+fieldMsgID, ownerToken, "")
		if rec.Code != http.StatusOK || body["deleted"] != true || body["text"] != "" || body["can_delete"] != false {
			t.Errorf("sahip silebilmeli: %d %v", rec.Code, body)
		}
	})

	t.Run("photo_upload_and_download", func(t *testing.T) {
		var buf bytes.Buffer
		mw := multipart.NewWriter(&buf)
		fw, _ := mw.CreateFormFile("file", "IMG_0001.jpg")
		_, _ = fw.Write(chatTestPNG)
		_ = mw.WriteField("text", "Şantiye girişi")
		_ = mw.Close()
		req := httptest.NewRequest(http.MethodPost, base+"/messages/photo", &buf)
		req.Header.Set("Content-Type", mw.FormDataContentType())
		req.AddCookie(&http.Cookie{Name: "access_token", Value: fieldToken})
		rec := httptest.NewRecorder()
		d.router.ServeHTTP(rec, req)
		if rec.Code != http.StatusCreated || !strings.Contains(rec.Body.String(), `"mime_type":"image/png"`) {
			t.Fatalf("fotoğraf mesajı: %d %s", rec.Code, rec.Body.String())
		}
		id := between(rec.Body.String(), `"id":"`, `"`)
		get := httptest.NewRequest(http.MethodGet, base+"/messages/"+id+"/photo", nil)
		get.AddCookie(&http.Cookie{Name: "access_token", Value: financeToken})
		out := httptest.NewRecorder()
		d.router.ServeHTTP(out, get)
		if out.Code != http.StatusOK || out.Header().Get("Content-Type") != "image/png" || !bytes.Equal(out.Body.Bytes(), chatTestPNG) {
			t.Errorf("fotoğraf indirilemedi: %d %q", out.Code, out.Header().Get("Content-Type"))
		}
	})

	t.Run("status_read_mute", func(t *testing.T) {
		rec, body := rbacDo(t, d.router, http.MethodGet, base+"/status", financeToken, "")
		if rec.Code != http.StatusOK || body["unread_count"].(float64) < 1 || body["muted"] != false {
			t.Fatalf("durum: %d %v", rec.Code, body)
		}
		rec, body = rbacDo(t, d.router, http.MethodPost, base+"/read", financeToken, `{"seq":1000000}`)
		if rec.Code != http.StatusOK || body["unread_count"].(float64) != 0 {
			t.Fatalf("okundu: %d %v", rec.Code, body)
		}
		if rec, body := rbacDo(t, d.router, http.MethodPut, base+"/mute", financeToken, `{"muted":true}`); rec.Code != http.StatusOK || body["muted"] != true {
			t.Errorf("sessize alma: %d %v", rec.Code, body)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodPut, base+"/mute", financeToken, `{}`); rec.Code != http.StatusBadRequest {
			t.Errorf("muted alanı zorunlu: %d", rec.Code)
		}
	})

	t.Run("validation_and_rate_limit", func(t *testing.T) {
		if rec, _ := rbacDo(t, d.router, http.MethodPost, base+"/messages", fieldToken, `{"text":"   "}`); rec.Code != http.StatusBadRequest {
			t.Errorf("boş mesaj 400: %d", rec.Code)
		}
		if rec, _ := rbacDo(t, d.router, http.MethodPost, base+"/messages", fieldToken, `{"text":"x","user_id":"başkası"}`); rec.Code != http.StatusBadRequest {
			t.Errorf("tanımsız alan (yazar uydurma) 400: %d", rec.Code)
		}
		var last *httptest.ResponseRecorder
		for i := 0; i < 25; i++ {
			last, _ = rbacDo(t, d.router, http.MethodPost, base+"/messages", ownerToken, `{"text":"döngü"}`)
			if last.Code == http.StatusTooManyRequests {
				break
			}
		}
		if last.Code != http.StatusTooManyRequests || last.Header().Get("Retry-After") == "" {
			t.Errorf("dakikada sınırı aşan gönderim 429 olmalı: %d", last.Code)
		}
	})

	t.Run("permission_revoked_is_403", func(t *testing.T) {
		detail, err := d.authzSvc.GetUserPermissionDetail(ctx, finance.ID, orgID)
		if err != nil {
			t.Fatal(err)
		}
		var keep []string
		for _, p := range detail.Effective {
			if p != domain.PermOrganizationChatUse {
				keep = append(keep, p)
			}
		}
		if _, err := d.authzSvc.SetUserPermissions(ctx, finance.ID, orgID, org.Owner.ID, keep); err != nil {
			t.Fatal(err)
		}
		for _, c := range []struct{ method, path, body string }{
			{http.MethodGet, base + "/messages", ""},
			{http.MethodPost, base + "/messages", `{"text":"x"}`},
			{http.MethodGet, base + "/status", ""},
		} {
			if rec, body := rbacDo(t, d.router, c.method, c.path, financeToken, c.body); rec.Code != http.StatusForbidden || body["code"] != "permission_denied" {
				t.Errorf("%s %s izinsiz 403 olmalı: %d %v", c.method, c.path, rec.Code, body)
			}
		}
	})
}

func between(s, start, end string) string {
	i := strings.Index(s, start)
	if i < 0 {
		return ""
	}
	s = s[i+len(start):]
	if j := strings.Index(s, end); j >= 0 {
		return s[:j]
	}
	return s
}
