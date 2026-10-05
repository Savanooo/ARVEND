package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

var (
	ErrProjectLocked    = errors.New("tamamlanmış veya iptal edilmiş projede yeni finans hareketi oluşturulamaz")
	ErrCurrencyMismatch = errors.New("hareketin para birimi projenin para biriminden farklı olamaz")
	ErrInvalidAmount    = errors.New("tutar sıfırdan büyük olmalıdır")
	ErrAlreadyVoided    = errors.New("bu kayıt zaten iptal edilmiş")
)

// logProjectEvent, project_events'e değişmez bir denetim kaydı yazar.
// offer_events'teki gibi, durum değiştiren akışlarda AYNI transaction'ın
// q'su geçirilir -- "hareket oluştu ama kaydı yok" durumu oluşamaz.
func logProjectEvent(ctx context.Context, q *sqlc.Queries, orgID, projectID pgtype.UUID, eventType string, userID pgtype.UUID, metadata map[string]any) error {
	metaBytes := []byte("{}")
	if len(metadata) > 0 {
		b, err := json.Marshal(metadata)
		if err != nil {
			return err
		}
		metaBytes = b
	}
	_, err := q.CreateProjectEvent(ctx, sqlc.CreateProjectEventParams{
		OrganizationID: orgID,
		ProjectID:      projectID,
		EventType:      eventType,
		UserID:         userID,
		Metadata:       metaBytes,
	})
	return err
}

func actorUUID(userID string) pgtype.UUID {
	var id pgtype.UUID
	if userID != "" {
		if u, err := repository.StringToUUID(userID); err == nil {
			id = u
		}
	}
	return id
}

// requireOpenProject, projeyi org-scope'lu okur ve YENİ HAREKET
// eklenebilir durumda olduğunu doğrular. Tamamlanmış proje varsayılan
// olarak kilitlidir (tekrar "active" yapılırsa yeniden açılır); iptal
// edilmiş projede hiç hareket oluşturulamaz. Okuma uçları bu kontrolü
// KULLANMAZ -- geçmiş finans verisi her durumda görüntülenebilir.
//
// SATIR KİLİDİ İLE okunur (SELECT ... FOR UPDATE) ve q her zaman AÇIK
// bir transaction'ın Queries'i olmalıdır: aksi halde bu okuma ile asıl
// hareketin INSERT'i arasında proje durumu değişebilir (ör. bir
// ProjectService.Update aynı anda projeyi "completed" yapar) ve kilit
// kontrolü eski/kilitlenmemiş anlık görüntüyü görüp hareketin geçmesine
// izin verirdi (TOCTOU). Kilit, aynı satırı güncelleyen diğer yazarla
// (ör. Update) serileşir çünkü o da aynı satırı FOR UPDATE ile okur.
func (s *ProjectService) requireOpenProject(ctx context.Context, q *sqlc.Queries, projectID, orgID pgtype.UUID) (sqlc.Project, error) {
	p, err := q.GetProjectByIDForUpdate(ctx, sqlc.GetProjectByIDForUpdateParams{ID: projectID, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return sqlc.Project{}, domain.ErrNotFound
		}
		return sqlc.Project{}, err
	}
	if p.Status == domain.ProjectStatusCompleted || p.Status == domain.ProjectStatusCancelled {
		return sqlc.Project{}, ErrProjectLocked
	}
	return p, nil
}

// validateMoney, tutarın pozitif ve para biriminin proje para birimiyle
// aynı olduğunu doğrular. Bu fazda kur dönüşümü YOKTUR: farklı para
// biriminde hareket sessizce kabul edilip yanlış toplamlara karışmaz.
func validateMoney(amount float64, currency string, project sqlc.Project) error {
	if amount <= 0 {
		return ErrInvalidAmount
	}
	if currency != "" && currency != project.Currency {
		return ErrCurrencyMismatch
	}
	return nil
}

// ---------- Ödeme Planı ----------

type PaymentPlanItemInput struct {
	Name string
	// Percentage doluysa tutar contract_amount üzerinden HESAPLANIR ve
	// PlannedAmount yok sayılır -- ikisi birbiriyle çelişemez.
	Percentage    *float64
	PlannedAmount float64
	DueDate       *time.Time
	SortOrder     int
	Notes         string
	UserID        string
}

