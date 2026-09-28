package service

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// DashboardService, ana sayfa özetini (GET /api/v1/dashboard) üretir --
// web ve mobilin TEK veri kaynağı (spec D1).
//
// Akış: tek bir RepeatableRead + ReadOnly transaction (bütün bölümler aynı
// anlık görüntüden), her bölüm kendi SAVEPOINT'inde -- bir bölümün hatası
// yalnızca o bölümü düşürür (section_errors), diğerleri etkilenmez.
// Yetkisi olmayan bölüm HİÇ çalıştırılmaz (hesaplanıp atılmaz). Görünürlük
// kararı tamamen sunucudadır (spec D2).
type DashboardService struct {
	pool *pgxpool.Pool
	q    *sqlc.Queries

	failMu       sync.RWMutex
	failSections map[string]bool
}

func NewDashboardService(pool *pgxpool.Pool, q *sqlc.Queries) *DashboardService {
	return &DashboardService{pool: pool, q: q}
}

// FailSection YALNIZCA testler içindir: verilen bölümlerin oluşturucusu
// kendi savepoint'inde bir veritabanı hatası üretir (section_errors ve
// bölüm yalıtımı testleri). Argümansız çağrı zorlamayı temizler. HTTP'den
// erişilebilen hiçbir yolu yoktur.
func (s *DashboardService) FailSection(keys ...string) {
	s.failMu.Lock()
	defer s.failMu.Unlock()
	s.failSections = make(map[string]bool, len(keys))
	for _, k := range keys {
		s.failSections[k] = true
	}
}

func (s *DashboardService) shouldFail(key string) bool {
	s.failMu.RLock()
	defer s.failMu.RUnlock()
	return s.failSections[key]
}

// DashboardInput: CoarseRole middleware.RoleFromContext'ten (users.role),
// Authz middleware.AuthzContextFromRequest'ten gelir. Now enjekte edilen
// saattir (testlerde sabit; sıfırsa time.Now()).
type DashboardInput struct {
	OrganizationID string
	UserID         string
	CoarseRole     domain.Role
	Authz          *AuthzContext
	Now            time.Time
}

// dashRun, TEK bir isteğin bölüm oluşturucularına verilen bağlamdır.
type dashRun struct {
	q           *sqlc.Queries
	clk         DashboardClock
	authz       *AuthzContext
	coarseAdmin bool
	orgID       pgtype.UUID
	userID      pgtype.UUID
	restrict    pgtype.UUID // NULL = tüm projeler (owner/admin/legacy_user)
	primary     string
	memo        *dashMemo // bölümler arası paylaşılan sonuçlar (runSection kopyaları aynı işaretçiyi taşır)
}

// dashMemo: aynı istekte birden çok bölümün AYNI parametrelerle çalıştırdığı
// sorguların sonuçları (bütçe aşımı: projects + cost_control; sözleşmesiz
// aktif projeler: projects + contracts). İşlem salt-okur RepeatableRead
// olduğundan bir bölümün savepoint'inde okunan satırlar -- o savepoint
// sonradan geri alınsa bile -- sonraki bölümler için de aynı anlık
// görüntüdür. Hata sonuçları saklanmaz: sonraki bölüm sorguyu yeniden dener.
type dashMemo struct {
	overBudget   []sqlc.DashboardProjectsOverBudgetRow
	overBudgetOK bool
	withoutCtr   []sqlc.DashboardActiveProjectsWithoutContractRow
	withoutCtrOK bool
}

func (r *dashRun) projectsOverBudget(ctx context.Context) ([]sqlc.DashboardProjectsOverBudgetRow, error) {
	if r.memo != nil && r.memo.overBudgetOK {
		return r.memo.overBudget, nil
	}
	rows, err := r.q.DashboardProjectsOverBudget(ctx, sqlc.DashboardProjectsOverBudgetParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict,
	})
	if err != nil {
		return nil, err
	}
	if r.memo != nil {
		r.memo.overBudget, r.memo.overBudgetOK = rows, true
	}
	return rows, nil
}

