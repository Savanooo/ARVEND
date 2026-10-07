package service

// Ana sayfa bölüm oluşturucuları (spec §2, §4.5). Her biri yalnızca kendi
// kapısı geçtiğinde, kendi savepoint'inde çalışır; bölüm İÇİNDEKİ izne
// bağlı alt bloklar (ör. taşeron ödemeleri) ayrı sorgulardır ve izin
// yoksa HİÇ çalıştırılmaz (null döner). Kayıt (ilk 3) sorguları yalnızca
// grup bu izleyicinin gündeminde görünecekse ve sayı > 0 ise çalışır.

import (
	"context"
	"slices"
	"sort"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/shopspring/decimal"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ============================================================ projects

func buildDashProjects(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	today := r.date(r.clk.Today)
	c, err := r.q.DashboardProjectCounts(ctx, sqlc.DashboardProjectCountsParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today, Plus29: r.date(r.clk.Plus29),
	})
	if err != nil {
		return nil, err
	}
	open, err := r.q.DashboardOpenProjects(ctx, sqlc.DashboardOpenProjectsParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today,
	})
	if err != nil {
		return nil, err
	}

	// Satır blokları ayrı sorgular, yalnızca izin varsa (bayrak sızıntısı
	// kuralı: bayrak ancak geldiği bloğun okuma izniyle üretilir).
	tasksRead := r.can(domain.PermProjectsTasksRead)
	financeRead := r.can(domain.PermProjectsFinanceRead)
	costRead := r.can(domain.PermProjectsCostControlRead)
	contractsRead := r.can(domain.PermProjectsContractsRead)

	taskStats := map[string]sqlc.DashboardProjectTaskStatsRow{}
	if tasksRead {
		rows, err := r.q.DashboardProjectTaskStats(ctx, sqlc.DashboardProjectTaskStatsParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today,
		})
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			taskStats[row.ProjectID.String()] = row
		}
	}
	finStats := map[string]sqlc.DashboardProjectFinanceStatsRow{}
	if financeRead {
		rows, err := r.q.DashboardProjectFinanceStats(ctx, sqlc.DashboardProjectFinanceStatsParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today,
		})
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			finStats[row.ProjectID.String()] = row
		}
	}
	overBudget := map[string]bool{}
	if costRead {
		rows, err := r.projectsOverBudget(ctx)
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			overBudget[row.ProjectID.String()] = true
		}
	}
	noContract := map[string]bool{}
	if contractsRead {
		rows, err := r.projectsWithoutContract(ctx)
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			noContract[row.ID.String()] = true
		}
	}

	type rankedRow struct {
		row  domain.DashProjectRow
		tier int
		end  pgtype.Date
	}
	ranked := make([]rankedRow, 0, len(open))
	payload := &sectionPayload{}
	var pastEnd []domain.AttentionRecord
	for _, p := range open {
		id := p.ID.String()
		row := domain.DashProjectRow{
			Ref:       dashProjectRef(domain.RefKindProject, p.ID),
			ProjectNo: p.ProjectNo, Name: p.Name, Status: p.Status, CustomerName: p.CustomerName,
			StartDate: dashDateStr(p.StartDate), EndDate: dashDateStr(p.EndDate),
			TimeProgressPct: dashPct(p.TimeProgressPct),
			Flags:           []string{},
		}
		isPastEnd, endingSoon := false, false
		if p.EndDate.Valid {
			daysToEnd := -r.clk.DaysSince(p.EndDate.Time)
			row.DaysToEnd = dashInt(daysToEnd)
			isPastEnd = daysToEnd < 0
			endingSoon = daysToEnd >= 0 && daysToEnd <= 29
			if isPastEnd {
				pastEnd = append(pastEnd, domain.AttentionRecord{
					Ref:         row.Ref,
					Label:       p.ProjectNo + " " + p.Name,
					ProjectName: dashStr(p.Name),
					Date:        row.EndDate,
					Days:        dashInt(-daysToEnd),
				})
			}
			if daysToEnd >= 0 && daysToEnd <= 13 {
				payload.upcoming = append(payload.upcoming, domain.UpcomingItem{
					Kind: domain.UpcomingProjectEnd, Date: *row.EndDate, Ref: row.Ref,
					Title: p.ProjectNo + " " + p.Name,
				})
			}
		}
		if isPastEnd {
			row.Flags = append(row.Flags, domain.ProjectFlagPastEnd)
		}
		if endingSoon {
			row.Flags = append(row.Flags, domain.ProjectFlagEndingSoon)
		}
		overdueTasks, overduePlan, isOverBudget := false, false, false
		if tasksRead {
			cnt := 0
			if st, ok := taskStats[id]; ok {
				row.TaskProgressPct = dashPct(st.TaskProgressPct)
				cnt = int(st.OverdueCount)
			}
			row.OverdueTaskCount = dashInt(cnt)
			if cnt > 0 {
				overdueTasks = true
				row.Flags = append(row.Flags, domain.ProjectFlagOverdueTasks)
			}
		}
		if financeRead {
			if fs, ok := finStats[id]; ok {
				row.CollectionPct = dashPct(fs.CollectionPct)
				row.CurrentValue = dashMoneyPtr(fs.Currency, fs.CurrentValue)
				if fs.OverduePlanCount > 0 {
					overduePlan = true
					row.Flags = append(row.Flags, domain.ProjectFlagOverduePlan)
				}
			}
		}
		if costRead && overBudget[id] {
			isOverBudget = true
			row.Flags = append(row.Flags, domain.ProjectFlagOverBudget)
		}
		if contractsRead && noContract[id] {
			row.Flags = append(row.Flags, domain.ProjectFlagNoContract)
		}
		tier := 3
		switch {
		case isPastEnd || overduePlan || isOverBudget:
			tier = 1
		case overdueTasks || endingSoon:
			tier = 2
		}
		ranked = append(ranked, rankedRow{row: row, tier: tier, end: p.EndDate})
	}
	sort.SliceStable(ranked, func(i, j int) bool {
		a, b := ranked[i], ranked[j]
		if a.tier != b.tier {
			return a.tier < b.tier
		}
		if a.end.Valid != b.end.Valid {
			return a.end.Valid // bitiş tarihi olmayanlar en sona
		}
		if a.end.Valid && !a.end.Time.Equal(b.end.Time) {
			return a.end.Time.Before(b.end.Time)
		}
		if a.row.Name != b.row.Name {
			return a.row.Name < b.row.Name
		}
		return a.row.Ref.ID < b.row.Ref.ID
	})
	top := make([]domain.DashProjectRow, 0, 5)
	for i := 0; i < len(ranked) && i < 5; i++ {
		top = append(top, ranked[i].row)
	}

	sec := &domain.DashProjects{
		Counts: domain.DashProjectCounts{
			Planned: int(c.Planned), Active: int(c.Active), Paused: int(c.Paused),
			Completed: int(c.Completed), Cancelled: int(c.Cancelled), Total: int(c.Total),
		},
		PastEndDate:     int(c.PastEndDate),
		EndingWithin30d: int(c.EndingWithin30d),
		Top:             top,
	}
	if c.PastEndDate > 0 && r.wantsAttention(domain.AttnProjectPastEnd) {
		// open ASC bitiş tarihiyle sıralı: ilk kayıt en çok gecikmiş olan.
		g := DashboardAttentionInput{Code: domain.AttnProjectPastEnd, Count: int(c.PastEndDate), Amounts: []domain.MoneyAmount{}}
		if len(pastEnd) > 0 {
			g.OldestDays = pastEnd[0].Days
		}
		g.Items = firstRecords(pastEnd)
		payload.groups = append(payload.groups, g)
	}
	payload.apply = func(s *domain.DashboardSections) { s.Projects = sec }
	return payload, nil
}

func firstRecords(recs []domain.AttentionRecord) []domain.AttentionRecord {
	if len(recs) > dashMaxGroupItems {
		recs = recs[:dashMaxGroupItems]
	}
	return append([]domain.AttentionRecord{}, recs...)
}

// ============================================================ finance

type dashFlow struct{ coll, exp, sub decimal.Decimal }