func (s *ProjectService) CreatePaymentPlanItem(ctx context.Context, projectID, organizationID string, in PaymentPlanItemInput) (*domain.PaymentPlanItem, error) {
	pid, err := repository.StringToUUID(projectID)
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

	project, err := s.requireOpenProject(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}

	name := strings.TrimSpace(in.Name)
	if name == "" {
		return nil, errors.New("kalem adı zorunludur")
	}

	amount := in.PlannedAmount
	var percentage pgtype.Numeric
	if in.Percentage != nil {
		if *in.Percentage <= 0 {
			return nil, errors.New("yüzde sıfırdan büyük olmalıdır")
		}
		percentage = repository.Float64ToNumeric(*in.Percentage)
		// Tutarı yüzdeden SQL'de numeric üzerinde hesapla -- Go'da
		// float çarpımı kuruş kaybettirebilir.
		row := tx.QueryRow(ctx, "SELECT round($1::numeric * $2::numeric / 100, 2)",
			project.ContractAmount, repository.Float64ToNumeric(*in.Percentage))
		var computed pgtype.Numeric
		if err := row.Scan(&computed); err != nil {
			return nil, err
		}
		amount = repository.NumericToFloat64(computed)
	}
	if amount <= 0 {
		return nil, ErrInvalidAmount
	}

	item, err := txq.CreatePaymentPlanItem(ctx, sqlc.CreatePaymentPlanItemParams{
		OrganizationID: orgID,
		ProjectID:      pid,
		SortOrder:      int32(in.SortOrder),
		Name:           name,
		Percentage:     percentage,
		PlannedAmount:  repository.Float64ToNumeric(amount),
		DueDate:        repository.TimePtrToDate(in.DueDate),
		Notes:          strings.TrimSpace(in.Notes),
		CreatedBy:      actorUUID(in.UserID),
	})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventPaymentPlanCreated, actorUUID(in.UserID),
		map[string]any{"item_id": item.ID.String(), "name": name, "planned_amount": amount}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainPaymentPlanItemRow(item)
	return &out, nil
}

func (s *ProjectService) ListPaymentPlan(ctx context.Context, projectID, organizationID string) ([]domain.PaymentPlanItem, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListPaymentPlanItems(ctx, sqlc.ListPaymentPlanItemsParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	// Vade karşılaştırması İstanbul takvim günüyle yapılır (sunucu UTC'de
	// çalışsa bile 00:00-03:00 arasında dünü "bugün" saymasın).
	now := IstanbulNow(time.Now())
	out := make([]domain.PaymentPlanItem, len(rows))
	for i, r := range rows {
		item := repository.ToDomainPaymentPlanItem(r)
		item.Status = domain.EffectivePlanItemStatus(item.Status, item.PlannedAmount, item.CollectedAmount, item.DueDate, now)
		out[i] = item
	}
	return out, nil
}

// GetPaymentPlanTotal, planlanan toplamı SQL/numeric üzerinde hesaplar
// (Go'da satır satır float64 toplamak YERİNE) -- financial-summary'deki
// "planned_collections" ile ikili yuvarlama farkından ötürü
// ayrışmasının önüne geçer (bkz. denetim bulgusu).
func (s *ProjectService) GetPaymentPlanTotal(ctx context.Context, projectID, organizationID string) (float64, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return 0, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return 0, domain.ErrNotFound
	}
	total, err := s.q.GetPaymentPlanTotal(ctx, sqlc.GetPaymentPlanTotalParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return 0, err
	}
	return repository.NumericToFloat64(total), nil
}