func (r *dashRun) projectsWithoutContract(ctx context.Context) ([]sqlc.DashboardActiveProjectsWithoutContractRow, error) {
	if r.memo != nil && r.memo.withoutCtrOK {
		return r.memo.withoutCtr, nil
	}
	rows, err := r.q.DashboardActiveProjectsWithoutContract(ctx, sqlc.DashboardActiveProjectsWithoutContractParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict,
	})
	if err != nil {
		return nil, err
	}
	if r.memo != nil {
		r.memo.withoutCtr, r.memo.withoutCtrOK = rows, true
	}
	return rows, nil
}

func (r *dashRun) can(code string) bool { return r.authz.HasPermission(code) }

// wantsAttention: kod bu izleyicide gündemde görünecek mi (görünür VE ya
// aksiyon alabiliyor ya da "takipte" şeridine düşüyor)? Görünmeyecek bir
// kodun kayıt sorguları hiç çalıştırılmaz.
func (r *dashRun) wantsAttention(code string) bool {
	_, ok := attentionLane(code, r.can)
	return ok
}

func (r *dashRun) date(t time.Time) pgtype.Date {
	y, m, d := t.Date()
	return pgtype.Date{Time: time.Date(y, m, d, 0, 0, 0, 0, time.UTC), Valid: true}
}

func (r *dashRun) ts(t time.Time) pgtype.Timestamptz { return pgTimestamptz(t) }

// daysSince: tarih kolonundan (ya da SQL'de İstanbul gününe çevrilmiş bir
// andan) bugüne geçen gün; tarih yoksa nil.
func (r *dashRun) daysSince(d pgtype.Date) *int {
	if !d.Valid {
		return nil
	}
	v := r.clk.DaysSince(d.Time)
	return &v
}

// sectionPayload: bir oluşturucunun başarıyla ürettiği sonuç. Gündem
// kayıtları yalnızca bölüm başarılıysa birleştirilir.
type sectionPayload struct {
	apply    func(*domain.DashboardSections)
	groups   []DashboardAttentionInput
	upcoming []domain.UpcomingItem
}

type dashSection struct {
	key   string
	gate  func(r *dashRun) bool
	build func(ctx context.Context, r *dashRun) (*sectionPayload, error)
}

