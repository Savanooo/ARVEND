package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ErrDuplicateWBSCode, aynı proje içinde ZATEN kullanılan bir WBS koduyla
// yeni bir düğüm oluşturma girişiminde döner (bkz. migration 0035
// UNIQUE(project_id, code)).
var ErrDuplicateWBSCode = errors.New("bu WBS kodu bu projede zaten kullanılıyor")

// ErrInvalidWBSParent, verilen parent_id BU projede/organizasyonda
// MEVCUT DEĞİLSE döner -- trg_project_wbs_nodes_check_consistency'nin
// (aynı proje/organizasyon şartı) servis katmanındaki erken, daha
// okunabilir hata mesajlı tespitidir.
var ErrInvalidWBSParent = errors.New("üst WBS düğümü bu projede bulunamadı")

type WBSNodeInput struct {
	ParentID  string // boşsa kök düğüm
	Code      string
	Name      string
	SortOrder int
	UserID    string
}

func (s *ProjectService) ListWBSNodes(ctx context.Context, projectID, organizationID string) ([]domain.WBSNode, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	rows, err := s.q.ListWBSNodes(ctx, sqlc.ListWBSNodesParams{ProjectID: pid, OrganizationID: orgID})
	if err != nil {
		return nil, err
	}
	out := make([]domain.WBSNode, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainWBSNode(r)
	}
	return out, nil
}

// resolveWBSParentRef, resolveChangeOrderRef İLE AYNI IDOR-güvenli
// desendir: boş ise kök düğüm (NULL parent), doluysa parent'ın GERÇEKTEN
// bu proje+organizasyona ait olduğunu sorgu seviyesinde doğrular.
func resolveWBSParentRef(ctx context.Context, q *sqlc.Queries, parentID string, pid, orgID pgtype.UUID) (pgtype.UUID, error) {
	parentID = strings.TrimSpace(parentID)
	if parentID == "" {
		return pgtype.UUID{}, nil
	}
	parent, err := repository.StringToUUID(parentID)
	if err != nil {
		return pgtype.UUID{}, ErrInvalidWBSParent
	}
	if _, err := q.GetWBSNode(ctx, sqlc.GetWBSNodeParams{ID: parent, OrganizationID: orgID, ProjectID: pid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return pgtype.UUID{}, ErrInvalidWBSParent
		}
		return pgtype.UUID{}, err
	}
	return parent, nil
}

func (s *ProjectService) CreateWBSNode(ctx context.Context, projectID, organizationID string, in WBSNodeInput) (*domain.WBSNode, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	in.Code = strings.TrimSpace(in.Code)
	in.Name = strings.TrimSpace(in.Name)
	if in.Code == "" {
		return nil, errors.New("WBS kodu zorunludur")
	}
	if in.Name == "" {
		return nil, errors.New("WBS adı zorunludur")
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	if _, err := s.requireOpenProject(ctx, txq, pid, orgID); err != nil {
		return nil, err
	}
	parentID, err := resolveWBSParentRef(ctx, txq, in.ParentID, pid, orgID)
	if err != nil {
		return nil, err
	}
	row, err := txq.CreateWBSNode(ctx, sqlc.CreateWBSNodeParams{
		OrganizationID: orgID, ProjectID: pid, ParentID: parentID,
		Code: in.Code, Name: in.Name, SortOrder: int32(in.SortOrder),
	})
	if err != nil {
		if isUniqueViolation(err) {
			return nil, ErrDuplicateWBSCode
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventWBSCreated, actorUUID(in.UserID),
		map[string]any{"wbs_node_id": row.ID.String(), "code": in.Code}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainWBSNode(row)
	return &out, nil
}

// UpdateWBSNode, YALNIZCA rename+reorder içindir -- parent_id (ağaç
// konumu) DEĞİŞTİRİLEMEZ (spec: "karmaşık drag/drop zorunlu değil",
// bkz. migration 0035 başlık notu "cycle OLUŞAMAZ çünkü parent hiç
// değişmez"). Kod TEKRAR tekilleşmesi is UniqueViolation ile yakalanır.
func (s *ProjectService) UpdateWBSNode(ctx context.Context, projectID, nodeID, organizationID string, in WBSNodeInput) (*domain.WBSNode, error) {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return nil, err
	}
	nid, err := repository.StringToUUID(nodeID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	in.Code = strings.TrimSpace(in.Code)
	in.Name = strings.TrimSpace(in.Name)
	if in.Code == "" {
		return nil, errors.New("WBS kodu zorunludur")
	}
	if in.Name == "" {
		return nil, errors.New("WBS adı zorunludur")
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	row, err := txq.UpdateWBSNode(ctx, sqlc.UpdateWBSNodeParams{
		ID: nid, OrganizationID: orgID, ProjectID: pid,
		Code: in.Code, Name: in.Name, SortOrder: int32(in.SortOrder),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		if isUniqueViolation(err) {
			return nil, ErrDuplicateWBSCode
		}
		return nil, err
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventWBSUpdated, actorUUID(in.UserID),
		map[string]any{"wbs_node_id": nodeID}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	out := repository.ToDomainWBSNode(row)
	return &out, nil
}

// ArchiveWBSNode, HARD DELETE DEĞİLDİR -- mevcut bütçe kalemleri
// wbs_node_id ile bu düğüme referans veriyor olabilir (bkz. migration
// 0035 project_budget_lines.wbs_node_id ON DELETE değil, nullable FK).
func (s *ProjectService) ArchiveWBSNode(ctx context.Context, projectID, nodeID, organizationID, userID string) error {
	pid, orgID, err := s.scopedIDs(projectID, organizationID)
	if err != nil {
		return err
	}
	nid, err := repository.StringToUUID(nodeID)
	if err != nil {
		return domain.ErrNotFound
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	txq := s.q.WithTx(tx)

	rows, err := txq.ArchiveWBSNode(ctx, sqlc.ArchiveWBSNodeParams{ID: nid, OrganizationID: orgID, ProjectID: pid})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	if err := logProjectEvent(ctx, txq, orgID, pid, domain.ProjectEventWBSArchived, actorUUID(userID),
		map[string]any{"wbs_node_id": nodeID}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
