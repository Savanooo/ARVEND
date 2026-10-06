package service

import (
	"context"
	"errors"
	"fmt"
	"sort"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Taşeron hakediş/değişiklik sınırları (2026-10 denetimi). Önceden hakediş
// sınırı YALNIZCA SOV kaleminin asıl tutarıydı: onaylı bir ek iş hiç
// hakedişe girilemiyor, onaylı bir eksiltme ise sınırı hiç düşürmüyordu
// (eksiltme sonrası güncel tutarın üzerinde sertifika verilebiliyordu);
// eksiltme onayı da sertifikalı/ödenmiş tutarın altına inebiliyordu.
//
// Değişiklik emri kalemleri bir SOV kalemine DEĞİL maliyet kodu/bütçe
// kalemine bağlıdır (subcontract_change_order_items'ta subcontract_item_id
// yok). Bu yüzden onaylı değişiklikler AYNI (maliyet kodu, bütçe kalemi)
// grubundaki SOV kalemlerine yansıtılır -- commitment senkronizasyonunun
// (currentSubcontractTargets) kullandığı gruplamanın AYNISI:
//
//   - kalem:    kümülatif <= kalem tutarı + grubun onaylı NET eki (pozitifse)
//   - grup:     gruptaki kalemlerin kümülatif toplamı <= grubun SOV toplamı
//     + grubun onaylı net değişikliği (ek +, eksiltme -)
//   - sözleşme: tüm kalemlerin kümülatif toplamı <= güncel sözleşme tutarı
//     (asıl + onaylı ekler - onaylı eksiltmeler; SOV'u olmayan bir maliyet
//     koduna yazılmış değişiklikler de burada sayılır)
//
// "Kümülatif", hakedişteki kalemler için hakedişin kendi kümülatifi, diğer
// kalemler için en son sertifikalı kümülatiftir.

var (
	ErrProgressClaimExceedsContract    = errors.New("kümülatif hakediş, onaylı ek iş/eksiltmelerle güncellenmiş sözleşme tutarını aşamaz")
	ErrSubcontractChangeBelowCertified = errors.New("değişiklik onaylanamaz: sözleşme tutarı sertifikalı hakediş veya ödenen tutarın altına düşer")
)

type subcontractClaimCaps struct {
	items        map[string]sqlc.SubcontractItem // SOV kalemi id -> satır
	groupOf      map[string]string               // SOV kalemi id -> grup anahtarı
	groupSOV     map[string]decimal.Decimal      // grup -> SOV asıl tutar toplamı
	groupChange  map[string]decimal.Decimal      // grup -> onaylı net değişiklik
	currentValue decimal.Decimal                 // güncel sözleşme tutarı
	certified    map[string]decimal.Decimal      // SOV kalemi id -> en son sertifikalı kümülatif
	currency     string
}

func capGroupKey(costCodeID, budgetLineID pgtype.UUID) string {
	return costCodeID.String() + "|" + uuidKeyPart(budgetLineID)
}

func loadSubcontractClaimCaps(ctx context.Context, txq *sqlc.Queries, orgID, pid pgtype.UUID, sc sqlc.ProjectSubcontract) (*subcontractClaimCaps, error) {
	rows, err := txq.ListSubcontractItems(ctx, sc.ID)
	if err != nil {
		return nil, err
	}
	changes, err := txq.ListApprovedSubcontractChangeItemTotalsByCostCode(ctx, sqlc.ListApprovedSubcontractChangeItemTotalsByCostCodeParams{
		SubcontractID: sc.ID, OrganizationID: orgID, ProjectID: pid,
	})
	if err != nil {
		return nil, err
	}
	certRows, err := txq.ListLatestCertifiedCumulativeBySubcontractItem(ctx, sqlc.ListLatestCertifiedCumulativeBySubcontractItemParams{
		SubcontractID: sc.ID, OrganizationID: orgID, ProjectID: pid,
	})
	if err != nil {
		return nil, err
	}
	c := &subcontractClaimCaps{
		items: map[string]sqlc.SubcontractItem{}, groupOf: map[string]string{},
		groupSOV: map[string]decimal.Decimal{}, groupChange: map[string]decimal.Decimal{},
		certified: map[string]decimal.Decimal{}, currency: sc.Currency,
	}
	for _, r := range rows {
		id, k := r.ID.String(), capGroupKey(r.CostCodeID, r.BudgetLineID)
		amount := repository.NumericToDecimal(r.OriginalAmount)
		c.items[id] = r
		c.groupOf[id] = k
		c.groupSOV[k] = c.groupSOV[k].Add(amount)
		c.currentValue = c.currentValue.Add(amount)
	}
	for _, ch := range changes {
		k, net := capGroupKey(ch.CostCodeID, ch.BudgetLineID), repository.NumericToDecimal(ch.Total)
		c.groupChange[k] = c.groupChange[k].Add(net)
		c.currentValue = c.currentValue.Add(net)
	}
	for _, cr := range certRows {
		c.certified[cr.SubcontractItemID.String()] = repository.NumericToDecimal(cr.Cumulative)
	}
	return c, nil
}

// itemCap, tek bir SOV kaleminin ulaşabileceği en yüksek kümülatiftir
// (hakediş kaleminin scheduled_value SNAPSHOT'ı). Grubun onaylı net eki
// kaleme eklenir; eksiltme burada DEĞİL grup/sözleşme kontrolünde düşülür
// (grupta birden fazla kalem varsa eksiltmenin hangisinden düşeceği belli
// değildir).
func (c *subcontractClaimCaps) itemCap(itemID string) decimal.Decimal {
	add := c.groupChange[c.groupOf[itemID]]
	if add.Sign() < 0 {
		add = decimal.Zero
	}
	return repository.NumericToDecimal(c.items[itemID].OriginalAmount).Add(add)
}

// capViolation, aşılan ilk grup/sözleşme sınırıdır.
type capViolation struct {
	group      bool
	limit      decimal.Decimal
	cumulative decimal.Decimal
}

// firstViolation, claimCumulative (hakedişteki kalemler -> kümülatif; nil
// ise yalnızca sertifikalı durum) uygulanmış haliyle YALNIZCA groups'taki
// grupların ve sözleşme toplamının sınırını kontrol eder -- işlemin
// dokunmadığı bir grupta eskiden kalma bir aşım, ilgisiz bir hakedişi ya
// da değişikliği kilitlemesin. Gruplar sabit sırayla gezilir: aynı veride
// her zaman aynı hata.
func (c *subcontractClaimCaps) firstViolation(claimCumulative map[string]decimal.Decimal, groups map[string]bool) *capViolation {
	groupCum := map[string]decimal.Decimal{}
	total := decimal.Zero
	for id := range c.items {
		cum, ok := claimCumulative[id]
		if !ok {
			cum = c.certified[id]
		}
		groupCum[c.groupOf[id]] = groupCum[c.groupOf[id]].Add(cum)
		total = total.Add(cum)
	}
	keys := make([]string, 0, len(groups))
	for k := range groups {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		limit := c.groupSOV[k].Add(c.groupChange[k])
		if groupCum[k].Cmp(limit) > 0 {
			return &capViolation{group: true, limit: limit, cumulative: groupCum[k]}
		}
	}
	if total.Cmp(c.currentValue) > 0 {
		return &capViolation{limit: c.currentValue, cumulative: total}
	}
	return nil
}

// checkClaim, hakedişin (kalemlerinin grupları + sözleşme toplamı)
// sınırlarını aşmadığını doğrular.
func (c *subcontractClaimCaps) checkClaim(claimCumulative map[string]decimal.Decimal) error {
	groups := map[string]bool{}
	for id := range claimCumulative {
		groups[c.groupOf[id]] = true
	}
	v := c.firstViolation(claimCumulative, groups)
	if v == nil {
		return nil
	}
	scope := "güncel sözleşme tutarı"
	if v.group {
		scope = "aynı maliyet kodundaki kalemlerin güncel tutarı"
	}
	return fmt.Errorf("%w: kümülatif %s, %s %s", ErrProgressClaimExceedsContract,
		formatMoneyCur(v.cumulative, c.currency), scope, formatMoneyCur(v.limit, c.currency))
}

// checkDeductionApproval, bir EKSİLTME onaylandıktan sonraki durumda
// (c, bu eksiltme dahil onaylı değişikliklerle yüklenmiş olmalı)
// eksiltmenin dokunduğu grupların ve sözleşmenin sertifikalı tutarın,
// sözleşmenin de ödenen tutarın altına düşmediğini doğrular. Ek iş yalnızca
// sınırları yükseltir, kontrol gerektirmez.
func (c *subcontractClaimCaps) checkDeductionApproval(paid decimal.Decimal, touchedGroups map[string]bool) error {
	if c.currentValue.Sign() < 0 {
		return fmt.Errorf("%w: eksiltme sonrası sözleşmenin yeni tutarı %s olur (sıfırın altında)", ErrSubcontractChangeBelowCertified,
			formatMoneyCur(c.currentValue, c.currency))
	}
	if v := c.firstViolation(nil, touchedGroups); v != nil {
		scope := "sözleşmenin yeni tutarı"
		if v.group {
			scope = "bu maliyet kodundaki kalemlerin yeni tutarı"
		}
		return fmt.Errorf("%w: %s %s olur, ama sertifikalı hakediş %s", ErrSubcontractChangeBelowCertified,
			scope, formatMoneyCur(v.limit, c.currency), formatMoneyCur(v.cumulative, c.currency))
	}
	if paid.Cmp(c.currentValue) > 0 {
		return fmt.Errorf("%w: sözleşmenin yeni tutarı %s olur, ama ödenen %s", ErrSubcontractChangeBelowCertified,
			formatMoneyCur(c.currentValue, c.currency), formatMoneyCur(paid, c.currency))
	}
	return nil
}
