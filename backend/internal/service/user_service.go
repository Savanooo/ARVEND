package service

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/auth"
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type UserService struct {
	pool *pgxpool.Pool
	q    *sqlc.Queries
	now  func() time.Time
}

// pool: pasifleştirme/şifre sıfırlama gibi birden çok yazımın (ve son-Sahip
// kilidinin, bkz. guardLastActiveOwner) tek transaction'da yapılması için.
func NewUserService(pool *pgxpool.Pool, q *sqlc.Queries) *UserService {
	return &UserService{pool: pool, q: q, now: time.Now}
}

type ListResult struct {
	Users []domain.User
	Total int64
}

func (s *UserService) List(ctx context.Context, organizationID string, page, limit int) (*ListResult, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	if page <= 0 {
		page = 1
	}
	rows, err := s.q.ListUsers(ctx, sqlc.ListUsersParams{
		OrganizationID: orgID,
		Limit:          int32(limit),
		Offset:         int32((page - 1) * limit),
	})
	if err != nil {
		return nil, err
	}
	total, err := s.q.CountUsers(ctx, orgID)
	if err != nil {
		return nil, err
	}
	users := make([]domain.User, len(rows))
	for i, r := range rows {
		users[i] = repository.ToDomainUser(r)
	}
	return &ListResult{Users: users, Total: total}, nil
}

func (s *UserService) Get(ctx context.Context, id, organizationID string) (*domain.User, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetUserByIDInOrg(ctx, sqlc.GetUserByIDInOrgParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	u := repository.ToDomainUser(row)
	return &u, nil
}

// Create, cmd/api'nin SEED_ADMIN_* bootstrap yolu (organizationRoleCode=""
// verir, aşağıdaki ESKİ varsayım zincirine düşer -- organization_roles henüz
// seed edilmemiş olabileceği bir bootstrap anıdır, bu yüzden BİLEREK
// dokunulmadı) ve testlerin hesap açma yardımcısıdır. Personel kaydı AÇMAZ
// (bkz. user_employee_link.go "kapsam dışı"): tenant "Yeni Kullanıcı" ucu
// artık CreateMember'ın kendi transaction'ından geçer (hesap + rol +
// personel birlikte). organizationRoleCode dolu olduğunda `role` parametresi
// YOK SAYILIR -- kaba users.role, seçilen organizasyon rolünden TÜRETİLİR
// (coarseRoleForOrgRole, tam olarak PlatformService.ProvisionOrganizationUser
// ile AYNI desen), "legacy_user" bir atama HEDEFİ olarak KESİNLİKLE reddedilir
// (o kod yalnızca migration backfill'i içindir, bkz. domain.OrgRoleLegacyUser
// yorumu) -- daha önce bu uç `role`'ü (admin/kullanici) yollayıp
// organization_role_code'u HİÇ göndermediği için her yeni tenant kullanıcısı
// sessizce "legacy_user"a düşüyordu (web'de "(Eski Sistem)" rozetiyle
// görünen, kafa karıştırıcı ve kesinlikle amaçlanmayan bir durum) --
// bu artık İMKANSIZ, çağıran bir rol vermek ZORUNDA.
func (s *UserService) Create(ctx context.Context, organizationID, username, password, fullName string, role domain.Role, organizationRoleCode string) (*domain.User, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	username = strings.TrimSpace(username)
	if username == "" || password == "" || strings.TrimSpace(fullName) == "" {
		return nil, errors.New("kullanıcı adı, şifre ve ad soyad zorunludur")
	}
	// Sıfırlama/değiştirme 8 karakter isterken oluşturma hiçbir alt sınır
	// koymuyordu -- "1" şifreli hesap açılabiliyordu.
	if !domain.ValidPasswordLength(password) {
		return nil, domain.ErrPasswordTooShort
	}

	var orgRole sqlc.OrganizationRole
	if organizationRoleCode != "" {
		if organizationRoleCode == domain.OrgRoleLegacyUser {
			return nil, domain.ErrRoleNotAssignable
		}
		orgRole, err = s.q.GetOrganizationRoleByCode(ctx, sqlc.GetOrganizationRoleByCodeParams{
			OrganizationID: orgID, Code: organizationRoleCode,
		})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, domain.ErrNotFound
			}
			return nil, err
		}
		role = coarseRoleForOrgRole(orgRole.Code)
	} else if !role.Valid() {
		role = domain.RoleKullanici
	}

	hash, err := auth.HashPassword(password)
	if err != nil {
		return nil, err
	}
	row, err := s.q.CreateUser(ctx, sqlc.CreateUserParams{
		OrganizationID: orgID,
		Username:       username,
		PasswordHash:   hash,
		FullName:       strings.TrimSpace(fullName),
		Role:           string(role),
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
			return nil, domain.ErrDuplicateUsername
		}
		return nil, err
	}

	if organizationRoleCode != "" {
		if updated, uerr := s.q.UpdateUserOrganizationRole(ctx, sqlc.UpdateUserOrganizationRoleParams{
			ID: row.ID, OrganizationID: orgID, OrganizationRoleID: orgRole.ID,
		}); uerr == nil {
			row = updated
		}
		u := repository.ToDomainUser(row)
		u.OrganizationRoleCode = orgRole.Code
		u.OrganizationRoleName = orgRole.Name
		return &u, nil
	}

	// RBAC/Project Membership sprint'i: YENİ kullanıcı organization_role_id
	// NULL bırakılırsa AuthorizationService.LoadAuthzContext deny-by-default
	// boş izin kümesi döner -- kullanıcı HİÇBİR business uca erişemez (bkz.
	// PlatformService.CreateOrganizationWithOwner'daki AYNI gerekçe).
	// Eski (role: admin/kullanici) sözleşmesiyle GERİYE DÖNÜK UYUMLU
	// varsayılan (YALNIZCA organizationRoleCode boşken, ör. bootstrap):
	// admin -> 'admin' sistem rolü (tam yetki), kullanici -> 'legacy_user'
	// (migration backfill'iyle AYNI eşleme). En iyi çaba: rol satırı her
	// zaman seed edilmiş olmalıdır, ama bulunamazsa kullanıcı yine de
	// OLUŞTURULUR -- yalnızca organization_role_id boş kalır.
	orgRoleCode := domain.OrgRoleLegacyUser
	if role == domain.RoleAdmin {
		orgRoleCode = domain.OrgRoleAdmin
	}
	if legacyRole, rerr := s.q.GetOrganizationRoleByCode(ctx, sqlc.GetOrganizationRoleByCodeParams{
		OrganizationID: orgID, Code: orgRoleCode,
	}); rerr == nil {
		if updated, uerr := s.q.UpdateUserOrganizationRole(ctx, sqlc.UpdateUserOrganizationRoleParams{
			ID: row.ID, OrganizationID: orgID, OrganizationRoleID: legacyRole.ID,
		}); uerr == nil {
			row = updated
		}
	}

	u := repository.ToDomainUser(row)
	return &u, nil
}

