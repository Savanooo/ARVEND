package service

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// Günlük stok uyarısı: her sabah 08:00'de (İstanbul) SKT'si geçen ya da
// yaklaşan parti veya minimum stoğun altına düşen malzeme olan firmalarda
// inventory.manage sahiplerine tek bir bildirim (Stok Takibi'ni açar).
// Aynı kişiye günde bir kez gider; sunucu gün içinde yeniden başlarsa
// tekrar göndermez.

const inventoryAlertHour = 8

// NextInventoryAlertRun: bir sonraki 08:00 (İstanbul).
func NextInventoryAlertRun(now time.Time) time.Time {
	t := now.In(istanbulLocation)
	next := time.Date(t.Year(), t.Month(), t.Day(), inventoryAlertHour, 0, 0, 0, istanbulLocation)
	if !next.After(t) {
		next = next.AddDate(0, 0, 1)
	}
	return next
}

// RunDailyAlerts: ctx iptal edilene kadar her sabah SendDailyAlerts.
func (s *InventoryService) RunDailyAlerts(ctx context.Context) {
	next := NextInventoryAlertRun(time.Now())
	for {
		wait := time.Until(next)
		if wait <= 0 {
			if n, err := s.SendDailyAlerts(ctx, time.Now()); err != nil {
				log.Printf("stok uyarısı: %v", err)
			} else if n > 0 {
				log.Printf("stok uyarısı: %d bildirim", n)
			}
			next = NextInventoryAlertRun(time.Now().Add(time.Minute))
			continue
		}
		timer := time.NewTimer(min(wait, schedulerMaxSleep))
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

// SendDailyAlerts: uyarısı olan her firmada, bugün henüz almamış
// inventory.manage sahiplerine bildirim yazar; yazılan sayıyı döner.
func (s *InventoryService) SendDailyAlerts(ctx context.Context, now time.Time) (int, error) {
	today := istanbulToday(now)
	rows, err := s.q.ListInventoryAlertCounts(ctx, repository.TimeToDate(today))
	if err != nil {
		return 0, err
	}
	local := now.In(istanbulLocation)
	dayStart := pgtype.Timestamptz{
		Time: time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, istanbulLocation), Valid: true,
	}
	sent := 0
	for _, r := range rows {
		if ctx.Err() != nil {
			return sent, ctx.Err()
		}
		var parts []string
		if r.ExpiredLotCount > 0 {
			parts = append(parts, fmt.Sprintf("%d partinin SKT'si geçti", r.ExpiredLotCount))
		}
		if r.ExpiringLotCount > 0 {
			parts = append(parts, fmt.Sprintf("%d partinin SKT'si yaklaşıyor", r.ExpiringLotCount))
		}
		if r.BelowMinCount > 0 {
			parts = append(parts, fmt.Sprintf("%d malzeme minimum stoğun altında", r.BelowMinCount))
		}
		holders, err := s.q.ListUsersWithPermission(ctx, sqlc.ListUsersWithPermissionParams{
			OrganizationID: r.OrganizationID, PermissionCode: domain.PermInventoryManage,
		})
		if err != nil {
			return sent, err
		}
		for _, h := range holders {
			already, err := s.q.InventoryAlertSentSince(ctx, sqlc.InventoryAlertSentSinceParams{
				OrganizationID: r.OrganizationID, UserID: h.ID, CreatedAt: dayStart,
			})
			if err != nil {
				return sent, err
			}
			if already {
				continue
			}
			if err := createNotification(ctx, s.q, CreateNotificationInput{
				OrganizationID: r.OrganizationID, UserID: h.ID, Type: domain.NotificationInventoryAlert,
				Title: "Stok uyarısı", Body: truncateRunes(joinNonEmpty(" · ", parts...), 500),
				EntityType: domain.NotificationEntityInventory, ActionTarget: "/diger/stok",
			}); err != nil {
				return sent, err
			}
			sent++
		}
	}
	return sent, nil
}
