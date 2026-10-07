package handler

import (
	"bytes"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/Savanooo/ARVEND/backend/internal/service"
)

func errorBody(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("yanıt JSON değil: %q", rec.Body.String())
	}
	return body.Error
}

// 25 MB'ı aşan yükleme ham Go metni ("http: request body too large")
// yerine 413 + Türkçe mesaj dönmeli.
func TestReadUploadTooLargeIs413(t *testing.T) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, err := mw.CreateFormFile("file", "buyuk.pdf")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := fw.Write(bytes.Repeat([]byte("a"), service.MaxUploadBytes+4096)); err != nil {
		t.Fatal(err)
	}
	_ = mw.Close()

	req := httptest.NewRequest(http.MethodPost, "/api/v1/projects/x/files", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	rec := httptest.NewRecorder()
	_, _, _, err = readUpload(rec, req)
	if err == nil {
		t.Fatal("sınırı aşan gövde reddedilmeli")
	}
	(&ProjectHandler{}).writeError(rec, err)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("durum = %d, beklenen 413", rec.Code)
	}
	if msg := errorBody(t, rec); msg != "Dosya 25 MB'tan büyük olamaz" {
		t.Errorf("mesaj = %q", msg)
	}
}

// Bozuk multipart gövdesinin ham çözümleyici metni istemciye sızmamalı.
func TestReadUploadMalformedHidesRawError(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/projects/x/files", strings.NewReader("bozuk"))
	req.Header.Set("Content-Type", "multipart/form-data; boundary=yok")
	rec := httptest.NewRecorder()
	_, _, _, err := readUpload(rec, req)
	if err == nil {
		t.Fatal("bozuk gövde reddedilmeli")
	}
	(&ProjectHandler{}).writeError(rec, err)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("durum = %d", rec.Code)
	}
	if msg := errorBody(t, rec); strings.Contains(msg, "multipart") || strings.Contains(msg, "EOF") {
		t.Errorf("ham hata sızdı: %q", msg)
	}
}

// Eşlemesi unutulmuş pgx sentinel'leri ham metinle 400 değil, 500 dönmeli.
func TestProjectWriteErrorHidesUnexpectedPgxErrors(t *testing.T) {
	for _, err := range []error{pgx.ErrNoRows, fmt.Errorf("sarılı: %w", pgx.ErrTxClosed)} {
		rec := httptest.NewRecorder()
		(&ProjectHandler{}).writeError(rec, err)
		if rec.Code != http.StatusInternalServerError {
			t.Errorf("%v: durum = %d, beklenen 500", err, rec.Code)
		}
		if msg := errorBody(t, rec); strings.Contains(msg, "no rows") || strings.Contains(msg, "tx") {
			t.Errorf("%v: ham metin sızdı: %q", err, msg)
		}
	}
	rec := httptest.NewRecorder()
	(&NotificationHandler{}).writeError(rec, pgx.ErrNoRows)
	if rec.Code != http.StatusInternalServerError {
		t.Errorf("bildirim uçları: durum = %d, beklenen 500", rec.Code)
	}
}
