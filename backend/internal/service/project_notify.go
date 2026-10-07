package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Sahada 2026-10: "plan vb. kişiye direkt bildirim gitsin", "bir resim
// vb. yüklediğimde yöneticilere bildirim gitsin".

// notificationGroupWindow: bu süre içinde aynı kişiye aynı projede aynı
// türden okunmamış bir bildirim varsa yenisi açılmaz, o güncellenir.
const notificationGroupWindow = 30 * time.Minute

// resolveEmployeeAssignee: personel kimliği -> (kimlik, ad, bağlı kullanıcı
// hesabı). Boş kimlik = atama yok (sıfır değerler). Başka firmanın
// personeli ErrInvalidEmployee.
func resolveEmployeeAssignee(ctx context.Context, txq *sqlc.Queries, orgID pgtype.UUID, employeeID string) (pgtype.UUID, string, pgtype.UUID, error) {
	employeeID = strings.TrimSpace(employeeID)
	if employeeID == "" {
		return pgtype.UUID{}, "", pgtype.UUID{}, nil
	}
	eid, err := repository.StringToUUID(employeeID)
	if err != nil {
		return pgtype.UUID{}, "", pgtype.UUID{}, ErrInvalidEmployee
	}
	emp, err := txq.GetEmployeeByID(ctx, sqlc.GetEmployeeByIDParams{ID: eid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return pgtype.UUID{}, "", pgtype.UUID{}, ErrInvalidEmployee
		}
		return pgtype.UUID{}, "", pgtype.UUID{}, err
	}
	return eid, emp.FullName, emp.UserID, nil
}

// notifyScheduleAssigned: aşamanın sorumlusuna "plan ataması" bildirimi.
// Kendini atayan kendine bildirim almaz; personelin uygulama hesabı yoksa
// createNotification sessizce atlar.
func notifyScheduleAssigned(ctx context.Context, txq *sqlc.Queries, item sqlc.ProjectScheduleItem, assigneeUser, actor pgtype.UUID) error {
	if !assigneeUser.Valid || (actor.Valid && assigneeUser == actor) {
		return nil
	}
	body := projectNameFor(ctx, txq, item.OrganizationID, item.ProjectID)
	if span := dateSpan(item.StartDate, item.EndDate); span != "" {
		body = joinNonEmpty(" · ", body, span)
	}
	return createNotification(ctx, txq, CreateNotificationInput{
		OrganizationID: item.OrganizationID, UserID: assigneeUser, Type: domain.NotificationScheduleAssigned,
		Title:      truncateRunes("Plan ataması: "+item.Name, 200),
		Body:       truncateRunes(body, 500),
		EntityType: domain.NotificationEntityScheduleItem, EntityID: item.ID, ProjectID: item.ProjectID,
		ActionTarget: "/projeler/" + item.ProjectID.String() + "/planlama/" + item.ID.String(),
	})
}

// uploadNotice: projeye yüklenen bir fotoğraf/dosya için yöneticilere
// gidecek bildirimin türü ve metni.
type uploadNotice struct {
	Type       string
	EntityType string
	EntityID   pgtype.UUID
	// Title, gruptaki toplam sayıyla metni üretir ("3 yeni fotoğraf yüklendi").
	Title func(n int) string
}

// notifyProjectManagersOfUpload: projenin Erişim listesinde AÇIKÇA olup
// yönetici yetkisi (projects.update) taşıyanlara -- yükleyen hariç --
// gruplu bildirim (alıcı kuralı: resolveProjectAudience). Aynı kişiye son
// notificationGroupWindow içinde okunmamış aynı tür bildirim varsa o
// güncellenir (sayaç +1, en üste çıkar).
func notifyProjectManagersOfUpload(ctx context.Context, txq *sqlc.Queries, orgID pgtype.UUID, project sqlc.Project, actor pgtype.UUID, n uploadNotice) error {
	managers, err := resolveProjectAudience(ctx, txq, orgID, project.ID, domain.PermProjectsUpdate)
	if err != nil {
		return err
	}
	if len(managers) == 0 {
		return nil
	}
	uploader := ""
	if actor.Valid {
		if u, err := txq.GetUserByID(ctx, actor); err == nil {
			uploader = u.FullName
		}
	}
	body := truncateRunes(joinNonEmpty(" · ", project.Name, uploader), 500)
	target := "/projeler/" + project.ID.String() + "?grup=dokumanlar&alt=dosyalar"
	since := pgtype.Timestamptz{Time: time.Now().Add(-notificationGroupWindow), Valid: true}

	for _, uid := range managers {
		if actor.Valid && uid == actor {
			continue
		}
		existing, err := txq.FindGroupableNotification(ctx, sqlc.FindGroupableNotificationParams{
			UserID: uid, OrganizationID: orgID, Type: n.Type, ProjectID: project.ID, Since: since,
		})
		switch {
		case err == nil:
			if _, err := txq.BumpGroupedNotification(ctx, sqlc.BumpGroupedNotificationParams{
				ID: existing.ID, Title: truncateRunes(n.Title(int(existing.GroupCount)+1), 200), Body: body,
			}); err != nil {
				return err
			}
		case errors.Is(err, pgx.ErrNoRows):
			if err := createNotification(ctx, txq, CreateNotificationInput{
				OrganizationID: orgID, UserID: uid, Type: n.Type,
				Title: truncateRunes(n.Title(1), 200), Body: body,
				EntityType: n.EntityType, EntityID: n.EntityID, ProjectID: project.ID,
				ActionTarget: target,
			}); err != nil {
				return err
			}
		default:
			return err
		}
	}
	return nil
}