// dashboardRegistry: bölüm kapıları (spec §4.5) ve oluşturucular, çalışma
// sırasıyla. Kapı etkin izin kümesine bakar -- kişiye özel ekleme/çıkarma
// bölüm kümesini değiştirir.
var dashboardRegistry = []dashSection{
	{domain.DashSectionProjects, func(r *dashRun) bool { return r.can(domain.PermProjectsRead) }, buildDashProjects},
	{domain.DashSectionFinance, func(r *dashRun) bool { return r.can(domain.PermProjectsFinanceRead) }, buildDashFinance},
	{domain.DashSectionChangeOrders, func(r *dashRun) bool { return r.can(domain.PermProjectsFinanceRead) }, buildDashChangeOrders},
	{domain.DashSectionOffers, func(r *dashRun) bool { return r.can(domain.PermOffersRead) }, buildDashOffers},
	{domain.DashSectionProcurement, func(r *dashRun) bool { return r.can(domain.PermProjectsProcurementRead) }, buildDashProcurement},
	{domain.DashSectionSubcontracts, func(r *dashRun) bool { return r.can(domain.PermProjectsSubcontractsRead) }, buildDashSubcontracts},
	{domain.DashSectionCostControl, func(r *dashRun) bool {
		return r.can(domain.PermProjectsBudgetRead) || r.can(domain.PermProjectsCostControlRead)
	}, buildDashCostControl},
	{domain.DashSectionContracts, func(r *dashRun) bool { return r.can(domain.PermProjectsContractsRead) }, buildDashContracts},
	{domain.DashSectionTasks, func(r *dashRun) bool { return r.can(domain.PermProjectsTasksRead) }, buildDashTasks},
	{domain.DashSectionOperations, func(r *dashRun) bool { return r.can(domain.PermProjectsOperationsRead) }, buildDashOperations},
	{domain.DashSectionAttendance, func(r *dashRun) bool { return r.can(domain.PermAttendanceRead) }, buildDashAttendance},
	{domain.DashSectionEmployees, func(r *dashRun) bool { return r.can(domain.PermEmployeesRead) }, buildDashEmployees},
	{domain.DashSectionCustomers, func(r *dashRun) bool { return r.can(domain.PermCustomersRead) }, buildDashCustomers},
	{domain.DashSectionProducts, func(r *dashRun) bool { return r.can(domain.PermProductsRead) }, buildDashProducts},
	{domain.DashSectionCalculations, func(r *dashRun) bool { return r.can(domain.PermCalculationsRead) }, buildDashCalculations},
	{domain.DashSectionSuppliers, func(r *dashRun) bool { return r.can(domain.PermOrganizationSuppliersRead) }, buildDashSuppliers},
	{domain.DashSectionCostCodes, func(r *dashRun) bool { return r.can(domain.PermOrganizationCostCodesRead) }, buildDashCostCodes},
	// Ekip: /users uçlarıyla AYNI iki kapı -- kaba rol admin VE
	// organization.users.read (izin tek başına kişiye özel eklenemez, bkz.
	// domain.IsAdminRoleOnlyPermission).
	{domain.DashSectionUsers, func(r *dashRun) bool {
		return r.coarseAdmin && r.can(domain.PermOrganizationUsersRead)
	}, buildDashUsers},
	{domain.DashSectionNotifications, func(r *dashRun) bool { return r.can(domain.PermNotificationsRead) }, buildDashNotifications},
	// Son hareketler her zaman değerlendirilir; satırlar olay->izin
	// haritasıyla süzülür (spec §4.9).
	{domain.DashSectionActivity, func(r *dashRun) bool { return true }, buildDashActivity},
}

var errDashboardNoAuthz = errors.New("dashboard: yetkilendirme bağlamı yok")

// DashboardSectionKeysFor, verilen izleyicinin bölüm kapılarından geçen
// anahtarları (çalışma sırasıyla) döner -- Get'in çalıştıracağı kümenin
// AYNISI (sözleşme/güvenlik testleri ve belgeleme için).
func DashboardSectionKeysFor(authz *AuthzContext, coarseRole domain.Role) []string {
	run := &dashRun{authz: authz, coarseAdmin: coarseRole == domain.RoleAdmin}
	var out []string
	for _, sec := range dashboardRegistry {
		if sec.gate(run) {
			out = append(out, sec.key)
		}
	}
	return out
}

