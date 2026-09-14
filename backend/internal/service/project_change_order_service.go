package service

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/platform/mailer"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

var (
	ErrChangeOrderNotEditable      = errors.New("yalnızca taslak durumundaki ek işler düzenlenebilir")
	ErrChangeOrderNotSendable      = errors.New("yalnızca taslak durumundaki bir ek iş gönderilebilir")
	ErrChangeOrderNotCancellable   = errors.New("bu ek iş iptal edilemez")
	ErrChangeOrderNotRevisable     = errors.New("bu ek iş için revizyon oluşturulamaz")
	ErrChangeOrderNotRespondable   = errors.New("bu ek iş için onay/red işlemi yapılamaz")
	ErrChangeOrderShareLinkRevoked = errors.New("bu paylaşım bağlantısı iptal edilmiş")
	ErrChangeOrderShareLinkExpired = errors.New("bu paylaşım bağlantısının süresi dolmuş")
	ErrChangeOrderWouldGoNegative  = errors.New("bu eksiltme onaylanırsa proje bedeli negatife düşer, onaylanamaz")
	ErrInvalidChangeOrderRef       = errors.New("geçersiz ek iş referansı")
	ErrNoChangeOrderItems          = errors.New("en az bir kalem girilmeli ve toplam sıfırdan büyük olmalıdır")
)

type ChangeOrderItemInput struct {
	ProductID         *string
	Description       string
	Quantity          float64
	Unit              string
	UnitPrice         float64
	EstimatedUnitCost *float64
}

type ChangeOrderInput struct {
	ChangeType    string
	Title         string
	Description   string
	VatRate       float64
	CustomerNotes string
	InternalNotes string
	Items         []ChangeOrderItemInput
	UserID        string
}

type ChangeOrderEmailInput struct {
	To      string
	Subject string
	Message string
	UserID  string
}

// PublicChangeOrderView, müşteri paylaşım sayfasının ihtiyaç duyduğu
// TÜM bilgiyi taşır -- maliyet/kâr/internal_notes ASLA içermez (bkz.
// handler katmanındaki ayrı public DTO).
type PublicChangeOrderView struct {
	ChangeOrder            domain.ChangeOrder
	ProjectNo              string
	ProjectName            string
	CustomerName           string
	BaseContractAmount     float64
	CurrentContractValue   float64
	ProjectedContractValue float64
	Currency               string
	CanRespond             bool
}

// resolveChangeOrderRef, opsiyonel bir change_order_id'yi doğrular: boşsa
// NULL (pgtype.UUID{}) döner, doluysa AYNI projeye ait olduğu
// doğrulanmış bir UUID döner. Başka bir projenin/firmanın ek işine
// masraf/taşeron bağlanamaz (bkz. denetim: cross-project/cross-tenant
// change_order_id kontrolü).
func resolveChangeOrderRef(ctx context.Context, q *sqlc.Queries, changeOrderID string, projectID, orgID pgtype.UUID) (pgtype.UUID, error) {
	changeOrderID = strings.TrimSpace(changeOrderID)
	if changeOrderID == "" {
		return pgtype.UUID{}, nil
	}
	cid, err := repository.StringToUUID(changeOrderID)
	if err != nil {
		return pgtype.UUID{}, ErrInvalidChangeOrderRef
	}
	co, err := q.GetChangeOrderByID(ctx, sqlc.GetChangeOrderByIDParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return pgtype.UUID{}, ErrInvalidChangeOrderRef
		}
		return pgtype.UUID{}, err
	}
	if co.ProjectID != projectID {
		return pgtype.UUID{}, ErrInvalidChangeOrderRef
	}
	return cid, nil
}

