package service

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type EmployeeService struct {
	pool *pgxpool.Pool
	q    *sqlc.Queries
	now  func() time.Time
}

// pool, personel satırı ile ücret geçmişinin (employee_wage_history) aynı
// transaction'da yazılması içindir: biri yazılıp diğeri yazılmazsa maaş
// hesabı geçmiş ayları yanlış ücretle hesaplardı.
func NewEmployeeService(pool *pgxpool.Pool, q *sqlc.Queries) *EmployeeService {
	return &EmployeeService{pool: pool, q: q, now: time.Now}
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
	// ChangedBy, oturumdaki kullanıcı -- ücret geçmişi satırına yazılır
	// (kim değiştirdi); boşsa NULL.
	ChangedBy string
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
	logins, err := s.q.ListEmployeeLogins(ctx, orgID)
	if err != nil {
		return nil, err
	}
	byEmployee := make(map[pgtype.UUID]sqlc.ListEmployeeLoginsRow, len(logins))
	for _, l := range logins {
		byEmployee[l.EmployeeID] = l
	}
	out := make([]domain.Employee, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainEmployee(r)
		if l, ok := byEmployee[r.ID]; ok {
			out[i].LoginUsername, out[i].LoginActive, out[i].LoginDeleted = l.Username, l.IsActive, l.Deleted
		}
	}
	return out, nil
}

// withLogin, tek personelin bağlı hesap özetini doldurur (Get/Create/
// Update cevabı listeyle aynı şekilde olsun diye). Hesap okunamazsa
// özet boş kalır -- personel cevabı bunun yüzünden düşmez.
func (s *EmployeeService) withLogin(ctx context.Context, row sqlc.Employee) domain.Employee {
	e := repository.ToDomainEmployee(row)
	if !row.UserID.Valid {
		return e
	}
	if u, err := s.q.GetUserByIDInOrg(ctx, sqlc.GetUserByIDInOrgParams{ID: row.UserID, OrganizationID: row.OrganizationID}); err == nil {
		e.LoginUsername, e.LoginActive, e.LoginDeleted = u.Username, u.IsActive, u.DeletedAt.Valid
	}
	return e
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
	e := s.withLogin(ctx, row)
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

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if err := prepareUserLink(ctx, txq, orgID, linkedUserID, pgtype.UUID{}); err != nil {
		return nil, err
	}
	row, err := txq.CreateEmployee(ctx, sqlc.CreateEmployeeParams{
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
			return nil, linkedEmployeeConflict(ctx, s.q, orgID, linkedUserID)
		}
		return nil, err
	}
	// İlk ücret, işe girişten (geçmişteyse) itibaren geçerli: sonradan
	// girilen bir personelin işe başladığı aydan bugüne kadarki ayları da
	// bu ücretle hesaplanır.
	today := istanbulToday(s.now())
	effective := today
	if in.StartDate != nil {
		if sd := time.Date(in.StartDate.Year(), in.StartDate.Month(), in.StartDate.Day(), 0, 0, 0, 0, time.UTC); sd.Before(today) {
			effective = sd
		}
	}
	if err := txq.UpsertEmployeeWage(ctx, sqlc.UpsertEmployeeWageParams{
		OrganizationID: orgID,
		EmployeeID:     row.ID,
		Salary:         row.Salary,
		DailyWage:      row.DailyWage,
		EffectiveFrom:  repository.TimeToDate(effective),
		CreatedBy:      optionalUUID(&in.ChangedBy),
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	e := s.withLogin(ctx, row)
	return &e, nil
}

// sameNumeric, iki nullable numeric'in aynı değer olup olmadığını söyler
// (NULL = NULL). Ücret değişikliği tespiti için.
func sameNumeric(a, b pgtype.Numeric) bool {
	if a.Valid != b.Valid {
		return false
	}
	if !a.Valid {
		return true
	}
	return repository.NumericToFloat64(a) == repository.NumericToFloat64(b)
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

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	old, err := txq.GetEmployeeForUpdate(ctx, sqlc.GetEmployeeForUpdateParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if linkedUserID != old.UserID {
		if err := prepareUserLink(ctx, txq, orgID, linkedUserID, uid); err != nil {
			return nil, err
		}
	}
	newSalary := repository.FloatPtrToNumeric(in.Salary)
	newDailyWage := repository.FloatPtrToNumeric(in.DailyWage)
	wageChanged := !sameNumeric(old.Salary, newSalary) || !sameNumeric(old.DailyWage, newDailyWage)
	today := istanbulToday(s.now())
	if wageChanged {
		// Geçmişi hiç olmayan personelde (servisi atlayan bir yazıcıdan
		// gelmiş) önce ESKİ ücret kaydedilir -- yoksa yeni ücret bilinen tek
		// ücret olur ve geçmiş ayların tamamına yayılırdı.
		if err := txq.InsertEmployeeWageIfNone(ctx, sqlc.InsertEmployeeWageIfNoneParams{
			Today: repository.TimeToDate(today), ID: uid, OrganizationID: orgID,
		}); err != nil {
			return nil, err
		}
	}

	row, err := txq.UpdateEmployee(ctx, sqlc.UpdateEmployeeParams{
		ID:             uid,
		OrganizationID: orgID,
		FullName:       in.FullName,
		Phone:          strings.TrimSpace(in.Phone),
		Position:       strings.TrimSpace(in.Position),
		Salary:         newSalary,
		DailyWage:      newDailyWage,
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
			return nil, linkedEmployeeConflict(ctx, s.q, orgID, linkedUserID)
		}
		return nil, err
	}
	if wageChanged {
		// Yeni ücret BUGÜNDEN (İstanbul) itibaren geçerli; maaş hesabı bir
		// ayı, ayın son günü geçerli ücretle kapatır (domain.WageForPeriod)
		// -- yani bu ayın tamamı yeni, önceki aylar eski ücretle kalır.
		if err := txq.UpsertEmployeeWage(ctx, sqlc.UpsertEmployeeWageParams{
			OrganizationID: orgID,
			EmployeeID:     uid,
			Salary:         row.Salary,
			DailyWage:      row.DailyWage,
			EffectiveFrom:  repository.TimeToDate(today),
			CreatedBy:      optionalUUID(&in.ChangedBy),
		}); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	e := s.withLogin(ctx, row)
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