// Get, izleyicinin ana sayfa özetini üretir. Yalnızca işlem/meta
// sorgularının hatası döner (-> 500); bölüm hataları section_errors'a
// yazılır.
func (s *DashboardService) Get(ctx context.Context, in DashboardInput) (*domain.Dashboard, error) {
	if in.Authz == nil {
		return nil, errDashboardNoAuthz
	}
	orgID, err := repository.StringToUUID(in.OrganizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	userID, err := repository.StringToUUID(in.UserID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	now := in.Now
	if now.IsZero() {
		now = time.Now()
	}
	clk := NewDashboardClock(now)

	// project_handler.go List ile BİREBİR aynı kural: owner/admin/
	// legacy_user tüm projeleri görür, diğerleri yalnızca üyesi olduklarını.
	var restrict pgtype.UUID
	if !in.Authz.BypassesProjectMembership() {
		restrict = userID
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // commit sonrası no-op
	if _, err := tx.Exec(ctx, "SET LOCAL statement_timeout = '5s'"); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, "SET LOCAL TIME ZONE 'Europe/Istanbul'"); err != nil {
		return nil, err
	}
	q := s.q.WithTx(tx)

	run := &dashRun{
		q: q, clk: clk, authz: in.Authz, coarseAdmin: in.CoarseRole == domain.RoleAdmin,
		orgID: orgID, userID: userID, restrict: restrict, memo: &dashMemo{},
	}

	// --- meta: savepoint DIŞINDA; hata = 500 ---
	primary, err := q.DashboardPrimaryCurrency(ctx, orgID)
	if err != nil {
		return nil, err
	}
	run.primary = primary
	accessible, err := q.DashboardAccessibleProjectCount(ctx, sqlc.DashboardAccessibleProjectCountParams{
		OrgID: orgID, RestrictToUserID: restrict,
	})
	if err != nil {
		return nil, err
	}
	var onboarding *domain.DashboardOnboarding
	if run.coarseAdmin {
		counts, err := q.DashboardOnboardingCounts(ctx, orgID)
		if err != nil {
			return nil, err
		}
		onboarding = buildDashOnboarding(counts, run.can)
	}

	out := &domain.Dashboard{
		GeneratedAt:     clk.Now.Format(time.RFC3339),
		Today:           isoDate(clk.Today),
		Timezone:        "Europe/Istanbul",
		IsWorkday:       clk.IsWorkday,
		Period:          domain.DashboardPeriod{MonthStart: isoDate(clk.MonthStart), NextMonthStart: isoDate(clk.NextMonthStart), UpcomingEnd: isoDate(clk.Plus13)},
		PrimaryCurrency: primary,
		Viewer: domain.DashboardViewer{
			UserID: in.UserID, OrganizationRoleCode: in.Authz.RoleCode, IsAdmin: run.coarseAdmin,
			AllProjects: in.Authz.BypassesProjectMembership(), AccessibleProjectCount: int(accessible),
		},
		Onboarding:    onboarding,
		SectionErrors: map[string]string{},
	}

	// --- bölümler: her biri kendi savepoint'inde ---
	var groups []DashboardAttentionInput
	var upcoming []domain.UpcomingItem
	for _, sec := range dashboardRegistry {
		if !sec.gate(run) {
			continue
		}
		payload, err := s.runSection(ctx, tx, run, sec)
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			log.Printf("dashboard: %q bölümü hesaplanamadı (org %s): %v", sec.key, in.OrganizationID, err)
			out.SectionErrors[sec.key] = domain.DashSectionFailed
			continue
		}
		payload.apply(&out.Sections)
		groups = append(groups, payload.groups...)
		upcoming = append(upcoming, payload.upcoming...)
	}

	out.Agenda = BuildDashboardAgenda(groups, upcoming, in.Authz.HasPermission, primary)

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return out, nil
}

// runSection, bölüm oluşturucusunu bir SAVEPOINT içinde çalıştırır; hata
// olursa savepoint'e geri dönülür (işlem kullanılabilir kalır).
func (s *DashboardService) runSection(ctx context.Context, tx pgx.Tx, run *dashRun, sec dashSection) (*sectionPayload, error) {
	sp, err := tx.Begin(ctx)
	if err != nil {
		return nil, err
	}
	scoped := *run
	scoped.q = s.q.WithTx(sp)

	var payload *sectionPayload
	if s.shouldFail(sec.key) {
		// Gerçek bir veritabanı hatası üretilir: işlem "aborted" durumuna
		// düşer ve savepoint'e dönüşün sonraki bölümleri kurtardığı da
		// sınanmış olur.
		_, err = sp.Exec(ctx, "SELECT 1/0")
		if err == nil {
			err = errors.New("dashboard: zorlanmış bölüm hatası")
		}
	} else {
		payload, err = sec.build(ctx, &scoped)
	}
	if err != nil {
		if rbErr := sp.Rollback(ctx); rbErr != nil {
			return nil, fmt.Errorf("%w (savepoint geri alınamadı: %v)", err, rbErr)
		}
		return nil, err
	}
	if err := sp.Commit(ctx); err != nil {
		return nil, err
	}
	return payload, nil
}

// ---------- kurulum (onboarding) ----------

// buildDashOnboarding: yalnızca kaba admin çağırır; firma 0 proje VE 0
// aktif teklifteyse adımlar, aksi hâlde nil (spec §3.6).
//
// Adımın sayılı ayrıntısı ("628 ürün") yalnızca izleyici o modülün okuma
// iznine sahipse doldurulur: owner dışındaki kaba admin'in okuma izinleri
// kişiye özel geri alınabilir ve o zaman ilgili bölüm de dönmez (spec D2);
// rehber, ilgili uçların 403 ile reddedeceği sayıyı sızdırmamalı.
func buildDashOnboarding(c sqlc.DashboardOnboardingCountsRow, can func(string) bool) *domain.DashboardOnboarding {
	if c.Projects > 0 || c.ActiveOffers > 0 {
		return nil
	}
	step := func(key string, n int32, done bool, noun, readPerm string) domain.DashboardOnboardingStep {
		st := domain.DashboardOnboardingStep{Key: key, Done: done}
		if done && can(readPerm) {
			d := formatCountTR(int(n)) + " " + noun
			st.Detail = &d
		}
		return st
	}
	steps := []domain.DashboardOnboardingStep{
		step(domain.OnboardingStepCustomer, c.ActiveCustomers, c.ActiveCustomers > 0, "müşteri", domain.PermCustomersRead),
		step(domain.OnboardingStepCatalog, c.Products, c.Products > 0, "ürün", domain.PermProductsRead),
		step(domain.OnboardingStepEmployee, c.ActiveEmployees, c.ActiveEmployees > 0, "personel", domain.PermEmployeesRead),
		step(domain.OnboardingStepTeam, c.ActiveUsers, c.ActiveUsers > 1, "kullanıcı", domain.PermOrganizationUsersRead),
		step(domain.OnboardingStepFirstOffer, c.ActiveOffers, c.ActiveOffers > 0, "teklif", domain.PermOffersRead),
		step(domain.OnboardingStepConvert, c.Projects, c.Projects > 0, "proje", domain.PermProjectsRead),
	}
	done := 0
	for _, st := range steps {
		if st.Done {
			done++
		}
	}
	return &domain.DashboardOnboarding{Steps: steps, DoneCount: done, Total: len(steps)}
}

// formatCountTR: Türkçe binlik ayraçlı tam sayı ("4.393").
func formatCountTR(n int) string {
	s := strconv.Itoa(n)
	neg := strings.HasPrefix(s, "-")
	if neg {
		s = s[1:]
	}
	var b strings.Builder
	for i, ch := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte('.')
		}
		b.WriteRune(ch)
	}
	if neg {
		return "-" + b.String()
	}
	return b.String()
}

