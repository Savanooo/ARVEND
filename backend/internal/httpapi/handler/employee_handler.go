package handler

import (
	"errors"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type EmployeeHandler struct {
	svc *service.EmployeeService
}

func NewEmployeeHandler(svc *service.EmployeeService) *EmployeeHandler {
	return &EmployeeHandler{svc: svc}
}

type employeeResponse struct {
	ID          string   `json:"id"`
	FullName    string   `json:"full_name"`
	Phone       string   `json:"phone"`
	Position    string   `json:"position"`
	Salary      *float64 `json:"salary"`
	DailyWage   *float64 `json:"daily_wage"`
	StartDate   *string  `json:"start_date"`
	IsActive    bool     `json:"is_active"`
	Description string   `json:"description"`
	// UserID, bağlı login hesabıdır (nullable) -- "Bağlı Kullanıcı Hesabı"
	// web alanının okuma yönü, bkz. docs/... GET /tasks/mine'ın tek
	// kaynağı (migration 0041).
	UserID *string `json:"user_id"`
}

// toEmployeeResponse: ücretler (maaş/yevmiye) yalnızca employees.manage
// sahibine döner. employees.read mesai girişi için de verilir ve kişiye
// özel yetkilerle Sahip/Yönetici dışındaki üyelere açılabilir -- personel
// listesini görmek maaşları görmek anlamına gelmemeli.
func toEmployeeResponse(e domain.Employee, showWages bool) employeeResponse {
	resp := employeeResponse{
		ID:          e.ID,
		FullName:    e.FullName,
		Phone:       e.Phone,
		Position:    e.Position,
		IsActive:    e.IsActive,
		Description: e.Description,
		UserID:      e.UserID,
	}
	if showWages {
		resp.Salary = e.Salary
		resp.DailyWage = e.DailyWage
	}
	if e.StartDate != nil {
		s := e.StartDate.Format("2006-01-02")
		resp.StartDate = &s
	}
	return resp
}

func canSeeEmployeeWages(r *http.Request) bool {
	authz, ok := middleware.AuthzContextFromRequest(r.Context())
	return ok && authz.HasPermission(domain.PermEmployeesManage)
}

func (h *EmployeeHandler) List(w http.ResponseWriter, r *http.Request) {
	var activeOnly *bool
	switch r.URL.Query().Get("filter") {
	case "aktif":
		v := true
		activeOnly = &v
	case "pasif":
		v := false
		activeOnly = &v
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	employees, err := h.svc.List(r.Context(), orgID, activeOnly)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "personel listesi alınamadı")
		return
	}
	showWages := canSeeEmployeeWages(r)
	out := make([]employeeResponse, len(employees))
	for i, e := range employees {
		out[i] = toEmployeeResponse(e, showWages)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"employees": out})
}

func (h *EmployeeHandler) Get(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	e, err := h.svc.Get(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toEmployeeResponse(*e, canSeeEmployeeWages(r)))
}

type upsertEmployeeRequest struct {
	FullName    string   `json:"full_name"`
	Phone       string   `json:"phone"`
	Position    string   `json:"position"`
	Salary      *float64 `json:"salary"`
	DailyWage   *float64 `json:"daily_wage"`
	StartDate   *string  `json:"start_date"`
	Description string   `json:"description"`
	IsActive    bool     `json:"is_active"`
	// UserID, nil/boş = bağlantı yok, dolu = bağla/değiştir. Web formu
	// "Bağlı Kullanıcı Hesabı" alanının TAM DURUMUNU her istekte gönderir
	// (kısmi PATCH değildir), bkz. service.EmployeeInput.UserID yorumu.
	UserID *string `json:"user_id"`
}

func (req upsertEmployeeRequest) toInput() (service.EmployeeInput, error) {
	in := service.EmployeeInput{
		FullName:    req.FullName,
		Phone:       req.Phone,
		Position:    req.Position,
		Salary:      req.Salary,
		DailyWage:   req.DailyWage,
		Description: req.Description,
		IsActive:    req.IsActive,
		UserID:      req.UserID,
	}
	if req.StartDate != nil && *req.StartDate != "" {
		t, err := time.Parse("2006-01-02", *req.StartDate)
		if err != nil {
			return in, errors.New("geçersiz işe başlama tarihi")
		}
		in.StartDate = &t
	}
	return in, nil
}

func (h *EmployeeHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req upsertEmployeeRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	req.IsActive = true
	in, err := req.toInput()
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	in.ChangedBy, _ = middleware.UserIDFromContext(r.Context())
	e, err := h.svc.Create(r.Context(), orgID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toEmployeeResponse(*e, canSeeEmployeeWages(r)))
}

func (h *EmployeeHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req upsertEmployeeRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	in, err := req.toInput()
	if err != nil {
		httpjson.Error(w, http.StatusBadRequest, err.Error())
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	in.ChangedBy, _ = middleware.UserIDFromContext(r.Context())
	e, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), orgID, in)
	if err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toEmployeeResponse(*e, canSeeEmployeeWages(r)))
}

func (h *EmployeeHandler) Archive(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	if err := h.svc.Archive(r.Context(), chi.URLParam(r, "id"), orgID); err != nil {
		h.writeError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *EmployeeHandler) writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "personel bulunamadı")
	case errors.Is(err, service.ErrEmployeeUserAlreadyLinked):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrEmployeeUserCrossOrg):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case isInternalError(err):
		// Ham veritabanı metni (tablo/kısıt adları) kullanıcıya gitmesin.
		writeInternalError(w, err)
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
