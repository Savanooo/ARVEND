package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

type ProjectService struct {
	pool *pgxpool.Pool
	q    *sqlc.Queries
}

func NewProjectService(pool *pgxpool.Pool, q *sqlc.Queries) *ProjectService {
	return &ProjectService{pool: pool, q: q}
}

var (
	ErrOfferNotAccepted    = errors.New("yalnızca kabul edilmiş bir teklif projeye dönüştürülebilir")
	ErrInvalidProjectState = errors.New("geçersiz proje durumu geçişi")
)

type CreateProjectInput struct {
	// Name boşsa müşteri adı + teklif numarasından bir ad türetilir.
	Name        string
	ProjectType string
	StartDate   *time.Time
	EndDate     *time.Time
	Description string
	UserID      string
}

// CreateFromOffer, teklifin KABUL EDİLMİŞ güncel revizyonunu bir projeye
// dönüştürür. Müşteri bilgileri ve sözleşme bedeli o revizyondan anlık
// görüntü olarak kopyalanır -- proje bundan sonra teklif tarafındaki
// hiçbir değişiklikten etkilenmez.
//
// İdempotenttir: aynı revizyon daha önce bir projeye dönüştürülmüşse yeni
// proje AÇILMAZ, mevcut proje döner. Çift tıklama/eşzamanlı istekte iki
// katmanlı koruma vardır: (1) teklif bazlı advisory lock istekleri
// serileştirir, (2) UNIQUE (organization_id, source_revision_id) kısıtı
// son güvencedir -- kilit bir şekilde atlansa bile ikinci INSERT veritabanı
// tarafından reddedilir ve yine mevcut proje döndürülür.
func (s *ProjectService) CreateFromOffer(ctx context.Context, offerID, organizationID string, in CreateProjectInput) (*domain.Project, error) {
	offerUUID, err := repository.StringToUUID(offerID)
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

	// Teklifi revize eden/karar veren akışlarla aynı kilit anahtarı
	// (kanonik offer UUID'si) -- böylece proje oluşturma, eşzamanlı bir
	// "Revize Et" ya da müşteri kararıyla araya girmez.
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtext($1))", offerUUID.String()); err != nil {
		return nil, err
	}

	offerRow, err := txq.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: offerUUID, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	revRow, err := txq.GetOfferRevisionByID(ctx, sqlc.GetOfferRevisionByIDParams{
		ID: offerRow.CurrentRevisionID, OrganizationID: orgID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if revRow.Status != domain.OfferStatusKabulEdildi {
		return nil, ErrOfferNotAccepted
	}

	// Zaten dönüştürülmüş mü? (idempotentlik -- kilit altında okunur)
	if existing, err := txq.GetProjectBySourceRevision(ctx, sqlc.GetProjectBySourceRevisionParams{
		SourceRevisionID: revRow.ID, OrganizationID: orgID,
	}); err == nil {
		p := repository.ToDomainProject(existing)
		p.SourceOfferNo = offerRow.OfferNo
		p.SourceRevisionNo = int(revRow.RevisionNo)
		return &p, nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}

	projectNo, err := s.generateProjectNo(ctx, txq, orgID)
	if err != nil {
		return nil, err
	}

	name := strings.TrimSpace(in.Name)
	if name == "" {
		name = fmt.Sprintf("%s - %s", revRow.CustomerName, offerRow.OfferNo)
	}

	var createdBy pgtype.UUID
	if in.UserID != "" {
		if u, err := repository.StringToUUID(in.UserID); err == nil {
			createdBy = u
		}
	}

	projectRow, err := txq.CreateProject(ctx, sqlc.CreateProjectParams{
		OrganizationID:   orgID,
		ProjectNo:        projectNo,
		Name:             name,
		ProjectType:      strings.TrimSpace(in.ProjectType),
		SourceOfferID:    offerRow.ID,
		SourceRevisionID: revRow.ID,
		CustomerID:       revRow.CustomerID,
		CustomerName:     revRow.CustomerName,
		CustomerPhone:    revRow.CustomerPhone,
		CustomerEmail:    revRow.CustomerEmail,
		CustomerAddress:  revRow.CustomerAddress,
		ContractAmount:   revRow.GrandTotal,
		Currency:         revRow.Currency,
		Status:           domain.ProjectStatusPlanned,
		StartDate:        repository.TimePtrToDate(in.StartDate),
		EndDate:          repository.TimePtrToDate(in.EndDate),
		Description:      strings.TrimSpace(in.Description),
		InternalNotes:    "",
		CreatedBy:        createdBy,
	})
	if err != nil {
		// UNIQUE (organization_id, source_revision_id) ihlali: eşzamanlı bir
		// istek bizden önce davrandı. Yeni proje açmak yerine onunkini
		// döndürüyoruz -- kullanıcı açısından işlem yine idempotent.
		if isUniqueViolation(err) {
			if existing, gerr := s.q.GetProjectBySourceRevision(ctx, sqlc.GetProjectBySourceRevisionParams{
				SourceRevisionID: revRow.ID, OrganizationID: orgID,
			}); gerr == nil {
				p := repository.ToDomainProject(existing)
				p.SourceOfferNo = offerRow.OfferNo
				p.SourceRevisionNo = int(revRow.RevisionNo)
				return &p, nil
			}
		}
		return nil, err
	}

	if err := logOfferEvent(ctx, txq, orgID, offerRow.ID, revRow.ID, domain.EventProjectCreated, createdBy,
		map[string]any{
			"project_id":         projectRow.ID.String(),
			"project_no":         projectRow.ProjectNo,
			"source_revision_id": revRow.ID.String(),
		}, "", ""); err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	p := repository.ToDomainProject(projectRow)
	p.SourceOfferNo = offerRow.OfferNo
	p.SourceRevisionNo = int(revRow.RevisionNo)
	return &p, nil
}

// isUniqueViolation, PostgreSQL'in 23505 (unique_violation) hatasını
// tanır -- pgx bunu *pgconn.PgError olarak sarar.
func isUniqueViolation(err error) bool {
	var pgErr interface{ SQLState() string }
	if errors.As(err, &pgErr) {
		return pgErr.SQLState() == "23505"
	}
	return false
}

func (s *ProjectService) generateProjectNo(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID) (string, error) {
	year := time.Now().Year()
	seq, err := q.NextProjectSeq(ctx, sqlc.NextProjectSeqParams{OrganizationID: orgID, Year: int32(year)})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("PRJ-%d-%04d", year, seq), nil
}

func (s *ProjectService) Get(ctx context.Context, id, organizationID string) (*domain.Project, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetProjectByID(ctx, sqlc.GetProjectByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	return s.withSourceOfferInfo(ctx, row, orgID)
}

// GetByOfferID, bir teklifin projeye dönüştürülüp dönüştürülmediğini
// söyler -- teklif detayındaki "Projeye Dönüştür"/"Projeyi Görüntüle"
// ayrımı buna dayanır. Dönüştürülmemişse domain.ErrNotFound döner.
func (s *ProjectService) GetByOfferID(ctx context.Context, offerID, organizationID string) (*domain.Project, error) {
	uid, err := repository.StringToUUID(offerID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetProjectBySourceOffer(ctx, sqlc.GetProjectBySourceOfferParams{
		SourceOfferID: uid, OrganizationID: orgID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	return s.withSourceOfferInfo(ctx, row, orgID)
}

// withSourceOfferInfo, projenin kaynak teklif numarasını ve kabul edilen
// revizyon numarasını doldurur (detay ekranındaki "Kaynak Teklif" /
// "Kabul Edilen Revizyon" satırları için).
func (s *ProjectService) withSourceOfferInfo(ctx context.Context, row sqlc.Project, orgID pgtype.UUID) (*domain.Project, error) {
	p := repository.ToDomainProject(row)
	if offerRow, err := s.q.GetOfferByID(ctx, sqlc.GetOfferByIDParams{ID: row.SourceOfferID, OrganizationID: orgID}); err == nil {
		p.SourceOfferNo = offerRow.OfferNo
	}
	if revRow, err := s.q.GetOfferRevisionByID(ctx, sqlc.GetOfferRevisionByIDParams{ID: row.SourceRevisionID, OrganizationID: orgID}); err == nil {
		p.SourceRevisionNo = int(revRow.RevisionNo)
	}
	return &p, nil
}

type ProjectListFilter struct {
	Status      string
	CustomerID  string
	ProjectType string
	Currency    string
	StartFrom   *time.Time
	Search      string
	Page        int
	Limit       int
}

type ProjectListResult struct {
	Projects []domain.Project
	Total    int64
}

func (s *ProjectService) List(ctx context.Context, organizationID string, f ProjectListFilter) (*ProjectListResult, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	limit := f.Limit
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	page := f.Page
	if page <= 0 {
		page = 1
	}

	var status, projectType, currency, search *string
	if f.Status != "" {
		if !domain.ValidProjectStatus(f.Status) {
			return nil, errors.New("geçersiz proje durumu")
		}
		status = &f.Status
	}
	if f.ProjectType != "" {
		projectType = &f.ProjectType
	}
	if f.Currency != "" {
		currency = &f.Currency
	}
	if f.Search != "" {
		search = &f.Search
	}
	var customerID pgtype.UUID
	if f.CustomerID != "" {
		if cid, err := repository.StringToUUID(f.CustomerID); err == nil {
			customerID = cid
		}
	}

	rows, err := s.q.ListProjects(ctx, sqlc.ListProjectsParams{
		OrganizationID: orgID,
		Status:         status,
		CustomerID:     customerID,
		ProjectType:    projectType,
		Currency:       currency,
		StartFrom:      repository.TimePtrToDate(f.StartFrom),
		Search:         search,
		Limit:          int32(limit),
		Offset:         int32((page - 1) * limit),
	})
	if err != nil {
		return nil, err
	}
	total, err := s.q.CountProjects(ctx, sqlc.CountProjectsParams{
		OrganizationID: orgID,
		Status:         status,
		CustomerID:     customerID,
		ProjectType:    projectType,
		Currency:       currency,
		StartFrom:      repository.TimePtrToDate(f.StartFrom),
		Search:         search,
	})
	if err != nil {
		return nil, err
	}

	projects := make([]domain.Project, len(rows))
	for i, r := range rows {
		projects[i] = repository.ToDomainProjectListItem(r)
	}
	return &ProjectListResult{Projects: projects, Total: total}, nil
}

// UpdateProjectInput, YALNIZCA düzenlenebilir alanları taşır. project_no,
// source_offer_id, source_revision_id, contract_amount, currency ve
// müşteri snapshot'ı bilinçli olarak burada yoktur -- bunlar kaynak
// teklife ait dondurulmuş verilerdir ve sözleşme bedeli ileride "Ek İşler"
// mekanizmasıyla değişecektir.
type UpdateProjectInput struct {
	Name          string
	ProjectType   string
	Status        string
	StartDate     *time.Time
	EndDate       *time.Time
	Description   string
	InternalNotes string
}

func (s *ProjectService) Update(ctx context.Context, id, organizationID string, in UpdateProjectInput) (*domain.Project, error) {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}

	current, err := s.q.GetProjectByID(ctx, sqlc.GetProjectByIDParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}

	name := strings.TrimSpace(in.Name)
	if name == "" {
		return nil, errors.New("proje adı zorunludur")
	}
	status := in.Status
	if status == "" {
		status = current.Status
	}
	if !domain.ValidProjectStatus(status) {
		return nil, errors.New("geçersiz proje durumu")
	}
	if !domain.CanTransitionProjectStatus(current.Status, status) {
		return nil, ErrInvalidProjectState
	}

	row, err := s.q.UpdateProject(ctx, sqlc.UpdateProjectParams{
		ID:             uid,
		OrganizationID: orgID,
		Name:           name,
		ProjectType:    strings.TrimSpace(in.ProjectType),
		Status:         status,
		StartDate:      repository.TimePtrToDate(in.StartDate),
		EndDate:        repository.TimePtrToDate(in.EndDate),
		Description:    strings.TrimSpace(in.Description),
		InternalNotes:  strings.TrimSpace(in.InternalNotes),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	return s.withSourceOfferInfo(ctx, row, orgID)
}
