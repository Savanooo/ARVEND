package handler

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type ProjectHandler struct {
	svc *service.ProjectService
}

func NewProjectHandler(svc *service.ProjectService) *ProjectHandler {
	return &ProjectHandler{svc: svc}
}

type projectResponse struct {
	ID               string  `json:"id"`
	ProjectNo        string  `json:"project_no"`
	Name             string  `json:"name"`
	ProjectType      string  `json:"project_type"`
	SourceOfferID    string  `json:"source_offer_id"`
	SourceOfferNo    string  `json:"source_offer_no"`
	SourceRevisionID string  `json:"source_revision_id"`
	SourceRevisionNo int     `json:"source_revision_no"`
	CustomerID       *string `json:"customer_id"`
	CustomerName     string  `json:"customer_name"`
	CustomerPhone    string  `json:"customer_phone"`
	CustomerEmail    string  `json:"customer_email"`
	CustomerAddress  string  `json:"customer_address"`
	ContractAmount   float64 `json:"contract_amount"`
	Currency         string  `json:"currency"`
	Status           string  `json:"status"`
	StartDate        *string `json:"start_date"`
	EndDate          *string `json:"end_date"`
	Description      string  `json:"description"`
	InternalNotes    string  `json:"internal_notes"`
	CreatedBy        *string `json:"created_by"`
	CreatedAt        string  `json:"created_at"`
	UpdatedAt        string  `json:"updated_at"`

	// Liste ekranı için aggregate finans alanları. YALNIZCA List
	// yanıtında dolu (pointer + omitempty): tekil okuma yollarında
	// (Get/GetByOffer/Create/Update) bu alanlar hiç sorgulanmadığı için
	// json'da TAMAMEN YOKTUR -- "0" değeri "gerçek sıfır" ile "bu uçta
	// hiç hesaplanmadı"yı ayırt edemezdi ve bu, financial-summary'nin
	// döndürdüğü gerçek (sıfır olmayan) değerlerle çelişen, yanlış finans
	// bilgisi taşıyan bir yanıt üretiyordu (bkz. denetim bulgusu). Proje
	// detayının gerçek finans kaynağı her zaman
	// GET /projects/{id}/financial-summary'dir.
	CollectedAmount        *float64 `json:"collected_amount,omitempty"`
	TotalExpenses          *float64 `json:"total_expenses,omitempty"`
	SubcontractorPaid      *float64 `json:"subcontractor_paid,omitempty"`
	SubcontractorRemaining *float64 `json:"subcontractor_remaining,omitempty"`
	NewSubcontractPaid     *float64 `json:"new_subcontract_paid,omitempty"`
	RemainingReceivable    *float64 `json:"remaining_receivable,omitempty"`
	RealizedCost           *float64 `json:"realized_cost,omitempty"`
	RealizedGrossProfit    *float64 `json:"realized_gross_profit,omitempty"`
	InvoiceCount           *int64   `json:"invoice_count,omitempty"`
	PaidInvoiceCount       *int64   `json:"paid_invoice_count,omitempty"`
	// ChangeOrderNet/CurrentContractValue, Faz 8: onaylı ek iş/eksiltme
	// net etkisi ve ondan türetilen güncel proje bedeli (ana sözleşme
	// ASLA değişmez -- bkz. domain.Project.CurrentContractValue).
	ChangeOrderNet       *float64 `json:"change_order_net,omitempty"`
	CurrentContractValue *float64 `json:"current_contract_value,omitempty"`
}