func buildDashFinance(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	today := r.date(r.clk.Today)
	rows, err := r.q.DashboardFinanceByCurrency(ctx, sqlc.DashboardFinanceByCurrencyParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today,
	})
	if err != nil {
		return nil, err
	}
	monthly, err := r.q.DashboardFinanceMonthly(ctx, sqlc.DashboardFinanceMonthlyParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict,
		TrendStart: r.date(r.clk.TrendStart), NextMonthStart: r.date(r.clk.NextMonthStart),
	})
	if err != nil {
		return nil, err
	}

	// Para birimi kümesi = P'nin para birimleri ∪ nakit hareketi olanlar.
	var currencies []string
	seen := map[string]bool{}
	addCur := func(c string) {
		if !seen[c] {
			seen[c] = true
			currencies = append(currencies, c)
		}
	}
	byRow := map[string]sqlc.DashboardFinanceByCurrencyRow{}
	for _, row := range rows {
		byRow[row.Currency] = row
		addCur(row.Currency)
	}
	flows := map[string]map[string]dashFlow{}
	for _, m := range monthly {
		addCur(m.Currency)
		if flows[m.Currency] == nil {
			flows[m.Currency] = map[string]dashFlow{}
		}
		flows[m.Currency][m.Month.Time.Format("2006-01")] = dashFlow{
			coll: dashDec(m.Collections), exp: dashDec(m.Expenses), sub: dashDec(m.SubcontractPayments),
		}
	}

	months := make([]string, 6)
	for i := range months {
		months[i] = r.clk.TrendStart.AddDate(0, i, 0).Format("2006-01")
	}
	currentMonth := r.clk.MonthStart.Format("2006-01")

	byCur := make([]domain.DashFinanceCurrency, 0, len(currencies))
	for _, cur := range currencies {
		fc := domain.DashFinanceCurrency{Currency: cur, Trend6m: make([]domain.DashFinanceTrend, 0, 6)}
		if row, ok := byRow[cur]; ok {
			fc.PortfolioValue = dashMoney(row.PortfolioValue)
			fc.CollectedTotal = dashMoney(row.CollectedTotal)
			fc.OpenReceivable = dashMoney(row.OpenReceivable)
			fc.CollectionPct = dashPct(row.CollectionPct)
			fc.RealizedCost = dashMoney(row.RealizedCost)
			fc.CashBalance = dashDec(row.CollectedTotal).Sub(dashDec(row.RealizedCost)).InexactFloat64()
			fc.OverduePlan = domain.CountAmount{Count: int(row.OverduePlanCount), Amount: dashMoney(row.OverduePlanAmount)}
			fc.OverdueSalesInvoices = domain.CountAmount{Count: int(row.OverdueInvoiceCount), Amount: dashMoney(row.OverdueInvoiceAmount)}
		}
		for _, m := range months {
			f := flows[cur][m]
			out := f.exp.Add(f.sub)
			fc.Trend6m = append(fc.Trend6m, domain.DashFinanceTrend{
				Month: m, Collections: f.coll.InexactFloat64(), Outflows: out.InexactFloat64(),
				Net: f.coll.Sub(out).InexactFloat64(),
			})
		}
		f := flows[cur][currentMonth]
		out := f.exp.Add(f.sub)
		fc.Month = domain.DashFinanceMonth{
			Collections: f.coll.InexactFloat64(), Expenses: f.exp.InexactFloat64(),
			SubcontractPayments: f.sub.InexactFloat64(), Outflows: out.InexactFloat64(),
			NetCash: f.coll.Sub(out).InexactFloat64(),
		}
		byCur = append(byCur, fc)
	}
	sortByCurrency(byCur, r.primary, func(f domain.DashFinanceCurrency) (string, float64) { return f.Currency, f.PortfolioValue })

	payload := &sectionPayload{}
	sec := &domain.DashFinance{ByCurrency: byCur}

	// --- plan_item_overdue ---
	planCount, planSums, planOldest := 0, newCurrencySums(), pgtype.Date{}
	invCount, invSums, invOldest := 0, newCurrencySums(), pgtype.Date{}
	for _, row := range rows {
		if row.OverduePlanCount > 0 {
			planCount += int(row.OverduePlanCount)
			planSums.add(row.Currency, dashDec(row.OverduePlanAmount))
			planOldest = minDate(planOldest, row.OverduePlanOldest)
		}
		if row.OverdueInvoiceCount > 0 {
			invCount += int(row.OverdueInvoiceCount)
			invSums.add(row.Currency, dashDec(row.OverdueInvoiceAmount))
			invOldest = minDate(invOldest, row.OverdueInvoiceOldest)
		}
	}
	if planCount > 0 && r.wantsAttention(domain.AttnPlanItemOverdue) {
		items, err := r.q.DashboardPlanItemsDue(ctx, sqlc.DashboardPlanItemsDueParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict,
			DueTo: r.date(r.clk.Today.AddDate(0, 0, -1)), RowLimit: dashMaxGroupItems,
		})
		if err != nil {
			return nil, err
		}
		g := DashboardAttentionInput{Code: domain.AttnPlanItemOverdue, Count: planCount,
			Amounts: planSums.amounts(r.primary), OldestDays: r.daysSince(planOldest)}
		for _, it := range items {
			g.Items = append(g.Items, domain.AttentionRecord{
				Ref:   dashRef(domain.RefKindPaymentPlanItem, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
				Label: it.Name, ProjectName: dashStr(it.ProjectName),
				Amount: dashMoneyPtr(it.Currency, it.Remaining),
				Date:   dashDateStr(it.DueDate), Days: r.daysSince(it.DueDate),
			})
		}
		payload.groups = append(payload.groups, g)
	}
	// --- sales_invoice_overdue ---
	if invCount > 0 && r.wantsAttention(domain.AttnSalesInvoiceOverdue) {
		items, err := r.q.DashboardOverdueSalesInvoicesTop(ctx, sqlc.DashboardOverdueSalesInvoicesTopParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today,
		})
		if err != nil {
			return nil, err
		}
		g := DashboardAttentionInput{Code: domain.AttnSalesInvoiceOverdue, Count: invCount,
			Amounts: invSums.amounts(r.primary), OldestDays: r.daysSince(invOldest)}
		for _, it := range items {
			g.Items = append(g.Items, domain.AttentionRecord{
				Ref:   dashRef(domain.RefKindInvoice, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
				Label: it.InvoiceNo, ProjectName: dashStr(it.ProjectName),
				Amount: dashMoneyPtr(it.Currency, it.Amount),
				Date:   dashDateStr(it.DueDate), Days: r.daysSince(it.DueDate),
			})
		}
		payload.groups = append(payload.groups, g)
	}
	// --- expense_approval (migration 0060): yalnızca onaylayabilen izleyicide ---
	if r.wantsAttention(domain.AttnExpenseApproval) {
		// İzleyicinin kendi masrafı gündeme girmez -- karar veremez (Sahip
		// hariç, bkz. ErrOwnExpenseDecision).
		var exclude pgtype.UUID
		if r.authz == nil || r.authz.RoleCode != domain.OrgRoleOwner {
			exclude = r.userID
		}
		totals, err := r.q.DashboardPendingExpensesTotals(ctx, sqlc.DashboardPendingExpensesTotalsParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict, ExcludeCreatedBy: exclude,
		})
		if err != nil {
			return nil, err
		}
		agg := dashTotals(totals, func(t sqlc.DashboardPendingExpensesTotalsRow) (string, int32, pgtype.Numeric, pgtype.Date) {
			return t.Currency, t.Cnt, t.Amount, t.Oldest
		})
		if g, ok := r.aggGroup(domain.AttnExpenseApproval, agg); ok {
			items, err := r.q.DashboardPendingExpensesTop(ctx, sqlc.DashboardPendingExpensesTopParams{
				OrgID: r.orgID, RestrictToUserID: r.restrict, ExcludeCreatedBy: exclude,
			})
			if err != nil {
				return nil, err
			}
			for _, it := range items {
				// Masrafın kendi ekranı yok: satır projenin Finans görünümünü açar.
				g.Items = append(g.Items, domain.AttentionRecord{
					Ref:   dashProjectRef(domain.RefKindProjectFinance, it.ProjectID),
					Label: it.Description, ProjectName: dashStr(it.ProjectName),
					Amount: dashMoneyPtr(it.Currency, it.Amount),
					Date:   dashDateStr(it.SinceDate), Days: r.daysSince(it.SinceDate),
				})
			}
			payload.groups = append(payload.groups, g)
		}
	}
	// --- yaklaşan ödeme planı kalemleri ---
	upcoming, err := r.q.DashboardPlanItemsDue(ctx, sqlc.DashboardPlanItemsDueParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict,
		DueFrom: today, DueTo: r.date(r.clk.Plus13), RowLimit: dashMaxUpcoming,
	})
	if err != nil {
		return nil, err
	}
	for _, it := range upcoming {
		payload.upcoming = append(payload.upcoming, domain.UpcomingItem{
			Kind: domain.UpcomingPlanItemDue, Date: isoDate(it.DueDate.Time),
			Ref:   dashRef(domain.RefKindPaymentPlanItem, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
			Title: dashJoin(it.Name, it.ProjectName), ProjectName: dashStr(it.ProjectName),
			Amount: dashMoneyPtr(it.Currency, it.Remaining),
		})
	}
	payload.apply = func(s *domain.DashboardSections) { s.Finance = sec }
	return payload, nil
}

// ============================================================ change_orders

func buildDashChangeOrders(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	rows, err := r.q.DashboardChangeOrdersByCurrency(ctx, sqlc.DashboardChangeOrdersByCurrencyParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict,
		MonthStartTs: r.ts(r.clk.MonthStart), NextMonthStartTs: r.ts(r.clk.NextMonthStart),
	})
	if err != nil {
		return nil, err
	}
	byCur := make([]domain.DashChangeOrderCurrency, 0, len(rows))
	count, sums, oldest := 0, newCurrencySums(), pgtype.Date{}
	for _, row := range rows {
		byCur = append(byCur, domain.DashChangeOrderCurrency{
			Currency:             row.Currency,
			AwaitingCustomer:     domain.CountAmount{Count: int(row.AwaitingCount), Amount: dashMoney(row.AwaitingAmount)},
			Draft:                domain.CountAmount{Count: int(row.DraftCount), Amount: dashMoney(row.DraftAmount)},
			ApprovedNetThisMonth: dashMoney(row.ApprovedNetThisMonth),
		})
		if row.AwaitingCount > 0 {
			count += int(row.AwaitingCount)
			sums.add(row.Currency, dashDec(row.AwaitingAmount))
			oldest = minDate(oldest, row.AwaitingOldest)
		}
	}
	sortByCurrency(byCur, r.primary, func(c domain.DashChangeOrderCurrency) (string, float64) {
		return c.Currency, c.AwaitingCustomer.Amount
	})
	payload := &sectionPayload{}
	if count > 0 && r.wantsAttention(domain.AttnChangeOrderAwaitingCust) {
		items, err := r.q.DashboardChangeOrdersAwaitingTop(ctx, sqlc.DashboardChangeOrdersAwaitingTopParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict,
		})
		if err != nil {
			return nil, err
		}
		g := DashboardAttentionInput{Code: domain.AttnChangeOrderAwaitingCust, Count: count,
			Amounts: sums.amounts(r.primary), OldestDays: r.daysSince(oldest)}
		for _, it := range items {
			g.Items = append(g.Items, domain.AttentionRecord{
				Ref:   dashRef(domain.RefKindChangeOrder, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
				Label: it.Title, ProjectName: dashStr(it.ProjectName),
				Amount: dashMoneyPtr(it.Currency, it.GrandTotal),
				Date:   dashDateStr(it.SentDate), Days: r.daysSince(it.SentDate),
			})
		}
		payload.groups = append(payload.groups, g)
	}
	sec := &domain.DashChangeOrders{ByCurrency: byCur}
	payload.apply = func(s *domain.DashboardSections) { s.ChangeOrders = sec }
	return payload, nil
}