// CreateMember, tenant "Yeni Kullanıcı" ucunun yoludur (bkz. Create):
// Sahip rolüyle kullanıcı açmak yalnızca bir Sahip'in işidir -- aksi hâlde
// bir Yönetici kendine ikinci bir Sahip hesabı açıp asıl Sahibi
// düşürebilirdi (bkz. domain.ErrOwnerOnlyAction).
//
// Hesap, rolü ve personel kaydı ("kişi = tek kayıt", bkz.
// user_employee_link.go) TEK transaction'da yazılır: hesap açılıp personel
// adımı yarıda kalırsa aynı kişi yine iki ilgisiz kayıt olurdu. Bu yüzden
// Create'in bootstrap'a özgü "rol bulunamazsa yine de aç" esnekliği burada
// yok -- organizationRoleCode zorunlu (uç da zaten zorunlu tutuyor).
func (s *UserService) CreateMember(ctx context.Context, organizationID, actorUserID, username, password, fullName, organizationRoleCode string, personnel PersonnelOptions) (*domain.User, *EmployeeLinkResult, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, nil, domain.ErrNotFound
	}
	username = strings.TrimSpace(username)
	fullName = strings.TrimSpace(fullName)
	organizationRoleCode = strings.TrimSpace(organizationRoleCode)
	if username == "" || password == "" || fullName == "" {
		return nil, nil, errors.New("kullanıcı adı, şifre ve ad soyad zorunludur")
	}
	if organizationRoleCode == "" {
		return nil, nil, errors.New("organizasyon rolü zorunludur")
	}
	if !domain.ValidPasswordLength(password) {
		return nil, nil, domain.ErrPasswordTooShort
	}
	if organizationRoleCode == domain.OrgRoleLegacyUser {
		return nil, nil, domain.ErrRoleNotAssignable
	}
	// bcrypt transaction'ı açık tutmasın diye önce.
	hash, err := auth.HashPassword(password)
	if err != nil {
		return nil, nil, err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if err := guardOwnerOnlyAction(ctx, txq, actorUserID, pgtype.UUID{}, orgID, organizationRoleCode); err != nil {
		return nil, nil, err
	}
	orgRole, err := txq.GetOrganizationRoleByCode(ctx, sqlc.GetOrganizationRoleByCodeParams{
		OrganizationID: orgID, Code: organizationRoleCode,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil, domain.ErrNotFound
		}
		return nil, nil, err
	}
	row, err := txq.CreateUser(ctx, sqlc.CreateUserParams{
		OrganizationID: orgID,
		Username:       username,
		PasswordHash:   hash,
		FullName:       fullName,
		Role:           string(coarseRoleForOrgRole(orgRole.Code)),
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" { // unique_violation
			return nil, nil, domain.ErrDuplicateUsername
		}
		return nil, nil, err
	}
	row, err = txq.UpdateUserOrganizationRole(ctx, sqlc.UpdateUserOrganizationRoleParams{
		ID: row.ID, OrganizationID: orgID, OrganizationRoleID: orgRole.ID,
	})
	if err != nil {
		return nil, nil, err
	}
	link, err := attachEmployeeToNewUser(ctx, txq, orgID, row, personnel, istanbulToday(s.now()), actorUserID)
	if err != nil {
		return nil, nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, nil, err
	}
	u := repository.ToDomainUser(row)
	u.OrganizationRoleCode = orgRole.Code
	u.OrganizationRoleName = orgRole.Name
	applyLinkedEmployee(&u, link)
	return &u, link, nil
}

