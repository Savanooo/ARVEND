package service

// Kişi = tek kayıt (ürün sahibi kararı, 2026-10: "kullanıcı oluşturunca
// direkt personel de oluştururuz").
//
// Bir kişi iki ilgisiz kayıt olarak yaşıyordu: giriş hesabı (Kişiler,
// users) ve personel (Çalışanlar, employees -- mesai/maaş ve görev
// ataması). İkisi yalnızca biri employees.user_id'yi elle doldurursa
// bağlanıyordu. Sahada "batu" (Saha rolü) hesabı ile "Batuhan İnci"
// personeli bağlı değildi: görev seçicisinde iki ayrı kişi göründü ve
// "Batuhan İnci"ye atanan görevin bildirimi kimseye gitmedi ("uygulaması
// yok").
//
// Artık giriş hesabı açan her yol (tenant "Yeni Kullanıcı" -- web ve mobil
// --, Süper Admin'in firmaya kullanıcı eklemesi) varsayılan olarak hesabı
// bir personel kaydına bağlar: verilen employee_id'ye, yoksa aynı adlı TEK
// bağlantısız aktif personele, o da yoksa yeni (ücretsiz) bir personel
// kaydına. Varsayılan "açık" -- dondurulmuş web hiçbir yeni alan
// göndermeden bu davranışı alır.
//
// BİLİNÇLİ OLARAK KAPSAM DIŞI: firmanın ilk Sahibi (Süper Admin'in "Yeni
// Firma" akışı, CreateOrganizationWithOwner) ve SEED_ADMIN bootstrap'ı.
// İlk Sahip firma daha kurulum sihirbazından geçmeden, platform tarafından
// açılır; patronun maaş/mesai listesinde bir personel olup olmadığı firmanın
// kararıdır (gerekirse Personel ekranından "Mevcut hesaba bağla").

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// PersonnelOptions, hesap açılırken personel kaydının ne olacağıdır.
type PersonnelOptions struct {
	// CreateEmployee: nil = varsayılan (EVET). false = personel adımı hiç
	// çalışmaz (ör. "Yeni Personel" formu personeli kendisi açıp hesabı ona
	// bağlayacaksa).
	CreateEmployee *bool
	// EmployeeID: dolu = yeni kayıt açmak yerine BU personele bağla
	// (CreateEmployee'den önceliklidir). Başka bir hesaba bağlı personel
	// ASLA alınmaz (ErrEmployeeHasOtherUser).
	EmployeeID string
	// LinkSameName: nil = varsayılan (EVET) -- aynı adlı tek bağlantısız
	// aktif personel varsa yeni kayıt açmak yerine ona bağlanır. false =
	// yönetici aynı adı taşıyan BAŞKA bir kişi olduğunu söyledi, yeni kayıt
	// açılır.
	LinkSameName *bool
	// CanManageEmployees: işlemi yapanın employees.manage izni var mı.
	// Personel kaydı açmak/bağlamak o izni ister; yoksa hesap yine açılır
	// ama personel adımı atlanır (açık employee_id isteği ise reddedilir).
	CanManageEmployees bool
}

// EmployeeLinkStatus, hesap açılırken personel adımının sonucudur (API'de
// employee_link.status).
type EmployeeLinkStatus string

const (
	// Yeni personel kaydı açıldı ve hesaba bağlandı.
	EmployeeLinkCreated EmployeeLinkStatus = "created"
	// İstenen (employee_id) mevcut personele bağlandı.
	EmployeeLinkLinked EmployeeLinkStatus = "linked"
	// Aynı adlı tek bağlantısız aktif personel bulundu, ona bağlandı.
	EmployeeLinkSameName EmployeeLinkStatus = "linked_same_name"
	// İstek personel kaydı istemedi (create_employee=false).
	EmployeeLinkSkipped EmployeeLinkStatus = "skipped"
	// Aynı adı taşıyan birden çok bağlantısız personel var: hangisi
	// olduğu tahmin edilmez, yeni kayıt da açılmaz (üçüncü bir aynı adlı
	// kayıt olurdu) -- yönetici Personel ekranından bağlar.
	EmployeeLinkAmbiguous EmployeeLinkStatus = "ambiguous_name"
	// İşlemi yapanın employees.manage izni yok; personel adımı atlandı.
	EmployeeLinkNoPermission EmployeeLinkStatus = "no_permission"
)

