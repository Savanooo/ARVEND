package service

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ErrPublicLinkUnavailable, kimlik doğrulamasız bir müşteri bağlantısının
// (teklif / ek iş paylaşım linki) iptal edilmemiş ve süresi dolmamış olsa
// bile artık kullanılamadığı durumdur: bağlantının ait olduğu firma askıya
// alınmış, iptal edilmiş ya da silinmiş, veya teklif pasife (arşive)
// alınmış. Müşteriye sebebi (firmanın hesap durumu gibi) söylenmez --
// yalnızca bağlantının artık geçerli olmadığı (410).
var ErrPublicLinkUnavailable = errors.New("bu paylaşım bağlantısı artık geçerli değil")

// publicLinkOrganization, public bir bağlantının sahibi olan firmayı okur
// ve firmanın hâlâ erişime açık olduğunu doğrular -- RequireAuth
// middleware'inin personel için uyguladığı kuralın (AllowsAccess +
// deleted_at) AYNISI. Eskiden public uçlar firma durumuna hiç bakmıyordu:
// askıya alınmış ya da silinmiş bir firmanın linkleri çalışmaya ve teklifler
// kabul edilmeye devam ediyordu.
//
// Dönen satır, public sayfada gösterilecek firma adını da taşır.
func publicLinkOrganization(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID) (sqlc.Organization, error) {
	org, err := q.GetOrganizationByID(ctx, orgID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return sqlc.Organization{}, domain.ErrNotFound
		}
		return sqlc.Organization{}, err
	}
	if !domain.OrgStatus(org.Status).AllowsAccess() || org.DeletedAt.Valid {
		return sqlc.Organization{}, ErrPublicLinkUnavailable
	}
	return org, nil
}