func toProjectResponse(p domain.Project) projectResponse {
	resp := projectResponse{
		ID:               p.ID,
		ProjectNo:        p.ProjectNo,
		Name:             p.Name,
		ProjectType:      p.ProjectType,
		SourceOfferID:    p.SourceOfferID,
		SourceOfferNo:    p.SourceOfferNo,
		SourceRevisionID: p.SourceRevisionID,
		SourceRevisionNo: p.SourceRevisionNo,
		CustomerID:       p.CustomerID,
		CustomerName:     p.CustomerName,
		CustomerPhone:    p.CustomerPhone,
		CustomerEmail:    p.CustomerEmail,
		CustomerAddress:  p.CustomerAddress,
		ContractAmount:   p.ContractAmount,
		Currency:         p.Currency,
		Status:           p.Status,
		Description:      p.Description,
		InternalNotes:    p.InternalNotes,
		CreatedBy:        p.CreatedBy,
		CreatedAt:        p.CreatedAt.Format(rfc3339),
		UpdatedAt:        p.UpdatedAt.Format(rfc3339),
	}
	if p.HasFinanceAggregates {
		resp.CollectedAmount = &p.CollectedAmount
		resp.TotalExpenses = &p.TotalExpenses
		resp.SubcontractorPaid = &p.SubcontractorPaid
		resp.SubcontractorRemaining = &p.SubcontractorRemaining
		resp.NewSubcontractPaid = &p.NewSubcontractPaid
		remaining := p.RemainingReceivable()
		resp.RemainingReceivable = &remaining
		realizedCost := p.RealizedCost()
		resp.RealizedCost = &realizedCost
		realizedProfit := p.RealizedGrossProfit()
		resp.RealizedGrossProfit = &realizedProfit
		resp.InvoiceCount = &p.InvoiceCount
		resp.PaidInvoiceCount = &p.PaidInvoiceCount
		resp.ChangeOrderNet = &p.ChangeOrderNet
		current := p.CurrentContractValue()
		resp.CurrentContractValue = &current
	}
	if p.StartDate != nil {
		s := p.StartDate.Format(dateLayout)
		resp.StartDate = &s
	}
	if p.EndDate != nil {
		s := p.EndDate.Format(dateLayout)
		resp.EndDate = &s
	}
	return resp
}

func parseDateParam(raw *string) *time.Time {
	if raw == nil || *raw == "" {
		return nil
	}
	t, err := time.Parse(dateLayout, *raw)
	if err != nil {
		return nil
	}
	return &t
}

type createProjectRequest struct {
	Name        string  `json:"name"`
	ProjectType string  `json:"project_type"`
	StartDate   *string `json:"start_date"`
	EndDate     *string `json:"end_date"`
	Description string  `json:"description"`
}

func (h *ProjectHandler) CreateFromOffer(w http.ResponseWriter, r *http.Request) {
	var req createProjectRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.CreateFromOffer(r.Context(), chi.URLParam(r, "offerId"), orgID, service.CreateProjectInput{
		Name:        req.Name,
		ProjectType: req.ProjectType,
		StartDate:   parseDateParam(req.StartDate),
		EndDate:     parseDateParam(req.EndDate),
		Description: req.Description,
		UserID:      userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toProjectResponse(*p))
}

func (h *ProjectHandler) List(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	page, _ := strconv.Atoi(q.Get("page"))
	limit, _ := strconv.Atoi(q.Get("limit"))
	startFrom := q.Get("start_from")

	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	// RBAC/Project Membership sprint'i: owner/admin/legacy_user organizasyon
	// içindeki TÜM projeleri görür (RestrictToUserID boş); project_manager/
	// finance/field yalnızca ATANDIĞI projeleri görür (bkz.
	// domain.RoleBypassesProjectMembership -- TEK kaynak, burada TEKRAR
	// karar VERİLMEZ, yalnızca okunur).
	var restrictToUserID string
	if authz, ok := middleware.AuthzContextFromRequest(r.Context()); ok && !authz.BypassesProjectMembership() {
		restrictToUserID = authz.UserID
	}
	result, err := h.svc.List(r.Context(), orgID, service.ProjectListFilter{
		Status:           q.Get("status"),
		CustomerID:       q.Get("customer_id"),
		ProjectType:      q.Get("project_type"),
		Currency:         q.Get("currency"),
		StartFrom:        parseDateParam(&startFrom),
		Search:           q.Get("q"),
		Page:             page,
		Limit:            limit,
		RestrictToUserID: restrictToUserID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	projects := make([]projectResponse, len(result.Projects))
	for i, p := range result.Projects {
		projects[i] = toProjectResponse(p)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"projects": projects, "total": result.Total})
}

func (h *ProjectHandler) Get(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	p, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProjectResponse(*p))
}

// GetByOffer, teklifin projeye dönüştürülüp dönüştürülmediğini söyler.
// Dönüştürülmemişse 404 döner -- frontend bunu "Projeye Dönüştür"
// butonunu göstermek için kullanır.
//
// Uç /offers altında (offers.read) durur ama yanıt PROJENİN kendisidir
// (sözleşme bedeli, iç notlar...): bu yüzden /projects/{id} ile AYNI kapı
// uygulanır -- projects.read izni VE proje erişimi (owner/admin dışındakiler
// için proje üyeliği, bkz. AuthorizationService.CanAccessProject). Eskiden
// offers.read'i olan herkes üyesi olmadığı projelerin bu bilgilerini
// okuyabiliyordu. İzin kontrolü projeye bakmadan önce yapılır (izinsiz
// kullanıcı projenin varlığını da öğrenmez).
func (h *ProjectHandler) GetByOffer(authzSvc *service.AuthorizationService) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		authz, ok := middleware.AuthzContextFromRequest(r.Context())
		if !ok || !authz.HasPermission(domain.PermProjectsRead) {
			httpjson.Write(w, http.StatusForbidden, map[string]string{
				"error": "bu işlem için yetkiniz yok", "code": "permission_denied",
			})
			return
		}
		orgID, _ := middleware.OrganizationIDFromContext(r.Context())
		p, err := h.svc.GetByOfferID(r.Context(), chi.URLParam(r, "id"), orgID)
		if err != nil {
			h.writeError(w, err)
			return
		}
		canAccess, err := authzSvc.CanAccessProject(r.Context(), authz, p.ID)
		if err != nil {
			h.writeError(w, err)
			return
		}
		if !canAccess {
			httpjson.Write(w, http.StatusForbidden, map[string]string{
				"error": "bu projeye erişim yetkiniz yok", "code": "project_access_denied",
			})
			return
		}
		httpjson.Write(w, http.StatusOK, toProjectResponse(*p))
	}
}

