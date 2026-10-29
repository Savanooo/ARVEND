package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/storage"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Masraf fişi / belgesi (migration 0076, kullanıcı geri bildirimi: "masraf
// girme yerine resim ve dosya ekleme gibi bir yer olsun"). Projeli ve genel
// (projesiz) masrafta aynı kurallar; uçlar projectID boş verilince genel
// masrafa bakar.
//
//   - Okuma, masrafı okuyabilen herkes: finans okuma/yönetme izni olan,
//     masrafı giren ve -- karar verebilmesi için -- onaylayıcı (onay bekleyen
//     ya da son günlerde karara bağlanmış masrafta, bkz.
//     domain.ExpenseApproverRecentDays). Okuyamayana masraf "bulunamadı":
//     başkasının masraf kimliği bilinse bile varlığı sızmaz.
//   - Ekleme/silme, masrafı giren (yalnızca onay bekleyen ya da reddedilen
//     masrafında) ve projects.finance.manage. Onaylanmış ya da iptal edilmiş
//     masrafın belgeleri SALT OKUNUR: onaylayıcı fişi görüp karar verdi;
//     karardan sonra fişin değişmesi o kararı boşa çıkarırdı.
//   - Masrafa yazan her yol gibi önce kilit alınır (projeli masrafta proje
//     satırı, genel masrafta masraf satırı): eşzamanlı bir onayla belge
//     ekleme sıraya girer, onaylanmış masrafa sonradan belge eklenemez.
//
// Belge eklemek/silmek olay (project_events) yazmaz: belge yalnızca karar
// öncesinde değişebilir ve satırın kendisi kimin ne zaman yüklediğini taşır;
// karara bağlanan masrafın belgeleri zaten donmuştur.

var (
	ErrExpenseAttachmentNotFound error = &NotFoundError{What: "masraf belgesi"}
	// ErrExpenseAttachmentsApproved / ErrExpenseAttachmentsVoided: kararı
	// verilmiş ya da iptal edilmiş masrafın belgeleri donmuştur (409).
	ErrExpenseAttachmentsApproved = errors.New("onaylanmış masrafın fiş ve belgeleri değiştirilemez")
	ErrExpenseAttachmentsVoided   = errors.New("iptal edilmiş masrafın fiş ve belgeleri değiştirilemez")
	// ErrExpenseAttachmentNotOwn: finans yöneticisi olmayan kişi başkasının
	// masrafına belge eklemeye/silmeye çalıştı (masrafı okuyabilen
	// onaylayıcı ya da finans okuyucusu; okuyamayana 404 döner).
	ErrExpenseAttachmentNotOwn = errors.New("yalnızca kendi girdiğiniz masrafa fiş veya belge ekleyip silebilirsiniz")
	ErrExpenseAttachmentLimit  = fmt.Errorf("bir masrafa en fazla %d fiş veya belge eklenebilir", domain.ExpenseAttachmentsMax)
	// ErrExpenseAttachmentType: fotoğraf (JPEG/PNG/WebP/HEIC) ya da PDF
	// dışındaki içerik. ErrUnsupportedType ile errors.Is uyumlu (400).
	ErrExpenseAttachmentType = &expenseAttachmentTypeError{}
)

type expenseAttachmentTypeError struct{}

func (*expenseAttachmentTypeError) Error() string {
	return "yalnızca fotoğraf (JPEG, PNG, HEIC) ya da PDF eklenebilir"
}
func (*expenseAttachmentTypeError) Is(target error) bool { return target == ErrUnsupportedType }

// ExpenseViewer: çağıranın masrafa göre yetkileri (handler AuthzContext'ten
// doldurur). Proje erişimi (üyelik) projeli uçlarda router'da denetlenir.
type ExpenseViewer struct {
	UserID        string
	FinanceRead   bool
	FinanceManage bool
	Approve       bool
}

// approverDecidedSince: onaylayıcı kapsamının (finans okuması olmadan)
// gördüğü en eski karar anı.
func approverDecidedSince(now time.Time) time.Time {
	return now.AddDate(0, 0, -domain.ExpenseApproverRecentDays)
}

// canReadExpense: bkz. dosya notu. ListExpensesFiltered'ın onaylayıcı
// kapsamıyla (decidable_since) aynı kural -- listede gördüğünün belgesini
// açabilir, görmediğininkini açamaz.
func canReadExpense(row sqlc.ProjectExpense, v ExpenseViewer, now time.Time) bool {
	actor := actorUUID(v.UserID)
	switch {
	case v.FinanceRead || v.FinanceManage:
		return true
	case actor.Valid && row.CreatedBy.Valid && row.CreatedBy == actor:
		return true
	case !v.Approve || row.VoidedAt.Valid:
		return false
	case row.ApprovalStatus == domain.ExpenseApprovalPending:
		return true
	}
	return row.DecidedAt.Valid && !row.DecidedAt.Time.Before(approverDecidedSince(now))
}

