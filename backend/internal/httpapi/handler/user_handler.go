package handler

import (
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/httpapi/middleware"
	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
	"github.com/Savanooo/ARVEND/backend/internal/service"
)

type UserHandler struct {
	svc      *service.UserService
	authzSvc *service.AuthorizationService
}

func NewUserHandler(svc *service.UserService, authzSvc *service.AuthorizationService) *UserHandler {
	return &UserHandler{svc: svc, authzSvc: authzSvc}
}

// List/Get, RBAC/Project Membership sprint'inden itibaren AuthorizationService'in
// organizasyon-rolüyle zenginleştirilmiş sorgusunu kullanır (N+1'siz TEK
// JOIN) -- UserService'in kendi CRUD metodları (Create/Update/Deactivate)
// BUNDAN ETKİLENMEZ.
func (h *UserHandler) List(w http.ResponseWriter, r *http.Request) {
	page, _ := strconv.Atoi(r.URL.Query().Get("page"))
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	rows, total, err := h.authzSvc.ListUsersWithRoles(r.Context(), orgID, page, limit)
	if err != nil {
		httpjson.Error(w, http.StatusInternalServerError, "kullanıcılar alınamadı")
		return
	}
	users := make([]userResponse, len(rows))
	for i, u := range rows {
		users[i] = toUserResponse(u)
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"users": users, "total": total})
}

func (h *UserHandler) Get(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	user, err := h.authzSvc.GetUserWithRole(r.Context(), chi.URLParam(r, "id"), orgID)
	if err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toUserResponse(*user))
}

type setUserOrganizationRoleRequest struct {
	RoleCode string `json:"role_code"`
}

// SetOrganizationRole, kullanıcının RBAC/Project Membership sprint'indeki
// ince-taneli organizasyon rolünü değiştirir (users.role -- admin/kullanici
// -- İLE KARIŞTIRILMAMALI, o alan bu uçtan HİÇ değişmez). "super_admin"
// kodu asla kabul EDİLMEZ çünkü organization_roles tablosunda böyle bir
// satır hiç yoktur (yalnızca migration'ın seed ettiği 6 tenant rolü) --
// GetOrganizationRoleByCode bulamaz, domain.ErrNotFound döner.
func (h *UserHandler) SetOrganizationRole(w http.ResponseWriter, r *http.Request) {
	var req setUserOrganizationRoleRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	actorID, _ := middleware.UserIDFromContext(r.Context())
	role, err := h.authzSvc.SetUserOrganizationRole(r.Context(), chi.URLParam(r, "id"), orgID, actorID, req.RoleCode)
	if err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]any{"organization_role_code": role.Code, "organization_role_name": role.Name})
}

type createUserRequest struct {
	Username             string `json:"username"`
	Password             string `json:"password"`
	FullName             string `json:"full_name"`
	OrganizationRoleCode string `json:"organization_role_code"`
	personnelRequest
}

// personnelRequest, hesap açan iki ucun (tenant POST /users, Süper Admin
// POST /platform/organizations/{id}/users) ortak personel alanlarıdır.
// Hepsi opsiyonel ve pointer: alan HİÇ gönderilmezse varsayılan (personel
// kaydı oluştur / aynı adlıya bağla) uygulanır -- dondurulmuş web bu
// alanları bilmeden yeni davranışı alır. Bkz. service.PersonnelOptions.
type personnelRequest struct {
	CreateEmployee *bool   `json:"create_employee"`
	EmployeeID     *string `json:"employee_id"`
	LinkSameName   *bool   `json:"link_same_name"`
}

func (p personnelRequest) options(canManageEmployees bool) service.PersonnelOptions {
	opts := service.PersonnelOptions{
		CreateEmployee: p.CreateEmployee, LinkSameName: p.LinkSameName, CanManageEmployees: canManageEmployees,
	}
	if p.EmployeeID != nil {
		opts.EmployeeID = strings.TrimSpace(*p.EmployeeID)
	}
	return opts
}

// Create, tenant self-servis "Yeni Kullanıcı" ucudur (Süper Admin'in AYRI
// platform.ProvisionOrganizationUser'ının kiracı tarafındaki eşdeğeri).
// `organization_role_code` ZORUNLUDUR -- eskiden burada yalnızca kaba bir
// `role` (admin/kullanici) alınırdı ve organizasyon rolü HİÇ sorulmazdı,
// bu yüzden UserService.Create'in bootstrap-only varsayım zincirine düşüp
// her yeni kullanıcıyı sessizce "legacy_user" (migration-only, atama
// HEDEFİ olmayan bir rol) yapıyordu -- web'de "(Eski Sistem)" rozetiyle
// görünen gerçek bir üretim hatasıydı, düzeltildi.
func (h *UserHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req createUserRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	if strings.TrimSpace(req.OrganizationRoleCode) == "" {
		httpjson.Error(w, http.StatusBadRequest, "organizasyon rolü zorunludur")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	actorID, _ := middleware.UserIDFromContext(r.Context())
	// Personel kaydı açmak/bağlamak employees.manage ister (personel
	// ekranındaki ile aynı sınır); izin yoksa hesap yine açılır, personel
	// adımı atlanır (employee_link.status = no_permission).
	user, link, err := h.svc.CreateMember(r.Context(), orgID, actorID, req.Username, req.Password, req.FullName,
		req.OrganizationRoleCode, req.personnelRequest.options(canSeeEmployeeWages(r)))
	if err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusCreated, toCreatedUserResponse(*user, link))
}