// ============================================================ offers

func buildDashOffers(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	today := r.date(r.clk.Today)
	rows, err := r.q.DashboardOffersByCurrency(ctx, sqlc.DashboardOffersByCurrencyParams{
		OrgID:       r.orgID,
		StatusDraft: domain.OfferStatusTaslak, StatusSent: domain.OfferStatusGonderildi,
		StatusAccepted: domain.OfferStatusKabulEdildi, StatusRejected: domain.OfferStatusReddedildi,
		Today: today, Plus6: r.date(r.clk.Plus6),
		D7StartTs: r.ts(r.clk.D7Start), D90StartTs: r.ts(r.clk.D90Start),
	})
	if err != nil {
		return nil, err
	}
	sec := &domain.DashOffers{ByCurrency: make([]domain.DashOfferCurrency, 0, len(rows))}
	accepted, rejected := 0, 0
	expSums, ncSums := newCurrencySums(), newCurrencySums()
	var expOldest, ncOldest pgtype.Date
	for _, row := range rows {
		sec.TotalActive += int(row.Total)
		sec.ByCurrency = append(sec.ByCurrency, domain.DashOfferCurrency{
			Currency:         row.Currency,
			Draft:            domain.CountAmount{Count: int(row.DraftCount), Amount: dashMoney(row.DraftAmount)},
			AwaitingCustomer: domain.CountAmount{Count: int(row.AwaitingCount), Amount: dashMoney(row.AwaitingAmount)},
			Accepted90d:      domain.CountAmount{Count: int(row.Accepted90dCount), Amount: dashMoney(row.Accepted90dAmount)},
			Rejected90d:      domain.CountAmount{Count: int(row.Rejected90dCount), Amount: dashMoney(row.Rejected90dAmount)},
		})
		sec.ExpiringWithin7d += int(row.Expiring7dCount)
		sec.ExpiredAwaiting += int(row.ExpiredCount)
		sec.ViewedByCustomer7d += int(row.Viewed7dCount)
		sec.AcceptedNotConverted += int(row.NotConvertedCount)
		accepted += int(row.Accepted90dCount)
		rejected += int(row.Rejected90dCount)
		if row.ExpiredCount > 0 {
			expSums.add(row.Currency, dashDec(row.ExpiredAmount))
			expOldest = minDate(expOldest, row.ExpiredOldest)
		}
		if row.NotConvertedCount > 0 {
			ncSums.add(row.Currency, dashDec(row.NotConvertedAmount))
			ncOldest = minDate(ncOldest, row.NotConvertedOldest)
		}
	}
	if accepted+rejected > 0 {
		v := decimal.NewFromInt(int64(accepted)).Mul(decimal.NewFromInt(100)).
			Div(decimal.NewFromInt(int64(accepted + rejected))).Round(1).InexactFloat64()
		sec.ConversionRate90dPct = &v
	}
	sortByCurrency(sec.ByCurrency, r.primary, func(c domain.DashOfferCurrency) (string, float64) {
		return c.Currency, c.AwaitingCustomer.Amount
	})

	payload := &sectionPayload{}
	offerLabel := func(no, customer string) string { return dashJoin(no, customer) }
	if sec.ExpiredAwaiting > 0 && r.wantsAttention(domain.AttnOfferExpiredAwaiting) {
		items, err := r.q.DashboardOffersExpiredTop(ctx, sqlc.DashboardOffersExpiredTopParams{
			OrgID: r.orgID, StatusSent: domain.OfferStatusGonderildi, Today: today,
		})
		if err != nil {
			return nil, err
		}
		g := DashboardAttentionInput{Code: domain.AttnOfferExpiredAwaiting, Count: sec.ExpiredAwaiting,
			Amounts: expSums.amounts(r.primary), OldestDays: r.daysSince(expOldest)}
		for _, it := range items {
			g.Items = append(g.Items, domain.AttentionRecord{
				Ref:    dashRef(domain.RefKindOffer, it.ID, pgtype.UUID{}, pgtype.UUID{}, domain.RefActionOpen),
				Label:  offerLabel(it.OfferNo, it.CustomerName),
				Amount: dashMoneyPtr(it.Currency, it.GrandTotal),
				Date:   dashDateStr(it.ValidUntil), Days: r.daysSince(it.ValidUntil),
			})
		}
		payload.groups = append(payload.groups, g)
	}
	if sec.AcceptedNotConverted > 0 && r.wantsAttention(domain.AttnOfferAcceptedNotConverted) {
		items, err := r.q.DashboardOffersNotConvertedTop(ctx, sqlc.DashboardOffersNotConvertedTopParams{
			OrgID: r.orgID, StatusAccepted: domain.OfferStatusKabulEdildi,
		})
		if err != nil {
			return nil, err
		}
		g := DashboardAttentionInput{Code: domain.AttnOfferAcceptedNotConverted, Count: sec.AcceptedNotConverted,
			Amounts: ncSums.amounts(r.primary), OldestDays: r.daysSince(ncOldest)}
		for _, it := range items {
			// ref.action (convert/open) gündemde, projects.create'e göre.
			g.Items = append(g.Items, domain.AttentionRecord{
				Ref:    dashRef(domain.RefKindOffer, it.ID, pgtype.UUID{}, pgtype.UUID{}, domain.RefActionOpen),
				Label:  offerLabel(it.OfferNo, it.CustomerName),
				Amount: dashMoneyPtr(it.Currency, it.GrandTotal),
			})
		}
		payload.groups = append(payload.groups, g)
	}
	upcoming, err := r.q.DashboardUpcomingOfferExpiries(ctx, sqlc.DashboardUpcomingOfferExpiriesParams{
		OrgID: r.orgID, StatusSent: domain.OfferStatusGonderildi, Today: today, Plus13: r.date(r.clk.Plus13),
	})
	if err != nil {
		return nil, err
	}
	for _, it := range upcoming {
		payload.upcoming = append(payload.upcoming, domain.UpcomingItem{
			Kind: domain.UpcomingOfferExpiry, Date: isoDate(it.ValidUntil.Time),
			Ref:    dashRef(domain.RefKindOffer, it.ID, pgtype.UUID{}, pgtype.UUID{}, domain.RefActionOpen),
			Title:  offerLabel(it.OfferNo, it.CustomerName),
			Amount: dashMoneyPtr(it.Currency, it.GrandTotal),
		})
	}
	payload.apply = func(s *domain.DashboardSections) { s.Offers = sec }
	return payload, nil
}

// ============================================================ procurement

type dashAgg struct {
	count  int
	sums   *currencySums
	oldest pgtype.Date
}