// ---------- proje seçici ----------

// ProjectOptions, hızlı işlem proje seçicisinin (GET /dashboard/project-
// options) satırlarıdır: açık projeler, üyelik kapsamlı, ada göre, en fazla
// 50; HİÇBİR para alanı yok.
func (s *DashboardService) ProjectOptions(ctx context.Context, organizationID string, authz *AuthzContext, search string) ([]domain.DashboardProjectOption, error) {
	if authz == nil {
		return nil, errDashboardNoAuthz
	}
	orgID, err := repository.StringToUUID(organizationID)
	if err != nil {
		return nil, domain.ErrNotFound
	}
	var restrict pgtype.UUID
	if !authz.BypassesProjectMembership() {
		if restrict, err = repository.StringToUUID(authz.UserID); err != nil {
			return nil, domain.ErrNotFound
		}
	}
	rows, err := s.q.DashboardProjectOptions(ctx, sqlc.DashboardProjectOptionsParams{
		OrgID: orgID, RestrictToUserID: restrict, Search: strings.TrimSpace(search),
	})
	if err != nil {
		return nil, err
	}
	out := make([]domain.DashboardProjectOption, len(rows))
	for i, p := range rows {
		out[i] = domain.DashboardProjectOption{
			ID: p.ID.String(), ProjectNo: p.ProjectNo, Name: p.Name,
			CustomerName: p.CustomerName, Currency: p.Currency, Status: p.Status,
		}
	}
	return out, nil
}

