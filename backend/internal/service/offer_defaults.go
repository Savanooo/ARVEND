package service

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// OfferDefaults, firmanın teklif varsayılanlarını (onboarding "Teklif"
// adımında kaydedilen organization_commercial_settings) döner. Satır yoksa
// (firma ayar kaydetmemiş) %20 / TRY / süresiz. Eskiden onboarding bu
// değerleri kaydediyor ama hiçbir teklif okumuyordu: KDV %20, para birimi
// TRY sabit yazılıyordu.
func (s *OfferService) OfferDefaults(ctx context.Context, organizationID string) (*domain.OfferDefaults, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	return loadOfferDefaults(ctx, s.q, orgID)
}

func loadOfferDefaults(ctx context.Context, q *sqlc.Queries, orgID pgtype.UUID) (*domain.OfferDefaults, error) {
	out := &domain.OfferDefaults{VATRate: domain.DefaultOfferVATRate, Currency: domain.DefaultOfferCurrency}
	row, err := q.GetOrganizationCommercialSettings(ctx, orgID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return out, nil
		}
		return nil, err
	}
	// Onboarding KDV'yi doğrulamıyor: aralık dışı bir değer her yeni teklifi
	// "KDV oranı 0 ile 100 arasında olmalıdır" ile reddettirirdi.
	if vat := repository.NumericToFloat64(row.DefaultVatRate); vat >= 0 && vat <= 100 {
		out.VATRate = vat
	}
	if c, ok := domain.NormalizeCurrency(row.DefaultCurrency); ok {
		out.Currency = c
	}
	if row.OfferValidityDays > 0 {
		days := int(row.OfferValidityDays)
		out.ValidityDays = &days
	}
	out.PaymentTerms = row.DefaultPaymentTerms
	out.DeliveryTerms = row.DefaultDeliveryTerms
	out.Footer = row.DefaultOfferFooter
	return out, nil
}

// istanbulDay, verilen anın İstanbul takvim gününü UTC gece yarısı olarak
// döner (offer_date ile aynı gün: DB oturumu da İstanbul diliminde).
func istanbulDay(now time.Time) time.Time {
	y, m, d := IstanbulNow(now).Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}