// EmployeeLinkResult, personel adımının sonucu -- istemci "aynı adlı
// mevcut personele bağlandı" gibi sonucu kullanıcıya söyler.
type EmployeeLinkResult struct {
	Status         EmployeeLinkStatus
	EmployeeID     string
	EmployeeName   string
	EmployeeActive bool
	// Candidates: ambiguous_name durumunda aynı adlı adayların sayısı.
	Candidates int
}

// Message, sonucun kullanıcıya gösterilecek Türkçe karşılığıdır.
func (r EmployeeLinkResult) Message() string {
	switch r.Status {
	case EmployeeLinkCreated:
		return "Personel kaydı da oluşturuldu."
	case EmployeeLinkLinked:
		return fmt.Sprintf("Mevcut personel kaydına (%s) bağlandı.", r.EmployeeName)
	case EmployeeLinkSameName:
		return fmt.Sprintf("Aynı adlı mevcut personel kaydına (%s) bağlandı; ikinci bir kayıt açılmadı.", r.EmployeeName)
	case EmployeeLinkAmbiguous:
		return fmt.Sprintf("Aynı adlı %d personel kaydı var; hangisi olduğu bilinmediği için hesap hiçbirine bağlanmadı. "+
			"Personel ekranından doğru kayda bağlayabilirsin.", r.Candidates)
	case EmployeeLinkNoPermission:
		return "Personel kaydı oluşturulmadı: \"Personeli düzenleme\" iznin yok."
	}
	return ""
}

// ErrLinkEmployeeNotFound: istenen employee_id bu firmada yok.
var ErrLinkEmployeeNotFound = errors.New("bağlanacak personel kaydı bulunamadı")

// ErrEmployeeHasOtherUser: istenen personel zaten başka bir giriş hesabına
// bağlı -- bir personel kaydı ASLA başka bir hesaptan alınmaz.
var ErrEmployeeHasOtherUser = errors.New("bu personel kaydı zaten başka bir giriş hesabına bağlı")

// ErrEmployeeLinkNotPermitted: açıkça bir personele bağlama istendi ama
// işlemi yapanın employees.manage izni yok.
var ErrEmployeeLinkNotPermitted = errors.New("hesabı bir personel kaydına bağlamak için \"Personeli düzenleme\" izni gerekir")