// loadChangeOrderRoute, bir ek işin id'sinden proje id'sini öğrenir --
// KİLİTSİZ bir okumadır, yalnızca hangi projenin kilitleneceğini
// belirlemek içindir (bkz. offer'daki resolveActiveShareLink'in ilk
// çağrısı). Karar bu okumaya DAYANMAZ; her mutasyon fonksiyonu proje ve
// ek iş satırlarını KİLİT ALTINDA yeniden okur.
func (s *ProjectService) loadChangeOrderRoute(ctx context.Context, q *sqlc.Queries, changeOrderID, organizationID string) (cid, pid, orgID pgtype.UUID, err error) {
	cid, err = repository.StringToUUID(changeOrderID)
	if err != nil {
		return cid, pid, orgID, domain.ErrNotFound
	}
	orgID, err = repository.StringToUUID(organizationID)
	if err != nil {
		return cid, pid, orgID, domain.ErrNotFound
	}
	co, err := q.GetChangeOrderByID(ctx, sqlc.GetChangeOrderByIDParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return cid, pid, orgID, domain.ErrNotFound
		}
		return cid, pid, orgID, err
	}
	return cid, co.ProjectID, orgID, nil
}

func validateChangeOrderInput(in ChangeOrderInput) error {
	if !domain.ValidChangeOrderType(in.ChangeType) {
		return errors.New("geçersiz ek iş türü")
	}
	if strings.TrimSpace(in.Title) == "" {
		return errors.New("ek iş başlığı zorunludur")
	}
	if in.VatRate < 0 {
		return errors.New("KDV oranı negatif olamaz")
	}
	if len(in.Items) == 0 {
		return ErrNoChangeOrderItems
	}
	for _, it := range in.Items {
		if strings.TrimSpace(it.Description) == "" {
			return errors.New("kalem açıklaması zorunludur")
		}
		if it.Quantity <= 0 {
			return errors.New("kalem miktarı sıfırdan büyük olmalıdır")
		}
		if it.UnitPrice <= 0 {
			return errors.New("kalem birim fiyatı sıfırdan büyük olmalıdır")
		}
	}
	return nil
}

// insertChangeOrderWithItems, taslak bir ek iş satırını ve kalemlerini
// TEK transaction içinde oluşturur, ardından toplamları SQL'de yeniden
// hesaplar. project KİLİT ALTINDA (FOR UPDATE) okunmuş olmalıdır --
// çağıran bunu garanti eder.
func (s *ProjectService) insertChangeOrderWithItems(
	ctx context.Context, txq *sqlc.Queries, orgID, pid pgtype.UUID, project sqlc.Project,
	in ChangeOrderInput, supersedes pgtype.UUID,
) (sqlc.ProjectChangeOrder, error) {
	seq, err := txq.NextChangeOrderSeq(ctx, pid)
	if err != nil {
		return sqlc.ProjectChangeOrder{}, err
	}
	row, err := txq.CreateChangeOrder(ctx, sqlc.CreateChangeOrderParams{
		OrganizationID:          orgID,
		ProjectID:               pid,
		SequenceNo:              seq,
		ChangeType:              in.ChangeType,
		Title:                   strings.TrimSpace(in.Title),
		Description:             strings.TrimSpace(in.Description),
		VatRate:                 repository.Float64ToNumeric(in.VatRate),
		Currency:                project.Currency,
		InternalNotes:           strings.TrimSpace(in.InternalNotes),
		CustomerNotes:           strings.TrimSpace(in.CustomerNotes),
		CreatedBy:               actorUUID(in.UserID),
		SupersedesChangeOrderID: supersedes,
	})
	if err != nil {
		return sqlc.ProjectChangeOrder{}, err
	}
	if err := s.replaceChangeOrderItems(ctx, txq, orgID, pid, row.ID, in.Items); err != nil {
		return sqlc.ProjectChangeOrder{}, err
	}
	final, err := txq.RecomputeChangeOrderTotals(ctx, sqlc.RecomputeChangeOrderTotalsParams{ID: row.ID, OrganizationID: orgID})
	if err != nil {
		return sqlc.ProjectChangeOrder{}, err
	}
	if repository.NumericToFloat64(final.GrandTotal) <= 0 {
		return sqlc.ProjectChangeOrder{}, ErrNoChangeOrderItems
	}
	return final, nil
}

