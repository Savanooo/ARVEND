package handler

import (
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// "Tümünü okundu" gövdesi isteğe bağlı: eski istemciler gövdesiz gönderir
// (sınırsız); yeni istemciler listede gördükleri en yeni created_at'i
// "before" olarak yollar.
func TestParseMarkAllReadBefore(t *testing.T) {
	want := time.Date(2026, 10, 11, 9, 30, 15, 0, time.UTC)
	cases := []struct {
		name    string
		body    string
		want    *time.Time
		wantErr bool
	}{
		{name: "gövdesiz (eski istemci)", body: "", want: nil},
		{name: "boş nesne", body: "{}", want: nil},
		{name: "null", body: `{"before": null}`, want: nil},
		{name: "boş metin", body: `{"before": "  "}`, want: nil},
		{name: "RFC3339 UTC", body: `{"before": "2026-10-11T09:30:15Z"}`, want: &want},
		{name: "RFC3339 +03:00", body: `{"before": "2026-10-11T12:30:15+03:00"}`, want: &want},
		{name: "bozuk tarih", body: `{"before": "11.10.2026"}`, wantErr: true},
		{name: "bozuk gövde", body: `{"before":`, wantErr: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequest("POST", "/notifications/read-all", strings.NewReader(c.body))
			got, err := parseMarkAllReadBefore(r)
			if c.wantErr {
				if err == nil {
					t.Fatalf("hata bekleniyordu, geldi: %v", got)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if (got == nil) != (c.want == nil) || (got != nil && !got.Equal(*c.want)) {
				t.Fatalf("beklenen %v, geldi %v", c.want, got)
			}
		})
	}
}