func buildDashProcurement(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	today := r.date(r.clk.Today)
	c, err := r.q.DashboardProcurementCounts(ctx, sqlc.DashboardProcurementCountsParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today,
	})
	if err != nil {
		return nil, err
	}
	approved, err := r.q.DashboardProcurementApprovedThisMonth(ctx, sqlc.DashboardProcurementApprovedThisMonthParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict,
		MonthStartTs: r.ts(r.clk.MonthStart), NextMonthStartTs: r.ts(r.clk.NextMonthStart),
	})
	if err != nil {
		return nil, err
	}
	sec := &domain.DashProcurement{
		PurchaseRequests: domain.DashPurchaseRequestCounts{Draft: int(c.PrDraft), Submitted: int(c.PrSubmitted)},
		RFQs: domain.DashRFQCounts{Issued: int(c.RfqIssued), AwaitingAward: int(c.RfqAwaitingAward),
			PastDueNoQuote: int(c.RfqPastDueNoQuote)},
		PurchaseOrders: domain.DashPurchaseOrderCounts{Draft: int(c.PoDraft), ApprovedOpen: int(c.PoApprovedOpen),
			LateDelivery: int(c.PoLateDelivery)},
		ApprovedThisMonth: make([]domain.DashCurrencyCountAmount, 0, len(approved)),
	}
	for _, a := range approved {
		sec.ApprovedThisMonth = append(sec.ApprovedThisMonth, domain.DashCurrencyCountAmount{
			Currency: a.Currency, Count: int(a.Cnt), Amount: dashMoney(a.Amount),
		})
	}
	sortByCurrency(sec.ApprovedThisMonth, r.primary, func(a domain.DashCurrencyCountAmount) (string, float64) {
		return a.Currency, a.Amount
	})

	payload := &sectionPayload{}
	aggs := map[string]*dashAgg{}
	if r.wantsAttention(domain.AttnPurchaseRequestApproval) || r.wantsAttention(domain.AttnPurchaseOrderDraft) ||
		r.wantsAttention(domain.AttnPOLateDelivery) {
		att, err := r.q.DashboardProcurementAttention(ctx, sqlc.DashboardProcurementAttentionParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today,
		})
		if err != nil {
			return nil, err
		}
		for _, a := range att {
			agg := aggs[a.Code]
			if agg == nil {
				agg = &dashAgg{sums: newCurrencySums()}
				aggs[a.Code] = agg
			}
			agg.count += int(a.Cnt)
			agg.sums.add(a.Currency, dashDec(a.Amount))
			agg.oldest = minDate(agg.oldest, a.Oldest)
		}
	}
	group := func(code string) (*DashboardAttentionInput, bool) {
		agg := aggs[code]
		if agg == nil || agg.count == 0 || !r.wantsAttention(code) {
			return nil, false
		}
		return &DashboardAttentionInput{Code: code, Count: agg.count, Amounts: agg.sums.amounts(r.primary),
			OldestDays: r.daysSince(agg.oldest)}, true
	}

	if g, ok := group(domain.AttnPurchaseRequestApproval); ok {
		items, err := r.q.DashboardPurchaseRequestsSubmittedTop(ctx, sqlc.DashboardPurchaseRequestsSubmittedTopParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict,
		})
		if err != nil {
			return nil, err
		}
		for _, it := range items {
			g.Items = append(g.Items, domain.AttentionRecord{
				Ref:   dashRef(domain.RefKindPurchaseRequest, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
				Label: dashJoin(it.PrNo, it.Title), ProjectName: dashStr(it.ProjectName),
				Amount: dashMoneyPtr(it.Currency, it.EstimatedTotal),
				Date:   dashDateStr(it.SinceDate), Days: r.daysSince(it.SinceDate),
			})
		}
		payload.groups = append(payload.groups, *g)
	}
	for _, spec := range []struct{ code, mode string }{
		{domain.AttnPurchaseOrderDraft, "draft"}, {domain.AttnPOLateDelivery, "late"},
	} {
		g, ok := group(spec.code)
		if !ok {
			continue
		}
		items, err := r.q.DashboardPurchaseOrdersTop(ctx, sqlc.DashboardPurchaseOrdersTopParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today, Mode: spec.mode,
		})
		if err != nil {
			return nil, err
		}
		for _, it := range items {
			g.Items = append(g.Items, domain.AttentionRecord{
				Ref:   dashRef(domain.RefKindPurchaseOrder, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
				Label: it.PoNo, ProjectName: dashStr(it.ProjectName),
				Amount: dashMoneyPtr(it.Currency, it.Total),
				Date:   dashDateStr(it.RefDate), Days: r.daysSince(it.RefDate),
			})
		}
		payload.groups = append(payload.groups, *g)
	}
	for _, spec := range []struct {
		code       string
		count      int32
		oldest     pgtype.Date
		withQuotes bool
		action     string
	}{
		{domain.AttnRFQAward, c.RfqAwaitingAward, c.RfqAwaitingAwardOldest, true, domain.RefActionAward},
		{domain.AttnRFQNoQuote, c.RfqPastDueNoQuote, c.RfqPastDueNoQuoteOldest, false, domain.RefActionOpen},
	} {
		if spec.count == 0 || !r.wantsAttention(spec.code) {
			continue
		}
		items, err := r.q.DashboardRFQsPastDueTop(ctx, sqlc.DashboardRFQsPastDueTopParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today, WithQuotes: spec.withQuotes,
		})
		if err != nil {
			return nil, err
		}
		g := DashboardAttentionInput{Code: spec.code, Count: int(spec.count), Amounts: []domain.MoneyAmount{},
			OldestDays: r.daysSince(spec.oldest)}
		for _, it := range items {
			label := it.RfqNo
			if spec.withQuotes {
				label = dashJoin(it.RfqNo, it.Title)
			}
			g.Items = append(g.Items, domain.AttentionRecord{
				Ref:   dashRef(domain.RefKindRFQ, it.ID, it.ProjectID, pgtype.UUID{}, spec.action),
				Label: label, ProjectName: dashStr(it.ProjectName),
				Date: dashDateStr(it.DueDate), Days: r.daysSince(it.DueDate),
			})
		}
		payload.groups = append(payload.groups, g)
	}
	deliveries, err := r.q.DashboardUpcomingPODeliveries(ctx, sqlc.DashboardUpcomingPODeliveriesParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today, Plus13: r.date(r.clk.Plus13),
	})
	if err != nil {
		return nil, err
	}
	for _, it := range deliveries {
		payload.upcoming = append(payload.upcoming, domain.UpcomingItem{
			Kind: domain.UpcomingPODelivery, Date: isoDate(it.ExpectedDeliveryDate.Time),
			Ref:   dashRef(domain.RefKindPurchaseOrder, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
			Title: dashJoin(it.PoNo, it.ProjectName), ProjectName: dashStr(it.ProjectName),
		})
	}
	payload.apply = func(s *domain.DashboardSections) { s.Procurement = sec }
	return payload, nil
}

// ============================================================ subcontracts

// dashCountAmounts, satırlardan çok para birimli sayı+tutar üretir.
func dashCountAmounts(n int, sums *currencySums, primary string) domain.CountAmounts {
	return domain.CountAmounts{Count: n, Amounts: sums.amounts(primary)}
}

func buildDashSubcontracts(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	active, err := r.q.DashboardSubcontractActiveCount(ctx, sqlc.DashboardSubcontractActiveCountParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict,
	})
	if err != nil {
		return nil, err
	}
	values, err := r.q.DashboardSubcontractValues(ctx, sqlc.DashboardSubcontractValuesParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict,
	})
	if err != nil {
		return nil, err
	}
	paymentsRead := r.can(domain.PermProjectsSubcontractPaymentsRead)
	claimsRead := r.can(domain.PermProjectsSubcontractClaimsRead)

	paid := map[string]sqlc.DashboardSubcontractPaidRow{}
	if paymentsRead {
		rows, err := r.q.DashboardSubcontractPaid(ctx, sqlc.DashboardSubcontractPaidParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict,
		})
		if err != nil {
			return nil, err
		}
		for _, row := range rows {
			paid[row.Currency] = row
		}
	}
	byCur := make([]domain.DashSubcontractCurrency, 0, len(values))
	for _, v := range values {
		sc := domain.DashSubcontractCurrency{Currency: v.Currency, CurrentValue: dashMoney(v.CurrentValue)}
		if paymentsRead {
			zero := 0.0
			sc.PaidToDate = &zero
			if p, ok := paid[v.Currency]; ok {
				sc.PaidToDate = dashFloat(dashMoney(p.PaidToDate))
				sc.PaidPct = dashPct(p.PaidPct)
			} else if sc.CurrentValue > 0 {
				sc.PaidPct = &zero
			}
		}
		byCur = append(byCur, sc)
	}
	sortByCurrency(byCur, r.primary, func(c domain.DashSubcontractCurrency) (string, float64) { return c.Currency, c.CurrentValue })

	payload := &sectionPayload{}
	sec := &domain.DashSubcontracts{ActiveCount: int(active), ByCurrency: byCur}

	// Dikkat kodları spec §4.6 deseninde: para birimi başına toplam sorgusu
	// (kart sayıları/tutarları ve grup her zaman buradan) + yalnızca grup bu
	// izleyicinin gündeminde görünecekse en eski 3 kayıt (LIMIT 3).
	coTotals, err := r.q.DashboardSubcontractCOsSubmittedTotals(ctx, sqlc.DashboardSubcontractCOsSubmittedTotalsParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict,
	})
	if err != nil {
		return nil, err
	}
	coAgg := dashTotals(coTotals, func(t sqlc.DashboardSubcontractCOsSubmittedTotalsRow) (string, int32, pgtype.Numeric, pgtype.Date) {
		return t.Currency, t.Cnt, t.Amount, t.Oldest
	})
	sec.ChangeOrdersSubmitted = dashCountAmounts(coAgg.count, coAgg.sums, r.primary)
	if g, ok := r.aggGroup(domain.AttnSubcontractCOApproval, coAgg); ok {
		items, err := r.q.DashboardSubcontractCOsSubmittedTop(ctx, sqlc.DashboardSubcontractCOsSubmittedTopParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict,
		})
		if err != nil {
			return nil, err
		}
		for _, it := range items {
			g.Items = append(g.Items, domain.AttentionRecord{
				Ref:   dashRef(domain.RefKindSubcontractChangeOrder, it.ID, it.ProjectID, it.SubcontractID, domain.RefActionOpen),
				Label: dashJoin(it.Number, it.Title), ProjectName: dashStr(it.ProjectName),
				Amount: dashMoneyPtr(it.Currency, it.Amount),
				Date:   dashDateStr(it.SinceDate), Days: r.daysSince(it.SinceDate),
			})
		}
		payload.groups = append(payload.groups, g)
	}

	if claimsRead {
		subTotals, err := r.q.DashboardClaimsSubmittedTotals(ctx, sqlc.DashboardClaimsSubmittedTotalsParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict,
		})
		if err != nil {
			return nil, err
		}
		subAgg := dashTotals(subTotals, func(t sqlc.DashboardClaimsSubmittedTotalsRow) (string, int32, pgtype.Numeric, pgtype.Date) {
			return t.Currency, t.Cnt, t.Amount, t.Oldest
		})
		claims := &domain.DashSubcontractClaims{Submitted: dashCountAmounts(subAgg.count, subAgg.sums, r.primary)}
		if g, ok := r.aggGroup(domain.AttnProgressClaimCertify, subAgg); ok {
			items, err := r.q.DashboardClaimsSubmittedTop(ctx, sqlc.DashboardClaimsSubmittedTopParams{
				OrgID: r.orgID, RestrictToUserID: r.restrict,
			})
			if err != nil {
				return nil, err
			}
			for _, it := range items {
				g.Items = append(g.Items, domain.AttentionRecord{
					Ref:   dashRef(domain.RefKindProgressClaim, it.ID, it.ProjectID, it.SubcontractID, domain.RefActionOpen),
					Label: it.ClaimNumber, ProjectName: dashStr(it.ProjectName),
					Amount: dashMoneyPtr(it.Currency, it.NetPayable),
					Date:   dashDateStr(it.SinceDate), Days: r.daysSince(it.SinceDate),
				})
			}
			payload.groups = append(payload.groups, g)
		}
		if paymentsRead {
			unTotals, err := r.q.DashboardClaimsCertifiedUnpaidTotals(ctx, sqlc.DashboardClaimsCertifiedUnpaidTotalsParams{
				OrgID: r.orgID, RestrictToUserID: r.restrict,
			})
			if err != nil {
				return nil, err
			}
			unAgg := dashTotals(unTotals, func(t sqlc.DashboardClaimsCertifiedUnpaidTotalsRow) (string, int32, pgtype.Numeric, pgtype.Date) {
				return t.Currency, t.Cnt, t.Amount, t.Oldest
			})
			ca := dashCountAmounts(unAgg.count, unAgg.sums, r.primary)
			claims.CertifiedUnpaid = &ca
			if g, ok := r.aggGroup(domain.AttnClaimCertifiedUnpaid, unAgg); ok {
				items, err := r.q.DashboardClaimsCertifiedUnpaidTop(ctx, sqlc.DashboardClaimsCertifiedUnpaidTopParams{
					OrgID: r.orgID, RestrictToUserID: r.restrict,
				})
				if err != nil {
					return nil, err
				}
				for _, it := range items {
					g.Items = append(g.Items, domain.AttentionRecord{
						Ref:   dashRef(domain.RefKindProgressClaim, it.ID, it.ProjectID, it.SubcontractID, domain.RefActionOpen),
						Label: it.ClaimNumber, ProjectName: dashStr(it.ProjectName),
						Amount: dashMoneyPtr(it.Currency, it.Unpaid),
						Date:   dashDateStr(it.SinceDate), Days: r.daysSince(it.SinceDate),
					})
				}
				payload.groups = append(payload.groups, g)
			}
		}
		sec.Claims = claims
	}
	payload.apply = func(s *domain.DashboardSections) { s.Subcontracts = sec }
	return payload, nil
}