// replaceChangeOrderItems, mevcut kalemleri SİLİP yeniden yazar (offer
// item'larının Update'te tam liste değişimiyle AYNI ilke) -- kısmi
// kalem CRUD'u yerine, her create/draft-update tüm kalem listesini
// bütün olarak taşır. line_total HER ZAMAN SQL'de hesaplanır.
func (s *ProjectService) replaceChangeOrderItems(ctx context.Context, txq *sqlc.Queries, orgID, pid, changeOrderID pgtype.UUID, items []ChangeOrderItemInput) error {
	if err := txq.DeleteChangeOrderItems(ctx, changeOrderID); err != nil {
		return err
	}
	for i, it := range items {
		// product_id (varsa) AYNI organizasyona ait olmadan kabul edilmez
		// (tenant izolasyonu) -- offer_service.go'daki insertRevisionItems
		// ile AYNI ilke: geçersiz/başka firmaya ait bir UUID sessizce
		// serbest metin satıra düşürülür (hata üretmez, kalem yine kaydedilir).
		var productID pgtype.UUID
		if it.ProductID != nil && strings.TrimSpace(*it.ProductID) != "" {
			if pidRef, err := repository.StringToUUID(*it.ProductID); err == nil {
				if _, err := txq.GetProductByID(ctx, sqlc.GetProductByIDParams{ID: pidRef, OrganizationID: orgID}); err == nil {
					productID = pidRef
				}
			}
		}
		if _, err := txq.CreateChangeOrderItem(ctx, sqlc.CreateChangeOrderItemParams{
			OrganizationID:    orgID,
			ProjectID:         pid,
			ChangeOrderID:     changeOrderID,
			ProductID:         productID,
			Description:       strings.TrimSpace(it.Description),
			Quantity:          repository.Float64ToNumeric(it.Quantity),
			Unit:              strings.TrimSpace(it.Unit),
			UnitPrice:         repository.Float64ToNumeric(it.UnitPrice),
			SortOrder:         int32(i),
			EstimatedUnitCost: repository.Float64PtrToNumeric(it.EstimatedUnitCost),
		}); err != nil {
			return err
		}
	}
	return nil
}

// ---------- Okuma ----------

func (s *ProjectService) ListChangeOrders(ctx context.Context, projectID, organizationID string) ([]domain.ChangeOrder, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListChangeOrders(ctx, sqlc.ListChangeOrdersParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.ChangeOrder, len(rows))
	for i, r := range rows {
		co, profit := repository.ToDomainChangeOrderListItem(r)
		co.Profitability = &profit
		out[i] = co
	}
	return out, nil
}

