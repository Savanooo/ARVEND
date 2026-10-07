package handler

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// Bu dosya, Sprint 2 (WBS + Cost Codes + Project Budget + Cost Control)
// proje-kapsamlı uçlarını taşır -- CostCodeHandler'ın (organizasyon-
// seviyeli katalog) AKSİNE hepsi ProjectService üzerinden AYNI
// ProjectHandler'a eklenir (mevcut finans/ek-iş uçlarıyla AYNI desen,
// bkz. project_finance_handler.go/project_change_order_service.go).

// ---------- WBS ----------

type wbsNodeResponse struct {
	ID        string  `json:"id"`
	ParentID  *string `json:"parent_id,omitempty"`
	Code      string  `json:"code"`
	Name      string  `json:"name"`
	SortOrder int     `json:"sort_order"`
	IsActive  bool    `json:"is_active"`
}

func toWBSNodeResponse(n domain.WBSNode) wbsNodeResponse {
	return wbsNodeResponse{ID: n.ID, ParentID: n.ParentID, Code: n.Code, Name: n.Name, SortOrder: n.SortOrder, IsActive: n.IsActive}
}

type wbsNodeRequest struct {
	ParentID  string `json:"parent_id"`
	Code      string `json:"code"`
	Name      string `json:"name"`
	SortOrder int    `json:"sort_order"`
}

func (req wbsNodeRequest) toInput(userID string) service.WBSNodeInput {
	return service.WBSNodeInput{ParentID: req.ParentID, Code: req.Code, Name: req.Name, SortOrder: req.SortOrder, UserID: userID}
}

func (h *ProjectHandler) ListWBSNodes(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	nodes, err := h.svc.ListWBSNodes(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]wbsNodeResponse, len(nodes))
	for i, n := range nodes {
		out[i] = toWBSNodeResponse(n)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"wbs_nodes": out})
}