func dashFloat(v float64) *float64 { return &v }

// dashTotals: bir dikkat kodunun para birimi başına toplam satırlarını
// (sayı, tutar, en eski gün) tek bir dashAgg'de birleştirir.
func dashTotals[T any](rows []T, f func(T) (string, int32, pgtype.Numeric, pgtype.Date)) dashAgg {
	agg := dashAgg{sums: newCurrencySums()}
	for _, row := range rows {
		cur, n, amount, oldest := f(row)
		agg.count += int(n)
		agg.sums.add(cur, dashDec(amount))
		agg.oldest = minDate(agg.oldest, oldest)
	}
	return agg
}

// aggGroup: toplamlardan dikkat grubu; sayı 0 ya da kod bu izleyicinin
// gündeminde görünmeyecekse yok (kayıt sorgusu da hiç çalıştırılmaz).
func (r *dashRun) aggGroup(code string, agg dashAgg) (DashboardAttentionInput, bool) {
	if agg.count == 0 || !r.wantsAttention(code) {
		return DashboardAttentionInput{}, false
	}
	return DashboardAttentionInput{Code: code, Count: agg.count, Amounts: agg.sums.amounts(r.primary),
		OldestDays: r.daysSince(agg.oldest)}, true
}

// ============================================================ cost_control

func buildDashCostControl(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	payload := &sectionPayload{}
	sec := &domain.DashCostControl{}
	projectLabel := func(no, name string) string { return no + " " + name }

	if r.can(domain.PermProjectsBudgetRead) {
		bc, err := r.q.DashboardBudgetCounts(ctx, sqlc.DashboardBudgetCountsParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict,
		})
		if err != nil {
			return nil, err
		}
		sec.Budgets = &domain.DashBudgetCounts{
			None: int(bc.NoBudget), Draft: int(bc.Draft), Baselined: int(bc.Baselined), OpenProjects: int(bc.OpenProjects),
		}
		adjTotals, err := r.q.DashboardPendingAdjustmentsTotals(ctx, sqlc.DashboardPendingAdjustmentsTotalsParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict,
		})
		if err != nil {
			return nil, err
		}
		adjAgg := dashTotals(adjTotals, func(t sqlc.DashboardPendingAdjustmentsTotalsRow) (string, int32, pgtype.Numeric, pgtype.Date) {
			return t.Currency, t.Cnt, t.Amount, t.Oldest
		})
		pa := dashCountAmounts(adjAgg.count, adjAgg.sums, r.primary)
		sec.PendingAdjustments = &pa
		if g, ok := r.aggGroup(domain.AttnBudgetAdjustmentApproval, adjAgg); ok {
			items, err := r.q.DashboardPendingAdjustmentsTop(ctx, sqlc.DashboardPendingAdjustmentsTopParams{
				OrgID: r.orgID, RestrictToUserID: r.restrict,
			})
			if err != nil {
				return nil, err
			}
			for _, it := range items {
				g.Items = append(g.Items, domain.AttentionRecord{
					Ref:   dashRef(domain.RefKindBudgetAdjustment, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
					Label: it.Reason, ProjectName: dashStr(it.ProjectName),
					Amount: dashMoneyPtr(it.Currency, it.Amount),
					Date:   dashDateStr(it.SinceDate), Days: r.daysSince(it.SinceDate),
				})
			}
			payload.groups = append(payload.groups, g)
		}
		if r.wantsAttention(domain.AttnActiveWithoutBudget) {
			// İlk 3 proje + pencere sayımıyla toplam (tek sorgu, LIMIT 3).
			rows, err := r.q.DashboardActiveProjectsWithoutBaselineTop(ctx, sqlc.DashboardActiveProjectsWithoutBaselineTopParams{
				OrgID: r.orgID, RestrictToUserID: r.restrict,
			})
			if err != nil {
				return nil, err
			}
			if len(rows) > 0 {
				g := DashboardAttentionInput{Code: domain.AttnActiveWithoutBudget, Count: int(rows[0].TotalCount), Amounts: []domain.MoneyAmount{}}
				for _, it := range rows {
					g.Items = append(g.Items, domain.AttentionRecord{
						Ref:   dashProjectRef(domain.RefKindProjectCost, it.ID),
						Label: projectLabel(it.ProjectNo, it.Name), ProjectName: dashStr(it.Name),
					})
				}
				payload.groups = append(payload.groups, g)
			}
		}
	}

	if r.can(domain.PermProjectsCostControlRead) {
		committed, err := r.q.DashboardCommittedActive(ctx, sqlc.DashboardCommittedActiveParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict,
		})
		if err != nil {
			return nil, err
		}
		sec.CommittedActive = make([]domain.MoneyAmount, 0, len(committed))
		for _, cm := range committed {
			sec.CommittedActive = append(sec.CommittedActive, domain.MoneyAmount{Currency: cm.Currency, Amount: dashMoney(cm.Amount)})
		}
		sortByCurrency(sec.CommittedActive, r.primary, func(m domain.MoneyAmount) (string, float64) { return m.Currency, m.Amount })

		over, err := r.projectsOverBudget(ctx)
		if err != nil {
			return nil, err
		}
		ob := &domain.DashOverBudget{Count: len(over)}
		sums := newCurrencySums()
		var recs []domain.AttentionRecord
		for i, it := range over {
			ref := dashProjectRef(domain.RefKindProjectCost, it.ProjectID)
			pct := dashPct(it.OverrunPct)
			if i == 0 && pct != nil {
				ob.Worst = &domain.DashOverBudgetWorst{Ref: ref, ProjectName: it.Name, OverrunPct: *pct}
			}
			sums.add(it.Currency, dashDec(it.OverrunAmount))
			recs = append(recs, domain.AttentionRecord{
				Ref: ref, Label: projectLabel(it.ProjectNo, it.Name), ProjectName: dashStr(it.Name),
				Amount: dashMoneyPtr(it.Currency, it.OverrunAmount), Pct: pct,
			})
		}
		sec.OverBudget = ob
		if len(over) > 0 && r.wantsAttention(domain.AttnOverBudget) {
			payload.groups = append(payload.groups, DashboardAttentionInput{
				Code: domain.AttnOverBudget, Count: len(over), Amounts: sums.amounts(r.primary), Items: firstRecords(recs),
			})
		}
	}
	payload.apply = func(s *domain.DashboardSections) { s.CostControl = sec }
	return payload, nil
}

// ============================================================ contracts

