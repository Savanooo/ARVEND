package service

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type EmployeeService struct {
	q *sqlc.Queries
}

func NewEmployeeService(q *sqlc.Queries) *EmployeeService {
	return &EmployeeService{q: q}
}

type EmployeeInput struct {
	FullName    string
	Phone       string
	Position    string
	Salary      *float64
	DailyWage   *float64
	StartDate   *time.Time
	Description string
	IsActive    bool
	// UserID, bu personeli bir login hesabına bağlar -- EmployeeInput'un
	// diğer alanları (ör. IsActive bool, pointer DEĞİL) gibi TAM
	// GÜNCELLEME (full-replace) semantiğini izler: nil VEYA boş string =
	// bağlantı YOK/KALDIRILDI, dolu = bağla/değiştir (3-durumlu "kısmi
	// PATCH" deseni İCAT EDİLMEDİ, bu uç zaten formun TÜM alanlarını
	// gönderdiği bir "düzenle" ekranı). Otomatik ad/e-posta/telefon
	// eşleştirmesi YAPILMAZ -- yalnızca yöneticinin açıkça seçtiği bir
	// kullanıcı ID'si kabul edilir.
	UserID *string
}

// ErrEmployeeUserAlreadyLinked, seçilen kullanıcı hesabı ZATEN başka bir
// personele bağlıysa döner (bkz. migration 0041'in idx_employees_user_id
// UNIQUE kısıtı — bir kullanıcı en fazla bir personele bağlanabilir).
var ErrEmployeeUserAlreadyLinked = errors.New("bu kullanıcı hesabı zaten başka bir personele bağlı")

// ErrEmployeeUserCrossOrg, bağlanmak istenen kullanıcı FARKLI bir
// organizasyona aitse döner (spec: "same-organization validation
// mandatory" — DB tetikleyicisiyle AYNI kural, burada daha erken ve daha
// okunaklı bir hata için TEKRAR doğrulanır).
var ErrEmployeeUserCrossOrg = errors.New("bağlanacak kullanıcı hesabı aynı organizasyona ait olmalıdır")

// resolveEmployeeUserLink, UserID girdisini pgtype.UUID'ye çevirir ve
// AYNI organizasyona ait olduğunu doğrular (nil ise dokunma anlamına
// gelen bir "değişmesin" sinyali — çağıran bunu ayrıca ele alır).
func (s *EmployeeService) resolveEmployeeUserLink(ctx context.Context, userID *string, orgID pgtype.UUID) (pgtype.UUID, error) {
	if userID == nil || strings.TrimSpace(*userID) == "" {
		return pgtype.UUID{}, nil
	}
	uid, err := repository.StringToUUID(*userID)
	if err != nil {
		return pgtype.UUID{}, domain.ErrNotFound
	}
	if _, err := s.q.GetUserByIDInOrg(ctx, sqlc.GetUserByIDInOrgParams{ID: uid, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return pgtype.UUID{}, ErrEmployeeUserCrossOrg
		}
		return pgtype.UUID{}, err
	}
	return uid, nil
}

func (s *EmployeeService) List(ctx context.Context, organizationID string, activeOnly *bool) ([]domain.Employee, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListEmployees(ctx, sqlc.ListEmployeesParams{OrganizationID: orgID, IsActive: activeOnly})
	if err != nil {
		return nil, err
	}
	out := make([]domain.Employee, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainEmployee(r)
	}
	return out, nil
}

func (s *EmployeeService) Get(ctx context.Context, id, organizationID string) (*domain.Employee, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetEmployeeByID(ctx, sqlc.GetEmployeeByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	e := repository.ToDomainEmployee(row)
	return &e, nil
}

func (s *EmployeeService) Create(ctx context.Context, organizationID string, in EmployeeInput) (*domain.Employee, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.FullName = strings.TrimSpace(in.FullName)
	if in.FullName == "" {
		return nil, errors.New("ad soyad zorunludur")
	}
	linkedUserID, err := s.resolveEmployeeUserLink(ctx, in.UserID, orgID)
	if err != nil {
		return nil, err
	}
	row, err := s.q.CreateEmployee(ctx, sqlc.CreateEmployeeParams{
		OrganizationID: orgID,
		FullName:       in.FullName,
		Phone:          strings.TrimSpace(in.Phone),
		Position:       strings.TrimSpace(in.Position),
		Salary:         repository.FloatPtrToNumeric(in.Salary),
		DailyWage:      repository.FloatPtrToNumeric(in.DailyWage),
		StartDate:      repository.TimePtrToDate(in.StartDate),
		Description:    strings.TrimSpace(in.Description),
		UserID:         linkedUserID,
	})
	if err != nil {
		if isUniqueViolation(err) {
			return nil, ErrEmployeeUserAlreadyLinked
		}
		return nil, err
	}
	e := repository.ToDomainEmployee(row)
	return &e, nil
}

func (s *EmployeeService) Update(ctx context.Context, id, organizationID string, in EmployeeInput) (*domain.Employee, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.FullName = strings.TrimSpace(in.FullName)
	if in.FullName == "" {
		return nil, errors.New("ad soyad zorunludur")
	}
	linkedUserID, err := s.resolveEmployeeUserLink(ctx, in.UserID, orgID)
	if err != nil {
		return nil, err
	}
	row, err := s.q.UpdateEmployee(ctx, sqlc.UpdateEmployeeParams{
		ID:             uid,
		OrganizationID: orgID,
		FullName:       in.FullName,
		Phone:          strings.TrimSpace(in.Phone),
		Position:       strings.TrimSpace(in.Position),
		Salary:         repository.FloatPtrToNumeric(in.Salary),
		DailyWage:      repository.FloatPtrToNumeric(in.DailyWage),
		StartDate:      repository.TimePtrToDate(in.StartDate),
		Description:    strings.TrimSpace(in.Description),
		IsActive:       in.IsActive,
		UserID:         linkedUserID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		if isUniqueViolation(err) {
			return nil, ErrEmployeeUserAlreadyLinked
		}
		return nil, err
	}
	e := repository.ToDomainEmployee(row)
	return &e, nil
}

// Archive, BYZ'deki kuralı korur: personel hard-delete edilmez (mesai/
// atama geçmişi referans verir), yalnızca pasifleştirilir.
func (s *EmployeeService) Archive(ctx context.Context, id, organizationID string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	rows, err := s.q.ArchiveEmployee(ctx, sqlc.ArchiveEmployeeParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	return nil
}
