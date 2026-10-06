package fcm

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/golang-jwt/jwt/v5"
)

func testServiceAccount(t *testing.T, tokenURI string) ([]byte, *rsa.PrivateKey) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	pemKey := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: mustPKCS8(t, key)})
	raw, _ := json.Marshal(map[string]string{
		"type": "service_account", "project_id": "arvend-test", "client_email": "push@arvend-test.iam.gserviceaccount.com",
		"private_key": string(pemKey), "token_uri": tokenURI,
	})
	return raw, key
}

func mustPKCS8(t *testing.T, key *rsa.PrivateKey) []byte {
	t.Helper()
	b, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestSendFlow(t *testing.T) {
	var tokenCalls, sendCalls atomic.Int32
	var key *rsa.PrivateKey
	var lastBody map[string]any
	mux := http.NewServeMux()
	srv := httptest.NewServer(mux)
	defer srv.Close()

	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		tokenCalls.Add(1)
		body, _ := io.ReadAll(r.Body)
		form, _ := url.ParseQuery(string(body))
		if form.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" {
			t.Errorf("grant_type: %q", form.Get("grant_type"))
		}
		// Talep anahtarla imzalı ve doğru kapsamda olmalı.
		claims := jwt.MapClaims{}
		if _, err := jwt.ParseWithClaims(form.Get("assertion"), claims, func(*jwt.Token) (any, error) { return &key.PublicKey, nil }); err != nil {
			t.Errorf("assertion doğrulanamadı: %v", err)
		}
		if claims["scope"] != scope || claims["aud"] != srv.URL+"/token" {
			t.Errorf("claims: %v", claims)
		}
		_, _ = w.Write([]byte(`{"access_token":"erisim-1","expires_in":3600}`))
	})
	mux.HandleFunc("/send", func(w http.ResponseWriter, r *http.Request) {
		sendCalls.Add(1)
		if r.Header.Get("Authorization") != "Bearer erisim-1" {
			t.Errorf("auth: %q", r.Header.Get("Authorization"))
		}
		_ = json.NewDecoder(r.Body).Decode(&lastBody)
		msg := lastBody["message"].(map[string]any)
		switch msg["token"] {
		case "kaldirilmis-cihaz":
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":404,"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}`))
		case "bozuk-istek":
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"Invalid value at 'message.data'"}}`))
		default:
			_, _ = w.Write([]byte(`{"name":"projects/arvend-test/messages/1"}`))
		}
	})

	raw, k := testServiceAccount(t, srv.URL+"/token")
	key = k
	c, err := New(raw, srv.Client())
	if err != nil {
		t.Fatal(err)
	}
	c.sendURL = srv.URL + "/send"
	ctx := context.Background()

	if err := c.Send(ctx, Message{Token: "cihaz-1", Title: "Plan ataması", Body: "Kaba inşaat", Tag: "n1", Data: map[string]string{"action_target": "/projeler/p1"}}); err != nil {
		t.Fatal(err)
	}
	msg := lastBody["message"].(map[string]any)
	if msg["notification"].(map[string]any)["title"] != "Plan ataması" ||
		msg["data"].(map[string]any)["action_target"] != "/projeler/p1" ||
		msg["android"].(map[string]any)["notification"].(map[string]any)["tag"] != "n1" {
		t.Errorf("gövde: %v", lastBody)
	}
	// İkinci gönderim önbellekteki belirteci kullanır.
	if err := c.Send(ctx, Message{Token: "cihaz-2", Title: "t", Body: "b"}); err != nil {
		t.Fatal(err)
	}
	if tokenCalls.Load() != 1 || sendCalls.Load() != 2 {
		t.Errorf("belirteç %d kez, gönderim %d kez", tokenCalls.Load(), sendCalls.Load())
	}
	if err := c.Send(ctx, Message{Token: "kaldirilmis-cihaz", Title: "t", Body: "b"}); !errors.Is(err, ErrUnregistered) {
		t.Errorf("kaldırılmış cihaz ErrUnregistered vermeli: %v", err)
	}
	// Token dışı bir alan hatası cihazı sildirmesin.
	if err := c.Send(ctx, Message{Token: "bozuk-istek", Title: "t", Body: "b"}); err == nil || errors.Is(err, ErrUnregistered) {
		t.Errorf("alan hatası cihaz silmemeli: %v", err)
	}
}

func TestNewRejectsIncompleteKeyFile(t *testing.T) {
	if _, err := New([]byte(`{"project_id":"x"}`), nil); err == nil || !strings.Contains(err.Error(), "eksik") {
		t.Errorf("eksik alanlı dosya reddedilmeli: %v", err)
	}
	if _, err := New([]byte(`not json`), nil); err == nil {
		t.Error("bozuk JSON reddedilmeli")
	}
}
