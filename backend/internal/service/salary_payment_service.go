package service

import (
	"context"
	"errors"
	"math"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

var (
	ErrInvalidPeriod      = errors.New("geçersiz ay (YYYY-MM bekleniyor)")
	ErrInvalidPaymentType = errors.New("geçersiz ödeme türü")
	ErrAmountTooLarge     = errors.New("ödeme tutarı çok büyük -- yazım hatası olabilir")
	// ErrInvalidAmount ve ErrInvalidEmployee paket genelinde zaten tanımlı
	// (project_finance_service.go, project_operations_service.go) ve
	// mesajları birebir uyuyor -- yeniden tanımlanmaz.
)

// maxPaymentAmount, numeric(18,2) sığarken aynı zamanda bir yazım hatasını
// (fazladan sıfırlar) da yakalayacak üst sınır. Tek bir personel ödemesinin
// 100 milyon TL'yi geçmesi gerçekçi değil.
const maxPaymentAmount = 100_000_000

type SalaryPaymentService struct {
	q *sqlc.Queries
}

func NewSalaryPaymentService(q *sqlc.Queries) *SalaryPaymentService {
	return &SalaryPaymentService{q: q}
}

type SalaryPaymentInput struct {
	EmployeeID  string
	Period      string
	PaymentType string
	Amount      float64
	PaidDate    time.Time
	Description string
	CreatedBy   string // oturumdaki kullanıcı; boşsa NULL
}

func (s *SalaryPaymentService) ListByPeriod(ctx context.Context, organizationID, period string) ([]domain.SalaryPayment, error) {
	if !domain.ValidPeriod(period) {
		return nil, ErrInvalidPeriod
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.ListSalaryPaymentsByPeriod(ctx, sqlc.ListSalaryPaymentsByPeriodParams{
		OrganizationID: orgID,
		Period:         period,
	})
	if err != nil {
		return nil, err
	}
	out := make([]domain.SalaryPayment, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainSalaryPaymentRow(r)
	}
	return out, nil
}

func (s *SalaryPaymentService) Summary(ctx context.Context, organizationID, period string) ([]domain.PayrollSummaryRow, error) {
	if !domain.ValidPeriod(period) {
		return nil, ErrInvalidPeriod
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	rows, err := s.q.PayrollSummaryByPeriod(ctx, sqlc.PayrollSummaryByPeriodParams{
		OrganizationID: orgID,
		Period:         period,
	})
	if err != nil {
		return nil, err
	}
	// Devir zinciri önceki ayların TAMAMINA bakar (bkz. domain
	// PayrollSummaryRow.carryOverInto); her ay o ayda geçerli ücretle
	// hesaplanır (employee_wage_history). İkisi de firma başına tek sorgu.
	history, err := s.q.PayrollHistoryBefore(ctx, sqlc.PayrollHistoryBeforeParams{
		OrganizationID: orgID,
		Period:         period,
	})
	if err != nil {
		return nil, err
	}
	wages, err := s.q.ListEmployeeWageHistoryByOrganization(ctx, orgID)
	if err != nil {
		return nil, err
	}
	historyByEmp := make(map[string][]domain.PayrollMonth)
	for _, h := range history {
		id := h.EmployeeID.String()
		historyByEmp[id] = append(historyByEmp[id], repository.ToDomainPayrollMonth(h))
	}
	wagesByEmp := make(map[string][]domain.WageRate)
	for _, w := range wages {
		id := w.EmployeeID.String()
		wagesByEmp[id] = append(wagesByEmp[id], repository.ToDomainWageRate(w))
	}
	// "İçinde bulunulan ay" İstanbul takvimine göre: sunucu UTC'de çalışır,
	// ayın 1'inde 00:00-03:00 arası bir önceki ayı gösterirdi.
	currentPeriod := IstanbulNow(time.Now()).Format("2006-01")
	out := make([]domain.PayrollSummaryRow, len(rows))
	for i, r := range rows {
		out[i] = repository.ToDomainPayrollSummaryRow(r)
		out[i].History = historyByEmp[out[i].EmployeeID]
		out[i].Wages = wagesByEmp[out[i].EmployeeID]
		out[i].Calculate(period, currentPeriod)
	}
	return out, nil
}

func (s *SalaryPaymentService) Create(ctx context.Context, organizationID string, in SalaryPaymentInput) (*domain.SalaryPayment, error) {
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	if !domain.ValidPeriod(in.Period) {
		return nil, ErrInvalidPeriod
	}
	paymentType := strings.TrimSpace(in.PaymentType)
	if paymentType == "" {
		paymentType = domain.PaymentTypeMaas
	}
	if !domain.ValidPaymentType(paymentType) {
		return nil, ErrInvalidPaymentType
	}
	// NaN/Inf, "> 0" kontrolünü ve DB kısıtını farklı biçimlerde atlatır --
	// numeric'e çevrilmeden önce reddedilir.
	if math.IsNaN(in.Amount) || math.IsInf(in.Amount, 0) || in.Amount <= 0 {
		return nil, ErrInvalidAmount
	}
	if in.Amount > maxPaymentAmount {
		return nil, ErrAmountTooLarge
	}
	empID, err := repository.StringToUUID(in.EmployeeID)
	if err != nil {
		return nil, ErrInvalidEmployee
	}
	// Personelin bu organizasyona ait olduğu doğrulanmadan ödeme yazılırsa
	// başka firmanın employee_id'sine bağlı bir kayıt açılabilir ve
	// ListSalaryPaymentsByPeriod'daki JOIN o firmanın personel adını sızdırır
	// (AttendanceService.Create ile aynı gerekçe; DB tetikleyicisi de ayrıca
	// engelliyor).
	if _, err := s.q.GetEmployeeByID(ctx, sqlc.GetEmployeeByIDParams{ID: empID, OrganizationID: orgID}); err != nil {
		return nil, ErrInvalidEmployee
	}

	paidDate := in.PaidDate
	if paidDate.IsZero() {
		// Varsayılan "bugün" İstanbul takvimiyle (sunucu UTC'de).
		paidDate = istanbulToday(time.Now())
	}
	var createdBy pgtype.UUID
	if in.CreatedBy != "" {
		if u, err := repository.StringToUUID(in.CreatedBy); err == nil {
			createdBy = u
		}
	}

	row, err := s.q.CreateSalaryPayment(ctx, sqlc.CreateSalaryPaymentParams{
		OrganizationID: orgID,
		EmployeeID:     empID,
		Period:         in.Period,
		PaymentType:    paymentType,
		Amount:         repository.Float64ToNumeric(math.Round(in.Amount*100) / 100),
		PaidDate:       repository.TimeToDate(paidDate),
		Description:    strings.TrimSpace(in.Description),
		CreatedBy:      createdBy,
	})
	if err != nil {
		return nil, err
	}
	p := repository.ToDomainSalaryPayment(row)
	return &p, nil
}

func (s *SalaryPaymentService) Delete(ctx context.Context, id, organizationID string) error {
	uid, err := repository.StringToUUID(id)
	if err != nil {
		return domain.ErrNotFound
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return domain.ErrNotFound
	}
	rows, err := s.q.DeleteSalaryPayment(ctx, sqlc.DeleteSalaryPaymentParams{ID: uid, OrganizationID: orgID})
	if err != nil {
		return err
	}
	if rows == 0 {
		return domain.ErrNotFound
	}
	return nil
}