// attachEmployeeToNewUser, yeni açılan hesabın personel adımını hesapla
// AYNI transaction'da çalıştırır: biri yazılıp diğeri yazılmazsa "kişi =
// tek kayıt" yine bozulurdu. Hata dönerse çağıran transaction'ı geri alır
// (hesap da açılmaz) -- yalnızca açık employee_id isteğinin hataları
// buraya kadar gelir; varsayılan yol hiçbir durumda hesabı engellemez.
func attachEmployeeToNewUser(ctx context.Context, txq *sqlc.Queries, orgID pgtype.UUID, user sqlc.User, opts PersonnelOptions, today time.Time, actorUserID string) (*EmployeeLinkResult, error) {
	if opts.EmployeeID != "" {
		if !opts.CanManageEmployees {
			return nil, ErrEmployeeLinkNotPermitted
		}
		eid, err := repository.StringToUUID(opts.EmployeeID)
		if err != nil {
			return nil, ErrLinkEmployeeNotFound
		}
		row, err := txq.LinkEmployeeToUser(ctx, sqlc.LinkEmployeeToUserParams{UserID: user.ID, ID: eid, OrganizationID: orgID})
		if err != nil {
			if !errors.Is(err, pgx.ErrNoRows) {
				return nil, err
			}
			// 0 satır: ya bu firmada yok ya da zaten bağlı.
			if _, gerr := txq.GetEmployeeByID(ctx, sqlc.GetEmployeeByIDParams{ID: eid, OrganizationID: orgID}); gerr != nil {
				if errors.Is(gerr, pgx.ErrNoRows) {
					return nil, ErrLinkEmployeeNotFound
				}
				return nil, gerr
			}
			return nil, ErrEmployeeHasOtherUser
		}
		return linkResult(EmployeeLinkLinked, row), nil
	}

	if opts.CreateEmployee != nil && !*opts.CreateEmployee {
		return &EmployeeLinkResult{Status: EmployeeLinkSkipped}, nil
	}
	if !opts.CanManageEmployees {
		return &EmployeeLinkResult{Status: EmployeeLinkNoPermission}, nil
	}

	if opts.LinkSameName == nil || *opts.LinkSameName {
		candidates, err := txq.ListUnlinkedActiveEmployees(ctx, orgID)
		if err != nil {
			return nil, err
		}
		var matches []sqlc.ListUnlinkedActiveEmployeesRow
		for _, c := range candidates {
			if domain.SamePersonName(c.FullName, user.FullName) {
				matches = append(matches, c)
			}
		}
		switch {
		case len(matches) == 1:
			row, err := txq.LinkEmployeeToUser(ctx, sqlc.LinkEmployeeToUserParams{UserID: user.ID, ID: matches[0].ID, OrganizationID: orgID})
			if err == nil {
				return linkResult(EmployeeLinkSameName, row), nil
			}
			if !errors.Is(err, pgx.ErrNoRows) {
				return nil, err
			}
			// Bu arada başka bir hesap o personeli aldı: aday kalmadı,
			// yeni kayıt açılır.
		case len(matches) > 1:
			return &EmployeeLinkResult{Status: EmployeeLinkAmbiguous, Candidates: len(matches)}, nil
		}
	}

	// Yeni personel: adı hesaptan, görev (position) BOŞ -- organizasyon
	// rolü (Saha, Finans...) bir erişim rolüdür, iş unvanı (Kalıpçı,
	// Şantiye Şefi) değil; rol sonradan değişince unvan da yanlış kalırdı.
	// İşe başlama bugün (İstanbul), ücret yok: maaş ekranı bu kişiyi
	// "Ücret tanımsız" gösterir (domain.WageBasisNone), hesap yapmaz.
	row, err := txq.CreateEmployee(ctx, sqlc.CreateEmployeeParams{
		OrganizationID: orgID,
		FullName:       user.FullName,
		StartDate:      repository.TimeToDate(today),
		UserID:         user.ID,
	})
	if err != nil {
		return nil, err
	}
	// EmployeeService.Create ile aynı: ilk ücret geçmişi satırı (burada
	// ücretsiz) -- sonradan girilen ücret bugünden itibaren işler, geçmiş
	// aylar "tanımsız" kalır.
	if err := txq.UpsertEmployeeWage(ctx, sqlc.UpsertEmployeeWageParams{
		OrganizationID: orgID,
		EmployeeID:     row.ID,
		Salary:         row.Salary,
		DailyWage:      row.DailyWage,
		EffectiveFrom:  repository.TimeToDate(today),
		CreatedBy:      optionalUUID(&actorUserID),
	}); err != nil {
		return nil, err
	}
	return linkResult(EmployeeLinkCreated, row), nil
}

func linkResult(status EmployeeLinkStatus, e sqlc.Employee) *EmployeeLinkResult {
	return &EmployeeLinkResult{Status: status, EmployeeID: e.ID.String(), EmployeeName: e.FullName, EmployeeActive: e.IsActive}
}

// applyLinkedEmployee, sonucu domain.User'a yazar (API cevabındaki
// employee_id/employee_full_name alanları için).
func applyLinkedEmployee(u *domain.User, r *EmployeeLinkResult) {
	if r == nil || r.EmployeeID == "" {
		return
	}
	id := r.EmployeeID
	u.LinkedEmployeeID = &id
	u.LinkedEmployeeName = r.EmployeeName
	u.LinkedEmployeeActive = r.EmployeeActive
}

