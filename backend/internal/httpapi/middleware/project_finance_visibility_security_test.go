package middleware_test

// Finans izni olmayana proje para bilgisi: GET /projects, GET /projects/{id},
// PUT /projects/{id}, POST /projects/from-offer/{offerId},
// GET /offers/{id}/project, GET /projects/{id}/events ve
// GET /projects/{id}/cost-control projects.read/cost_control.read ile açılır
// (Saha, Proje Yöneticisi). Sözleşme bedeli, liste aggregate'leri, olay
// tutarları ve maliyet kontrolündeki gelir/kâr YALNIZCA efektif
// projects.finance.read sahibine döner -- rol ya da kişiye özel ekleme/
// kaldırma fark etmez. Gerçek router + gerçek DB (require_permission_test.go
// harness'i).

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// projectMoneyKeys: proje yanıtında finans iznine bağlı alanlar.
var projectMoneyKeys = []string{
	"contract_amount", "collected_amount", "total_expenses", "subcontractor_paid",
	"subcontractor_remaining", "new_subcontract_paid", "remaining_receivable",
	"realized_cost", "realized_gross_profit", "invoice_count", "paid_invoice_count",
	"change_order_net", "current_contract_value",
}

// projectPublicKeys: finans izni olmayana dolu dönebilecek TEK alanlar.
// Proje yanıtına yeni bir alan eklenirse ya buraya (tutar değilse) eklenir
// ya da finans kapısının (canSeeProjectFinance) arkasına konur -- yoksa bu
// test, alan sızıntıya dönüşmeden önce kırılır.
var projectPublicKeys = map[string]bool{
	"id": true, "project_no": true, "name": true, "project_type": true,
	"source_offer_id": true, "source_offer_no": true, "source_revision_id": true,
	"source_revision_no": true, "customer_id": true, "customer_name": true,
	"customer_phone": true, "customer_email": true, "customer_address": true,
	"currency": true, "status": true, "start_date": true, "end_date": true,
	"description": true, "internal_notes": true, "created_by": true,
	"created_at": true, "updated_at": true,
}

// distinctiveCollection: yanıt gövdesinde metin olarak aranabilecek kadar
// özgün bir tahsilat tutarı.
const distinctiveCollection = 4321.5

