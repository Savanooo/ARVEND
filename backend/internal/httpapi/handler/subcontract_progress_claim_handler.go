package handler

import (
	"net/http"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

// ARVEND V2 — Sprint 5: Taşeron Yönetimi, Progress Claim (Hakediş) uçları.
// Müşteri hakedişi DEĞİLDİR (Sprint 6), Supplier Invoice/Payment DEĞİLDİR
// (bu sprintte yok) -- bkz. docs/subcontracts.md §Actual Cost Kararı.

type progressClaimResponse struct {
	ID            string `json:"id"`
	SubcontractID string `json:"subcontract_id"`
	ClaimNumber   string `json:"claim_number"`

	PeriodStart *string `json:"period_start,omitempty"`
	PeriodEnd   string  `json:"period_end"`
	Status      string  `json:"status"`

	GrossWorkAmount          float64 `json:"gross_work_amount"`
	RetentionPercentSnapshot float64 `json:"retention_percent_snapshot"`
	RetentionAmount          float64 `json:"retention_amount"`
	AdvanceRecoveryAmount    float64 `json:"advance_recovery_amount"`
	OtherDeductions          float64 `json:"other_deductions"`
	PreviousCertifiedAmount  float64 `json:"previous_certified_amount"`
	CurrentCertifiedAmount   float64 `json:"current_certified_amount"`
	NetPayable               float64 `json:"net_payable"`

	SubmittedAt *string `json:"submitted_at,omitempty"`
	CertifiedAt *string `json:"certified_at,omitempty"`

	RejectedAt      *string `json:"rejected_at,omitempty"`
	RejectionReason string  `json:"rejection_reason,omitempty"`

	CancelledAt *string `json:"cancelled_at,omitempty"`

	Notes     string `json:"notes"`
	CreatedAt string `json:"created_at"`
	UpdatedAt string `json:"updated_at"`
}

func toProgressClaimResponse(pc domain.SubcontractProgressClaim) progressClaimResponse {
	periodEnd := pc.PeriodEnd.Format(dateLayout)
	return progressClaimResponse{
		ID: pc.ID, SubcontractID: pc.SubcontractID, ClaimNumber: pc.ClaimNumber,
		PeriodStart: dateStrPtr(pc.PeriodStart), PeriodEnd: periodEnd, Status: pc.Status,
		GrossWorkAmount: pc.GrossWorkAmount, RetentionPercentSnapshot: pc.RetentionPercentSnapshot,
		RetentionAmount: pc.RetentionAmount, AdvanceRecoveryAmount: pc.AdvanceRecoveryAmount,
		OtherDeductions: pc.OtherDeductions, PreviousCertifiedAmount: pc.PreviousCertifiedAmount,
		CurrentCertifiedAmount: pc.CurrentCertifiedAmount, NetPayable: pc.NetPayable,
		SubmittedAt: tsStrPtr(pc.SubmittedAt), CertifiedAt: tsStrPtr(pc.CertifiedAt),
		RejectedAt: tsStrPtr(pc.RejectedAt), RejectionReason: pc.RejectionReason,
		CancelledAt: tsStrPtr(pc.CancelledAt),
		Notes:       pc.Notes, CreatedAt: pc.CreatedAt.Format(rfc3339), UpdatedAt: pc.UpdatedAt.Format(rfc3339),
	}
}

type progressClaimItemResponse struct {
	ID                       string  `json:"id"`
	SubcontractItemID        string  `json:"subcontract_item_id"`
	ItemDescription          string  `json:"item_description"`
	ItemUnit                 string  `json:"item_unit"`
	ScheduledValue           float64 `json:"scheduled_value"`
	PreviousProgressAmount   float64 `json:"previous_progress_amount"`
	CurrentProgressAmount    float64 `json:"current_progress_amount"`
	CumulativeProgressAmount float64 `json:"cumulative_progress_amount"`
	ProgressPercent          float64 `json:"progress_percent"`
	RemainingAmount          float64 `json:"remaining_amount"`
	SortOrder                int     `json:"sort_order"`
}

func toProgressClaimItemResponse(i domain.SubcontractProgressClaimItem) progressClaimItemResponse {
	return progressClaimItemResponse{
		ID: i.ID, SubcontractItemID: i.SubcontractItemID, ItemDescription: i.ItemDescription, ItemUnit: i.ItemUnit,
		ScheduledValue: i.ScheduledValue, PreviousProgressAmount: i.PreviousProgressAmount,
		CurrentProgressAmount: i.CurrentProgressAmount, CumulativeProgressAmount: i.CumulativeProgressAmount,
		ProgressPercent: i.ProgressPercent(), RemainingAmount: i.RemainingAmount(), SortOrder: i.SortOrder,
	}
}

type progressClaimItemRequest struct {
	SubcontractItemID     string  `json:"subcontract_item_id"`
	CurrentProgressAmount float64 `json:"current_progress_amount"`
}

type progressClaimRequest struct {
	PeriodStart           *string                    `json:"period_start"`
	PeriodEnd             string                     `json:"period_end"`
	RetentionPercent      *float64                   `json:"retention_percent"`
	AdvanceRecoveryAmount float64                    `json:"advance_recovery_amount"`
	OtherDeductions       float64                    `json:"other_deductions"`
	Notes                 string                     `json:"notes"`
	Items                 []progressClaimItemRequest `json:"items"`
}

func (req progressClaimRequest) toInput(userID string) service.ProgressClaimInput {
	items := make([]service.ProgressClaimItemInput, len(req.Items))
	for i, it := range req.Items {
		items[i] = service.ProgressClaimItemInput{SubcontractItemID: it.SubcontractItemID, CurrentProgressAmount: it.CurrentProgressAmount}
	}
	periodEnd := parseDateParam(&req.PeriodEnd)
	in := service.ProgressClaimInput{
		PeriodStart: parseDateParam(req.PeriodStart), RetentionPercent: req.RetentionPercent,
		AdvanceRecoveryAmount: req.AdvanceRecoveryAmount, OtherDeductions: req.OtherDeductions,
		Notes: req.Notes, Items: items, UserID: userID,
	}
	if periodEnd != nil {
		in.PeriodEnd = *periodEnd
	}
	return in
}

func (h *ProjectHandler) ListSubcontractProgressClaims(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, err := h.svc.ListProgressClaims(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "subcontractId"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	out := make([]progressClaimResponse, len(rows))
	for i, pc := range rows {
		out[i] = toProgressClaimResponse(pc)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"progress_claims": out})
}

func (h *ProjectHandler) CreateSubcontractProgressClaim(w http.ResponseWriter, r *http.Request) {
	var req progressClaimRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	pc, err := h.svc.CreateProgressClaim(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "subcontractId"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toProgressClaimResponse(*pc))
}

func (h *ProjectHandler) GetSubcontractProgressClaim(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	projectID, claimID := chi.URLParam(r, "id"), chi.URLParam(r, "claimId")
	pc, err := h.svc.GetProgressClaim(r.Context(), projectID, claimID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	items, err := h.svc.ListProgressClaimItems(r.Context(), projectID, claimID, orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	itemsOut := make([]progressClaimItemResponse, len(items))
	for i, it := range items {
		itemsOut[i] = toProgressClaimItemResponse(it)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"progress_claim": toProgressClaimResponse(*pc), "items": itemsOut})
}

func (h *ProjectHandler) UpdateSubcontractProgressClaim(w http.ResponseWriter, r *http.Request) {
	var req progressClaimRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	pc, err := h.svc.UpdateProgressClaimDraft(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "claimId"), orgID, req.toInput(userID))
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProgressClaimResponse(*pc))
}

func (h *ProjectHandler) SubmitSubcontractProgressClaim(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	pc, err := h.svc.SubmitProgressClaim(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "claimId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProgressClaimResponse(*pc))
}

func (h *ProjectHandler) CertifySubcontractProgressClaim(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	pc, err := h.svc.CertifyProgressClaim(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "claimId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProgressClaimResponse(*pc))
}

func (h *ProjectHandler) RejectSubcontractProgressClaim(w http.ResponseWriter, r *http.Request) {
	var req voidRequest
	_ = httpjson.Decode(r, &req)
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	pc, err := h.svc.RejectProgressClaim(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "claimId"), orgID, userID, req.Reason)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProgressClaimResponse(*pc))
}

func (h *ProjectHandler) CancelSubcontractProgressClaim(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	pc, err := h.svc.CancelProgressClaim(r.Context(), chi.URLParam(r, "id"), chi.URLParam(r, "claimId"), orgID, userID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProgressClaimResponse(*pc))
}