func buildDashContracts(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	today := r.date(r.clk.Today)
	cc, err := r.q.DashboardContractCounts(ctx, sqlc.DashboardContractCountsParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today,
	})
	if err != nil {
		return nil, err
	}
	without, err := r.projectsWithoutContract(ctx)
	if err != nil {
		return nil, err
	}
	sec := &domain.DashContracts{
		Counts: domain.DashContractCounts{
			Draft: int(cc.Draft), Active: int(cc.Active), Completed: int(cc.Completed),
			Cancelled: int(cc.Cancelled), Terminated: int(cc.Terminated),
		},
		ActiveProjectsWithoutContract: len(without),
		PastPlannedCompletion:         int(cc.PastPlannedCompletion),
	}
	payload := &sectionPayload{}
	label := func(no, name string) string { return no + " " + name }

	if r.wantsAttention(domain.AttnContractActivation) || r.wantsAttention(domain.AttnContractPastCompletion) {
		rows, err := r.q.DashboardContractsAttention(ctx, sqlc.DashboardContractsAttentionParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today,
		})
		if err != nil {
			return nil, err
		}
		var drafts, past []domain.AttentionRecord
		var draftOldest, pastOldest pgtype.Date
		for _, it := range rows {
			rec := domain.AttentionRecord{
				Ref:   dashRef(domain.RefKindContract, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
				Label: label(it.ProjectNo, it.ProjectName), ProjectName: dashStr(it.ProjectName),
			}
			if it.Kind == "draft" {
				draftOldest = minDate(draftOldest, it.RefDate)
				drafts = append(drafts, rec)
			} else {
				pastOldest = minDate(pastOldest, it.RefDate)
				rec.Date, rec.Days = dashDateStr(it.RefDate), r.daysSince(it.RefDate)
				past = append(past, rec)
			}
		}
		if len(drafts) > 0 && r.wantsAttention(domain.AttnContractActivation) {
			payload.groups = append(payload.groups, DashboardAttentionInput{
				Code: domain.AttnContractActivation, Count: len(drafts), Amounts: []domain.MoneyAmount{},
				OldestDays: r.daysSince(draftOldest), Items: firstRecords(drafts),
			})
		}
		if len(past) > 0 && r.wantsAttention(domain.AttnContractPastCompletion) {
			payload.groups = append(payload.groups, DashboardAttentionInput{
				Code: domain.AttnContractPastCompletion, Count: len(past), Amounts: []domain.MoneyAmount{},
				OldestDays: r.daysSince(pastOldest), Items: firstRecords(past),
			})
		}
	}
	if len(without) > 0 && r.wantsAttention(domain.AttnActiveWithoutContract) {
		g := DashboardAttentionInput{Code: domain.AttnActiveWithoutContract, Count: len(without), Amounts: []domain.MoneyAmount{}}
		for i, it := range without {
			if i == dashMaxGroupItems {
				break
			}
			g.Items = append(g.Items, domain.AttentionRecord{
				Ref:   dashProjectRef(domain.RefKindProjectFinance, it.ID),
				Label: label(it.ProjectNo, it.Name), ProjectName: dashStr(it.Name),
			})
		}
		payload.groups = append(payload.groups, g)
	}
	payload.apply = func(s *domain.DashboardSections) { s.Contracts = sec }
	return payload, nil
}

// ============================================================ tasks

func buildDashTasks(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	today := r.date(r.clk.Today)
	payload := &sectionPayload{}
	mine := domain.DashMyTasks{Items: []domain.DashMyTask{}}

	// /tasks/mine ile aynı çözümleme: bağlı personel yoksa "benim
	// görevlerim" boştur -- ASLA ekibin görevlerine düşmez.
	emp, err := r.q.DashboardLinkedEmployee(ctx, sqlc.DashboardLinkedEmployeeParams{UserID: r.userID, OrgID: r.orgID})
	if err != nil {
		return nil, err
	}
	if len(emp) > 0 {
		employeeID := emp[0]
		mine.LinkedEmployee = true
		mc, err := r.q.DashboardMyTaskCounts(ctx, sqlc.DashboardMyTaskCountsParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today, EmployeeID: employeeID,
		})
		if err != nil {
			return nil, err
		}
		mine.Open, mine.Overdue, mine.DueToday = int(mc.OpenCount), int(mc.Overdue), int(mc.DueToday)
		list := func(mode string, from, to pgtype.Date, limit int32) ([]sqlc.DashboardMyTasksRow, error) {
			return r.q.DashboardMyTasks(ctx, sqlc.DashboardMyTasksParams{
				OrgID: r.orgID, RestrictToUserID: r.restrict, EmployeeID: employeeID, Today: today,
				Mode: mode, DueFrom: from, DueTo: to, RowLimit: limit,
			})
		}
		items, err := list("items", pgtype.Date{}, pgtype.Date{}, 5)
		if err != nil {
			return nil, err
		}
		for _, it := range items {
			t := domain.DashMyTask{
				Ref:   dashRef(domain.RefKindTask, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
				Title: it.Title, ProjectName: it.ProjectName, DueDate: dashDateStr(it.DueDate),
				Priority: it.Priority, Status: it.Status,
			}
			if d := r.daysSince(it.DueDate); d != nil && *d > 0 {
				t.DaysOverdue = d
			}
			mine.Items = append(mine.Items, t)
		}
		taskRecords := func(rows []sqlc.DashboardMyTasksRow, withDays bool) []domain.AttentionRecord {
			out := make([]domain.AttentionRecord, 0, len(rows))
			for _, it := range rows {
				rec := domain.AttentionRecord{
					Ref:   dashRef(domain.RefKindTask, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
					Label: it.Title, ProjectName: dashStr(it.ProjectName), Date: dashDateStr(it.DueDate),
				}
				if withDays {
					rec.Days = r.daysSince(it.DueDate)
				}
				out = append(out, rec)
			}
			return out
		}
		if mine.Overdue > 0 {
			rows, err := list("overdue", pgtype.Date{}, pgtype.Date{}, dashMaxGroupItems)
			if err != nil {
				return nil, err
			}
			payload.groups = append(payload.groups, DashboardAttentionInput{
				Code: domain.AttnMyTaskOverdue, Count: mine.Overdue, Amounts: []domain.MoneyAmount{},
				OldestDays: r.daysSince(mc.OverdueOldest), Items: taskRecords(rows, true),
			})
		}
		if mine.DueToday > 0 {
			rows, err := list("range", today, today, dashMaxGroupItems)
			if err != nil {
				return nil, err
			}
			payload.groups = append(payload.groups, DashboardAttentionInput{
				Code: domain.AttnMyTaskDueToday, Count: mine.DueToday, Amounts: []domain.MoneyAmount{},
				OldestDays: dashInt(0), Items: taskRecords(rows, false),
			})
		}
		// Bugünün kendi görevleri my_task_due_today'de; yaklaşan yarından başlar.
		soon, err := list("range", r.date(r.clk.Today.AddDate(0, 0, 1)), r.date(r.clk.Plus13), dashMaxUpcoming)
		if err != nil {
			return nil, err
		}
		for _, it := range soon {
			payload.upcoming = append(payload.upcoming, domain.UpcomingItem{
				Kind: domain.UpcomingMyTaskDue, Date: isoDate(it.DueDate.Time),
				Ref:   dashRef(domain.RefKindTask, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
				Title: dashJoin(it.Title, it.ProjectName), ProjectName: dashStr(it.ProjectName),
			})
		}
	}

	tc, err := r.q.DashboardTeamTaskCounts(ctx, sqlc.DashboardTeamTaskCountsParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today, D7StartTs: r.ts(r.clk.D7Start),
	})
	if err != nil {
		return nil, err
	}
	team := domain.DashTeamTasks{
		Open: int(tc.OpenCount), Overdue: int(tc.Overdue), DueToday: int(tc.DueToday),
		Unassigned: int(tc.Unassigned), Completed7d: int(tc.Completed7d),
	}
	for _, spec := range []struct {
		code   string
		mode   string
		count  int
		oldest pgtype.Date
	}{
		{domain.AttnTeamTaskOverdue, "overdue", team.Overdue, tc.OverdueOldest},
		{domain.AttnTeamTaskUnassigned, "unassigned", team.Unassigned, tc.UnassignedOldest},
	} {
		if spec.count == 0 || !r.wantsAttention(spec.code) {
			continue
		}
		rows, err := r.q.DashboardTeamTasksTop(ctx, sqlc.DashboardTeamTasksTopParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today, Mode: spec.mode,
		})
		if err != nil {
			return nil, err
		}
		g := DashboardAttentionInput{Code: spec.code, Count: spec.count, Amounts: []domain.MoneyAmount{},
			OldestDays: r.daysSince(spec.oldest)}
		for _, it := range rows {
			rec := domain.AttentionRecord{
				Ref:   dashRef(domain.RefKindTask, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
				Label: it.Title, ProjectName: dashStr(it.ProjectName), Date: dashDateStr(it.DueDate),
			}
			if spec.mode == "overdue" {
				rec.Days = r.daysSince(it.DueDate)
			}
			g.Items = append(g.Items, rec)
		}
		payload.groups = append(payload.groups, g)
	}
	sec := &domain.DashTasks{Mine: mine, Team: team}
	payload.apply = func(s *domain.DashboardSections) { s.Tasks = sec }
	return payload, nil
}

// ============================================================ operations

func buildDashOperations(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	today := r.date(r.clk.Today)
	oc, err := r.q.DashboardOperationsCounts(ctx, sqlc.DashboardOperationsCountsParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today, Plus6: r.date(r.clk.Plus6),
		D7StartTs: r.ts(r.clk.D7Start),
	})
	if err != nil {
		return nil, err
	}
	sec := &domain.DashOperations{
		ActiveCrew: int(oc.ActiveCrew),
		Milestones: domain.DashMilestoneCount{Due7d: int(oc.MilestonesDue7d), Overdue: int(oc.MilestonesOverdue)},
		Photos7d:   int(oc.Photos7d),
	}
	payload := &sectionPayload{}
	milestones := func(mode string, from, to pgtype.Date, limit int32) ([]sqlc.DashboardMilestonesRow, error) {
		return r.q.DashboardMilestones(ctx, sqlc.DashboardMilestonesParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict, Today: today, Mode: mode,
			DueFrom: from, DueTo: to, RowLimit: limit,
		})
	}
	if sec.Milestones.Overdue > 0 && r.wantsAttention(domain.AttnMilestoneOverdue) {
		rows, err := milestones("overdue", pgtype.Date{}, pgtype.Date{}, dashMaxGroupItems)
		if err != nil {
			return nil, err
		}
		g := DashboardAttentionInput{Code: domain.AttnMilestoneOverdue, Count: sec.Milestones.Overdue,
			Amounts: []domain.MoneyAmount{}, OldestDays: r.daysSince(oc.MilestonesOverdueOldest)}
		for _, it := range rows {
			g.Items = append(g.Items, domain.AttentionRecord{
				Ref:   dashRef(domain.RefKindMilestone, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
				Label: it.Name, ProjectName: dashStr(it.ProjectName),
				Date: dashDateStr(it.EndDate), Days: r.daysSince(it.EndDate),
			})
		}
		payload.groups = append(payload.groups, g)
	}
	soon, err := milestones("range", today, r.date(r.clk.Plus13), dashMaxUpcoming)
	if err != nil {
		return nil, err
	}
	for _, it := range soon {
		payload.upcoming = append(payload.upcoming, domain.UpcomingItem{
			Kind: domain.UpcomingMilestoneEnd, Date: isoDate(it.EndDate.Time),
			Ref:   dashRef(domain.RefKindMilestone, it.ID, it.ProjectID, pgtype.UUID{}, domain.RefActionOpen),
			Title: dashJoin(it.Name, it.ProjectName), ProjectName: dashStr(it.ProjectName),
		})
	}
	payload.apply = func(s *domain.DashboardSections) { s.Operations = sec }
	return payload, nil
}