func photoUploadTitle(n int) string {
	if n <= 1 {
		return "Yeni fotoğraf yüklendi"
	}
	return fmt.Sprintf("%d yeni fotoğraf yüklendi", n)
}

func fileUploadTitle(n int) string {
	if n <= 1 {
		return "Yeni dosya yüklendi"
	}
	return fmt.Sprintf("%d yeni dosya yüklendi", n)
}

func projectNameFor(ctx context.Context, txq *sqlc.Queries, orgID, projectID pgtype.UUID) string {
	p, err := txq.GetProjectByID(ctx, sqlc.GetProjectByIDParams{ID: projectID, OrganizationID: orgID})
	if err != nil {
		return ""
	}
	return p.Name
}

// dateSpan: "12.10.2026 – 20.10.2026", tek uç varsa yalnızca o.
func dateSpan(start, end pgtype.Date) string {
	f := func(d pgtype.Date) string {
		if !d.Valid {
			return ""
		}
		return d.Time.Format("02.01.2006")
	}
	a, b := f(start), f(end)
	switch {
	case a != "" && b != "" && a != b:
		return a + " – " + b
	case a != "":
		return a
	default:
		return b
	}
}

func joinNonEmpty(sep string, parts ...string) string {
	out := parts[:0:0]
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return strings.Join(out, sep)
}