// projectID, URL'deki proje kimliğidir -- itemID'nin GERÇEKTEN bu projeye
// ait olduğunu sorgu seviyesinde doğrular (bkz. IDOR denetim bulgusu).
func (s *ProjectService) UpdatePaymentPlanItem(ctx context.Context, projectID, itemID, organizationID string, in PaymentPlanItemInput) (*domain.PaymentPlanItem, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	iid, err := repository.StringToUUID(itemID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	current, err := txq.GetPaymentPlanItem(ctx, sqlc.GetPaymentPlanItemParams{ID: iid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	project, err := s.requireOpenProject(ctx, txq, current.ProjectID, orgID)
	if err != nil {
		return nil, err
	}

	name := strings.TrimSpace(in.Name)
	if name == "" {
		return nil, errors.New("kalem adı zorunludur")
	}
	amount := in.PlannedAmount
	var percentage pgtype.Numeric
	if in.Percentage != nil {
		if *in.Percentage <= 0 {
			return nil, errors.New("yüzde sıfırdan büyük olmalıdır")
		}
		percentage = repository.Float64ToNumeric(*in.Percentage)
		row := tx.QueryRow(ctx, "SELECT round($1::numeric * $2::numeric / 100, 2)",
			project.ContractAmount, repository.Float64ToNumeric(*in.Percentage))
		var computed pgtype.Numeric
		if err := row.Scan(&computed); err != nil {
			return nil, err
		}
		amount = repository.NumericToFloat64(computed)
	}
	if amount <= 0 {
		return nil, ErrInvalidAmount
	}

	updated, err := txq.UpdatePaymentPlanItem(ctx, sqlc.UpdatePaymentPlanItemParams{
		ID:             iid,
		OrganizationID: orgID,
		SortOrder:      int32(in.SortOrder),
		Name:           name,
		Percentage:     percentage,
		PlannedAmount:  repository.Float64ToNumeric(amount),
		DueDate:        repository.TimePtrToDate(in.DueDate),
		Notes:          strings.TrimSpace(in.Notes),
		ProjectID:      pid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, current.ProjectID, domain.ProjectEventPaymentPlanUpdated, actorUUID(in.UserID),
		map[string]any{"item_id": itemID, "name": name}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainPaymentPlanItemRow(updated)
	return &out, nil
}

// projectID, URL'deki proje kimliğidir -- itemID'nin GERÇEKTEN bu projeye
// ait olduğunu sorgu seviyesinde doğrular (bkz. IDOR denetim bulgusu).
func (s *ProjectService) CancelPaymentPlanItem(ctx context.Context, projectID, itemID, organizationID, userID string) error {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return err
	}
	iid, err := repository.StringToUUID(itemID)
	if err != nil {
		return domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	item, err := txq.CancelPaymentPlanItem(ctx, sqlc.CancelPaymentPlanItemParams{ID: iid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return domain.ErrNotFound
		}
		return err
	}
	if err := logProjectEvent(ctx, txq, orgID, item.ProjectID, domain.ProjectEventPaymentPlanCancelled, actorUUID(userID),
		map[string]any{"item_id": itemID}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// ---------- Tahsilatlar ----------

type CollectionInput struct {
	PaymentPlanItemID *string
	Amount            float64
	Currency          string
	ReceivedDate      time.Time
	PaymentMethod     string
	Description       string
	ReferenceNo       string
	IdempotencyKey    string
	UserID            string
}

// CreateCollection, gerçek bir para girişi kaydeder. Çift tıklama/ağ
// tekrarına karşı istemcinin gönderdiği idempotency_key kullanılır: aynı
// anahtarla ikinci istek YENİ kayıt açmaz, ilk kaydı döner (DB'deki kısmi
// UNIQUE indeks son güvencedir).
func (s *ProjectService) CreateCollection(ctx context.Context, projectID, organizationID string, in CollectionInput) (*domain.Collection, error) {
	pid, err := repository.StringToUUID(projectID)
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

	project, err := s.requireOpenProject(ctx, txq, pid, orgID)
	if err != nil {
		return nil, err
	}
	if err := validateMoney(in.Amount, in.Currency, project); err != nil {
		return nil, err
	}

	key := strings.TrimSpace(in.IdempotencyKey)
	if key != "" {
		if existing, err := txq.GetCollectionByIdempotencyKey(ctx, sqlc.GetCollectionByIdempotencyKeyParams{
			ProjectID: pid, IdempotencyKey: &key,
		}); err == nil {
			out := repository.ToDomainCollection(existing)
			return &out, nil
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}

	// Plan kalemi verilmişse AYNI projeye ve organizasyona ait olmalı --
	// başka bir projenin/firmanın kalemine tahsilat bağlanamaz.
	var planItemID pgtype.UUID
	if in.PaymentPlanItemID != nil && *in.PaymentPlanItemID != "" {
		iid, err := repository.StringToUUID(*in.PaymentPlanItemID)
		if err != nil {
			return nil, errors.New("geçersiz ödeme planı kalemi")
		}
		if _, err := txq.GetPaymentPlanItem(ctx, sqlc.GetPaymentPlanItemParams{ID: iid, OrganizationID: orgID, ProjectID: pid}); err != nil {
			return nil, errors.New("geçersiz ödeme planı kalemi")
		}
		planItemID = iid
	}

	var keyPtr *string
	if key != "" {
		keyPtr = &key
	}
	row, err := txq.CreateCollection(ctx, sqlc.CreateCollectionParams{
		OrganizationID:    orgID,
		ProjectID:         pid,
		PaymentPlanItemID: planItemID,
		Amount:            repository.Float64ToNumeric(in.Amount),
		Currency:          project.Currency,
		ReceivedDate:      repository.TimeToDate(in.ReceivedDate),
		PaymentMethod:     strings.TrimSpace(in.PaymentMethod),
		Description:       strings.TrimSpace(in.Description),
		ReferenceNo:       strings.TrimSpace(in.ReferenceNo),
		IdempotencyKey:    keyPtr,
		CreatedBy:         actorUUID(in.UserID),
	})
	if err != nil {
		// Eşzamanlı AYNI anahtarlı bir istek bizden önce commit etti:
		// kısmi UNIQUE indeks bu INSERT'i reddeder. Bu bir sunucu hatası
		// değil, idempotency'nin ta kendisidir -- transaction'ı bırakıp
		// kazananın kaydını döneriz (yeniden okuma HAVUZ üzerinden olmalı,
		// bu transaction artık iptal durumunda).
		if key != "" && isUniqueViolation(err) {
			if existing, gerr := s.q.GetCollectionByIdempotencyKey(ctx, sqlc.GetCollectionByIdempotencyKeyParams{
				ProjectID: pid, IdempotencyKey: &key,
			}); gerr == nil {
				out := repository.ToDomainCollection(existing)
				return &out, nil
			}
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventCollectionReceived, actorUUID(in.UserID),
		map[string]any{"collection_id": row.ID.String(), "amount": in.Amount}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainCollection(row)
	return &out, nil
}

func (s *ProjectService) ListCollections(ctx context.Context, projectID, organizationID string) ([]domain.Collection, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListCollections(ctx, sqlc.ListCollectionsParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.Collection, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainCollection(r)
	}
	return out, nil
}

// VoidCollection, tahsilatı SİLMEZ -- muhasebesel iz korunur, kayıt
// yalnızca aggregate'lerden düşer.
// projectID, URL'deki proje kimliğidir -- collectionID'nin GERÇEKTEN bu
// projeye ait olduğunu sorgu seviyesinde doğrular (bkz. IDOR denetim
// bulgusu).
func (s *ProjectService) VoidCollection(ctx context.Context, projectID, collectionID, organizationID, userID, reason string) (*domain.Collection, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	cid, err := repository.StringToUUID(collectionID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.VoidCollection(ctx, sqlc.VoidCollectionParams{
		ID: cid, OrganizationID: orgID, VoidedBy: actorUUID(userID), VoidReason: strings.TrimSpace(reason), ProjectID: pid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// Yok/başka firmaya ya da başka projeye ait ile ZATEN iptal
			// edilmiş ayrı hatalardır (biri 404, diğeri 409 olmalı) --
			// ayrım için voided_at filtresi OLMADAN tekrar okunur.
			if existing, gerr := txq.GetCollection(ctx, sqlc.GetCollectionParams{ID: cid, OrganizationID: orgID, ProjectID: pid}); gerr == nil && existing.VoidedAt.Valid {
				return nil, ErrAlreadyVoided
			}
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, row.ProjectID, domain.ProjectEventCollectionVoided, actorUUID(userID),
		map[string]any{"collection_id": collectionID, "reason": reason}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainCollection(row)
	return &out, nil
}

// ---------- Masraflar ----------

type ExpenseInput struct {
	Category       string
	Description    string
	Amount         float64
	Currency       string
	ExpenseDate    time.Time
	SupplierName   string
	InvoiceNo      string
	Notes          string
	IdempotencyKey string
	// ChangeOrderID, OPSİYONELDİR (bkz. SubcontractorInput notu).
	ChangeOrderID string
	// CostCodeID/BudgetLineID, Cost Control (Sprint 2) eşlemesi için
	// OPSİYONELDİR (bkz. domain.Expense.CostCodeID notu). BudgetLineID
	// doluysa, boşsa dahi CostCodeID otomatik doldurulur (bkz. CreateExpense/
	// UpdateExpense: seçilen bütçe kaleminin cost_code_id'si kullanılır --
	// spec: "budget-line seçilince cost code otomatik doldurulmalı").
	CostCodeID   string
	BudgetLineID string
	UserID       string
}

func (s *ProjectService) CreateExpense(ctx context.Context, projectID, organizationID string, in ExpenseInput) (*domain.Expense, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if !domain.ValidExpenseCategory(in.Category) {
		return nil, errors.New("geçersiz masraf kategorisi")
	}
	if strings.TrimSpace(in.Description) == "" {
		return nil, errors.New("masraf açıklaması zorunludur")
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
	if err := validateMoney(in.Amount, in.Currency, project); err != nil {
		return nil, err
	}

	// Çift tıklama/ağ tekrarına karşı: tahsilat ve taşeron ödemesiyle
	// SİMETRİK idempotency anahtarı (bkz. denetim bulgusu -- masraf
	// eskiden bu korumaya sahip değildi).
	key := strings.TrimSpace(in.IdempotencyKey)
	if key != "" {
		if existing, err := txq.GetExpenseByIdempotencyKey(ctx, sqlc.GetExpenseByIdempotencyKeyParams{
			ProjectID: pid, IdempotencyKey: &key,
		}); err == nil {
			out := repository.ToDomainExpense(existing)
			return &out, nil
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}

	var keyPtr *string
	if key != "" {
		keyPtr = &key
	}
	changeOrderID, err := resolveChangeOrderRef(ctx, txq, in.ChangeOrderID, pid, orgID)
	if err != nil {
		return nil, err
	}
	costCodeID, budgetLineID, err := resolveCostAllocation(ctx, txq, in.CostCodeID, in.BudgetLineID, pid, orgID)
	if err != nil {
		return nil, err
	}
	row, err := txq.CreateExpense(ctx, sqlc.CreateExpenseParams{
		OrganizationID: orgID,
		ProjectID:      pid,
		Category:       in.Category,
		Description:    strings.TrimSpace(in.Description),
		Amount:         repository.Float64ToNumeric(in.Amount),
		Currency:       project.Currency,
		ExpenseDate:    repository.TimeToDate(in.ExpenseDate),
		SupplierName:   strings.TrimSpace(in.SupplierName),
		InvoiceNo:      strings.TrimSpace(in.InvoiceNo),
		Notes:          strings.TrimSpace(in.Notes),
		IdempotencyKey: keyPtr,
		CreatedBy:      actorUUID(in.UserID),
		ChangeOrderID:  changeOrderID,
		CostCodeID:     costCodeID,
		BudgetLineID:   budgetLineID,
	})
	if err != nil {
		// bkz. CreateCollection: eşzamanlı aynı anahtarlı istek kazandıysa
		// onun kaydını döneriz (havuz üzerinden -- bu transaction artık
		// iptal durumunda), 500 üretmeyiz.
		if key != "" && isUniqueViolation(err) {
			if existing, gerr := s.q.GetExpenseByIdempotencyKey(ctx, sqlc.GetExpenseByIdempotencyKeyParams{
				ProjectID: pid, IdempotencyKey: &key,
			}); gerr == nil {
				out := repository.ToDomainExpense(existing)
				return &out, nil
			}
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventExpenseAdded, actorUUID(in.UserID),
		map[string]any{"expense_id": row.ID.String(), "amount": in.Amount, "category": in.Category}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainExpense(row)
	return &out, nil
}

func (s *ProjectService) ListExpenses(ctx context.Context, projectID, organizationID string) ([]domain.Expense, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListExpenses(ctx, sqlc.ListExpensesParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.Expense, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainExpense(r)
	}
	return out, nil
}

// projectID, URL'deki proje kimliğidir -- expenseID'nin GERÇEKTEN bu
// projeye ait olduğunu sorgu seviyesinde doğrular (bkz. IDOR denetim
// bulgusu).
func (s *ProjectService) UpdateExpense(ctx context.Context, projectID, expenseID, organizationID string, in ExpenseInput) (*domain.Expense, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	eid, err := repository.StringToUUID(expenseID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if !domain.ValidExpenseCategory(in.Category) {
		return nil, errors.New("geçersiz masraf kategorisi")
	}
	if in.Amount <= 0 {
		return nil, ErrInvalidAmount
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	costCodeID, budgetLineID, err := resolveCostAllocation(ctx, txq, in.CostCodeID, in.BudgetLineID, pid, orgID)
	if err != nil {
		return nil, err
	}
	row, err := txq.UpdateExpense(ctx, sqlc.UpdateExpenseParams{
		ID:             eid,
		OrganizationID: orgID,
		Category:       in.Category,
		Description:    strings.TrimSpace(in.Description),
		Amount:         repository.Float64ToNumeric(in.Amount),
		ExpenseDate:    repository.TimeToDate(in.ExpenseDate),
		SupplierName:   strings.TrimSpace(in.SupplierName),
		InvoiceNo:      strings.TrimSpace(in.InvoiceNo),
		Notes:          strings.TrimSpace(in.Notes),
		ProjectID:      pid,
		CostCodeID:     costCodeID,
		BudgetLineID:   budgetLineID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, row.ProjectID, domain.ProjectEventExpenseUpdated, actorUUID(in.UserID),
		map[string]any{"expense_id": expenseID, "amount": in.Amount}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainExpense(row)
	return &out, nil
}

// projectID, URL'deki proje kimliğidir -- expenseID'nin GERÇEKTEN bu
// projeye ait olduğunu sorgu seviyesinde doğrular (bkz. IDOR denetim
// bulgusu).
func (s *ProjectService) VoidExpense(ctx context.Context, projectID, expenseID, organizationID, userID, reason string) (*domain.Expense, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	eid, err := repository.StringToUUID(expenseID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.VoidExpense(ctx, sqlc.VoidExpenseParams{
		ID: eid, OrganizationID: orgID, VoidedBy: actorUUID(userID), VoidReason: strings.TrimSpace(reason), ProjectID: pid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			if existing, gerr := txq.GetExpense(ctx, sqlc.GetExpenseParams{ID: eid, OrganizationID: orgID, ProjectID: pid}); gerr == nil && existing.VoidedAt.Valid {
				return nil, ErrAlreadyVoided
			}
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, row.ProjectID, domain.ProjectEventExpenseVoided, actorUUID(userID),
		map[string]any{"expense_id": expenseID, "reason": reason}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainExpense(row)
	return &out, nil
}

// ---------- Faturalar ----------

type InvoiceInput struct {
	InvoiceNo    string
	InvoiceType  string
	InvoiceDate  time.Time
	DueDate      *time.Time
	Amount       float64
	Currency     string
	Status       string
	CustomerName string
	Notes        string
	UserID       string
}

func (s *ProjectService) CreateInvoice(ctx context.Context, projectID, organizationID string, in InvoiceInput) (*domain.ProjectInvoice, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if !domain.ValidInvoiceType(in.InvoiceType) {
		return nil, errors.New("geçersiz fatura tipi")
	}
	status := in.Status
	if status == "" {
		status = domain.InvoiceDraft
	}
	if !domain.ValidInvoiceStatus(status) {
		return nil, errors.New("geçersiz fatura durumu")
	}
	if strings.TrimSpace(in.InvoiceNo) == "" {
		return nil, errors.New("fatura numarası zorunludur")
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
	if err := validateMoney(in.Amount, in.Currency, project); err != nil {
		return nil, err
	}

	customerName := strings.TrimSpace(in.CustomerName)
	if customerName == "" {
		customerName = project.CustomerName
	}

	row, err := txq.CreateInvoice(ctx, sqlc.CreateInvoiceParams{
		OrganizationID: orgID,
		ProjectID:      pid,
		InvoiceNo:      strings.TrimSpace(in.InvoiceNo),
		InvoiceType:    in.InvoiceType,
		InvoiceDate:    repository.TimeToDate(in.InvoiceDate),
		DueDate:        repository.TimePtrToDate(in.DueDate),
		Amount:         repository.Float64ToNumeric(in.Amount),
		Currency:       project.Currency,
		Status:         status,
		CustomerName:   customerName,
		Notes:          strings.TrimSpace(in.Notes),
		CreatedBy:      actorUUID(in.UserID),
	})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventInvoiceCreated, actorUUID(in.UserID),
		map[string]any{"invoice_id": row.ID.String(), "invoice_no": in.InvoiceNo, "amount": in.Amount}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectInvoice(row)
	return &out, nil
}

func (s *ProjectService) ListInvoices(ctx context.Context, projectID, organizationID string) ([]domain.ProjectInvoice, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListInvoices(ctx, sqlc.ListInvoicesParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.ProjectInvoice, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainProjectInvoice(r)
	}
	return out, nil
}

// projectID, URL'deki proje kimliğidir -- invoiceID'nin GERÇEKTEN bu
// projeye ait olduğunu sorgu seviyesinde doğrular (bkz. IDOR denetim
// bulgusu).
func (s *ProjectService) UpdateInvoiceStatus(ctx context.Context, projectID, invoiceID, organizationID, status, userID string) (*domain.ProjectInvoice, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	iid, err := repository.StringToUUID(invoiceID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if !domain.ValidInvoiceStatus(status) {
		return nil, errors.New("geçersiz fatura durumu")
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.UpdateInvoiceStatus(ctx, sqlc.UpdateInvoiceStatusParams{
		ID: iid, OrganizationID: orgID, Status: status, ProjectID: pid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, row.ProjectID, domain.ProjectEventInvoiceStatusChanged, actorUUID(userID),
		map[string]any{"invoice_id": invoiceID, "status": status}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainProjectInvoice(row)
	return &out, nil
}

// ---------- Taşeronlar ----------

type SubcontractorInput struct {
	Name            string
	CompanyName     string
	Phone           string
	Email           string
	WorkDescription string
	ContractAmount  float64
	Currency        string
	StartDate       *time.Time
	EndDate         *time.Time
	Status          string
	Notes           string
	// ChangeOrderID, OPSİYONELDİR: bu taşeron sözleşmesini bir ek işe
	// etiketler (bkz. Faz 8 kârlılık filtrelemesi). Boşsa ana sözleşme
	// kapsamındadır.
	ChangeOrderID string
	// CostCodeID, Cost Control (Sprint 2) eşlemesi için OPSİYONELDİR --
	// taşeronun BudgetLineID'si YOKTUR (bkz. domain.Subcontractor.CostCodeID
	// notu): taşeron taahhüdü yalnızca cost_code_id üzerinden "bütçe dışı"
	// olarak kırılım tablosuna katkı verir.
	CostCodeID string
	UserID     string
}

func (s *ProjectService) CreateSubcontractor(ctx context.Context, projectID, organizationID string, in SubcontractorInput) (*domain.Subcontractor, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if strings.TrimSpace(in.Name) == "" {
		return nil, errors.New("taşeron adı zorunludur")
	}
	status := in.Status
	if status == "" {
		status = domain.SubcontractorPlanned
	}
	if !domain.ValidSubcontractorStatus(status) {
		return nil, errors.New("geçersiz taşeron durumu")
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
	if err := validateMoney(in.ContractAmount, in.Currency, project); err != nil {
		return nil, err
	}
	changeOrderID, err := resolveChangeOrderRef(ctx, txq, in.ChangeOrderID, pid, orgID)
	if err != nil {
		return nil, err
	}
	costCodeID, err := resolveCostCodeRef(ctx, txq, in.CostCodeID, orgID)
	if err != nil {
		return nil, err
	}

	row, err := txq.CreateSubcontractor(ctx, sqlc.CreateSubcontractorParams{
		OrganizationID:  orgID,
		ProjectID:       pid,
		Name:            strings.TrimSpace(in.Name),
		CompanyName:     strings.TrimSpace(in.CompanyName),
		Phone:           strings.TrimSpace(in.Phone),
		Email:           strings.TrimSpace(in.Email),
		WorkDescription: strings.TrimSpace(in.WorkDescription),
		ContractAmount:  repository.Float64ToNumeric(in.ContractAmount),
		Currency:        project.Currency,
		StartDate:       repository.TimePtrToDate(in.StartDate),
		EndDate:         repository.TimePtrToDate(in.EndDate),
		Status:          status,
		Notes:           strings.TrimSpace(in.Notes),
		CreatedBy:       actorUUID(in.UserID),
		ChangeOrderID:   changeOrderID,
		CostCodeID:      costCodeID,
	})
	if err != nil {
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventSubcontractorAdded, actorUUID(in.UserID),
		map[string]any{"subcontractor_id": row.ID.String(), "name": in.Name, "contract_amount": in.ContractAmount}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontractorRow(row)
	out.RemainingAmount = out.ContractAmount
	return &out, nil
}

func (s *ProjectService) ListSubcontractors(ctx context.Context, projectID, organizationID string) ([]domain.Subcontractor, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListSubcontractors(ctx, sqlc.ListSubcontractorsParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.Subcontractor, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainSubcontractor(r)
	}
	return out, nil
}

// projectID, URL'deki proje kimliğidir -- subcontractorID'nin GERÇEKTEN
// bu projeye ait olduğunu sorgu seviyesinde doğrular (bkz. IDOR denetim
// bulgusu).
func (s *ProjectService) UpdateSubcontractor(ctx context.Context, projectID, subcontractorID, organizationID string, in SubcontractorInput) (*domain.Subcontractor, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	sid, err := repository.StringToUUID(subcontractorID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if strings.TrimSpace(in.Name) == "" {
		return nil, errors.New("taşeron adı zorunludur")
	}
	if in.ContractAmount <= 0 {
		return nil, ErrInvalidAmount
	}
	status := in.Status
	if !domain.ValidSubcontractorStatus(status) {
		return nil, errors.New("geçersiz taşeron durumu")
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	costCodeID, err := resolveCostCodeRef(ctx, txq, in.CostCodeID, orgID)
	if err != nil {
		return nil, err
	}
	row, err := txq.UpdateSubcontractor(ctx, sqlc.UpdateSubcontractorParams{
		ID:              sid,
		OrganizationID:  orgID,
		Name:            strings.TrimSpace(in.Name),
		CompanyName:     strings.TrimSpace(in.CompanyName),
		Phone:           strings.TrimSpace(in.Phone),
		Email:           strings.TrimSpace(in.Email),
		WorkDescription: strings.TrimSpace(in.WorkDescription),
		ContractAmount:  repository.Float64ToNumeric(in.ContractAmount),
		StartDate:       repository.TimePtrToDate(in.StartDate),
		EndDate:         repository.TimePtrToDate(in.EndDate),
		Status:          status,
		Notes:           strings.TrimSpace(in.Notes),
		ProjectID:       pid,
		CostCodeID:      costCodeID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, row.ProjectID, domain.ProjectEventSubcontractorUpdated, actorUUID(in.UserID),
		map[string]any{"subcontractor_id": subcontractorID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontractorRow(row)
	return &out, nil
}

// ---------- Taşeron Ödemeleri ----------

type SubcontractorPaymentInput struct {
	Amount         float64
	Currency       string
	PaidDate       time.Time
	Description    string
	IdempotencyKey string
	UserID         string
}

// projectID, URL'deki proje kimliğidir -- subcontractorID'nin GERÇEKTEN
// bu projeye ait olduğunu sorgu seviyesinde doğrular: aksi halde Proje
// A'ya yetkili biri, Proje B'nin taşeron UUID'sini bilerek Proje A
// URL'si üzerinden ona ödeme kaydedebilirdi (bkz. IDOR denetim bulgusu).
func (s *ProjectService) CreateSubcontractorPayment(ctx context.Context, projectID, subcontractorID, organizationID string, in SubcontractorPaymentInput) (*domain.SubcontractorPayment, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	sid, err := repository.StringToUUID(subcontractorID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	// Taşeron org-scope'lu VE project-scope'lu okunur: URL'deki projeye
	// gerçekten ait olduğu doğrulanmadan hiçbir ödeme kaydedilmez.
	sub, err := txq.GetSubcontractor(ctx, sqlc.GetSubcontractorParams{ID: sid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	project, err := s.requireOpenProject(ctx, txq, sub.ProjectID, orgID)
	if err != nil {
		return nil, err
	}
	if err := validateMoney(in.Amount, in.Currency, project); err != nil {
		return nil, err
	}

	// Anahtar TAŞERON bazında aranır (proje bazında DEĞİL): aksi halde
	// aynı projede farklı bir taşerona aynı anahtarla girilen ödeme bu
	// taşeronun kaydı sanılıp sessizce kaybolurdu (bkz. denetim bulgusu).
	key := strings.TrimSpace(in.IdempotencyKey)
	if key != "" {
		if existing, err := txq.GetSubcontractorPaymentByIdempotencyKey(ctx, sqlc.GetSubcontractorPaymentByIdempotencyKeyParams{
			SubcontractorID: sid, IdempotencyKey: &key,
		}); err == nil {
			out := repository.ToDomainSubcontractorPayment(existing)
			return &out, nil
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}

	// Toplam ödeme sözleşme bedelini aşamaz. Tekrar gönderilen (aynı
	// anahtarlı) ödeme yukarıda döndüğü için bu kontrolden ÖNCE çıkar.
	capRow, err := txq.LockSubcontractorForPayment(ctx, sqlc.LockSubcontractorForPaymentParams{
		ID: sid, OrganizationID: orgID, ProjectID: pid,
	})
	if err != nil {
		return nil, err
	}
	if err := checkWithinContract(repository.NumericToDecimal(capRow.ContractAmount), repository.NumericToDecimal(capRow.PaidAmount),
		in.Amount, project.Currency, "önce taşeronun sözleşme bedelini güncelleyin"); err != nil {
		return nil, err
	}

	var keyPtr *string
	if key != "" {
		keyPtr = &key
	}
	row, err := txq.CreateSubcontractorPayment(ctx, sqlc.CreateSubcontractorPaymentParams{
		OrganizationID:  orgID,
		ProjectID:       sub.ProjectID,
		SubcontractorID: sid,
		Amount:          repository.Float64ToNumeric(in.Amount),
		Currency:        project.Currency,
		PaidDate:        repository.TimeToDate(in.PaidDate),
		Description:     strings.TrimSpace(in.Description),
		IdempotencyKey:  keyPtr,
		CreatedBy:       actorUUID(in.UserID),
	})
	if err != nil {
		// bkz. CreateCollection: eşzamanlı aynı anahtarlı istek kazandıysa
		// onun kaydını döneriz, 500 üretmeyiz.
		if key != "" && isUniqueViolation(err) {
			if existing, gerr := s.q.GetSubcontractorPaymentByIdempotencyKey(ctx, sqlc.GetSubcontractorPaymentByIdempotencyKeyParams{
				SubcontractorID: sid, IdempotencyKey: &key,
			}); gerr == nil {
				out := repository.ToDomainSubcontractorPayment(existing)
				return &out, nil
			}
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, sub.ProjectID, domain.ProjectEventSubcontractorPaymentMade, actorUUID(in.UserID),
		map[string]any{"payment_id": row.ID.String(), "subcontractor_id": subcontractorID, "amount": in.Amount}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontractorPayment(row)
	return &out, nil
}

func (s *ProjectService) ListSubcontractorPayments(ctx context.Context, projectID, organizationID string) ([]domain.SubcontractorPayment, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListSubcontractorPayments(ctx, sqlc.ListSubcontractorPaymentsParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.SubcontractorPayment, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainSubcontractorPayment(r)
	}
	return out, nil
}

// projectID, URL'deki proje kimliğidir -- paymentID'nin GERÇEKTEN bu
// projeye ait olduğunu sorgu seviyesinde doğrular (bkz. IDOR denetim
// bulgusu).
func (s *ProjectService) VoidSubcontractorPayment(ctx context.Context, projectID, paymentID, organizationID, userID, reason string) (*domain.SubcontractorPayment, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	payID, err := repository.StringToUUID(paymentID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.VoidSubcontractorPayment(ctx, sqlc.VoidSubcontractorPaymentParams{
		ID: payID, OrganizationID: orgID, VoidedBy: actorUUID(userID), VoidReason: strings.TrimSpace(reason), ProjectID: pid,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			if existing, gerr := txq.GetSubcontractorPayment(ctx, sqlc.GetSubcontractorPaymentParams{ID: payID, OrganizationID: orgID, ProjectID: pid}); gerr == nil && existing.VoidedAt.Valid {
				return nil, ErrAlreadyVoided
			}
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, row.ProjectID, domain.ProjectEventSubcontractorPaymentVoid, actorUUID(userID),
		map[string]any{"payment_id": paymentID, "reason": reason}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainSubcontractorPayment(row)
	return &out, nil
}

// ---------- Finans Özeti ----------

// FinancialSummary, projenin tüm finans tablosunu TEK sorguda üretir.
func (s *ProjectService) FinancialSummary(ctx context.Context, projectID, organizationID string) (*domain.ProjectFinancialSummary, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetProjectFinancialSummary(ctx, sqlc.GetProjectFinancialSummaryParams{ID: pid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	out := repository.ToDomainFinancialSummary(row)
	return &out, nil
}

func (s *ProjectService) ListProjectEvents(ctx context.Context, projectID, organizationID string) ([]domain.ProjectEvent, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListProjectEvents(ctx, sqlc.ListProjectEventsParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.ProjectEvent, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainProjectEvent(r)
	}
	return out, nil
}