// ============================================================ attendance

func buildDashAttendance(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	row, err := r.q.DashboardAttendanceToday(ctx, sqlc.DashboardAttendanceTodayParams{
		OrgID: r.orgID, Today: r.date(r.clk.Today),
		MonthStart: r.date(r.clk.MonthStart), NextMonthStart: r.date(r.clk.NextMonthStart),
		StatusPresent: domain.AttendanceGeldi, StatusHalfDay: domain.AttendanceYarimGun,
		StatusAbsent: domain.AttendanceGelmedi, StatusOnLeave: domain.AttendanceIzinli,
	})
	if err != nil {
		return nil, err
	}
	sec := &domain.DashAttendance{
		Date: isoDate(r.clk.Today), Scope: domain.DashAttendanceScopeOrganization,
		ActiveEmployees: int(row.ActiveEmployees), Present: int(row.Present), HalfDay: int(row.HalfDay),
		Absent: int(row.Absent), OnLeave: int(row.OnLeave), NotRecorded: int(row.NotRecorded),
		OnSite: int(row.Present) + int(row.HalfDay), MonthWorkHours: dashMoney(row.MonthWorkHours),
	}
	payload := &sectionPayload{}
	// Pazar günü mesai beklenmez (tatil takvimi yok, spec §9).
	if r.clk.IsWorkday && sec.NotRecorded > 0 && r.wantsAttention(domain.AttnAttendanceNotRecorded) {
		payload.groups = append(payload.groups, DashboardAttentionInput{
			Code: domain.AttnAttendanceNotRecorded, Count: sec.NotRecorded,
			Amounts: []domain.MoneyAmount{}, Items: []domain.AttentionRecord{},
		})
	}
	payload.apply = func(s *domain.DashboardSections) { s.Attendance = sec }
	return payload, nil
}

// ============================================================ employees / customers

func buildDashEmployees(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	row, err := r.q.DashboardEmployeeCounts(ctx, sqlc.DashboardEmployeeCountsParams{
		OrgID: r.orgID, MonthStart: r.date(r.clk.MonthStart), NextMonthStart: r.date(r.clk.NextMonthStart),
	})
	if err != nil {
		return nil, err
	}
	sec := &domain.DashEmployees{
		Active: int(row.Active), Inactive: int(row.Inactive),
		WithUserAccount: int(row.WithUserAccount), NewThisMonth: int(row.NewThisMonth),
	}
	return &sectionPayload{apply: func(s *domain.DashboardSections) { s.Employees = sec }}, nil
}

func buildDashCustomers(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	row, err := r.q.DashboardCustomerCounts(ctx, sqlc.DashboardCustomerCountsParams{
		OrgID: r.orgID, RestrictToUserID: r.restrict,
		MonthStartTs: r.ts(r.clk.MonthStart), NextMonthStartTs: r.ts(r.clk.NextMonthStart),
	})
	if err != nil {
		return nil, err
	}
	sec := &domain.DashCustomers{
		Active: int(row.Active), NewThisMonth: int(row.NewThisMonth), WithActiveProjects: int(row.WithActiveProjects),
	}
	return &sectionPayload{apply: func(s *domain.DashboardSections) { s.Customers = sec }}, nil
}

// ============================================================ products

func buildDashProducts(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	pc, err := r.q.DashboardProductCounts(ctx, r.orgID)
	if err != nil {
		return nil, err
	}
	// Zam Geçmişi sayfasıyla aynı sorgular, varsayılan filtresiyle (tedarikçi
	// zammı, tüm kaynaklar), son 30 gün -- tx'e bağlı q üzerinden.
	from, to := r.ts(r.clk.D30Start), r.ts(r.clk.Now.Add(time.Microsecond))
	sum, err := r.q.SummarizePriceChanges(ctx, sqlc.SummarizePriceChangesParams{
		OrganizationID: r.orgID, FromTime: from, ToTime: to, Reason: domain.PriceChangeReasonSupplier, Source: "",
	})
	if err != nil {
		return nil, err
	}
	maxRows, err := r.q.GetMaxPriceIncrease(ctx, sqlc.GetMaxPriceIncreaseParams{
		OrganizationID: r.orgID, FromTime: from, ToTime: to, Reason: domain.PriceChangeReasonSupplier, Source: "",
	})
	if err != nil {
		return nil, err
	}
	sources, err := r.q.DashboardPriceSources(ctx, r.orgID)
	if err != nil {
		return nil, err
	}
	sec := &domain.DashProducts{
		Total:    int(pc.Total),
		BySource: domain.DashProductsBySource{Manual: int(pc.Manual), Ulas: int(pc.Ulas), DemirProfil: int(pc.Demirprofil)},
		PriceChanges30d: domain.DashPriceChanges{
			IncreasedCount: int(sum.IncreasedCount), DecreasedCount: int(sum.DecreasedCount),
			ProductsIncreased: int(sum.ProductsIncreased), AvgIncreasePercent: dashPct(sum.AvgIncreasePercent),
		},
		PriceSources: make([]domain.DashPriceSource, 0, len(sources)),
	}
	if len(maxRows) > 0 {
		m := maxRows[0]
		pct := 0.0
		if v := dashPct(m.ChangePercent); v != nil {
			pct = *v
		}
		sec.PriceChanges30d.MaxIncrease = &domain.DashPriceMaxIncrease{
			Ref:         dashRef(domain.RefKindProduct, m.ProductID, pgtype.UUID{}, pgtype.UUID{}, domain.RefActionOpen),
			ProductName: m.ProductName, ChangePercent: pct,
		}
	}
	payload := &sectionPayload{}
	var failed, never []domain.AttentionRecord
	for _, src := range sources {
		ps := domain.DashPriceSource{
			Source: src.Source, LastSyncedAt: dashTimestamp(src.LastSyncedAt),
			LastStatus: src.LastStatus, AutoSync: src.AutoSync,
		}
		var syncedDate *string
		if src.LastSyncedAt.Valid {
			local := src.LastSyncedAt.Time.In(istanbulLocation)
			ps.DaysSinceSync = dashInt(r.clk.DaysSince(local))
			d := isoDate(local)
			syncedDate = &d
		}
		sec.PriceSources = append(sec.PriceSources, ps)
		name := src.Source
		if info, ok := domain.LookupPriceSource(src.Source); ok {
			name = info.ShortName
		}
		rec := domain.AttentionRecord{
			Ref:   domain.DashboardRef{Kind: domain.RefKindPriceSource, ID: src.Source, Action: domain.RefActionOpen},
			Label: name, Date: syncedDate, Days: ps.DaysSinceSync,
		}
		switch src.LastStatus {
		case domain.PriceSyncStatusFailed:
			failed = append(failed, rec)
		case domain.PriceSyncStatusNever:
			never = append(never, rec)
		}
	}
	if len(failed) > 0 && r.wantsAttention(domain.AttnPriceSyncFailed) {
		payload.groups = append(payload.groups, DashboardAttentionInput{
			Code: domain.AttnPriceSyncFailed, Count: len(failed), Amounts: []domain.MoneyAmount{}, Items: firstRecords(failed),
		})
	}
	if len(never) > 0 && r.wantsAttention(domain.AttnPriceSyncNever) {
		payload.groups = append(payload.groups, DashboardAttentionInput{
			Code: domain.AttnPriceSyncNever, Count: len(never), Amounts: []domain.MoneyAmount{}, Items: firstRecords(never),
		})
	}
	payload.apply = func(s *domain.DashboardSections) { s.Products = sec }
	return payload, nil
}