type updateUserRequest struct {
	FullName string `json:"full_name"`
	IsActive bool   `json:"is_active"`
}

// Update, kullanıcının profilini (ad soyad + aktiflik) değiştirir. Rol
// artık BU uçtan alınmaz -- organizasyon rolü (SetOrganizationRole)
// kaba users.role'ü de senkronlar (bkz. UserService.Update yorumu);
// isteğin gövdesinde bir "role" alanı olsa bile YOK SAYILIR.
func (h *UserHandler) Update(w http.ResponseWriter, r *http.Request) {
	var req updateUserRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	actorID, _ := middleware.UserIDFromContext(r.Context())
	user, err := h.svc.Update(r.Context(), chi.URLParam(r, "id"), orgID, actorID, req.FullName, req.IsActive)
	if err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, toUserResponse(*user))
}

func (h *UserHandler) Deactivate(w http.ResponseWriter, r *http.Request) {
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	actorID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.Deactivate(r.Context(), chi.URLParam(r, "id"), orgID, actorID); err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type changeOwnPasswordRequest struct {
	CurrentPassword string `json:"current_password"`
	NewPassword     string `json:"new_password"`
}

func (h *UserHandler) ChangeOwnPassword(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.UserIDFromContext(r.Context())
	if !ok {
		httpjson.Error(w, http.StatusUnauthorized, "oturum bulunamadı")
		return
	}
	var req changeOwnPasswordRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	// Şifre değişince diğer oturumlar kapanır; bu cihazınki açık kalsın diye
	// onun refresh token'ı (HttpOnly cookie, web ve mobil ikisi de taşır)
	// servise verilir.
	if err := h.svc.ChangeOwnPassword(r.Context(), userID, orgID, req.CurrentPassword, req.NewPassword, currentRefreshToken(r)); err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type setInitialPasswordRequest struct {
	NewPassword string `json:"new_password"`
}

// SetInitialPassword, "şifre belirle" (must_change_password) akışıdır --
// mevcut şifre istemez (kullanıcı zaten oturum açmış durumda), yalnızca
// requireAuth arkasındadır (requireAdmin YOK -- her rol kendi ilk şifresini
// belirleyebilmeli).
func (h *UserHandler) SetInitialPassword(w http.ResponseWriter, r *http.Request) {
	userID, ok := middleware.UserIDFromContext(r.Context())
	if !ok {
		httpjson.Error(w, http.StatusUnauthorized, "oturum bulunamadı")
		return
	}
	var req setInitialPasswordRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	if err := h.svc.SetInitialPassword(r.Context(), userID, orgID, req.NewPassword, currentRefreshToken(r)); err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

type resetPasswordRequest struct {
	NewPassword string `json:"new_password"`
}

func (h *UserHandler) AdminResetPassword(w http.ResponseWriter, r *http.Request) {
	var req resetPasswordRequest
	if err := httpjson.Decode(r, &req); err != nil {
		httpjson.Error(w, http.StatusBadRequest, "geçersiz istek gövdesi")
		return
	}
	orgID, _ := middleware.OrganizationIDFromContext(r.Context())
	actorID, _ := middleware.UserIDFromContext(r.Context())
	if err := h.svc.AdminResetPassword(r.Context(), chi.URLParam(r, "id"), orgID, actorID, req.NewPassword); err != nil {
		h.writeUserError(w, err)
		return
	}
	httpjson.Write(w, http.StatusOK, map[string]bool{"ok": true})
}

// currentRefreshToken, isteği yapan cihazın refresh token'ı (yoksa "").
func currentRefreshToken(r *http.Request) string {
	if c, err := r.Cookie("refresh_token"); err == nil {
		return c.Value
	}
	return ""
}

func (h *UserHandler) writeUserError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrNotFound):
		httpjson.Error(w, http.StatusNotFound, "kullanıcı bulunamadı")
	case errors.Is(err, domain.ErrDuplicateUsername):
		httpjson.Error(w, http.StatusConflict, "bu kullanıcı adı zaten kullanılıyor")
	case errors.Is(err, domain.ErrInvalidCredentials):
		httpjson.Error(w, http.StatusBadRequest, "mevcut şifre hatalı")
	case errors.Is(err, domain.ErrLastOwner), errors.Is(err, domain.ErrInitialPasswordAlreadySet):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, domain.ErrOwnerOnlyAction), errors.Is(err, service.ErrEmployeeLinkNotPermitted):
		httpjson.Error(w, http.StatusForbidden, err.Error())
	case errors.Is(err, service.ErrEmployeeHasOtherUser):
		httpjson.Error(w, http.StatusConflict, err.Error())
	case errors.Is(err, service.ErrLinkEmployeeNotFound):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, domain.ErrCannotAssignSuperAdmin), errors.Is(err, domain.ErrCrossOrgMembership),
		errors.Is(err, domain.ErrPasswordTooShort):
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	case isInternalError(err):
		// Ham veritabanı metni kullanıcıya gitmesin.
		writeInternalError(w, err)
	default:
		httpjson.Error(w, http.StatusBadRequest, err.Error())
	}
}
