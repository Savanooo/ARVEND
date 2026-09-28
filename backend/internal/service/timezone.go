package service

import (
	"time"
	_ "time/tzdata" // Europe/Istanbul, sunucuda zoneinfo olmasa da çözülsün.
)

// istanbulLocation, uygulamanın TEK "bugün" tanımının saat dilimidir
// (fiyat senkronu, Zam Geçmişi günleri, vade karşılaştırmaları, ana sayfa
// özeti). Veritabanı oturumları da aynı dilimle açılır (bkz.
// repository.NewPool) -- SQL'deki CURRENT_DATE ile Go'daki "bugün" aynı
// takvim gününü gösterir.
var istanbulLocation = func() *time.Location {
	if loc, err := time.LoadLocation("Europe/Istanbul"); err == nil {
		return loc
	}
	return time.FixedZone("TRT", 3*60*60) // 2016'dan beri kalıcı UTC+3
}()

// IstanbulLocation, Europe/Istanbul konumunu döner.
func IstanbulLocation() *time.Location { return istanbulLocation }

// IstanbulNow, verilen anı İstanbul saatine çevirir. domain.IsPastDue gibi
// takvim günü karşılaştırmalarına verilen "şimdi" HER ZAMAN bundan geçer --
// sunucunun yerel saat dilimi (ör. UTC) 00:00-03:00 arasında bir önceki
// günü gösterirdi.
func IstanbulNow(now time.Time) time.Time { return now.In(istanbulLocation) }

// DashboardClock, ana sayfa özetinin (GET /dashboard) bütün tarih
// sınırlarıdır -- hepsi İstanbul takvim günü üzerinden, TEK bir "şimdi"den
// hesaplanır. Tarih alanları İstanbul gece yarısı (00:00) anlarıdır; hem
// "date" kolonlarına (takvim günü olarak) hem "timestamptz" kolonlarına
// (İstanbul gece yarısı sınırı olarak) aynı değer verilir.
type DashboardClock struct {
	Now            time.Time // İstanbul saatinde
	Today          time.Time
	MonthStart     time.Time
	NextMonthStart time.Time
	TrendStart     time.Time // MonthStart - 5 ay (6 aylık nakit grafiğinin ilk ayı)
	D7Start        time.Time // bugün - 6 (bugün dahil son 7 gün)
	D30Start       time.Time // bugün - 29
	D90Start       time.Time // bugün - 89
	Plus6          time.Time
	Plus13         time.Time // "Yaklaşan · 14 gün" penceresinin son günü
	Plus29         time.Time
	// IsWorkday: Pazartesi-Cumartesi (tatil takvimi yok, bkz. spec §9).
	IsWorkday bool
}

// NewDashboardClock, verilen andan (testlerde sabit, üretimde time.Now())
// İstanbul takvimine göre bütün sınırları kurar. time.Date ile gün/ay
// aritmetiği yapılır -- yaz saati geçişi olsa bile gün atlamaz.
func NewDashboardClock(now time.Time) DashboardClock {
	n := now.In(istanbulLocation)
	day := func(y int, m time.Month, d int) time.Time {
		return time.Date(y, m, d, 0, 0, 0, 0, istanbulLocation)
	}
	today := day(n.Year(), n.Month(), n.Day())
	monthStart := day(n.Year(), n.Month(), 1)
	return DashboardClock{
		Now:            n,
		Today:          today,
		MonthStart:     monthStart,
		NextMonthStart: day(n.Year(), n.Month()+1, 1),
		TrendStart:     day(n.Year(), n.Month()-5, 1),
		D7Start:        day(n.Year(), n.Month(), n.Day()-6),
		D30Start:       day(n.Year(), n.Month(), n.Day()-29),
		D90Start:       day(n.Year(), n.Month(), n.Day()-89),
		Plus6:          day(n.Year(), n.Month(), n.Day()+6),
		Plus13:         day(n.Year(), n.Month(), n.Day()+13),
		Plus29:         day(n.Year(), n.Month(), n.Day()+29),
		IsWorkday:      n.Weekday() != time.Sunday,
	}
}

// DaysSince, bir takvim gününden (date kolonu ya da İstanbul'a çevrilmiş
// bir an) bugüne kaç gün geçtiğini döner; ileri tarihler için negatiftir.
func (c DashboardClock) DaysSince(t time.Time) int {
	y, m, d := t.Date()
	from := time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
	ty, tm, td := c.Today.Date()
	to := time.Date(ty, tm, td, 0, 0, 0, 0, time.UTC)
	return int(to.Sub(from).Hours() / 24)
}

// isoDate, bir takvim gününü "2026-09-28" biçiminde yazar (saat dilimi
// dönüşümü YAPMAZ -- date kolonlarından gelen UTC gece yarısı değerleri de
// İstanbul gece yarısı değerleri de aynı günü verir).
func isoDate(t time.Time) string { return t.Format("2006-01-02") }