// ============================================================ compact registries

func buildDashCalculations(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	cc, err := r.q.DashboardCalcCounts(ctx, r.orgID)
	if err != nil {
		return nil, err
	}
	sec := &domain.DashCalculations{Groups: int(cc.Groups), Categories: int(cc.Categories)}
	if r.can(domain.PermOffersRead) {
		n, err := r.q.DashboardCalcUsedInOffers(ctx, sqlc.DashboardCalcUsedInOffersParams{
			OrgID: r.orgID, D30StartTs: r.ts(r.clk.D30Start),
		})
		if err != nil {
			return nil, err
		}
		sec.UsedInOfferLines30d = dashInt(int(n))
	}
	if r.can(domain.PermCalculationsManage) {
		n, err := r.q.DashboardCalcRecipeUnlinked(ctx, r.orgID)
		if err != nil {
			return nil, err
		}
		sec.RecipeItemsUnlinked = dashInt(int(n))
	}
	return &sectionPayload{apply: func(s *domain.DashboardSections) { s.Calculations = sec }}, nil
}

func buildDashSuppliers(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	sc, err := r.q.DashboardSupplierCounts(ctx, r.orgID)
	if err != nil {
		return nil, err
	}
	sec := &domain.DashSuppliers{Active: int(sc.Active), Inactive: int(sc.Inactive)}
	if r.can(domain.PermProjectsProcurementRead) {
		n, err := r.q.DashboardSuppliersOrderedThisMonth(ctx, sqlc.DashboardSuppliersOrderedThisMonthParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict,
			MonthStartTs: r.ts(r.clk.MonthStart), NextMonthStartTs: r.ts(r.clk.NextMonthStart),
		})
		if err != nil {
			return nil, err
		}
		sec.OrderedThisMonth = dashInt(int(n))
	}
	return &sectionPayload{apply: func(s *domain.DashboardSections) { s.Suppliers = sec }}, nil
}

func buildDashCostCodes(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	cc, err := r.q.DashboardCostCodeCounts(ctx, r.orgID)
	if err != nil {
		return nil, err
	}
	sec := &domain.DashCostCodes{Active: int(cc.Active), Inactive: int(cc.Inactive)}
	if r.can(domain.PermProjectsCostControlRead) {
		n, err := r.q.DashboardExpensesWithoutCostCode(ctx, sqlc.DashboardExpensesWithoutCostCodeParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict,
			MonthStart: r.date(r.clk.MonthStart), NextMonthStart: r.date(r.clk.NextMonthStart),
		})
		if err != nil {
			return nil, err
		}
		sec.ExpensesWithoutCodeMonth = dashInt(int(n))
	}
	return &sectionPayload{apply: func(s *domain.DashboardSections) { s.CostCodes = sec }}, nil
}

// ============================================================ users

func buildDashUsers(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	uc, err := r.q.DashboardUserCounts(ctx, r.orgID)
	if err != nil {
		return nil, err
	}
	roles, err := r.q.DashboardUsersByRole(ctx, r.orgID)
	if err != nil {
		return nil, err
	}
	sec := &domain.DashUsers{
		Active: int(uc.Active), Inactive: int(uc.Inactive), NeverLoggedIn: int(uc.NeverLoggedIn),
		RestrictedWithoutProject: int(uc.RestrictedWithoutProject), WithoutEmployeeLink: int(uc.WithoutEmployeeLink),
		ByRole: make([]domain.DashUserByRole, 0, len(roles)),
	}
	for _, role := range roles {
		sec.ByRole = append(sec.ByRole, domain.DashUserByRole{Code: role.Code, Name: role.Name, Count: int(role.Cnt)})
	}
	if r.can(domain.PermOrganizationRolesRead) {
		n, err := r.q.DashboardUsersWithOverrides(ctx, r.orgID)
		if err != nil {
			return nil, err
		}
		sec.WithPersonalOverrides = dashInt(int(n))
	}
	payload := &sectionPayload{}
	if sec.RestrictedWithoutProject > 0 && r.wantsAttention(domain.AttnUsersWithoutProject) {
		rows, err := r.q.DashboardUsersWithoutProjectTop(ctx, r.orgID)
		if err != nil {
			return nil, err
		}
		g := DashboardAttentionInput{Code: domain.AttnUsersWithoutProject, Count: sec.RestrictedWithoutProject,
			Amounts: []domain.MoneyAmount{}}
		for _, it := range rows {
			g.Items = append(g.Items, domain.AttentionRecord{
				Ref:   dashRef(domain.RefKindUser, it.ID, pgtype.UUID{}, pgtype.UUID{}, domain.RefActionOpen),
				Label: dashJoin(it.FullName, it.RoleName),
			})
		}
		payload.groups = append(payload.groups, g)
	}
	payload.apply = func(s *domain.DashboardSections) { s.Users = sec }
	return payload, nil
}

// ============================================================ notifications

func buildDashNotifications(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	unread, err := r.q.CountUnreadNotifications(ctx, sqlc.CountUnreadNotificationsParams{
		UserID: r.userID, OrganizationID: r.orgID,
	})
	if err != nil {
		return nil, err
	}
	rows, err := r.q.ListNotificationsForUser(ctx, sqlc.ListNotificationsForUserParams{
		UserID: r.userID, OrganizationID: r.orgID, Limit: 5, Offset: 0,
	})
	if err != nil {
		return nil, err
	}
	sec := &domain.DashNotifications{Unread: int(unread), Latest: make([]domain.DashNotificationEntry, 0, len(rows))}
	for _, n := range rows {
		created := ""
		if ts := dashTimestamp(n.CreatedAt); ts != nil {
			created = *ts
		}
		sec.Latest = append(sec.Latest, domain.DashNotificationEntry{
			ID: n.ID.String(), Type: n.Type, Title: n.Title, Body: n.Body,
			ActionTarget: dashStr(n.ActionTarget), CreatedAt: created, ReadAt: dashTimestamp(n.ReadAt),
		})
	}
	return &sectionPayload{apply: func(s *domain.DashboardSections) { s.Notifications = sec }}, nil
}

// ============================================================ activity

func buildDashActivity(ctx context.Context, r *dashRun) (*sectionPayload, error) {
	type stamped struct {
		at   time.Time
		item domain.DashActivityItem
	}
	var all []stamped
	if allowed := domain.AllowedProjectActivityTypes(r.can); len(allowed) > 0 {
		rows, err := r.q.DashboardProjectActivity(ctx, sqlc.DashboardProjectActivityParams{
			OrgID: r.orgID, RestrictToUserID: r.restrict, AllowedTypes: allowed,
		})
		if err != nil {
			return nil, err
		}
		for _, ev := range rows {
			all = append(all, stamped{at: ev.CreatedAt.Time, item: domain.DashActivityItem{
				Source: domain.ActivitySourceProject, EventType: ev.EventType,
				Ref:       dashProjectRef(domain.RefKindProject, ev.ProjectID),
				ProjectNo: dashStr(ev.ProjectNo), ProjectName: dashStr(ev.ProjectName),
				UserName: dashStr(ev.UserName), CreatedAt: *dashTimestamp(ev.CreatedAt),
			}})
		}
	}
	if r.can(domain.PermOffersRead) {
		rows, err := r.q.DashboardOfferActivity(ctx, sqlc.DashboardOfferActivityParams{
			OrgID: r.orgID, AllowedTypes: domain.OfferActivityEvents,
		})
		if err != nil {
			return nil, err
		}
		for _, ev := range rows {
			all = append(all, stamped{at: ev.CreatedAt.Time, item: domain.DashActivityItem{
				Source: domain.ActivitySourceOffer, EventType: ev.EventType,
				Ref:      dashRef(domain.RefKindOffer, ev.OfferID, pgtype.UUID{}, pgtype.UUID{}, domain.RefActionOpen),
				OfferNo:  dashStr(ev.OfferNo),
				UserName: dashStr(ev.UserName), CreatedAt: *dashTimestamp(ev.CreatedAt),
			}})
		}
		// Müşteri görüntülemeleri teklif başına EN SON olanıyla (paylaşım
		// linkinin her açılışı ayrı satır yazar; tekrarlar listeyi doldurmasın).
		if slices.Contains(domain.OfferActivityEvents, domain.EventCustomerViewed) {
			views, err := r.q.DashboardOfferLatestViews(ctx, r.orgID)
			if err != nil {
				return nil, err
			}
			for _, v := range views {
				all = append(all, stamped{at: v.CreatedAt.Time, item: domain.DashActivityItem{
					Source: domain.ActivitySourceOffer, EventType: domain.EventCustomerViewed,
					Ref:       dashRef(domain.RefKindOffer, v.OfferID, pgtype.UUID{}, pgtype.UUID{}, domain.RefActionOpen),
					OfferNo:   dashStr(v.OfferNo),
					CreatedAt: *dashTimestamp(v.CreatedAt),
				}})
			}
		}
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].at.After(all[j].at) })
	sec := &domain.DashActivity{Items: make([]domain.DashActivityItem, 0, 10)}
	for i := 0; i < len(all) && i < 10; i++ {
		sec.Items = append(sec.Items, all[i].item)
	}
	return &sectionPayload{apply: func(s *domain.DashboardSections) { s.Activity = sec }}, nil
}