type updateProjectRequest struct {
	Name          string  `json:"name"`
	ProjectType   string  `json:"project_type"`
	Status        string  `json:"status"`
	StartDate     *string `json:"start_date"`
	EndDate       *string `json:"end_date"`
	Description   string  `json:"description"`
	InternalNotes string  `json:"internal_notes"`
}

func (h *ProjectHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req updateProjectRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	// UserID: proje güncelleme/durum değişikliği olayının yazarı -- eskiden
	// geçirilmediği için aktivite geçmişinde bu olaylar yazarsız (user_id
	// NULL) görünüyordu.
	userID, _ := middleware.UserIDFromContext(r.Context())
	p, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), orgID, service.UpdateProjectInput{
		Name:          req.Name,
		ProjectType:   req.ProjectType,
		Status:        req.Status,
		StartDate:     parseDateParam(req.StartDate),
		EndDate:       parseDateParam(req.EndDate),
		Description:   req.Description,
		InternalNotes: req.InternalNotes,
		UserID:        userID,
	})
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toProjectResponse(*p))
}

func (h *ProjectHandler) writeError(w http.ResponseWriter, err error) {
	var notFound *service.NotFoundError
	switch {
	case errors.As(err, &notFound):
		// İstekte gönderilen bir referans (bütçe kalemi, tedarikçi, SOV
		// kalemi...) bulunamadı -- "proje bulunamadı" yanıltıcı olurdu.
		httpjson.Error(w, http.StatusNotFound, notFound.Error())
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "proje bulunamadı")
	case errors.Is(err, service.ErrPaymentExceedsContract),
		errors.Is(err, service.ErrPaymentExceedsClaim):
		// Metin rakamları ve ne yapılacağını içerir (bkz. PaymentExceedsContractError).
		httpjson.Error(w, http.StatusUnprocessableEntity, err.Error())
	case errors.Is(err, service.ErrBudgetNotFound):
		httpjson.Error(w, http.StatusNotFound, err.Error())
	case errors.Is(err, service.ErrBudgetAlreadyExists),
		errors.Is(err, service.ErrBudgetNotBaselinable),
		errors.Is(err, service.ErrBudgetBaselined),
		errors.Is(err, service.ErrBudgetNotYetBaselined),
		errors.Is(err, service.ErrAdjustmentNotPending),
		// 403 değil 409: istemciler 403'ü sabit "yetkin yok" metnine
		// çeviriyor; bu bir izin eksikliği değil, kayda bağlı bir kural ve
		// mesajın kendisi ne yapılacağını söylüyor.
		errors.Is(err, service.ErrOwnAdjustmentDecision),
		errors.Is(err, service.ErrAdjustmentWouldGoNegative),
		errors.Is(err, service.ErrDuplicateWBSCode),
		errors.Is(err, service.ErrCommitmentNotActive),
		errors.Is(err, service.ErrCommitmentNotManual):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrInvalidWBSParent),
		errors.Is(err, service.ErrArchivedWBSParent),
		errors.Is(err, service.ErrInvalidWBSNodeRef),
		errors.Is(err, service.ErrArchivedWBSNodeRef),
		errors.Is(err, service.ErrInvalidBudgetLineCostCode):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrWBSHasActiveChildren):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrContractNotFound):
		httpjson.Error(w, http.StatusNotFound, err.Error())
	case errors.Is(err, service.ErrContractAlreadyExists),
		errors.Is(err, service.ErrContractNotEditable),
		errors.Is(err, service.ErrContractNotesNotEditable),
		errors.Is(err, service.ErrContractNotActivatable),
		errors.Is(err, service.ErrContractNotCancellable),
		errors.Is(err, service.ErrContractNotCompletable),
		errors.Is(err, service.ErrContractNotTerminable):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrContractReasonRequired):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrDuplicateSupplierCode):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrSupplierFieldsRequired):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrPurchaseRequestNotEditable),
		errors.Is(err, service.ErrPurchaseRequestNotSubmittable),
		errors.Is(err, service.ErrPurchaseRequestNotWithdrawable),
		errors.Is(err, service.ErrPurchaseRequestNotApprovable),
		errors.Is(err, service.ErrPurchaseRequestNotRejectable),
		errors.Is(err, service.ErrPurchaseRequestNotCancellable),
		errors.Is(err, service.ErrPurchaseRequestItemsRequired):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrPurchaseRequestReasonRequired):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrRFQNotEditable),
		errors.Is(err, service.ErrRFQNotIssuable),
		errors.Is(err, service.ErrRFQNotCloseable),
		errors.Is(err, service.ErrRFQNotCancellable),
		errors.Is(err, service.ErrRFQNotAwardable),
		errors.Is(err, service.ErrRFQItemsRequired),
		errors.Is(err, service.ErrRFQSuppliersRequired),
		errors.Is(err, service.ErrPurchaseRequestNotApprovedForRFQ),
		errors.Is(err, service.ErrQuotationSupplierNotInvited),
		errors.Is(err, service.ErrQuotationRFQNotOpen),
		errors.Is(err, service.ErrQuotationItemsRequired),
		errors.Is(err, service.ErrAwardQuotationMismatch):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrPurchaseOrderNotEditable),
		errors.Is(err, service.ErrPurchaseOrderNotApprovable),
		errors.Is(err, service.ErrPurchaseOrderNotCancellable),
		errors.Is(err, service.ErrPurchaseOrderNotCloseable),
		errors.Is(err, service.ErrPurchaseOrderItemsRequired),
		errors.Is(err, service.ErrPurchaseOrderSupplierInactive),
		errors.Is(err, service.ErrPurchaseOrderQuotationNotAwarded),
		errors.Is(err, service.ErrPurchaseOrderSupplierMismatch),
		errors.Is(err, service.ErrPurchaseOrderQuotationAlreadyOrdered):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrPurchaseOrderReasonRequired):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrSubcontractNotEditable),
		errors.Is(err, service.ErrSubcontractNotActivatable),
		errors.Is(err, service.ErrSubcontractNotCompletable),
		errors.Is(err, service.ErrSubcontractNotCancellable),
		errors.Is(err, service.ErrSubcontractNotTerminable),
		errors.Is(err, service.ErrSubcontractItemsRequired),
		errors.Is(err, service.ErrSubcontractSupplierInactive),
		errors.Is(err, service.ErrSubcontractChangeOrderNotEditable),
		errors.Is(err, service.ErrSubcontractChangeOrderNotSubmittable),
		errors.Is(err, service.ErrSubcontractChangeOrderNotApprovable),
		errors.Is(err, service.ErrSubcontractChangeOrderNotRejectable),
		errors.Is(err, service.ErrSubcontractChangeOrderNotCancellable),
		errors.Is(err, service.ErrSubcontractChangeOrderItemsRequired),
		errors.Is(err, service.ErrSubcontractNotActiveForChange),
		errors.Is(err, service.ErrProgressClaimNotEditable),
		errors.Is(err, service.ErrProgressClaimNotSubmittable),
		errors.Is(err, service.ErrProgressClaimNotCertifiable),
		errors.Is(err, service.ErrProgressClaimNotRejectable),
		errors.Is(err, service.ErrProgressClaimNotCancellable),
		errors.Is(err, service.ErrProgressClaimItemsRequired),
		errors.Is(err, service.ErrProgressClaimOverrun),
		errors.Is(err, service.ErrProgressClaimDuplicateItem),
		errors.Is(err, service.ErrProgressClaimExceedsContract),
		errors.Is(err, service.ErrSubcontractChangeBelowCertified),
		errors.Is(err, service.ErrProgressClaimStale),
		errors.Is(err, service.ErrSubcontractNotActiveForClaim),
		errors.Is(err, service.ErrSubcontractNotCertifiable):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrSubcontractReasonRequired),
		errors.Is(err, service.ErrSubcontractChangeOrderReasonRequired),
		errors.Is(err, service.ErrProgressClaimReasonRequired):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrTitleRequired),
		errors.Is(err, service.ErrItemDescriptionRequired),
		errors.Is(err, service.ErrInvalidQuantity),
		errors.Is(err, service.ErrInvalidUnitPrice),
		errors.Is(err, service.ErrInvalidChangeType),
		errors.Is(err, service.ErrInvalidRetentionPercent),
		errors.Is(err, service.ErrInvalidTaxRate),
		errors.Is(err, service.ErrNegativeDeduction),
		errors.Is(err, service.ErrNegativeDiscount),
		errors.Is(err, service.ErrNegativeAdvance),
		errors.Is(err, service.ErrNegativeProgress),
		errors.Is(err, service.ErrQuotationDuplicateItem),
		errors.Is(err, service.ErrInvalidProfitPercent),
		errors.Is(err, service.ErrInvalidExpenseVATRate),
		errors.Is(err, service.ErrInvalidAmount):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrOfferNotAccepted),
		errors.Is(err, service.ErrInvalidProjectState),
		errors.Is(err, service.ErrProjectLocked),
		errors.Is(err, service.ErrCurrencyMismatch),
		errors.Is(err, service.ErrAlreadyVoided),
		errors.Is(err, service.ErrDuplicateMember),
		errors.Is(err, service.ErrDuplicateContent),
		errors.Is(err, service.ErrChangeOrderNotEditable),
		errors.Is(err, service.ErrChangeOrderNotSendable),
		errors.Is(err, service.ErrChangeOrderNotCancellable),
		errors.Is(err, service.ErrChangeOrderNotRevisable),
		errors.Is(err, service.ErrChangeOrderNotRespondable),
		errors.Is(err, service.ErrChangeOrderWouldGoNegative),
		errors.Is(err, service.ErrExpenseNotPending):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrExpenseRejectReasonRequired),
		errors.Is(err, service.ErrExpenseRejectReasonTooLong):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrFileTooLarge):
		httpjson.Error(w, http.StatusRequestEntityTooLarge, err.Error())
	case errors.Is(err, service.ErrInvalidEmployee),
		errors.Is(err, service.ErrInvalidSchedule),
		errors.Is(err, service.ErrUnsupportedType),
		errors.Is(err, service.ErrEmptyFile),
		errors.Is(err, service.ErrAssigneeNoProjectAccess),
		errors.Is(err, service.ErrProjectFieldTooLong),
		errors.Is(err, service.ErrInvalidChangeOrderRef),
		errors.Is(err, service.ErrNoChangeOrderItems):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, service.ErrStorageFailure):
		writeInternalError(w, err)
	case isInternalError(err), isUnexpectedServiceError(err):
		writeInternalError(w, err)
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}

// isUnexpectedServiceError: isInternalError'un (pgconn/ağ/context)
// yakalamadığı ama yine de bir GİRDİ hatası olmayan pgx sentinel'leri. Bir
// servis yolunda eşlemesi unutulmuş pgx.ErrNoRows eskiden "no rows in
// result set" ham metniyle 400 dönüyordu; bunlar sunucu hatasıdır (500,
// ayrıntı yalnızca logda).
func isUnexpectedServiceError(err error) bool {
	return errors.Is(err, pgx.ErrNoRows) || errors.Is(err, pgx.ErrTooManyRows) ||
		errors.Is(err, pgx.ErrTxClosed) || errors.Is(err, pgx.ErrTxCommitRollback)
}