func TestProjectFinanceVisibilityMatrix(t *testing.T) {
	d := setupRBACTestRouter(t)
	ctx := context.Background()

	org := mustCreateReadyOrg(t, ctx, d, "project-finance-visibility-org")
	t.Cleanup(func() { rbacCleanupOrg(t, d.pool, org.Organization.ID) })
	orgID := org.Organization.ID

	ownerToken, err := d.issuer.IssueAccessToken(org.Owner.ID, domain.RoleAdmin, orgID)
	if err != nil {
		t.Fatalf("owner token üretilemedi: %v", err)
	}
	pmUser, pmToken := mustCreateRoleUser(t, ctx, d, orgID, "pfv_pm", domain.OrgRoleProjectManager)
	finUser, finToken := mustCreateRoleUser(t, ctx, d, orgID, "pfv_fin", domain.OrgRoleFinance)
	fieldUser, fieldToken := mustCreateRoleUser(t, ctx, d, orgID, "pfv_field", domain.OrgRoleField)
	grantedUser, grantedToken := mustCreateRoleUser(t, ctx, d, orgID, "pfv_field_granted", domain.OrgRoleField)
	revokedUser, revokedToken := mustCreateRoleUser(t, ctx, d, orgID, "pfv_admin_revoked", domain.OrgRoleAdmin)

	p := mustCreateProject(t, ctx, d, orgID, "Finans Görünürlüğü Projesi")
	for _, u := range []string{pmUser.ID, finUser.ID, fieldUser.ID, grantedUser.ID} {
		if _, err := d.authzSvc.AddProjectUser(ctx, p.ID, orgID, service.ProjectUserInput{
			UserID: u, ProjectRole: domain.ProjectRoleMember, CreatedBy: org.Owner.ID,
		}); err != nil {
			t.Fatalf("üyelik eklenemedi: %v", err)
		}
	}

	// Kişiye özel ayarlar: Proje Yöneticisi'ne offers.read (teklif -> proje
	// ucu için), bir Saha'ya projects.finance.read, Yönetici'den finans
	// okuma/yönetme geri alınır (web düzenleyicisi okuma kalkınca yönetmeyi
	// de kaldırır).
	setPerms := func(userID string, add []string, remove ...string) {
		t.Helper()
		detail, err := d.authzSvc.GetUserPermissionDetail(ctx, userID, orgID)
		if err != nil {
			t.Fatal(err)
		}
		drop := map[string]bool{}
		for _, r := range remove {
			drop[r] = true
		}
		var perms []string
		for _, c := range detail.RolePermissions {
			if !drop[c] {
				perms = append(perms, c)
			}
		}
		if _, err := d.authzSvc.SetUserPermissions(ctx, userID, orgID, org.Owner.ID, append(perms, add...)); err != nil {
			t.Fatalf("izin ayarlanamadı: %v", err)
		}
	}
	setPerms(pmUser.ID, []string{domain.PermOffersRead})
	setPerms(grantedUser.ID, []string{domain.PermProjectsFinanceRead})
	setPerms(revokedUser.ID, nil, domain.PermProjectsFinanceRead, domain.PermProjectsFinanceManage)

	if _, err := d.projectSvc.CreateCollection(ctx, p.ID, orgID, service.CollectionInput{
		Amount: distinctiveCollection, Currency: p.Currency, ReceivedDate: time.Now(), UserID: org.Owner.ID,
	}); err != nil {
		t.Fatalf("tahsilat eklenemedi: %v", err)
	}

	viewers := []struct {
		name      string
		token     string
		seesMoney bool
	}{
		{"owner", ownerToken, true},
		{"finance_role", finToken, true},
		{"field_with_personal_finance_grant", grantedToken, true},
		{"project_manager", pmToken, false},
		{"field", fieldToken, false},
		{"admin_with_finance_revoked", revokedToken, false},
	}

	// assertProjectMoney: tek bir proje nesnesinde para alanları ya dolu
	// (izinli) ya da yok/null (izinsiz). onlyContract: tekil uçlar
	// aggregate taşımaz, yalnızca contract_amount'a bakılır.
	assertProjectMoney := func(t *testing.T, proj map[string]any, seesMoney, onlyContract bool) {
		t.Helper()
		if proj == nil {
			t.Fatal("proje yanıtı boş")
		}
		if proj["id"] != p.ID || proj["name"] == nil || proj["status"] == nil {
			t.Fatalf("finans dışı alanlar herkese dönmeli: %v", proj)
		}
		v, present := proj["contract_amount"]
		if !present {
			t.Errorf("contract_amount alanı her zaman yanıtta olmalı (izinsizde null): %v", proj)
		}
		if seesMoney {
			if _, ok := v.(float64); !ok {
				t.Errorf("finans izinli kişi sözleşme bedelini görmeli, geldi %v", v)
			}
			if !onlyContract {
				if c, _ := proj["collected_amount"].(float64); c != distinctiveCollection {
					t.Errorf("collected_amount = %v, want %v", proj["collected_amount"], distinctiveCollection)
				}
				if _, ok := proj["current_contract_value"].(float64); !ok {
					t.Errorf("current_contract_value görünmeli: %v", proj)
				}
			}
			return
		}
		for _, k := range projectMoneyKeys {
			if val, ok := proj[k]; ok && val != nil {
				t.Errorf("finans izni olmayana %s sızdı: %v", k, val)
			}
		}
		for k, val := range proj {
			if val != nil && !projectPublicKeys[k] {
				t.Errorf("finans izni olmayana tanınmayan dolu alan döndü: %s=%v (tutar değilse projectPublicKeys'e ekleyin)", k, val)
			}
		}
	}

	t.Run("list", func(t *testing.T) {
		for _, v := range viewers {
			t.Run(v.name, func(t *testing.T) {
				rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects?limit=100", v.token, "")
				if rec.Code != http.StatusOK {
					t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
				}
				var found map[string]any
				list, _ := body["projects"].([]any)
				for _, item := range list {
					if m, _ := item.(map[string]any); m != nil && m["id"] == p.ID {
						found = m
					}
				}
				assertProjectMoney(t, found, v.seesMoney, false)
				if !v.seesMoney && strings.Contains(rec.Body.String(), "4321.5") {
					t.Errorf("tahsilat tutarı liste gövdesinde sızıyor: %s", rec.Body.String())
				}
			})
		}
	})

	t.Run("get", func(t *testing.T) {
		for _, v := range viewers {
			t.Run(v.name, func(t *testing.T) {
				rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+p.ID, v.token, "")
				if rec.Code != http.StatusOK {
					t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
				}
				assertProjectMoney(t, body, v.seesMoney, true)
			})
		}
	})

	t.Run("update_response", func(t *testing.T) {
		// projects.update: Sahip ve Proje Yöneticisi; Yönetici (finans geri
		// alınmış) de taşır.
		for _, v := range []struct {
			name      string
			token     string
			seesMoney bool
		}{{"owner", ownerToken, true}, {"project_manager", pmToken, false}, {"admin_with_finance_revoked", revokedToken, false}} {
			t.Run(v.name, func(t *testing.T) {
				rec, body := rbacDo(t, d.router, http.MethodPut, "/api/v1/projects/"+p.ID, v.token,
					`{"name":"Finans Görünürlüğü Projesi"}`)
				if rec.Code != http.StatusOK {
					t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
				}
				assertProjectMoney(t, body, v.seesMoney, true)
			})
		}
	})

	t.Run("offer_project_lookup", func(t *testing.T) {
		path := "/api/v1/offers/" + p.SourceOfferID + "/project"
		for _, v := range []struct {
			name      string
			token     string
			seesMoney bool
		}{{"owner", ownerToken, true}, {"project_manager_with_offers_read", pmToken, false}, {"admin_with_finance_revoked", revokedToken, false}} {
			t.Run(v.name, func(t *testing.T) {
				rec, body := rbacDo(t, d.router, http.MethodGet, path, v.token, "")
				if rec.Code != http.StatusOK {
					t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
				}
				assertProjectMoney(t, body, v.seesMoney, true)
			})
		}
	})

	t.Run("create_from_offer_response", func(t *testing.T) {
		// projects.create: Sahip ve Yönetici (finans geri alınmış Yönetici de
		// proje açabilir -- dönen projede sözleşme bedelini görmemeli).
		for _, v := range []struct {
			name      string
			token     string
			seesMoney bool
		}{{"owner", ownerToken, true}, {"admin_with_finance_revoked", revokedToken, false}} {
			t.Run(v.name, func(t *testing.T) {
				offerID := mustAcceptedOfferForFinanceTest(t, ctx, d, orgID)
				rec, body := rbacDo(t, d.router, http.MethodPost, "/api/v1/projects/from-offer/"+offerID, v.token,
					`{"name":"Finans Görünürlüğü `+v.name+`"}`)
				if rec.Code != http.StatusCreated {
					t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
				}
				val, present := body["contract_amount"]
				if !present {
					t.Fatalf("contract_amount alanı her zaman yanıtta olmalı: %v", body)
				}
				if _, isNum := val.(float64); isNum != v.seesMoney {
					t.Errorf("contract_amount = %v, finans görünürlüğü %v olmalıydı", val, v.seesMoney)
				}
				if body["name"] == nil || body["project_no"] == nil {
					t.Errorf("finans dışı alanlar dönmeli: %v", body)
				}
			})
		}
	})

	t.Run("events", func(t *testing.T) {
		for _, v := range viewers {
			t.Run(v.name, func(t *testing.T) {
				rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+p.ID+"/events", v.token, "")
				if rec.Code != http.StatusOK {
					t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
				}
				var out struct {
					Events []struct {
						EventType string         `json:"event_type"`
						Metadata  map[string]any `json:"metadata"`
					} `json:"events"`
				}
				if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
					t.Fatalf("yanıt çözümlenemedi: %v", err)
				}
				seen := map[string]map[string]any{}
				for _, e := range out.Events {
					seen[e.EventType] = e.Metadata
				}
				// Olaylar herkese görünür; yalnızca tutar alanları düşer.
				col, okCol := seen[domain.ProjectEventCollectionReceived]
				created, okCreated := seen[domain.ProjectEventCreated]
				if !okCol || !okCreated {
					t.Fatalf("olaylar listede olmalı (tutar olmasa da): %v", seen)
				}
				if col["collection_id"] == nil || created["project_no"] == nil {
					t.Errorf("tutar dışı metadata korunmalı: tahsilat=%v proje=%v", col, created)
				}
				if v.seesMoney {
					if col["amount"] != distinctiveCollection {
						t.Errorf("tahsilat tutarı görünmeli: %v", col)
					}
					if _, ok := created["contract_amount"].(float64); !ok {
						t.Errorf("proje oluşturma olayında teklif toplamı görünmeli: %v", created)
					}
					return
				}
				for _, e := range out.Events {
					for k := range e.Metadata {
						if domain.ProjectEventMoneyKeys[k] {
							t.Errorf("%s olayında %s sızdı: %v", e.EventType, k, e.Metadata)
						}
					}
				}
				if strings.Contains(rec.Body.String(), "4321.5") {
					t.Errorf("tahsilat tutarı olay gövdesinde sızıyor: %s", rec.Body.String())
				}
			})
		}
	})

	t.Run("cost_control_revenue", func(t *testing.T) {
		// cost_control.read: Sahip, Finans, Proje Yöneticisi, Yönetici. Saha
		// ucu hiç açamaz (403).
		for _, v := range []struct {
			name      string
			token     string
			seesMoney bool
		}{{"owner", ownerToken, true}, {"finance_role", finToken, true}, {"project_manager", pmToken, false}, {"admin_with_finance_revoked", revokedToken, false}} {
			t.Run(v.name, func(t *testing.T) {
				rec, body := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+p.ID+"/cost-control", v.token, "")
				if rec.Code != http.StatusOK {
					t.Fatalf("status = %d, body=%s", rec.Code, rec.Body.String())
				}
				summary, _ := body["summary"].(map[string]any)
				if _, ok := summary["eac"].(float64); !ok {
					t.Fatalf("maliyet rakamları cost_control.read ile görünmeli: %v", summary)
				}
				for _, k := range []string{"contract_value", "forecast_profit", "forecast_margin_percent"} {
					val, present := summary[k]
					if !present {
						t.Errorf("%s alanı yanıtta olmalı (izinsizde null): %v", k, summary)
						continue
					}
					if _, isNum := val.(float64); isNum != v.seesMoney {
						t.Errorf("%s = %v, finans görünürlüğü %v olmalıydı", k, val, v.seesMoney)
					}
				}
			})
		}
		if rec, _ := rbacDo(t, d.router, http.MethodGet, "/api/v1/projects/"+p.ID+"/cost-control", fieldToken, ""); rec.Code != http.StatusForbidden {
			t.Errorf("Saha maliyet kontrolünü açamamalı, geldi %d", rec.Code)
		}
	})
}