// ---------- küçük dönüştürücüler ----------

func dashMoney(n pgtype.Numeric) float64 { return repository.NumericToFloat64(n) }

func dashDec(n pgtype.Numeric) decimal.Decimal { return repository.NumericToDecimal(n) }

// dashPct: NULL -> nil; değer 1 ondalığa yuvarlanır.
func dashPct(n pgtype.Numeric) *float64 {
	if !n.Valid {
		return nil
	}
	v := repository.NumericToDecimal(n).Round(1).InexactFloat64()
	return &v
}

func dashDateStr(d pgtype.Date) *string {
	if !d.Valid {
		return nil
	}
	s := isoDate(d.Time)
	return &s
}

func dashTimestamp(t pgtype.Timestamptz) *string {
	if !t.Valid {
		return nil
	}
	s := t.Time.In(istanbulLocation).Format(time.RFC3339)
	return &s
}

func dashStr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func dashInt(v int) *int { return &v }

func dashRef(kind string, id pgtype.UUID, projectID pgtype.UUID, parentID pgtype.UUID, action string) domain.DashboardRef {
	ref := domain.DashboardRef{Kind: kind, ID: id.String(), Action: action}
	if projectID.Valid {
		p := projectID.String()
		ref.ProjectID = &p
	}
	if parentID.Valid {
		p := parentID.String()
		ref.ParentID = &p
	}
	return ref
}

// dashProjectRef: proje düzeyi bağlantılar (project/project_finance/
// project_cost/project_operations) -- id = project_id.
func dashProjectRef(kind string, projectID pgtype.UUID) domain.DashboardRef {
	return dashRef(kind, projectID, projectID, pgtype.UUID{}, domain.RefActionOpen)
}

func dashMoneyPtr(currency string, n pgtype.Numeric) *domain.MoneyAmount {
	return &domain.MoneyAmount{Currency: currency, Amount: dashMoney(n)}
}

// dashJoin: " · " ile boş olmayan parçaları birleştirir (başlık/etiket).
func dashJoin(parts ...string) string {
	kept := parts[:0:0]
	for _, p := range parts {
		if strings.TrimSpace(p) != "" {
			kept = append(kept, p)
		}
	}
	return strings.Join(kept, " · ")
}

// minDate: geçerli tarihlerin en eskisi.
func minDate(ds ...pgtype.Date) pgtype.Date {
	var out pgtype.Date
	for _, d := range ds {
		if d.Valid && (!out.Valid || d.Time.Before(out.Time)) {
			out = d
		}
	}
	return out
}

// currencySums: para birimi başına tutar biriktirir (numeric/decimal).
type currencySums struct {
	order []string
	sums  map[string]decimal.Decimal
}

func newCurrencySums() *currencySums { return &currencySums{sums: map[string]decimal.Decimal{}} }

func (c *currencySums) add(currency string, v decimal.Decimal) {
	if _, ok := c.sums[currency]; !ok {
		c.order = append(c.order, currency)
		c.sums[currency] = decimal.Zero
	}
	c.sums[currency] = c.sums[currency].Add(v)
}

// amounts: []MoneyAmount (asla nil), birincil para birimi önce, sonra tutar
// azalan (spec D13).
func (c *currencySums) amounts(primary string) []domain.MoneyAmount {
	out := make([]domain.MoneyAmount, 0, len(c.order))
	for _, cur := range c.order {
		out = append(out, domain.MoneyAmount{Currency: cur, Amount: c.sums[cur].Round(2).InexactFloat64()})
	}
	sortByCurrency(out, primary, func(m domain.MoneyAmount) (string, float64) { return m.Currency, m.Amount })
	return out
}