// checkAttachmentsWritable: kararı verilmiş/iptal edilmiş masrafın belgesi
// değişmez; finans yöneticisi dışındakiler yalnızca kendi masrafına yazar.
func checkAttachmentsWritable(row sqlc.ProjectExpense, v ExpenseViewer) error {
	actor := actorUUID(v.UserID)
	switch {
	case row.VoidedAt.Valid:
		return ErrExpenseAttachmentsVoided
	case row.ApprovalStatus == domain.ExpenseApprovalApproved:
		return ErrExpenseAttachmentsApproved
	case v.FinanceManage:
		return nil
	case !actor.Valid || !row.CreatedBy.Valid || row.CreatedBy != actor:
		return ErrExpenseAttachmentNotOwn
	}
	return nil
}

func expenseNotFoundFor(projectID string) error {
	if strings.TrimSpace(projectID) == "" {
		return ErrGeneralExpenseNotFound
	}
	return ErrExpenseNotFound
}

// attachmentIDs: kimlikleri ayrıştırır; projectID boşsa genel masraf.
func attachmentIDs(organizationID, projectID, expenseID string) (orgID, pid, eid pgtype.UUID, err error) {
	if orgID, err = repository.StringToUUID(organizationID); err != nil {
		return orgID, pid, eid, domain.ErrNotFound
	}
	if strings.TrimSpace(projectID) != "" {
		if pid, err = repository.StringToUUID(projectID); err != nil {
			return orgID, pid, eid, domain.ErrNotFound
		}
	}
	if eid, err = repository.StringToUUID(expenseID); err != nil {
		return orgID, pid, eid, expenseNotFoundFor(projectID)
	}
	return orgID, pid, eid, nil
}

// readScopedExpense: masrafı kilitsiz okur ve URL'deki kapsamla eşleştirir
// (projeli uçta o proje, genel uçta project_id NULL) -- başka bir projenin
// masrafı bu projenin URL'sinden açılamaz.
func readScopedExpense(ctx context.Context, q *sqlc.Queries, orgID, pid, eid pgtype.UUID) (sqlc.ProjectExpense, error) {
	row, err := q.GetExpenseAnyScope(ctx, sqlc.GetExpenseAnyScopeParams{ID: eid, OrganizationID: orgID})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && row.ProjectID != pid) {
		if pid.Valid {
			return sqlc.ProjectExpense{}, ErrExpenseNotFound
		}
		return sqlc.ProjectExpense{}, ErrGeneralExpenseNotFound
	}
	return row, err
}

// lockScopedExpense: yazım yolları için kilit -- projeli masrafta proje
// satırı (kapalı proje ErrProjectLocked; masraf kararı da aynı satırı
// kilitler), genel masrafta masraf satırı.
func (s *ProjectService) lockScopedExpense(ctx context.Context, txq *sqlc.Queries, orgID, pid, eid pgtype.UUID) (sqlc.ProjectExpense, error) {
	if !pid.Valid {
		return lockGeneralExpense(ctx, txq, eid, orgID)
	}
	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return sqlc.ProjectExpense{}, err
	}
	row, err := txq.GetExpense(ctx, sqlc.GetExpenseParams{ID: eid, OrganizationID: orgID, ProjectID: pid})
	if errors.Is(err, pgx.ErrNoRows) {
		return row, ErrExpenseNotFound
	}
	return row, err
}

// ListExpenseAttachments: GET .../expenses/{expenseId}/attachments.
func (s *ProjectService) ListExpenseAttachments(ctx context.Context, organizationID, projectID, expenseID string, v ExpenseViewer) ([]domain.ExpenseAttachment, error) {
	orgID, pid, eid, err := attachmentIDs(organizationID, projectID, expenseID)
	if err != nil {
		return nil, err
	}
	row, err := readScopedExpense(ctx, s.q, orgID, pid, eid)
	if err != nil {
		return nil, err
	}
	if !canReadExpense(row, v, time.Now()) {
		return nil, expenseNotFoundFor(projectID)
	}
	return listAttachments(ctx, s.q, orgID, eid)
}

func listAttachments(ctx context.Context, q *sqlc.Queries, orgID, eid pgtype.UUID) ([]domain.ExpenseAttachment, error) {
	rows, err := q.ListExpenseAttachments(ctx, sqlc.ListExpenseAttachmentsParams{OrganizationID: orgID, ExpenseID: eid})
	if err != nil {
		return nil, err
	}
	out := make([]domain.ExpenseAttachment, len(rows))
	for i, a := range rows {
		out[i] = repository.ToDomainExpenseAttachment(a)
	}
	return out, nil
}

