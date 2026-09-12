package handler

import (
	"context"
	"errors"
	"log"
	"net/http"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/Savanooo/ARVEND/backend/internal/platform/httpjson"
)

// isInternalError, istemcinin düzeltebileceği bir girdi hatası DEĞİL,
// sunucu tarafı bir arıza olan hataları tanır: veritabanı hataları
// (*pgconn.PgError -- kısıt ihlalleri, "value too long", bağlantı
// sorunları) ve context iptal/zaman aşımları.
//
// Servis katmanındaki iş kuralı hataları düz errors.New ile üretilir ve
// kullanıcıya gösterilmek üzere yazılmıştır; onlar bu kontrolden geçmez ve
// 400 olarak kendi metinleriyle dönmeye devam eder.
func isInternalError(err error) bool {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return true
	}
	return errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)
}

// writeInternalError, hatanın ayrıntısını SUNUCU LOGUNA yazar ve istemciye
// yalnızca genel bir mesaj döner -- ham veritabanı hata metinleri (tablo/
// kolon adları, kısıt isimleri) dışarı sızmamalı.
func writeInternalError(w http.ResponseWriter, err error) {
	log.Printf("beklenmeyen sunucu hatası: %v", err)
	httpjson.Error(w, http.StatusInternalServerError, "beklenmeyen bir sunucu hatası oluştu")
}