// prepareUserLink, bir personeli userID hesabına bağlamadan ÖNCE (personel
// Create/Update içinde, aynı transaction'da) çalışır: hesap şu an BAŞKA bir
// personele bağlıysa ve o kayıt hesapla birlikte otomatik açılmış, hiç
// kullanılmamış bir kayıtsa silinir -- yöneticinin açık seçimi sistemin
// kendi tahminine üstün gelir (bkz. DeleteUntouchedAutoEmployee). Bu,
// "batu" hesabı açılırken otomatik açılan "batu" personeli yerine hesabı
// "Batuhan İnci"ye tek adımda bağlamayı ve dondurulmuş web'in "Yeni
// Personel + yeni giriş hesabı" / "Giriş hesabı aç" akışlarını (önce
// hesap, sonra personele user_id) bozulmadan çalıştırır.
//
// Kayıt kullanılmışsa dokunulmaz; çağıranın INSERT/UPDATE'i unique
// kısıtına takılır ve linkedEmployeeConflict hangi personele bağlı
// olduğunu söyler.
func prepareUserLink(ctx context.Context, txq *sqlc.Queries, orgID, userID, targetEmployeeID pgtype.UUID) error {
	if !userID.Valid {
		return nil
	}
	current, err := txq.GetEmployeeByUserID(ctx, sqlc.GetEmployeeByUserIDParams{UserID: userID, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	}
	if targetEmployeeID.Valid && current.ID == targetEmployeeID {
		return nil
	}
	_, err = txq.DeleteUntouchedAutoEmployee(ctx, sqlc.DeleteUntouchedAutoEmployeeParams{ID: current.ID, OrganizationID: orgID})
	return err
}

// linkedEmployeeConflictError, "hesap zaten bir personele bağlı" hatasının
// HANGİ personel olduğunu söyleyen hâlidir (errors.Is ile
// ErrEmployeeUserAlreadyLinked yakalanır). Dondurulmuş web'in "Yeni
// Personel + yeni giriş hesabı" akışında aynı adlı mevcut personel varsa
// hesap ona bağlanır ve web ikinci kaydı açmaya çalışır -- genel "başka bir
// personele bağlı" metni sebebi gizliyordu.
type linkedEmployeeConflictError struct{ name string }

func (e *linkedEmployeeConflictError) Error() string {
	return fmt.Sprintf("bu kullanıcı hesabı zaten \"%s\" personel kaydına bağlı; bir hesap yalnızca bir personele bağlanabilir", e.name)
}

func (e *linkedEmployeeConflictError) Is(target error) bool {
	return target == ErrEmployeeUserAlreadyLinked
}

// linkedEmployeeConflict, unique ihlalinden sonra (transaction artık
// kullanılamaz) havuz üzerinden hangi personele bağlı olduğunu okur.
func linkedEmployeeConflict(ctx context.Context, q *sqlc.Queries, orgID, userID pgtype.UUID) error {
	if e, err := q.GetEmployeeByUserID(ctx, sqlc.GetEmployeeByUserIDParams{UserID: userID, OrganizationID: orgID}); err == nil {
		return &linkedEmployeeConflictError{name: e.FullName}
	}
	return ErrEmployeeUserAlreadyLinked
}

// LinkSuggestion, personel kaydı olmayan bir hesap ile bağlantısız bir
// personelin BİREBİR aynı (normalize) adı taşıdığı öneridir.
type LinkSuggestion struct {
	UserID           string
	Username         string
	UserFullName     string
	EmployeeID       string
	EmployeeName     string
	EmployeePosition string
}

// LinkSuggestions: mevcut verideki eşleşmemiş hesap/personel çiftleri.
// OTOMATİK BAĞLAMAZ -- mevcut kayıtlar bulanık adla eşleştirilmez ("batu"
// ile "Batuhan İnci" gibi). Yalnızca iki tarafta da TEK olan birebir aynı
// normalize ad önerilir; aynı adı taşıyan birden çok hesap ya da personel
// varsa öneri yok (hangisinin hangisi olduğu tahmin edilmez). Bağlamayı
// yönetici PUT /employees/{id} ile yapar.
func (s *EmployeeService) LinkSuggestions(ctx context.Context, organizationID string) ([]LinkSuggestion, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	users, err := s.q.ListUsersWithoutEmployee(ctx, orgID)
	if err != nil {
		return nil, err
	}
	employees, err := s.q.ListUnlinkedActiveEmployees(ctx, orgID)
	if err != nil {
		return nil, err
	}
	usersByName := map[string][]sqlc.ListUsersWithoutEmployeeRow{}
	for _, u := range users {
		if k := domain.NormalizePersonName(u.FullName); k != "" {
			usersByName[k] = append(usersByName[k], u)
		}
	}
	employeesByName := map[string][]sqlc.ListUnlinkedActiveEmployeesRow{}
	for _, e := range employees {
		if k := domain.NormalizePersonName(e.FullName); k != "" {
			employeesByName[k] = append(employeesByName[k], e)
		}
	}
	out := []LinkSuggestion{}
	for _, u := range users {
		k := domain.NormalizePersonName(u.FullName)
		if len(usersByName[k]) != 1 || len(employeesByName[k]) != 1 {
			continue
		}
		e := employeesByName[k][0]
		out = append(out, LinkSuggestion{
			UserID: u.ID.String(), Username: u.Username, UserFullName: u.FullName,
			EmployeeID: e.ID.String(), EmployeeName: e.FullName, EmployeePosition: e.Position,
		})
	}
	return out, nil
}
