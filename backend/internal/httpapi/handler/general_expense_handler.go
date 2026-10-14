package handler

import (
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// Genel (projesiz) masraf ve "Masraflar" listesi (migration 0068). İzin
// kapıları router'da: giriş projects.expenses.create, düzenleme/iptal
// projects.finance.manage ya da (yalnızca kendi masrafında) expenses.create,
// karar projects.expenses.approve.

// listedExpenseResponse: "Masraflar" satırı -- masraf + proje (genel
// masrafta boş) + giren.
type listedExpenseResponse struct {
	myExpenseResponse
	IsGeneral     bool   `json:"is_general"`
	CreatedByName string `json:"created_by_name"`
}

// expenseTotalsResponse: para birimi başına onaylı ve bekleyen toplam
// (iptaller hariç) -- yalnızca herkesin masrafını görebilene döner.
type expenseTotalsResponse struct {
	Currency string  `json:"currency"`
	Approved float64 `json:"approved"`
	Pending  float64 `json:"pending"`
}

// ListAllExpenses: GET /expenses?kind=&status=&project_id=&date_from=&date_to=&mine=1
// (projects.expenses.create). projects.finance.read taşıyan herkesin
// masraflarını görür (üyelikle sınırlı rolde yalnızca üyesi olduğu
// projelerdeki projeli masraflar + bütün genel masraflar) ve toplamları
// alır; taşımayan yalnızca kendi girdiklerini görür (mine=1 aynısını
// herkes için ister).
func (h *ProjectHandler) ListAllExpenses(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	q := r.URL.Query()
	authz, ok := middleware.AuthzContextFromRequest(r.Context())
	seeAll := ok && authz.HasPermission(domain.PermProjectsFinanceRead) && q.Get("mine") != "1"

	f := service.ExpenseListFilter{
		Kind: strings.TrimSpace(q.Get("kind")), Status: strings.TrimSpace(q.Get("status")),
		ProjectID: strings.TrimSpace(q.Get("project_id")),
	}
	for i, key := range []string{"date_from", "date_to"} {
		raw := strings.TrimSpace(q.Get(key))
		if raw == "" {
			continue
		}
		t, err := time.Parse(dateLayout, raw)
		if err != nil {
			httpjson.Error(w, http.StatusBadRequest, "geçersiz tarih süzgeci (YYYY-AA-GG bekleniyor)")
			return
		}
		if i == 0 {
			f.DateFrom = &t
		} else {
			f.DateTo = &t
		}
	}
	if !seeAll {
		f.OnlyCreatedBy = userID
	}
	if !ok || !authz.BypassesProjectMembership() {
		f.RestrictToUserID = userID
	}
	rows, err := h.svc.ListExpensesAll(r.Context(), orgID, f)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]listedExpenseResponse, len(rows))
	sums := map[string]*expenseTotalsResponse{}
	var order []string
	for i, e := range rows {
		out[i] = listedExpenseResponse{
			myExpenseResponse: myExpenseResponse{
				expenseResponse: toExpenseResponse(e.Expense),
				ProjectName:     e.ProjectName, ProjectNo: e.ProjectNo, ProjectStatus: e.ProjectStatus,
			},
			IsGeneral: e.IsGeneral(), CreatedByName: e.CreatedByName,
		}
		if e.VoidedAt != nil || e.ApprovalStatus == domain.ExpenseApprovalRejected {
			continue
		}
		t := sums[e.Currency]
		if t == nil {
			t = &expenseTotalsResponse{Currency: e.Currency}
			sums[e.Currency] = t
			order = append(order, e.Currency)
		}
		if e.ApprovalStatus == domain.ExpenseApprovalApproved {
			t.Approved += e.Amount
		} else {
			t.Pending += e.Amount
		}
	}
	resp := map[string]any{
		"expenses": out, "limit": domain.ExpensesListLimit,
		"truncated": len(rows) >= domain.ExpensesListLimit, "can_see_all": seeAll,
	}
	if seeAll {
		totals := make([]expenseTotalsResponse, 0, len(order))
		for _, c := range order {
			t := sums[c]
			t.Approved, t.Pending = roundMoney(t.Approved), roundMoney(t.Pending)
			totals = append(totals, *t)
		}
		resp["totals"] = totals
	}
	httpjson.Write(w, http.StatusOK, resp)
}

func roundMoney(v float64) float64 {
	if v < 0 {
		return -roundMoney(-v)
	}
	return float64(int64(v*100+0.5)) / 100
}

// CreateGeneralExpense: POST /expenses/general (projects.expenses.create).
// Gövde projeli masrafla aynı; ek iş / maliyet kodu / bütçe kalemi
// gönderilemez. Para birimi boşsa TRY.
func (h *ProjectHandler) CreateGeneralExpense(w http.ResponseWriter, r *http.Request) {
	var req expenseRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	expenseDate, ok := requestDate(w, req.ExpenseDate)
	if !ok {
		return
	}
	e, err := h.svc.CreateGeneralExpense(r.Context(), orgID, req.toInput(userID, expenseDate, expenseOwnOnly(r)))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toExpenseResponse(*e))
}

// UpdateGeneralExpense: PUT /expenses/general/{expenseId}.
func (h *ProjectHandler) UpdateGeneralExpense(w http.ResponseWriter, r *http.Request) {
	var req expenseRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	expenseDate, ok := requestDate(w, req.ExpenseDate)
	if !ok {
		return
	}
	e, err := h.svc.UpdateGeneralExpense(r.Context(), chi.URLParam(r, "expenseId"), orgID, req.toInput(userID, expenseDate, expenseOwnOnly(r)))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toExpenseResponse(*e))
}

// VoidGeneralExpense: POST /expenses/general/{expenseId}/void {reason} --
// finans yetkilisi iptal eder, diğerleri kendi bekleyen/reddedilen
// masrafını geri çeker.
func (h *ProjectHandler) VoidGeneralExpense(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	e, err := h.svc.VoidGeneralExpense(r.Context(), chi.URLParam(r, "expenseId"), orgID, userID, req.Reason, expenseOwnOnly(r))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toExpenseResponse(*e))
}

// ApproveGeneralExpense: POST /expenses/general/{expenseId}/approve.
func (h *ProjectHandler) ApproveGeneralExpense(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	e, err := h.svc.ApproveGeneralExpense(r.Context(), chi.URLParam(r, "expenseId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toExpenseResponse(*e))
}

// RejectGeneralExpense: POST /expenses/general/{expenseId}/reject {reason}
// -- gerekçe zorunlu.
func (h *ProjectHandler) RejectGeneralExpense(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	e, err := h.svc.RejectGeneralExpense(r.Context(), chi.URLParam(r, "expenseId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toExpenseResponse(*e))
}