func (h *ProjectHandler) CreateWBSNode(w http.ResponseWriter, r *http.Request) {
	var req wbsNodeRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	n, err := h.svc.CreateWBSNode(r.Context(), chi.URLParam(r, "id"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toWBSNodeResponse(*n))
}

func (h *ProjectHandler) UpdateWBSNode(w http.ResponseWriter, r *http.Request) {
	var req wbsNodeRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	n, err := h.svc.UpdateWBSNode(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "nodeId"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toWBSNodeResponse(*n))
}

func (h *ProjectHandler) ArchiveWBSNode(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.ArchiveWBSNode(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "nodeId"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

// ---------- Bütçe ----------

type projectBudgetResponse struct {
	ID          string  `json:"id"`
	Currency    string  `json:"currency"`
	Status      string  `json:"status"`
	Version     int     `json:"version"`
	BaselinedAt *string `json:"baselined_at,omitempty"`
}

func toProjectBudgetResponse(b domain.ProjectBudget) projectBudgetResponse {
	return projectBudgetResponse{ID: b.ID, Currency: b.Currency, Status: b.Status, Version: b.Version, BaselinedAt: tsStrPtr(b.BaselinedAt)}
}

func (h *ProjectHandler) GetProjectBudget(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	b, err := h.svc.GetProjectBudget(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProjectBudgetResponse(*b))
}

func (h *ProjectHandler) CreateProjectBudget(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	b, err := h.svc.CreateProjectBudget(r.Context(), chi.URLParam(r, "id"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toProjectBudgetResponse(*b))
}

// BaselineProjectBudget, TEK YÖNLÜ bir geçiştir -- geri alma UCU YOKTUR
// (bkz. service.ProjectService.BaselineProjectBudget yorumu).
func (h *ProjectHandler) BaselineProjectBudget(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	b, err := h.svc.BaselineProjectBudget(r.Context(), chi.URLParam(r, "id"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProjectBudgetResponse(*b))
}

// ---------- Bütçe Kalemleri ----------

type budgetLineResponse struct {
	ID             string   `json:"id"`
	WBSNodeID      *string  `json:"wbs_node_id,omitempty"`
	WBSCode        string   `json:"wbs_code,omitempty"`
	WBSName        string   `json:"wbs_name,omitempty"`
	CostCodeID     string   `json:"cost_code_id"`
	CostCodeCode   string   `json:"cost_code_code,omitempty"`
	CostCodeName   string   `json:"cost_code_name,omitempty"`
	Description    string   `json:"description"`
	Quantity       *float64 `json:"quantity,omitempty"`
	Unit           string   `json:"unit,omitempty"`
	UnitCost       *float64 `json:"unit_cost,omitempty"`
	OriginalAmount float64  `json:"original_amount"`
	Notes          string   `json:"notes,omitempty"`
}

func toBudgetLineResponse(l domain.BudgetLine) budgetLineResponse {
	return budgetLineResponse{
		ID: l.ID, WBSNodeID: l.WBSNodeID, WBSCode: l.WBSCode, WBSName: l.WBSName,
		CostCodeID: l.CostCodeID, CostCodeCode: l.CostCodeCode, CostCodeName: l.CostCodeName,
		Description: l.Description, Quantity: l.Quantity, Unit: l.Unit, UnitCost: l.UnitCost,
		OriginalAmount: l.OriginalAmount, Notes: l.Notes,
	}
}

type budgetLineRequest struct {
	WBSNodeID      string   `json:"wbs_node_id"`
	CostCodeID     string   `json:"cost_code_id"`
	Description    string   `json:"description"`
	Quantity       *float64 `json:"quantity"`
	Unit           string   `json:"unit"`
	UnitCost       *float64 `json:"unit_cost"`
	OriginalAmount float64  `json:"original_amount"`
	Notes          string   `json:"notes"`
}

func (req budgetLineRequest) toInput(userID string) service.BudgetLineInput {
	return service.BudgetLineInput{
		WBSNodeID: req.WBSNodeID, CostCodeID: req.CostCodeID, Description: req.Description,
		Quantity: req.Quantity, Unit: req.Unit, UnitCost: req.UnitCost,
		OriginalAmount: req.OriginalAmount, Notes: req.Notes, UserID: userID,
	}
}

func (h *ProjectHandler) ListBudgetLines(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	lines, err := h.svc.ListBudgetLines(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]budgetLineResponse, len(lines))
	for i, l := range lines {
		out[i] = toBudgetLineResponse(l)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"budget_lines": out})
}

func (h *ProjectHandler) CreateBudgetLine(w http.ResponseWriter, r *http.Request) {
	var req budgetLineRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	l, err := h.svc.CreateBudgetLine(r.Context(), chi.URLParam(r, "id"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toBudgetLineResponse(*l))
}

func (h *ProjectHandler) UpdateBudgetLine(w http.ResponseWriter, r *http.Request) {
	var req budgetLineRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	l, err := h.svc.UpdateBudgetLine(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "lineId"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toBudgetLineResponse(*l))
}

func (h *ProjectHandler) DeleteBudgetLine(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.DeleteBudgetLine(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "lineId"), orgID, userID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

// ---------- Bütçe Revizyonları (Adjustments) ----------

type budgetAdjustmentResponse struct {
	ID           string  `json:"id"`
	BudgetLineID string  `json:"budget_line_id"`
	Amount       float64 `json:"amount"`
	Reason       string  `json:"reason"`
	Status       string  `json:"status"`
	ApprovedAt   *string `json:"approved_at,omitempty"`
	CreatedAt    string  `json:"created_at"`
}

func toBudgetAdjustmentResponse(a domain.BudgetAdjustment) budgetAdjustmentResponse {
	return budgetAdjustmentResponse{
		ID: a.ID, BudgetLineID: a.BudgetLineID, Amount: a.Amount, Reason: a.Reason,
		Status: a.Status, ApprovedAt: tsStrPtr(a.ApprovedAt), CreatedAt: a.CreatedAt.Format(rfc3339),
	}
}

type budgetAdjustmentRequest struct {
	BudgetLineID string  `json:"budget_line_id"`
	Amount       float64 `json:"amount"`
	Reason       string  `json:"reason"`
}

func (h *ProjectHandler) ListBudgetAdjustments(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListBudgetAdjustments(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]budgetAdjustmentResponse, len(rows))
	for i, a := range rows {
		out[i] = toBudgetAdjustmentResponse(a)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"adjustments": out})
}

func (h *ProjectHandler) CreateBudgetAdjustment(w http.ResponseWriter, r *http.Request) {
	var req budgetAdjustmentRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	a, err := h.svc.CreateBudgetAdjustment(r.Context(), chi.URLParam(r, "id"), orgID, service.BudgetAdjustmentInput{
		BudgetLineID: req.BudgetLineID, Amount: req.Amount, Reason: req.Reason, UserID: userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toBudgetAdjustmentResponse(*a))
}

func (h *ProjectHandler) ApproveBudgetAdjustment(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	a, err := h.svc.ApproveBudgetAdjustment(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "adjustmentId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toBudgetAdjustmentResponse(*a))
}

func (h *ProjectHandler) RejectBudgetAdjustment(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	a, err := h.svc.RejectBudgetAdjustment(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "adjustmentId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toBudgetAdjustmentResponse(*a))
}

// ---------- Taahhütler (Commitments) ----------
//
// Bu sprintte YALNIZCA manuel taahhüt -- UI'de "Manuel Taahhüt" olarak
// AÇIKÇA etiketlenmeli, gerçek bir PO/sözleşme belgesi gibi GÖSTERİLMEMELİ
// (spec §17).

type commitmentResponse struct {
	ID              string  `json:"id"`
	BudgetLineID    *string `json:"budget_line_id,omitempty"`
	CostCodeID      string  `json:"cost_code_id"`
	CostCodeCode    string  `json:"cost_code_code,omitempty"`
	CostCodeName    string  `json:"cost_code_name,omitempty"`
	SourceType      string  `json:"source_type"`
	Description     string  `json:"description"`
	CommittedAmount float64 `json:"committed_amount"`
	Currency        string  `json:"currency"`
	Status          string  `json:"status"`
	CommittedAt     string  `json:"committed_at"`
	VoidedAt        *string `json:"voided_at,omitempty"`
	VoidReason      string  `json:"void_reason,omitempty"`
}

func toCommitmentResponse(c domain.Commitment) commitmentResponse {
	return commitmentResponse{
		ID: c.ID, BudgetLineID: c.BudgetLineID, CostCodeID: c.CostCodeID,
		CostCodeCode: c.CostCodeCode, CostCodeName: c.CostCodeName, SourceType: c.SourceType,
		Description: c.Description, CommittedAmount: c.CommittedAmount, Currency: c.Currency,
		Status: c.Status, CommittedAt: c.CommittedAt.Format(dateLayout),
		VoidedAt: tsStrPtr(c.VoidedAt), VoidReason: c.VoidReason,
	}
}

type commitmentRequest struct {
	BudgetLineID    string  `json:"budget_line_id"`
	CostCodeID      string  `json:"cost_code_id"`
	Description     string  `json:"description"`
	CommittedAmount float64 `json:"committed_amount"`
	CommittedAt     string  `json:"committed_at"`
	IdempotencyKey  string  `json:"idempotency_key"`
}

func (h *ProjectHandler) ListCommitments(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListCommitments(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]commitmentResponse, len(rows))
	for i, c := range rows {
		out[i] = toCommitmentResponse(c)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"commitments": out})
}

func (h *ProjectHandler) CreateCommitment(w http.ResponseWriter, r *http.Request) {
	var req commitmentRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	committedAt, ok := requestDate(w, req.CommittedAt)
	if !ok {
		return
	}
	c, err := h.svc.CreateCommitment(r.Context(), chi.URLParam(r, "id"), orgID, service.CommitmentInput{
		CostCodeID: req.CostCodeID, BudgetLineID: req.BudgetLineID, Description: req.Description,
		CommittedAmount: req.CommittedAmount, CommittedAt: committedAt,
		IdempotencyKey: req.IdempotencyKey, UserID: userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toCommitmentResponse(*c))
}

func (h *ProjectHandler) VoidCommitment(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	c, err := h.svc.VoidCommitment(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "commitmentId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toCommitmentResponse(*c))
}

// ---------- Tahmin (Forecast / ETC) ----------

type forecastResponse struct {
	BudgetLineID string  `json:"budget_line_id"`
	ETCAmount    float64 `json:"etc_amount"`
	Note         string  `json:"note"`
	UpdatedAt    string  `json:"updated_at"`
}

func toForecastResponse(f domain.CostForecast) forecastResponse {
	return forecastResponse{BudgetLineID: f.BudgetLineID, ETCAmount: f.ETCAmount, Note: f.Note, UpdatedAt: f.UpdatedAt.Format(rfc3339)}
}

type forecastRequest struct {
	ETCAmount float64 `json:"etc_amount"`
	Note      string  `json:"note"`
}

func (h *ProjectHandler) ListForecasts(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListForecasts(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]forecastResponse, len(rows))
	for i, f := range rows {
		out[i] = toForecastResponse(f)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"forecasts": out})
}

func (h *ProjectHandler) UpsertForecast(w http.ResponseWriter, r *http.Request) {
	var req forecastRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	f, err := h.svc.UpsertForecastETC(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "lineId"), orgID, req.ETCAmount, req.Note, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toForecastResponse(*f))
}

// ---------- Maliyet Kontrolü Özeti + Kırılım Tablosu ----------

type costControlLineResponse struct {
	BudgetLineID        *string `json:"budget_line_id,omitempty"`
	WBSCode             string  `json:"wbs_code,omitempty"`
	WBSName             string  `json:"wbs_name,omitempty"`
	CostCodeID          string  `json:"cost_code_id"`
	CostCodeCode        string  `json:"cost_code_code"`
	CostCodeName        string  `json:"cost_code_name"`
	Description         string  `json:"description"`
	OriginalBudget      float64 `json:"original_budget"`
	ApprovedAdjustments float64 `json:"approved_adjustments"`
	RevisedBudget       float64 `json:"revised_budget"`
	CommittedCost       float64 `json:"committed_cost"`
	ActualCost          float64 `json:"actual_cost"`
	ETC                 float64 `json:"etc"`
	EAC                 float64 `json:"eac"`
	Variance            float64 `json:"variance"`
	IsUnbudgeted        bool    `json:"is_unbudgeted"`
}

func toCostControlLineResponse(l domain.CostControlLine) costControlLineResponse {
	return costControlLineResponse{
		BudgetLineID: l.BudgetLineID, WBSCode: l.WBSCode, WBSName: l.WBSName,
		CostCodeID: l.CostCodeID, CostCodeCode: l.CostCodeCode, CostCodeName: l.CostCodeName,
		Description: l.Description, OriginalBudget: l.OriginalAmount, ApprovedAdjustments: l.ApprovedAdjustments,
		RevisedBudget: l.RevisedBudget, CommittedCost: l.CommittedCost, ActualCost: l.ActualCost,
		ETC: l.ETCAmount, EAC: l.EAC, Variance: l.Variance, IsUnbudgeted: l.IsUnbudgeted,
	}
}

// costControlSummaryResponse, spec'in örnek özet DTO'suyla BİREBİR
// uyumludur (bkz. spec "Report/DTO" bölümü) -- dahili alanlar (ör.
// bütçe/adjustment UUID'leri) SIZDIRILMAZ.
type costControlSummaryResponse struct {
	Currency              string  `json:"currency"`
	ContractValue         float64 `json:"contract_value"`
	OriginalBudget        float64 `json:"original_budget"`
	ApprovedAdjustments   float64 `json:"approved_adjustments"`
	RevisedBudget         float64 `json:"revised_budget"`
	CommittedCost         float64 `json:"committed_cost"`
	ActualCost            float64 `json:"actual_cost"`
	ETC                   float64 `json:"etc"`
	EAC                   float64 `json:"eac"`
	Variance              float64 `json:"variance"`
	ForecastProfit        float64 `json:"forecast_profit"`
	ForecastMarginPercent float64 `json:"forecast_margin_percent"`
	HasBudget             bool    `json:"has_budget"`
}

func toCostControlSummaryResponse(s domain.CostControlSummary) costControlSummaryResponse {
	return costControlSummaryResponse{
		Currency: s.Currency, ContractValue: s.ContractValue, OriginalBudget: s.OriginalBudget,
		ApprovedAdjustments: s.ApprovedAdjustments, RevisedBudget: s.RevisedBudget,
		CommittedCost: s.CommittedCost, ActualCost: s.ActualCost, ETC: s.ETCTotal, EAC: s.EACTotal,
		Variance: s.Variance, ForecastProfit: s.ForecastProfit, ForecastMarginPercent: s.ForecastMarginPercent,
		HasBudget: s.HasBudget,
	}
}

// CostControl, "Maliyet Kontrolü" ekranının TEK istekle ihtiyaç duyduğu
// özet+kırılım tablosunu birlikte döner (spec: N+1 YOK, bkz. service
// katmanındaki SUM()-tabanlı agregasyon). Bütçe HENÜZ oluşturulmamış
// projelerde BİLE 404 DEĞİL, has_budget=false ile 200 döner (spec §42).
func (h *ProjectHandler) CostControl(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	projectID := chi.URLParam(r, "id")

	summary, err := h.svc.CostControlSummary(r.Context(), projectID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	lines, err := h.svc.CostControlLines(r.Context(), projectID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	lineResp := make([]costControlLineResponse, len(lines))
	for i, l := range lines {
		lineResp[i] = toCostControlLineResponse(l)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{
		"summary": toCostControlSummaryResponse(*summary),
		"lines":   lineResp,
	})
}
