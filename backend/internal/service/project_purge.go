package service

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Proje temizliği (cmd/purge-project): uygulamadaki "Projeyi sil" para
// hareketi olan projeyi silmez, iptal eder (migration 0070). Yanlış ya da
// deneme için açılmış böyle bir projeyi BÜTÜN kayıtlarıyla (masraf,
// tahsilat, ödeme, fatura, satın alma, taşeron, hakediş, rapor, görev,
// dosya...) kalıcı silmek için sunucuda elle çalıştırılan araç. Yalnızca
// durumu "iptal" olan proje silinir; stok fişlerindeki proje bağı düşer
// (fiş kalır). Kaynak teklif silinmez, yeniden projeye dönüştürülebilir.

// projectPurgeTables: projeye project_id ile bağlı tablolar (sayım için).
var projectPurgeTables = []string{
	"project_expenses", "project_collections", "project_invoices", "project_payment_plan_items",
	"project_subcontractors", "project_subcontractor_payments",
	"project_subcontracts", "subcontract_items", "subcontract_change_orders", "subcontract_change_order_items",
	"subcontract_progress_claims", "subcontract_progress_claim_items", "subcontract_payments",
	"purchase_requests", "purchase_request_items", "rfqs", "rfq_items", "supplier_quotations", "quotation_items",
	"purchase_orders", "purchase_order_items",
	"project_budgets", "project_budget_lines", "project_budget_adjustments", "project_commitments",
	"project_cost_forecasts", "project_wbs_nodes", "project_contracts",
	"project_change_orders", "project_change_order_items", "project_change_order_share_links",
	"project_change_order_email_logs", "change_order_counters",
	"project_tasks", "project_task_updates", "project_schedule_items", "project_members", "project_users",
	"project_files", "project_photos", "project_notes", "project_daily_reports", "project_events",
	"project_delete_requests", "notifications", "inventory_documents",
}

// projectPurgeSteps: CASCADE ile gitmeyen (RESTRICT) bağlar çocuktan
// ebeveyne sırayla; kalanı proje satırıyla CASCADE gider. $1 proje id.
var projectPurgeSteps = []string{
	"UPDATE rfqs SET awarded_quotation_id = NULL WHERE project_id = $1",
	"DELETE FROM subcontract_payments WHERE project_id = $1",
	"DELETE FROM subcontract_progress_claim_items WHERE project_id = $1",
	"DELETE FROM subcontract_progress_claims WHERE project_id = $1",
	"DELETE FROM subcontract_change_order_items WHERE project_id = $1",
	"DELETE FROM subcontract_change_orders WHERE project_id = $1",
	"DELETE FROM subcontract_items WHERE project_id = $1",
	"DELETE FROM project_subcontracts WHERE project_id = $1",
	"DELETE FROM purchase_order_items WHERE project_id = $1",
	"DELETE FROM purchase_orders WHERE project_id = $1",
	"DELETE FROM quotation_items WHERE project_id = $1",
	"DELETE FROM supplier_quotations WHERE project_id = $1",
	"DELETE FROM rfq_items WHERE project_id = $1",
	"DELETE FROM rfqs WHERE project_id = $1",
	"DELETE FROM purchase_request_items WHERE project_id = $1",
	"DELETE FROM purchase_requests WHERE project_id = $1",
	"DELETE FROM project_cost_forecasts WHERE project_id = $1",
	"DELETE FROM project_commitments WHERE project_id = $1",
	"DELETE FROM project_budget_adjustments WHERE project_id = $1",
	"DELETE FROM project_expenses WHERE project_id = $1",
	"DELETE FROM project_budget_lines WHERE project_id = $1",
	"DELETE FROM project_budgets WHERE project_id = $1",
	"DELETE FROM project_wbs_nodes WHERE project_id = $1",
	"DELETE FROM project_contracts WHERE project_id = $1",
}

