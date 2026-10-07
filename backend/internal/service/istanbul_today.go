package service

import "time"

// istanbulToday, İstanbul takvimine göre bugünün tarihidir -- UTC gece
// yarısı olarak döner, date kolonuna yazılmaya ve date kolonundan gelen
// değerlerle (pgx onları UTC gece yarısı verir) karşılaştırılmaya hazır.
// Sunucu UTC'de çalışır: time.Now() 00:00-03:00 arası bir önceki günü
// gösterir, bu yüzden "bugün" hiçbir yerde sunucu saatinden alınmaz.
func istanbulToday(now time.Time) time.Time {
	y, m, d := IstanbulNow(now).Date()
	return time.Date(y, m, d, 0, 0, 0, 0, time.UTC)
}

// IstanbulToday, istanbulToday'in handler'lar için dışa açık hâlidir
// (ör. tarih verilmezse varsayılan "bugün").
func IstanbulToday() time.Time { return istanbulToday(time.Now()) }
