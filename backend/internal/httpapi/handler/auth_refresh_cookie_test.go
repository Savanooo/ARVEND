package handler

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

// Refresh cookie'leri yalnızca oturum gerçekten bittiğinde silmeli; geçici
// bir sunucu hatası (500) tüm sekmeleri oturumdan düşürmemeli.
func TestIsSessionEndingError(t *testing.T) {
	for _, err := range []error{
		domain.ErrInvalidToken, domain.ErrInactiveUser, domain.ErrOrganizationSuspended,
		fmt.Errorf("sarılmış: %w", domain.ErrInvalidToken),
	} {
		if !isSessionEndingError(err) {
			t.Errorf("%v oturumu bitirmeli", err)
		}
	}
	for _, err := range []error{errors.New("bağlantı koptu"), context.DeadlineExceeded} {
		if isSessionEndingError(err) {
			t.Errorf("%v geçici bir hata; cookie silinmemeli", err)
		}
	}
}
