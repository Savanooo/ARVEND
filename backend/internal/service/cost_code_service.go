package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ErrDuplicateCostCode, aynı organizasyon içinde ZATEN kullanılan bir
// kodla yeni bir organization_cost_codes satırı oluşturma girişiminde
// döner (bkz. migration 0035 UNIQUE(organization_id, code)).
var ErrDuplicateCostCode = errors.New("bu kod bu firmada zaten kullanılıyor")

// CostCodeService, organization_cost_codes (kuruluş-seviyeli, projeler
// arası PAYLAŞILAN maliyet kodu kataloğu) için CRUD işlemlerini yönetir --
// project_wbs_nodes'un AKSİNE proje-bağımsızdır (bkz. docs/cost-
// control.md "WBS ≠ Cost Code").
type CostCodeService struct {
	pool *pgxpool.Pool
	q    *sqlc.Queries
}

func NewCostCodeService(pool *pgxpool.Pool, q *sqlc.Queries) *CostCodeService {
	return &CostCodeService{pool: pool, q: q}
}

// logOrgEvent, logProjectEvent (project_finance_service.go) İLE AYNI
// desenin kuruluş-seviyeli (proje-bağımsız) karşılığıdır -- organization_
// events tablosuna yazar (bkz. migration 0035 §8b gerekçesi).
func logOrgEvent(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID, eventType string, userID pgtype.UUID, metadata map[string]any) error {
	metaBytes := []byte("{}")
	if len(metadata) > 0 {
		b, err := json.Marshal(metadata)
		if err != nil {
			return err
		}
		metaBytes = b
	}
	_, err := q.CreateOrganizationEvent(ctx, sqlc.CreateOrganizationEventParams{
		OrganizationID: orgID,
		EventType:      eventType,
		UserID:         userID,
		Metadata:       metaBytes,
	})
	return err
}

type CostCodeInput struct {
	Code        string
	Name        string
	Description string
	Category    string
	UserID      string
}

func (s *CostCodeService) List(ctx context.Context, organizationID string) ([]domain.OrganizationCostCode, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListOrganizationCostCodes(ctx, orgID)
	if err != nil {
		return nil, err
	}
	out := make([]domain.OrganizationCostCode, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainOrganizationCostCode(r)
	}
	return out, nil
}

func (s *CostCodeService) Get(ctx context.Context, id, organizationID string) (*domain.OrganizationCostCode, error) {
	cid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	row, err := s.q.GetOrganizationCostCode(ctx, sqlc.GetOrganizationCostCodeParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	c := repository.ToDomainOrganizationCostCode(row)
	return &c, nil
}

func (s *CostCodeService) Create(ctx context.Context, organizationID string, in CostCodeInput) (*domain.OrganizationCostCode, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.Code = strings.TrimSpace(in.Code)
	in.Name = strings.TrimSpace(in.Name)
	if in.Code == "" {
		return nil, errors.New("maliyet kodu zorunludur")
	}
	if in.Name == "" {
		return nil, errors.New("maliyet kodu adı zorunludur")
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.CreateOrganizationCostCode(ctx, sqlc.CreateOrganizationCostCodeParams{
		OrganizationID: orgID,
		Code:           in.Code,
		Name:           in.Name,
		Description:    strings.TrimSpace(in.Description),
		Category:       strings.TrimSpace(in.Category),
	})
	if err != nil {
		if isUniqueViolation(err) {
			return nil, ErrDuplicateCostCode
		}
		return nil, err
	}
	if err := logOrgEvent(ctx, txq, orgID, domain.OrgEventCostCodeCreated, actorUUID(in.UserID),
		map[string]any{"cost_code_id": row.ID.String(), "code": in.Code}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	c := repository.ToDomainOrganizationCostCode(row)
	return &c, nil
}

// Update, code'u DEĞİŞTİRMEZ -- kod, migration 0035'te UNIQUE(organization_
// id, code) ile korunur ve mevcut bütçe kalemi/taahhüt/gider satırları
// cost_code_id (UUID) ÜZERİNDEN bağlıdır, ama kodun kendisi raporlarda/
// dışa aktarımlarda sabit bir kimlik gibi kullanılabileceğinden değişimi
// bilinçli olarak API'ye açılmamıştır (yalnızca ad/açıklama/kategori
// düzenlenebilir).
func (s *CostCodeService) Update(ctx context.Context, id, organizationID string, in CostCodeInput) (*domain.OrganizationCostCode, error) {
	cid, err := repository.StringToUUID(id)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		return nil, errors.New("maliyet kodu adı zorunludur")
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.UpdateOrganizationCostCode(ctx, sqlc.UpdateOrganizationCostCodeParams{
		ID: cid, OrganizationID: orgID,
		Name:        in.Name,
		Description: strings.TrimSpace(in.Description),
		Category:    strings.TrimSpace(in.Category),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if err := logOrgEvent(ctx, txq, orgID, domain.OrgEventCostCodeUpdated, actorUUID(in.UserID),
		map[string]any{"cost_code_id": id}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	c := repository.ToDomainOrganizationCostCode(row)
	return &c, nil
}

// Archive, HARD DELETE DEĞİLDİR (spec: "NEVER hard-delete, archive via
// active=false only") -- geçmiş bütçe kalemi/taahhüt/gider kayıtları bu
// koda referans veriyor olabilir; yalnızca yeni seçim listelerinden
// çıkarılır (bkz. ArchiveOrganizationCostCode sorgu yorumu).
func (s *CostCodeService) Archive(ctx context.Context, id, organizationID, userID string) error {
	cid, err := repository.StringToUUID(id)
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

	rows, err := txq.ArchiveOrganizationCostCode(ctx, sqlc.ArchiveOrganizationCostCodeParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	if err := logOrgEvent(ctx, txq, orgID, domain.OrgEventCostCodeArchived, actorUUID(userID),
		map[string]any{"cost_code_id": id}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Reactivate, arşivlenmiş bir maliyet kodunu yeniden seçim listelerine
// döndürür -- yeni bir olay türü İCAT ETMEZ, "updated" olarak loglanır
// (aktiflik durumu da bir güncellemedir).
func (s *CostCodeService) Reactivate(ctx context.Context, id, organizationID, userID string) error {
	cid, err := repository.StringToUUID(id)
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

	rows, err := txq.ReactivateOrganizationCostCode(ctx, sqlc.ReactivateOrganizationCostCodeParams{ID: cid, OrganizationID: orgID})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	if err := logOrgEvent(ctx, txq, orgID, domain.OrgEventCostCodeUpdated, actorUUID(userID),
		map[string]any{"cost_code_id": id, "reactivated": true}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