// OpenExpenseAttachment: belgenin içeriği (indirme). Masrafı okuyamayan ya
// da belge bu masrafın değilse 404.
func (s *ProjectService) OpenExpenseAttachment(ctx context.Context, organizationID, projectID, expenseID, attachmentID string, v ExpenseViewer) (domain.ExpenseAttachment, io.ReadCloser, error) {
	orgID, pid, eid, err := attachmentIDs(organizationID, projectID, expenseID)
	if err != nil {
		return domain.ExpenseAttachment{}, nil, err
	}
	aid, err := repository.StringToUUID(attachmentID)
	if err != nil {
		return domain.ExpenseAttachment{}, nil, ErrExpenseAttachmentNotFound
	}
	row, err := readScopedExpense(ctx, s.q, orgID, pid, eid)
	if err != nil {
		return domain.ExpenseAttachment{}, nil, err
	}
	if !canReadExpense(row, v, time.Now()) {
		return domain.ExpenseAttachment{}, nil, expenseNotFoundFor(projectID)
	}
	a, err := s.q.GetExpenseAttachment(ctx, sqlc.GetExpenseAttachmentParams{ID: aid, ExpenseID: eid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ExpenseAttachment{}, nil, ErrExpenseAttachmentNotFound
		}
		return domain.ExpenseAttachment{}, nil, err
	}
	rc, err := s.store.Open(ctx, a.ObjectKey)
	if err != nil {
		if errors.Is(err, storage.ErrNotFound) {
			return domain.ExpenseAttachment{}, nil, ErrExpenseAttachmentNotFound
		}
		return domain.ExpenseAttachment{}, nil, wrapStorageErr(err)
	}
	return repository.ToDomainExpenseAttachment(a), rc, nil
}

// UploadExpenseAttachment: masrafa fiş/belge ekler. created=false: aynı
// içerik bu masrafta zaten var, mevcut kayıt döner (zayıf bağlantıda yanıtı
// kaybolan yüklemenin yeniden denenmesi mükerrer belge açmasın).
func (s *ProjectService) UploadExpenseAttachment(ctx context.Context, organizationID, projectID, expenseID string, v ExpenseViewer, name string, r io.Reader) (*domain.ExpenseAttachment, bool, error) {
	orgID, pid, eid, err := attachmentIDs(organizationID, projectID, expenseID)
	if err != nil {
		return nil, false, err
	}
	name = strings.TrimSpace(name)
	if name == "" {
		name = "belge"
	}
	name = truncateRunes(name, 255)
	actor := actorUUID(v.UserID)

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := s.lockScopedExpense(ctx, txq, orgID, pid, eid)
	if err != nil {
		return nil, false, err
	}
	if !canReadExpense(row, v, time.Now()) {
		return nil, false, expenseNotFoundFor(projectID)
	}
	if err := checkAttachmentsWritable(row, v); err != nil {
		return nil, false, err
	}

	scope := "general"
	if pid.Valid {
		scope = pid.String()
	}
	obj, key, err := s.storeExpenseAttachment(ctx, orgID.String(), scope, name, r)
	if err != nil {
		return nil, false, err
	}
	// Kayıt oluşmazsa depoya yazılan dosya sahipsiz kalmasın.
	keep := false
	defer func() {
		if !keep {
			_ = s.store.Delete(ctx, key)
		}
	}()

	existing, err := txq.GetExpenseAttachmentBySHA(ctx, sqlc.GetExpenseAttachmentBySHAParams{
		ExpenseID: eid, Sha256: obj.SHA256, OrganizationID: orgID,
	})
	switch {
	case err == nil:
		out := repository.ToDomainExpenseAttachment(existing)
		return &out, false, nil
	case !errors.Is(err, pgx.ErrNoRows):
		return nil, false, err
	}
	n, err := txq.CountExpenseAttachments(ctx, sqlc.CountExpenseAttachmentsParams{OrganizationID: orgID, ExpenseID: eid})
	if err != nil {
		return nil, false, err
	}
	if n >= domain.ExpenseAttachmentsMax {
		return nil, false, ErrExpenseAttachmentLimit
	}
	created, err := txq.CreateExpenseAttachment(ctx, sqlc.CreateExpenseAttachmentParams{
		OrganizationID: orgID, ExpenseID: eid, ObjectKey: key, OriginalName: name,
		MimeType: obj.MIMEType, SizeBytes: obj.Size, Sha256: obj.SHA256, UploadedBy: actor,
	})
	if err != nil {
		return nil, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, false, err
	}
	keep = true
	out := repository.ToDomainExpenseAttachment(created)
	return &out, true, nil
}