// ProjectPurgeTarget: silinecek proje adayı.
type ProjectPurgeTarget struct {
	ID               string
	OrganizationID   string
	OrganizationName string
	OrganizationSlug string
	ProjectNo        string
	Name             string
	OfferNo          string
	Status           string
	CreatedAt        time.Time
}

// TableCount: tablodaki satır sayısı.
type TableCount struct {
	Table string
	Rows  int64
}

var ErrProjectNotCancelled = errors.New("yalnızca iptal edilmiş proje kalıcı silinir; önce uygulamada projeyi iptal edin")

// FindProjectsForPurge: proje numarası, kaynak teklif numarası ya da tam
// proje adıyla eşleşen projeler (orgSlug verilirse yalnızca o firmada).
func FindProjectsForPurge(ctx context.Context, pool *pgxpool.Pool, identifier, orgSlug string) ([]ProjectPurgeTarget, error) {
	rows, err := pool.Query(ctx, `
		SELECT p.id::text, p.organization_id::text, o.name, o.slug, p.project_no, p.name, p.status,
		       COALESCE(f.offer_no, ''), p.created_at
		FROM projects p
		JOIN organizations o ON o.id = p.organization_id
		LEFT JOIN offers f ON f.id = p.source_offer_id
		WHERE (p.project_no = $1 OR f.offer_no = $1 OR p.name = $1) AND ($2 = '' OR o.slug = $2)
		ORDER BY o.name, p.created_at`, identifier, orgSlug)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ProjectPurgeTarget
	for rows.Next() {
		var t ProjectPurgeTarget
		if err := rows.Scan(&t.ID, &t.OrganizationID, &t.OrganizationName, &t.OrganizationSlug, &t.ProjectNo,
			&t.Name, &t.Status, &t.OfferNo, &t.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// CountProjectPurge: projeye bağlı tablolardaki satır sayıları (yalnızca
// sıfırdan büyükler).
func CountProjectPurge(ctx context.Context, pool *pgxpool.Pool, projectID string) ([]TableCount, error) {
	var out []TableCount
	for _, t := range projectPurgeTables {
		var n int64
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM "+t+" WHERE project_id = $1", projectID).Scan(&n); err != nil {
			return nil, fmt.Errorf("%s: %w", t, err)
		}
		if n > 0 {
			out = append(out, TableCount{Table: t, Rows: n})
		}
	}
	return out, nil
}

// PurgeCancelledProject: iptal edilmiş projeyi bütün kayıtlarıyla tek
// transaction'da siler; depodan silinecek dosya anahtarlarını döner
// (çağıran işlem bittikten sonra siler).
func PurgeCancelledProject(ctx context.Context, pool *pgxpool.Pool, projectID string) ([]string, error) {
	pid, err := repository.StringToUUID(projectID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	var orgID pgtype.UUID
	var projectNo, name, status string
	if err := tx.QueryRow(ctx, `SELECT organization_id, project_no, name, status FROM projects WHERE id = $1 FOR UPDATE`, pid).
		Scan(&orgID, &projectNo, &name, &status); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, err
	}
	if status != domain.ProjectStatusCancelled {
		return nil, ErrProjectNotCancelled
	}
	txq := sqlc.New(tx)
	keys, err := txq.ListProjectObjectKeys(ctx, pid)
	if err != nil {
		return nil, err
	}
	for _, stmt := range projectPurgeSteps {
		if _, err := tx.Exec(ctx, stmt, pid); err != nil {
			return nil, fmt.Errorf("%s: %w", stmt, err)
		}
	}
	tag, err := tx.Exec(ctx, "DELETE FROM projects WHERE id = $1 AND organization_id = $2", pid, orgID)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() != 1 {
		return nil, domain.ErrNotFound
	}
	if err := logOrgEvent(ctx, txq, orgID, domain.OrgEventProjectDeleted, pgtype.UUID{}, map[string]any{
		"project_id": pid.String(), "project_no": projectNo, "name": name, "purged": true,
	}); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return keys, nil
}