// Update, kullanıcının profilini (ad soyad + aktiflik) değiştirir. Kaba
// users.role BİLEREK burada bir parametre DEĞİLDİR: "admin"/"kullanici"
// artık bağımsız düzenlenebilir bir kavram değil, organizasyon rolünden
// TÜRETİLEN bir alan (bkz. setUserOrganizationRole/coarseRoleForOrgRole) --
// bu uç onu bağımsız değiştirebilseydi, ikisi birbirinden sapar (requireAdmin
// kapısı ve /admin vs /panel kabuk seçimi organizasyon rolüyle tutarsız
// kalırdı) ve son-Sahip koruması organizasyon rolüne bakan guardLastActiveOwner
// tarafından bu sapmayı GÖREMEZDİ. Rol değişikliği yalnızca
// SetOrganizationRole ile yapılır (o hem senkronu hem son-Sahip korumasını
// uygular).
//
// Aktif bir Sahip'i pasifleştirmek yalnızca bir Sahip'in işidir
// (guardOwnerOnlyAction); kontrol, kilit ve değişiklik tek transaction'da.
func (s *UserService) Update(ctx context.Context, id, organizationID, actorUserID, fullName string, isActive bool) (*domain.User, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := txq.GetUserByIDInOrg(ctx, sqlc.GetUserByIDInOrgParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if !isActive {
		// Zaten pasif bir Sahip'in adını düzeltmek pasifleştirme değildir.
		if current.IsActive {
			if err := guardOwnerOnlyAction(ctx, txq, actorUserID, uid, orgID, ""); err != nil {
				return nil, err
			}
		}
		if err := guardLastActiveOwner(ctx, txq, uid, orgID); err != nil {
			return nil, err
		}
	} else if current.DeletedAt.Valid {
		// Silinmiş bir kullanıcı bu yoldan doğrudan aktifleştirilemez --
		// önce restore edilmeli (bkz. user_lifecycle.go reactivateUser'daki
		// AYNI kural; bu, tenant tarafının reaktivasyon yoludur).
		return nil, domain.ErrUserDeleted
	}
	fullName = strings.TrimSpace(fullName)
	row, err := txq.UpdateUserProfile(ctx, sqlc.UpdateUserProfileParams{
		ID:             uid,
		OrganizationID: orgID,
		FullName:       fullName,
		IsActive:       isActive,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if !isActive {
		// Personel kaydına BİLEREK dokunulmaz (ne silinir ne bağı koparılır
		// ne pasife alınır): pasif hesap "uygulamaya giremez" demektir,
		// "işten ayrıldı" değil -- yevmiyeli çalışmaya devam eden birinin
		// hesabı kapatılabilir. Mesai/maaş geçmişi personelde kalır; bağ
		// durduğu için hesap yeniden açılınca kişi yine tek kayıttır.
		// Görev seçicisi pasif hesabı zaten "uygulaması yok" sayar
		// (ListProjectAssignees: u.is_active).
		if err := endUserAccess(ctx, txq, uid); err != nil {
			return nil, err
		}
	}
	if err := syncLinkedEmployeeName(ctx, txq, uid, orgID, current.FullName, fullName); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	u := repository.ToDomainUser(row)
	return &u, nil
}

// ChangeOwnPassword, kullanıcının kendi şifresini değiştirmesi için mevcut
// şifreyi doğrular (admin resetinden farkı budur). Şifre değişince
// kullanıcının DİĞER oturumları kapanır (çalınmış bir oturum, şifre
// değiştirilerek kesilebilmeli); keepRefreshToken -- isteği yapan cihazın
// refresh token'ı -- açık kalır, kullanıcı kendi oturumundan atılmaz. Boşsa
// tüm oturumlar kapanır.
func (s *UserService) ChangeOwnPassword(ctx context.Context, id, organizationID, currentPassword, newPassword, keepRefreshToken string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	row, err := s.q.GetUserByID(ctx, uid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNotFound
		}
		return err
	}
	if !auth.CheckPassword(row.PasswordHash, currentPassword) {
		return domain.ErrInvalidCredentials
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	if !domain.ValidPasswordLength(newPassword) {
		return domain.ErrPasswordTooShort
	}
	hash, err := auth.HashPassword(newPassword)
	if err != nil {
		return err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	rows, err := txq.UpdateUserPassword(ctx, sqlc.UpdateUserPasswordParams{ID: uid, OrganizationID: orgID, PasswordHash: hash})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	if err := revokeOtherSessions(ctx, txq, uid, keepRefreshToken); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// AdminResetPassword, mevcut şifre istemeden bir kullanıcının şifresini
// değiştirir — yalnız RequireRole("admin") arkasında çağrılmalıdır. Süper
// Admin'in sıfırlamasıyla (PlatformService.ResetOrganizationUserPassword)
// AYNI sonuç: verilen şifre geçicidir (must_change_password=true, kullanıcı
// ilk girişte kendi şifresini belirler) ve hedefin açık oturumları kapanır
// -- şifresi sıfırlanan hesapta eski oturumlar çalışmaya devam ediyordu.
// Sahip'in şifresini yalnızca bir Sahip sıfırlayabilir (aksi hâlde bir
// Yönetici yeni şifreyle Sahip olarak giriş yapabilirdi).
func (s *UserService) AdminResetPassword(ctx context.Context, id, organizationID, actorUserID, newPassword string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	if !domain.ValidPasswordLength(newPassword) {
		return domain.ErrPasswordTooShort
	}
	hash, err := auth.HashPassword(newPassword)
	if err != nil {
		return err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	if err := guardOwnerOnlyAction(ctx, txq, actorUserID, uid, orgID, ""); err != nil {
		return err
	}
	rows, err := txq.ResetPasswordRequireChange(ctx, sqlc.ResetPasswordRequireChangeParams{ID: uid, OrganizationID: orgID, PasswordHash: hash})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	if err := txq.RevokeAllUserRefreshTokens(ctx, uid); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// SetInitialPassword, Super Admin'in provision ettiği bir Owner'ın (veya
// başka bir must_change_password=true kullanıcının) ilk girişte YENİ bir
// şifre belirlemesi içindir -- ChangeOwnPassword'ün aksine mevcut şifreyi
// DOĞRULAMAZ (kullanıcı zaten geçici şifreyle kimlik doğrulamış durumda).
// Bu yüzden YALNIZCA must_change_password açıkken çalışır; değilse
// domain.ErrInitialPasswordAlreadySet. Bayrağı AYNI sorguda temizler (bkz.
// SetPasswordAndClearMustChange). Geçici şifreyle açılmış DİĞER oturumlar
// kapanır, isteği yapan cihazınki (keepRefreshToken) açık kalır.
func (s *UserService) SetInitialPassword(ctx context.Context, id, organizationID, newPassword, keepRefreshToken string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	if !domain.ValidPasswordLength(newPassword) {
		return domain.ErrPasswordTooShort
	}
	hash, err := auth.HashPassword(newPassword)
	if err != nil {
		return err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	rows, err := txq.SetPasswordAndClearMustChange(ctx, sqlc.SetPasswordAndClearMustChangeParams{
		ID: uid, OrganizationID: orgID, PasswordHash: hash,
	})
	if err != nil {
		return err
	}
	if rows == 0 {
		if _, gerr := txq.GetUserByIDInOrg(ctx, sqlc.GetUserByIDInOrgParams{ID: uid, OrganizationID: orgID}); gerr != nil {
			if errors.Is(gerr, pgx.ErrNoRows) {
				return domain.ErrNotFound
			}
			return gerr
		}
		return domain.ErrInitialPasswordAlreadySet
	}
	if err := revokeOtherSessions(ctx, txq, uid, keepRefreshToken); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// revokeOtherSessions, kullanıcının keepRefreshToken DIŞINDAKİ tüm açık
// oturumlarını kapatır; keepRefreshToken boşsa hepsini.
func revokeOtherSessions(ctx context.Context, q *sqlc.Queries, uid pgtype.UUID, keepRefreshToken string) error {
	if keepRefreshToken == "" {
		return q.RevokeAllUserRefreshTokens(ctx, uid)
	}
	return q.RevokeUserRefreshTokensExcept(ctx, sqlc.RevokeUserRefreshTokensExceptParams{
		UserID: uid, TokenHash: auth.HashRefreshToken(keepRefreshToken),
	})
}

// Deactivate, kullanıcıyı pasifleştirir -- satır silinmez, son aktif Owner
// korunur, açık oturumları iptal edilir (bkz. user_lifecycle.go). Bir
// Sahip'i yalnızca bir Sahip pasifleştirebilir. Kontrol, firma kilidi ve
// değişiklik tek transaction'da (bkz. guardLastActiveOwner).
func (s *UserService) Deactivate(ctx context.Context, id, organizationID, actorUserID string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)
	if err := guardOwnerOnlyAction(ctx, txq, actorUserID, uid, orgID, ""); err != nil {
		return err
	}
	if _, err := deactivateUser(ctx, txq, id, organizationID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// syncLinkedEmployeeName: hesabın adı değişince bağlı personelin adı da
// değişir -- YALNIZCA ikisi önceden aynı addaysa (domain.SamePersonName).
// Aynıysalar ikisi tek kişinin tek adıdır; birini düzeltip diğerini eski
// bırakmak "kişi = tek kayıt"ı bozardı. Farklıysalar (hesap "batu",
// personel "Batuhan İnci") fark bilinçlidir -- personel adı bordroda/mesai
// listesinde resmî ad olarak durur, kısa hesap adı onu ezmemeli.
//
// Ters yön (personel adı -> hesap adı) BİLEREK yok: personeli düzenlemek
// employees.manage ister, hesabı düzenlemek Sahip/Yönetici'ye özel
// (organization.users.manage + requireAdmin); personel ekranı hesap
// verisini değiştirmemeli.
func syncLinkedEmployeeName(ctx context.Context, txq *sqlc.Queries, uid, orgID pgtype.UUID, oldName, newName string) error {
	if oldName == newName || newName == "" {
		return nil
	}
	emp, err := txq.GetEmployeeByUserID(ctx, sqlc.GetEmployeeByUserIDParams{UserID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		return err
	}
	if !domain.SamePersonName(emp.FullName, oldName) || emp.FullName == newName {
		return nil
	}
	return txq.UpdateEmployeeFullName(ctx, sqlc.UpdateEmployeeFullNameParams{ID: emp.ID, OrganizationID: orgID, FullName: newName})
}