// resolveProjectAudience: operasyon bildirimlerinin (görev notu/durumu,
// dosya/fotoğraf yükleme) "yönetici" alıcıları -- permissionCode'u tutan
// aktif kullanıcılardan:
//   - firmanın Sahip ve Yöneticileri (her projede; ürün sahibinin isteği:
//     "fotoğraf/dosya yüklenince yöneticilere bildirim"),
//   - diğer herkes yalnızca projenin Erişim listesinde (project_users)
//     AÇIKÇA varsa.
//
// resolveProjectApprovers'tan farkı "Eski Sistem" (legacy_user) rolü: o da
// her projeyi görebilir ama BYZ'den taşınan firmalarda herkes bu roldeydi --
// her projenin her fotoğrafı/görev notu firmadaki herkese yağıyordu. Onlar
// artık yalnızca listede açıkça varsa alır. Onay türü bildirimler (satın
// alma talebi, hakediş, değişiklik emri) onay verebilecek HERKESE gitmeye
// devam eder (resolveProjectApprovers).
func resolveProjectAudience(ctx context.Context, txq *sqlc.Queries, orgID, projectID pgtype.UUID, permissionCode string) ([]pgtype.UUID, error) {
	holders, err := txq.ListUsersWithPermission(ctx, sqlc.ListUsersWithPermissionParams{OrganizationID: orgID, PermissionCode: permissionCode})
	if err != nil {
		return nil, err
	}
	if len(holders) == 0 {
		return nil, nil
	}
	members, err := txq.ListProjectUsersDetailed(ctx, sqlc.ListProjectUsersDetailedParams{ProjectID: projectID, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	memberSet := make(map[pgtype.UUID]bool, len(members))
	for _, m := range members {
		memberSet[m.UserID] = true
	}
	var out []pgtype.UUID
	for _, h := range holders {
		firmManager := h.OrganizationRoleCode == domain.OrgRoleOwner || h.OrganizationRoleCode == domain.OrgRoleAdmin
		if firmManager || memberSet[h.ID] {
			out = append(out, h.ID)
		}
	}
	return out, nil
}

// canAccessProject: (kullanıcı aktif mi, projeye erişebilir mi). Erişim
// kuralı middleware ile aynıdır: bypass rolü (domain.
// RoleBypassesProjectMembership) ya da project_users'ta açık üyelik.
// Kullanıcı bu firmada yoksa (false, false).
func canAccessProject(ctx context.Context, txq *sqlc.Queries, orgID, projectID, userID pgtype.UUID) (active, access bool, err error) {
	row, err := txq.GetUserProjectAccess(ctx, sqlc.GetUserProjectAccessParams{
		ProjectID: projectID, UserID: userID, OrganizationID: orgID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, false, nil
		}
		return false, false, err
	}
	return row.IsActive, row.IsActive && (domain.RoleBypassesProjectMembership(row.OrganizationRoleCode) || row.IsProjectMember), nil
}

// ErrAssigneeNoProjectAccess: görev/plan, uygulama hesabı olan ama projeyi
// GÖREMEYEN birine atanmak istendi (errors.Is ile yakalanır; metin kişinin
// adını taşır, bkz. assigneeNoAccessError).
var ErrAssigneeNoProjectAccess = errors.New("atanan kişinin bu projeye erişimi yok")

type assigneeNoAccessError struct{ name string }

func (e *assigneeNoAccessError) Error() string {
	return e.name + " bu projeye erişimi olmadığı için atanamaz; önce Proje Erişimi'nden projeye eklenmeli."
}

func (e *assigneeNoAccessError) Is(target error) bool { return target == ErrAssigneeNoProjectAccess }

// requireAssigneeProjectAccess: atanan personelin bağlı ve AKTİF bir
// uygulama hesabı varsa, o hesap projeye erişebilmelidir. Aksi halde kişi
// "Yeni görev atandı" bildirimini (ve telefon push'unu) alır, dokununca
// 403 görür ve görev "Görevlerim"de hiç çıkmaz.
//
// Neden otomatik erişim VERMİYORUZ: proje erişimi yalnızca
// projects.access.manage sahibinin (Sahip/Yönetici) Proje Erişimi
// ekranından verdiği bir yetkidir. Görev atayabilen proje yöneticisi bu
// izne sahip değil; atama erişim verseydi, kendisinin veremeyeceği
// erişimi (ör. bir Finans kullanıcısına projenin finans verisini) dolaylı
// yoldan vermiş olurdu. Aynı gerekçeyle "Ekibe Ekle" (İK roster'ı, Saha
// rolü de yapabilir) erişim vermez.
//
// Hesabı olmayan ya da pasif hesaplı personel atanabilir (bildirim
// gitmez; açacağı bir ekran da yok).
func requireAssigneeProjectAccess(ctx context.Context, txq *sqlc.Queries, orgID, projectID, userID pgtype.UUID, name string) error {
	if !userID.Valid {
		return nil
	}
	active, access, err := canAccessProject(ctx, txq, orgID, projectID, userID)
	if err != nil {
		return err
	}
	if active && !access {
		return &assigneeNoAccessError{name: name}
	}
	return nil
}

// Assignee, görev/plan formundaki "kime" seçicisinin satırı. Ücret yok:
// projeyi görebilen herkes (proje yöneticisi dahil -- onda employees.read
// yok) seçiciyi doldurabilsin, ama personel listesi maaş göstermesin.
type Assignee struct {
	ID       string
	FullName string
	Position string
	// HasAccount: personelin AKTİF bir uygulama hesabı var mı -- yoksa
	// atama bildirimi kimseye ulaşmaz; form bunu söyler.
	HasAccount bool
	// HasProjectAccess: o hesap bu projeyi görebiliyor mu (bypass rolü ya
	// da Proje Erişimi'nde). HasAccount true iken false ise kişiye görev/
	// plan ATANAMAZ (bkz. requireAssigneeProjectAccess) -- seçici bunu
	// gösterir.
	HasProjectAccess bool
}

// ListAssignees: projenin firmasındaki aktif personel (projeyi
// doğrulayarak; başka firmanın projesi ErrNotFound).
func (s *ProjectService) ListAssignees(ctx context.Context, projectID, organizationID string) ([]Assignee, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	if _, err := s.q.GetProjectByID(ctx, sqlc.GetProjectByIDParams{ID: pid, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	rows, err := s.q.ListProjectAssignees(ctx, sqlc.ListProjectAssigneesParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]Assignee, len(rows))
	for i, e := range rows {
		out[i] = Assignee{
			ID: e.ID.String(), FullName: e.FullName, Position: e.Position, HasAccount: e.HasAccount,
			HasProjectAccess: e.HasAccount && (domain.RoleBypassesProjectMembership(e.OrganizationRoleCode) || e.IsProjectMember),
		}
	}
	return out, nil
}