func (s *ProjectService) GetChangeOrder(ctx context.Context, changeOrderID, organizationID string) (*domain.ChangeOrder, error) {
	cid, err := repository.StringToUUID(changeOrderID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetChangeOrderByID(ctx, sqlc.GetChangeOrderByIDParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	co := repository.ToDomainChangeOrder(row)
	items, err := s.q.ListChangeOrderItems(ctx, cid)
	if err != nil {
		return nil, err
	}
	co.Items = make([]domain.ChangeOrderItem, len(items))
	for i, it := range items {
		co.Items[i] = repository.ToDomainChangeOrderItem(it)
	}
	if co.Status == domain.ChangeOrderSent {
		if link, err := s.q.GetActiveChangeOrderShareLink(ctx, cid); err == nil {
			tok := link.Token.String()
			co.ActiveShareToken = &tok
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}
	return &co, nil
}

// ---------- Oluşturma / Düzenleme ----------

func (s *ProjectService) CreateChangeOrder(ctx context.Context, projectID, organizationID string, in ChangeOrderInput) (*domain.ChangeOrder, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if err := validateChangeOrderInput(in); err != nil {
		return nil, err
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	project, err := s.requireOpenProject(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	row, err := s.insertChangeOrderWithItems(ctx, txq, orgID, pid, project, in, pgtype.UUID{})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventChangeOrderCreated, actorUUID(in.UserID),
		map[string]any{"change_order_id": row.ID.String(), "title": in.Title, "grand_total": repository.NumericToFloat64(row.GrandTotal)}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainChangeOrder(row)
	return &out, nil
}

func (s *ProjectService) UpdateChangeOrderDraft(ctx context.Context, changeOrderID, organizationID string, in ChangeOrderInput) (*domain.ChangeOrder, error) {
	if err := validateChangeOrderInput(in); err != nil {
		return nil, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	cid, pid, orgID, err := s.loadChangeOrderRoute(ctx, txq, changeOrderID, organizationID)
	if err != nil {
		return nil, err
	}
	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}
	current, err := txq.GetChangeOrderForUpdate(ctx, sqlc.GetChangeOrderForUpdateParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if current.Status != domain.ChangeOrderDraft {
		return nil, ErrChangeOrderNotEditable
	}

	if _, err := txq.UpdateChangeOrderDraft(ctx, sqlc.UpdateChangeOrderDraftParams{
		ID: cid, OrganizationID: orgID, ChangeType: in.ChangeType, Title: strings.TrimSpace(in.Title),
		Description: strings.TrimSpace(in.Description), VatRate: repository.Float64ToNumeric(in.VatRate),
		CustomerNotes: strings.TrimSpace(in.CustomerNotes), InternalNotes: strings.TrimSpace(in.InternalNotes),
	}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrChangeOrderNotEditable
		}
		return nil, err
	}
	if err := s.replaceChangeOrderItems(ctx, txq, orgID, pid, cid, in.Items); err != nil {
		return nil, err
	}
	final, err := txq.RecomputeChangeOrderTotals(ctx, sqlc.RecomputeChangeOrderTotalsParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	if repository.NumericToFloat64(final.GrandTotal) <= 0 {
		return nil, ErrNoChangeOrderItems
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventChangeOrderUpdated, actorUUID(in.UserID),
		map[string]any{"change_order_id": changeOrderID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainChangeOrder(final)
	return &out, nil
}

// ---------- Durum Geçişleri ----------

func (s *ProjectService) SendChangeOrder(ctx context.Context, changeOrderID, organizationID, userID string) (*domain.ChangeOrder, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	cid, pid, orgID, err := s.loadChangeOrderRoute(ctx, txq, changeOrderID, organizationID)
	if err != nil {
		return nil, err
	}
	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}
	current, err := txq.GetChangeOrderForUpdate(ctx, sqlc.GetChangeOrderForUpdateParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if current.Status != domain.ChangeOrderDraft {
		return nil, ErrChangeOrderNotSendable
	}
	row, err := txq.SendChangeOrder(ctx, sqlc.SendChangeOrderParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrChangeOrderNotSendable
		}
		return nil, err
	}
	if _, err := txq.CreateChangeOrderShareLink(ctx, sqlc.CreateChangeOrderShareLinkParams{
		OrganizationID: orgID, ProjectID: pid, ChangeOrderID: cid, CreatedBy: actorUUID(userID),
	}); err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventChangeOrderSent, actorUUID(userID),
		map[string]any{"change_order_id": changeOrderID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainChangeOrder(row)
	return &out, nil
}

func (s *ProjectService) CancelChangeOrder(ctx context.Context, changeOrderID, organizationID, userID string) (*domain.ChangeOrder, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	cid, pid, orgID, err := s.loadChangeOrderRoute(ctx, txq, changeOrderID, organizationID)
	if err != nil {
		return nil, err
	}
	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}
	current, err := txq.GetChangeOrderForUpdate(ctx, sqlc.GetChangeOrderForUpdateParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if current.Status != domain.ChangeOrderDraft && current.Status != domain.ChangeOrderSent {
		return nil, ErrChangeOrderNotCancellable
	}
	row, err := txq.CancelChangeOrder(ctx, sqlc.CancelChangeOrderParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrChangeOrderNotCancellable
		}
		return nil, err
	}
	if err := txq.RevokeChangeOrderShareLinks(ctx, cid); err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventChangeOrderCancelled, actorUUID(userID),
		map[string]any{"change_order_id": changeOrderID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainChangeOrder(row)
	return &out, nil
}

// ReviseChangeOrder, "Revize Et": eski (sent/rejected) kaydı SESSİZCE
// değiştirmez -- içeriğini klonlayan yeni bir TASLAK oluşturur, eski
// kaydı supersedes_change_order_id ile bu yeni kayda bağlar, eskiyi
// 'superseded' yapar ve aktif paylaşım linkini iptal eder (offer'ın
// Revise deseniyle birebir aynı ilke: gönderilmiş ticari belge
// sonradan mutate edilmez).
func (s *ProjectService) ReviseChangeOrder(ctx context.Context, changeOrderID, organizationID, userID string) (*domain.ChangeOrder, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	cid, pid, orgID, err := s.loadChangeOrderRoute(ctx, txq, changeOrderID, organizationID)
	if err != nil {
		return nil, err
	}
	project, err := s.requireOpenProject(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	current, err := txq.GetChangeOrderForUpdate(ctx, sqlc.GetChangeOrderForUpdateParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if current.Status != domain.ChangeOrderSent && current.Status != domain.ChangeOrderRejected {
		return nil, ErrChangeOrderNotRevisable
	}

	items, err := txq.ListChangeOrderItems(ctx, cid)
	if err != nil {
		return nil, err
	}
	itemInputs := make([]ChangeOrderItemInput, len(items))
	for i, it := range items {
		itemInputs[i] = ChangeOrderItemInput{
			Description: it.Description,
			Quantity:    repository.NumericToFloat64(it.Quantity),
			Unit:        it.Unit,
			UnitPrice:   repository.NumericToFloat64(it.UnitPrice),
		}
		if it.ProductID.Valid {
			s := it.ProductID.String()
			itemInputs[i].ProductID = &s
		}
		itemInputs[i].EstimatedUnitCost = repository.NumericToFloat64Ptr(it.EstimatedUnitCost)
	}

	newRow, err := s.insertChangeOrderWithItems(ctx, txq, orgID, pid, project, ChangeOrderInput{
		ChangeType: current.ChangeType, Title: current.Title, Description: current.Description,
		VatRate: repository.NumericToFloat64(current.VatRate), CustomerNotes: current.CustomerNotes,
		InternalNotes: current.InternalNotes, Items: itemInputs, UserID: userID,
	}, cid)
	if err != nil {
		return nil, err
	}

	if _, err := txq.SupersedeChangeOrder(ctx, sqlc.SupersedeChangeOrderParams{ID: cid, OrganizationID: orgID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrChangeOrderNotRevisable
		}
		return nil, err
	}
	if err := txq.RevokeChangeOrderShareLinks(ctx, cid); err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventChangeOrderSuperseded, actorUUID(userID),
		map[string]any{"old_change_order_id": changeOrderID, "new_change_order_id": newRow.ID.String()}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainChangeOrder(newRow)
	return &out, nil
}

// ---------- E-posta ----------

// SendChangeOrderEmail, mail gönderimini KASITLI olarak 3 aşamaya böler:
//  1. KISA bir transaction'da proje+ek iş satırları kilit altında
//     doğrulanır, aktif paylaşım linki bulunur/oluşturulur ve HEMEN
//     commit edilir;
//  2. hiçbir kilit/transaction AÇIK DEĞİLKEN bloklayan SMTP çağrısı
//     yapılır;
//  3. sonucu (başarı/hata farketmeksizin) yazan AYRI, kısa bir
//     transaction.
//
// Önceki sürüm proje+ek iş kilitlerini SMTP çağrısı boyunca açık
// tutuyordu -- bir SMTP zaman aşımı/gecikmesi, o süre boyunca AYNI
// projedeki tüm finans mutasyonlarını (müşterinin public linkten
// onay/red kararı DAHİL) bloke ederdi (bkz. denetim bulgusu).
func (s *ProjectService) SendChangeOrderEmail(ctx context.Context, changeOrderID, organizationID string, in ChangeOrderEmailInput) error {
	to := strings.TrimSpace(in.To)
	if to == "" {
		return errors.New("alıcı e-posta adresi zorunludur")
	}
	if len([]rune(to)) > 255 {
		return errors.New("alıcı e-posta adresi çok uzun")
	}

	// ---- Aşama 1: doğrulama + link çözümü, kısa transaction ----
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	cid, pid, orgID, err := s.loadChangeOrderRoute(ctx, txq, changeOrderID, organizationID)
	if err != nil {
		return err
	}
	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return err
	}
	co, err := txq.GetChangeOrderForUpdate(ctx, sqlc.GetChangeOrderForUpdateParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNotFound
		}
		return err
	}
	// ALLOW-list, deny-list DEĞİL: cancelled/superseded bir kayıt için
	// buradan YENİ bir aktif link üretilirse, Cancel/Revise'ın bilinçli
	// olarak çağırdığı RevokeChangeOrderShareLinks etkisiz kalır --
	// iptal edilmiş/yerine yenisi oluşturulmuş bir belge sessizce tekrar
	// erişilebilir hale gelir (bkz. denetim bulgusu).
	if co.Status != domain.ChangeOrderSent && co.Status != domain.ChangeOrderApproved && co.Status != domain.ChangeOrderRejected {
		return ErrChangeOrderNotSendable
	}
	link, err := txq.GetActiveChangeOrderShareLink(ctx, cid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			link, err = txq.CreateChangeOrderShareLink(ctx, sqlc.CreateChangeOrderShareLinkParams{
				OrganizationID: orgID, ProjectID: pid, ChangeOrderID: cid, CreatedBy: actorUUID(in.UserID),
			})
			if err != nil {
				return err
			}
		} else {
			return err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}

	// ---- Aşama 2: kilit/transaction YOK -- bloklayan SMTP çağrısı ----
	subject := strings.TrimSpace(in.Subject)
	if subject == "" {
		subject = fmt.Sprintf("Ek İş Onayınız İçin: EK-%03d", co.SequenceNo)
	}
	subject = truncateRunes(subject, 300)

	shareURL := s.frontendURL + "/ek-is/" + link.Token.String()
	body := strings.TrimSpace(in.Message)
	if body == "" {
		body = "Merhaba,\n\nProjenizle ilgili bir ek iş/değişiklik talebini incelemenizi rica ederiz."
	}
	body += "\n\n" + shareURL

	settings, err := s.settingsSvc.GetSmtp(ctx, organizationID)
	if err != nil {
		return err
	}
	sendErr := s.SendMailFunc(*settings, mailer.Message{To: to, Subject: subject, Body: body})

	// ---- Aşama 3: sonucu yaz, ayrı kısa transaction ----
	status := domain.ChangeOrderEmailLogStatusSent
	errMsg := ""
	eventType := domain.ProjectEventChangeOrderEmailSent
	if sendErr != nil {
		status = domain.ChangeOrderEmailLogStatusFailed
		errMsg = sendErr.Error()
		eventType = domain.ProjectEventChangeOrderEmailFail
	}

	tx2, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx2.Rollback(ctx)
	txq2 := s.q.WithTx(tx2)

	if _, err := txq2.CreateChangeOrderEmailLog(ctx, sqlc.CreateChangeOrderEmailLogParams{
		OrganizationID: orgID, ProjectID: pid, ChangeOrderID: cid, ShareLinkID: link.ID,
		Recipient: to, Subject: subject, Status: status, ErrorMessage: errMsg, SentBy: actorUUID(in.UserID),
	}); err != nil {
		return err
	}
	if err := logProjectEvent(ctx, txq2, orgID, pid, eventType, actorUUID(in.UserID),
		map[string]any{"change_order_id": changeOrderID, "recipient": to}); err != nil {
		return err
	}
	if err := tx2.Commit(ctx); err != nil {
		return err
	}
	return sendErr
}

// ---------- Müşteri Paylaşımı (kimlik doğrulamasız) ----------

// resolveActiveChangeOrderShareLink, token'ı çözer -- q hem havuzdan
// (salt okunur görüntüleme) hem transaction'dan (yanıt verme, kilit
// altında) çağrılabilir (offer'daki resolveActiveShareLink ile AYNI
// çift-kullanım deseni).
func (s *ProjectService) resolveActiveChangeOrderShareLink(ctx context.Context, q *sqlc.Queries, token string) (sqlc.ProjectChangeOrderShareLink, error) {
	tid, err := repository.StringToUUID(token)
	if err != nil {
		return sqlc.ProjectChangeOrderShareLink{}, domain.ErrNotFound
	}
	link, err := q.GetChangeOrderShareLinkByToken(ctx, tid)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return sqlc.ProjectChangeOrderShareLink{}, domain.ErrNotFound
		}
		return sqlc.ProjectChangeOrderShareLink{}, err
	}
	if link.RevokedAt.Valid {
		return sqlc.ProjectChangeOrderShareLink{}, ErrChangeOrderShareLinkRevoked
	}
	if link.ExpiresAt.Valid && time.Now().After(link.ExpiresAt.Time) {
		return sqlc.ProjectChangeOrderShareLink{}, ErrChangeOrderShareLinkExpired
	}
	return link, nil
}

// GetChangeOrderByShareLinkToken, müşterinin kimlik doğrulamasız
// görüntülemesidir -- KİLİT ALINMAZ (salt okunur). Görüntüleme olayı
// EN İYİ ÇABA ile loglanır: log başarısız olsa bile müşteri sayfayı
// görebilmeye devam eder (offer'ın customer_viewed deseniyle aynı).
func (s *ProjectService) GetChangeOrderByShareLinkToken(ctx context.Context, token, ip, userAgent string) (*PublicChangeOrderView, error) {
	link, err := s.resolveActiveChangeOrderShareLink(ctx, s.q, token)
	if err != nil {
		return nil, err
	}
	coRow, err := s.q.GetChangeOrderByID(ctx, sqlc.GetChangeOrderByIDParams{ID: link.ChangeOrderID, OrganizationID: link.OrganizationID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	project, err := s.q.GetProjectByID(ctx, sqlc.GetProjectByIDParams{ID: link.ProjectID, OrganizationID: link.OrganizationID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	items, err := s.q.ListChangeOrderItems(ctx, link.ChangeOrderID)
	if err != nil {
		return nil, err
	}
	totals, err := s.q.GetChangeOrderEffectTotals(ctx, sqlc.GetChangeOrderEffectTotalsParams{ProjectID: link.ProjectID, OrganizationID: link.OrganizationID})
	if err != nil {
		return nil, err
	}

	co := repository.ToDomainChangeOrder(coRow)
	co.Items = make([]domain.ChangeOrderItem, len(items))
	for i, it := range items {
		co.Items[i] = repository.ToDomainChangeOrderItem(it)
	}

	base := repository.NumericToFloat64(project.ContractAmount)
	current := base + repository.NumericToFloat64(totals.ApprovedAdditions) - repository.NumericToFloat64(totals.ApprovedDeductions)
	canRespond := co.Status == domain.ChangeOrderSent

	// current, zaten ONAYLANMIŞ ek işlerin toplam etkisini taşır. Bu ek iş
	// KENDİSİ onaylanmışsa etkisi current'a zaten dahildir -- tekrar
	// eklemek çift sayıma yol açar (bkz. denetim bulgusu). Yalnızca hâlâ
	// beklemede (sent) olan bir ek iş için "onaylanırsa ne olur" projeksiyonu
	// anlamlıdır; onaylanmış/reddedilmiş/iptal/superseded durumlarda
	// projected == current.
	projected := current
	if co.Status != domain.ChangeOrderApproved {
		projected = current + co.SignedEffect()
	}

	if err := logProjectEvent(ctx, s.q, link.OrganizationID, link.ProjectID, domain.ProjectEventChangeOrderViewed, pgtype.UUID{},
		map[string]any{"change_order_id": link.ChangeOrderID.String(), "ip": truncateRunes(ip, 45), "user_agent": truncateRunes(userAgent, 500)}); err != nil {
		log.Printf("change_order_viewed olayı yazılamadı: %v", err)
	}

	return &PublicChangeOrderView{
		ChangeOrder:            co,
		ProjectNo:              project.ProjectNo,
		ProjectName:            project.Name,
		CustomerName:           project.CustomerName,
		BaseContractAmount:     base,
		CurrentContractValue:   current,
		ProjectedContractValue: projected,
		Currency:               project.Currency,
		CanRespond:             canRespond,
	}, nil
}

// RespondChangeOrderByShareLinkToken, müşterinin kabul/red kararıdır.
// offer'daki RespondByShareLinkToken ile BİREBİR aynı yarış-koruması:
//  1. token, kilit anahtarını (project_id) öğrenmek için ÖNCE kilitsiz
//     çözülür; 2) proje satırı KİLİT ALTINDA okunur (requireOpenProject
//     ile AYNI sırada -- deadlock'a karşı tutarlı kilit sırası); 3) token
//     kilit ALTINDA tekrar çözülür (personel bu arada linki iptal etmiş
//     olabilir); 4) ek iş satırı KİLİT ALTINDA okunur ve durumu
//     doğrulanır; 5) eksiltme onayıysa GÜNCEL toplamlar (aynı kilit
//     altında, tamamen serileştirilmiş) okunup negatife düşüp
//     düşmeyeceği kontrol edilir.
func (s *ProjectService) RespondChangeOrderByShareLinkToken(ctx context.Context, token, decision, ip, userAgent string) (*domain.ChangeOrder, error) {
	if decision != domain.ChangeOrderApproved && decision != domain.ChangeOrderRejected {
		return nil, errors.New("geçersiz karar")
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	link, err := s.resolveActiveChangeOrderShareLink(ctx, txq, token)
	if err != nil {
		return nil, err
	}

	// project'in kendisi (proje kilidi ALINDIKTAN sonra) burada yalnızca
	// yan etkisi (satır kilidi + açık-proje doğrulaması) için gerekli --
	// negatife-düşürme kontrolü artık ChangeOrderApprovalWouldGoNegative
	// ile TAMAMEN SQL'de yapılıyor, project'in alanlarına Go'da ihtiyaç yok.
	if _, err := s.requireOpenProject(ctx, txq, link.ProjectID, link.OrganizationID); err != nil {
		if errors.Is(err, ErrProjectLocked) {
			return nil, ErrChangeOrderNotRespondable
		}
		return nil, err
	}

	// Kilidi beklerken personel bağlantıyı iptal etmiş/ek işi revize
	// etmiş olabilir; karara dayanak olan HER ŞEY kilit altında taze
	// okunur (READ COMMITTED'da her sorgu yeni bir snapshot görür).
	link, err = s.resolveActiveChangeOrderShareLink(ctx, txq, token)
	if err != nil {
		return nil, err
	}
	co, err := txq.GetChangeOrderForUpdate(ctx, sqlc.GetChangeOrderForUpdateParams{ID: link.ChangeOrderID, OrganizationID: link.OrganizationID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if co.Status != domain.ChangeOrderSent {
		return nil, ErrChangeOrderNotRespondable
	}

	if decision == domain.ChangeOrderApproved && co.ChangeType == domain.ChangeOrderDeduction {
		// Karşılaştırma TAMAMEN numeric'te yapılır (Go float64
		// aritmetiğine hiç dönülmez) -- 4 ayrı float64 dönüşümünün
		// birikimli IEEE-754 gürültüsü, tam sıfıra eşitlenen bir
		// eksiltmeyi yanlışlıkla negatif sayıp reddedebiliyordu (bkz.
		// denetim bulgusu).
		negative, err := txq.ChangeOrderApprovalWouldGoNegative(ctx, sqlc.ChangeOrderApprovalWouldGoNegativeParams{ID: co.ID, OrganizationID: co.OrganizationID})
		if err != nil {
			return nil, err
		}
		if negative {
			return nil, ErrChangeOrderWouldGoNegative
		}
	}

	row, err := txq.RespondChangeOrder(ctx, sqlc.RespondChangeOrderParams{ID: co.ID, OrganizationID: co.OrganizationID, Status: decision})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrChangeOrderNotRespondable
		}
		return nil, err
	}

	eventType := domain.ProjectEventChangeOrderApproved
	if decision == domain.ChangeOrderRejected {
		eventType = domain.ProjectEventChangeOrderRejected
	}
	if err := logProjectEvent(ctx, txq, row.OrganizationID, row.ProjectID, eventType, pgtype.UUID{},
		map[string]any{"change_order_id": row.ID.String(), "ip": truncateRunes(ip, 45), "user_agent": truncateRunes(userAgent, 500)}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainChangeOrder(row)
	return &out, nil
}