// DeleteExpenseAttachment: belgeyi kalıcı siler (satır + depodaki dosya).
// Satır işlemle birlikte gider; dosya işlem bittikten sonra silinir --
// silinemezse (disk hatası) hiçbir uç onu artık bulamaz (okuma hep bu
// tablodan geçer), yalnızca logda kalır.
func (s *ProjectService) DeleteExpenseAttachment(ctx context.Context, organizationID, projectID, expenseID, attachmentID string, v ExpenseViewer) error {
	orgID, pid, eid, err := attachmentIDs(organizationID, projectID, expenseID)
	if err != nil {
		return err
	}
	aid, err := repository.StringToUUID(attachmentID)
	if err != nil {
		return ErrExpenseAttachmentNotFound
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := s.lockScopedExpense(ctx, txq, orgID, pid, eid)
	if err != nil {
		return err
	}
	if !canReadExpense(row, v, time.Now()) {
		return expenseNotFoundFor(projectID)
	}
	if err := checkAttachmentsWritable(row, v); err != nil {
		return err
	}
	key, err := txq.DeleteExpenseAttachment(ctx, sqlc.DeleteExpenseAttachmentParams{ID: aid, ExpenseID: eid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrExpenseAttachmentNotFound
		}
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	if err := s.store.Delete(ctx, key); err != nil {
		log.Printf("masraf belgesi depodan silinemedi (%s): %v", key, err)
	}
	return nil
}

// storeExpenseAttachment: içeriği doğrular (tür içerikten) ve depoya yazar.
func (s *ProjectService) storeExpenseAttachment(ctx context.Context, orgID, scope, name string, r io.Reader) (storage.Object, string, error) {
	mime, body, n, err := sniffExpenseAttachment(io.LimitReader(r, MaxUploadBytes+1))
	if err != nil {
		return storage.Object{}, "", err
	}
	if n == 0 {
		return storage.Object{}, "", ErrEmptyFile
	}
	if !domain.ExpenseAttachmentMIMETypes[mime] {
		return storage.Object{}, "", ErrExpenseAttachmentType
	}
	key := storage.BuildKey("expenses", orgID, scope, uuid.NewString(), name)
	obj, err := s.store.Put(ctx, key, body)
	if err != nil {
		return storage.Object{}, "", wrapStorageErr(err)
	}
	if obj.Size > MaxUploadBytes {
		_ = s.store.Delete(ctx, key)
		return storage.Object{}, "", ErrFileTooLarge
	}
	obj.MIMEType = mime
	return obj, key, nil
}

// sniffExpenseAttachment: sniffMIME gibi ilk 512 bayttan türü tespit eder;
// http.DetectContentType HEIC/HEIF'i tanımadığı için (application/octet-
// stream der) ISO-BMFF "ftyp" kutusunun markasına ayrıca bakılır.
func sniffExpenseAttachment(r io.Reader) (string, io.Reader, int, error) {
	head := make([]byte, 512)
	n, err := io.ReadFull(r, head)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return "", nil, 0, err
	}
	head = head[:n]
	mime := http.DetectContentType(head)
	if i := strings.IndexByte(mime, ';'); i >= 0 {
		mime = strings.TrimSpace(mime[:i])
	}
	if mime == "application/octet-stream" {
		if heif := detectHEIF(head); heif != "" {
			mime = heif
		}
	}
	return mime, io.MultiReader(bytes.NewReader(head), r), n, nil
}

// detectHEIF: "....ftypheic" gibi başlıklar. Marka listesi HEIF/HEIC
// belirtimindeki görüntü markalarıdır (video markaları değil).
func detectHEIF(head []byte) string {
	if len(head) < 12 || string(head[4:8]) != "ftyp" {
		return ""
	}
	switch string(head[8:12]) {
	case "heic", "heix", "heim", "heis":
		return "image/heic"
	case "mif1", "heif":
		return "image/heif"
	}
	return ""
}

// attachExpenseAttachments: liste satırlarına belgeleri tek sorguda ekler.
// Her satır boş da olsa bir dilim alır (yanıtta "attachments": []).
func attachExpenseAttachments(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID, expenses []*domain.Expense) error {
	if len(expenses) == 0 {
		return nil
	}
	ids := make([]pgtype.UUID, 0, len(expenses))
	for _, e := range expenses {
		e.Attachments = []domain.ExpenseAttachment{}
		id, err := repository.StringToUUID(e.ID)
		if err != nil {
			continue
		}
		ids = append(ids, id)
	}
	rows, err := q.ListExpenseAttachmentsForExpenses(ctx, sqlc.ListExpenseAttachmentsForExpensesParams{
		OrganizationID: orgID, ExpenseIds: ids,
	})
	if err != nil {
		return err
	}
	byExpense := make(map[string][]domain.ExpenseAttachment, len(rows))
	for _, a := range rows {
		d := repository.ToDomainExpenseAttachment(a)
		byExpense[d.ExpenseID] = append(byExpense[d.ExpenseID], d)
	}
	for _, e := range expenses {
		if list, ok := byExpense[e.ID]; ok {
			e.Attachments = list
		}
	}
	return nil
}
