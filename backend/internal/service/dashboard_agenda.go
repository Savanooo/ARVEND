package service

import (
	"sort"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

// Ana sayfa gündemi ("Dikkat Gerektirenler" + "Yaklaşan · 14 gün") --
// SAF fonksiyonlar (veritabanı yok), spec §3.1/§3.2/§4.7.

// DashboardAttentionInput, bir bölüm oluşturucusunun ürettiği ham dikkat
// grubudur: kod, TOPLAM sayı (yalnızca ilk 3 kayıt değil), para birimi
// başına tutarlar, en eski kaydın gün sayısı ve en acil ilk kayıtlar.
// Şerit/önem gündemde, domain.AttentionRules'tan belirlenir.
type DashboardAttentionInput struct {
	Code       string
	Count      int
	Amounts    []domain.MoneyAmount
	OldestDays *int
	Items      []domain.AttentionRecord
}

const (
	dashMaxGroupItems = 3
	dashMaxUpcoming   = 8
)

// attentionLane, kodun izleyicideki şeridini döner; ok=false ise kod bu
// izleyicide gündemde görünmez (görünürlük izni yok ya da aksiyon alamıyor
// ve kural "gizle" diyor). Bilinmeyen kod her zaman gizlidir (fail-closed).
func attentionLane(code string, can func(string) bool) (string, bool) {
	rule, ok := domain.AttentionRules[code]
	if !ok {
		return "", false
	}
	if !canAll(rule.Visible, can) {
		return "", false
	}
	switch {
	case rule.AlwaysMine:
		return domain.LaneMine, true
	case len(rule.Act) > 0 && canAll(rule.Act, can):
		return domain.LaneMine, true
	case rule.WhenCannotAct != "":
		return rule.WhenCannotAct, true
	default:
		return "", false
	}
}

func canAll(codes []string, can func(string) bool) bool {
	for _, c := range codes {
		if !can(c) {
			return false
		}
	}
	return true
}

var severityRank = map[string]int{
	domain.SeverityDanger: 3,
	domain.SeverityAction: 2,
	domain.SeverityInfo:   1,
}

// BuildDashboardAgenda, başarılı bölümlerin ham gruplarından ve yaklaşan
// kalemlerinden gündemi kurar:
//  1. şerit (mine/watching/gizli) ve önem kuraldan;
//  2. sıralama: mine önce; danger > action > info; en eski gün azalan;
//     birincil para birimindeki tutar azalan; kod artan (belirlenimcilik);
//  3. her grubun kayıtları en fazla 3, yaklaşanlar en fazla 8 (tarih, sonra
//     tür sırası);
//  4. sayaçlar = şerit başına grup SAYILARININ toplamı.
//
// offer_accepted_not_converted kayıtlarında ref.action, izleyici
// projects.create tutuyorsa "convert", aksi hâlde "open" olur.
func BuildDashboardAgenda(inputs []DashboardAttentionInput, upcoming []domain.UpcomingItem, can func(string) bool, primary string) domain.DashboardAgenda {
	agenda := domain.DashboardAgenda{Groups: []domain.AttentionGroup{}, Upcoming: []domain.UpcomingItem{}}
	for _, in := range inputs {
		if in.Count <= 0 {
			continue
		}
		lane, ok := attentionLane(in.Code, can)
		if !ok {
			continue
		}
		rule := domain.AttentionRules[in.Code]
		items := make([]domain.AttentionRecord, 0, dashMaxGroupItems)
		for i, rec := range in.Items {
			if i == dashMaxGroupItems {
				break
			}
			if in.Code == domain.AttnOfferAcceptedNotConverted {
				rec.Ref.Action = domain.RefActionOpen
				if can(domain.PermProjectsCreate) {
					rec.Ref.Action = domain.RefActionConvert
				}
			}
			items = append(items, rec)
		}
		amounts := append([]domain.MoneyAmount{}, in.Amounts...)
		sortByCurrency(amounts, primary, func(m domain.MoneyAmount) (string, float64) { return m.Currency, m.Amount })
		agenda.Groups = append(agenda.Groups, domain.AttentionGroup{
			Code: in.Code, Module: rule.Module, Lane: lane, Severity: rule.Severity,
			Count: in.Count, Amounts: amounts, OldestDays: in.OldestDays, Items: items,
		})
	}

	sort.SliceStable(agenda.Groups, func(i, j int) bool {
		return attentionGroupLess(agenda.Groups[i], agenda.Groups[j], primary)
	})

	for _, g := range agenda.Groups {
		switch g.Lane {
		case domain.LaneMine:
			agenda.MineCount += g.Count
			if g.Severity == domain.SeverityDanger {
				agenda.MineDangerCount += g.Count
			}
		case domain.LaneWatching:
			agenda.WatchingCount += g.Count
		}
	}

	agenda.Upcoming = append(agenda.Upcoming, upcoming...)
	sort.SliceStable(agenda.Upcoming, func(i, j int) bool {
		a, b := agenda.Upcoming[i], agenda.Upcoming[j]
		if a.Date != b.Date {
			return a.Date < b.Date
		}
		ka, kb := domain.UpcomingKindOrder[a.Kind], domain.UpcomingKindOrder[b.Kind]
		if ka != kb {
			return ka < kb
		}
		if a.Title != b.Title {
			return a.Title < b.Title
		}
		return a.Ref.ID < b.Ref.ID
	})
	if len(agenda.Upcoming) > dashMaxUpcoming {
		agenda.Upcoming = agenda.Upcoming[:dashMaxUpcoming]
	}
	return agenda
}

func attentionGroupLess(a, b domain.AttentionGroup, primary string) bool {
	if a.Lane != b.Lane {
		return a.Lane == domain.LaneMine
	}
	if sa, sb := severityRank[a.Severity], severityRank[b.Severity]; sa != sb {
		return sa > sb
	}
	oa, ob := -1, -1
	if a.OldestDays != nil {
		oa = *a.OldestDays
	}
	if b.OldestDays != nil {
		ob = *b.OldestDays
	}
	if oa != ob {
		return oa > ob
	}
	if pa, pb := primaryAmount(a.Amounts, primary), primaryAmount(b.Amounts, primary); pa != pb {
		return pa > pb
	}
	return a.Code < b.Code
}

func primaryAmount(amounts []domain.MoneyAmount, primary string) float64 {
	for _, m := range amounts {
		if m.Currency == primary {
			return m.Amount
		}
	}
	return 0
}

// sortByCurrency: birincil para birimi önce, sonra ana tutar azalan, sonra
// para birimi kodu (spec D13). Bütün by_currency dizileri bununla sıralanır.
func sortByCurrency[T any](items []T, primary string, key func(T) (string, float64)) {
	sort.SliceStable(items, func(i, j int) bool {
		ci, ai := key(items[i])
		cj, aj := key(items[j])
		if (ci == primary) != (cj == primary) {
			return ci == primary
		}
		if ai != aj {
			return ai > aj
		}
		return ci < cj
	})
}