// mustAcceptedOfferForFinanceTest: projeye henüz dönüştürülmemiş, müşterinin
// kabul ettiği bir teklif (mustCreateProject'in ilk yarısı) -- POST
// /projects/from-offer yanıtını sınamak için.
func mustAcceptedOfferForFinanceTest(t *testing.T, ctx context.Context, d *rbacTestDeps, orgID string) string {
	t.Helper()
	o, err := d.offerSvc.Create(ctx, service.CreateOfferInput{
		OrganizationID: orgID, CustomerName: "RBAC Test Müşteri",
		Items: []service.OfferItemInput{{ProductName: "İş", Quantity: 1, UnitPrice: 10000}},
	})
	if err != nil {
		t.Fatalf("teklif oluşturulamadı: %v", err)
	}
	if _, err := d.offerSvc.UpdateStatus(ctx, o.ID, orgID, domain.OfferStatusGonderildi, ""); err != nil {
		t.Fatalf("teklif gönderilemedi: %v", err)
	}
	link, err := d.offerSvc.CreateShareLink(ctx, o.ID, orgID, "", nil)
	if err != nil {
		t.Fatalf("paylaşım linki oluşturulamadı: %v", err)
	}
	if _, err := d.offerSvc.RespondByShareLinkToken(ctx, link.Token, domain.OfferStatusKabulEdildi, "", ""); err != nil {
		t.Fatalf("teklif kabul edilemedi: %v", err)
	}
	return o.ID
}
