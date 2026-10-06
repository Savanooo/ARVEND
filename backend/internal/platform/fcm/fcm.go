// Package fcm, Firebase Cloud Messaging HTTP v1 istemcisi: hizmet hesabı
// anahtarıyla OAuth erişim belirteci alır (JWT bearer akışı) ve tek bir
// cihaza bildirim gönderir. Bağımlılık eklememek için Google'ın oauth2
// kitaplığı yerine akış elle (golang-jwt ile) yazıldı -- yalnızca bu iki
// HTTP çağrısı.
package fcm

import (
	"bytes"
	"context"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	scope          = "https://www.googleapis.com/auth/firebase.messaging"
	defaultSendURL = "https://fcm.googleapis.com/v1/projects/%s/messages:send"
)

// ErrUnregistered: token artık geçersiz (uygulama kaldırıldı, token
// yenilendi). Çağıran cihaz kaydını silmeli.
var ErrUnregistered = errors.New("fcm: cihaz kaydı geçersiz")

// serviceAccount: Firebase konsolundan indirilen JSON'un kullandığımız alanları.
type serviceAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

// Message: tek bir cihaza gidecek bildirim.
type Message struct {
	Token string
	Title string
	Body  string
	// Tag: aynı etiketli yeni bildirim telefondakinin yerine geçer
	// (gruplanan bildirim büyüdüğünde ikinci bir kart açılmasın).
	Tag  string
	Data map[string]string
}

type Client struct {
	projectID   string
	clientEmail string
	tokenURI    string
	sendURL     string
	key         *rsa.PrivateKey
	http        *http.Client

	mu          sync.Mutex
	accessToken string
	expires     time.Time
}

// NewFromFile: hizmet hesabı JSON dosyasından istemci.
func NewFromFile(path string) (*Client, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("fcm: anahtar dosyası okunamadı: %w", err)
	}
	return New(raw, nil)
}

// New: hizmet hesabı JSON'undan istemci. httpClient nil ise 15 sn zaman
// aşımlı varsayılan kullanılır.
func New(serviceAccountJSON []byte, httpClient *http.Client) (*Client, error) {
	var sa serviceAccount
	if err := json.Unmarshal(serviceAccountJSON, &sa); err != nil {
		return nil, fmt.Errorf("fcm: anahtar dosyası geçersiz: %w", err)
	}
	if sa.ProjectID == "" || sa.ClientEmail == "" || sa.PrivateKey == "" || sa.TokenURI == "" {
		return nil, errors.New("fcm: anahtar dosyasında project_id/client_email/private_key/token_uri eksik")
	}
	key, err := jwt.ParseRSAPrivateKeyFromPEM([]byte(sa.PrivateKey))
	if err != nil {
		return nil, fmt.Errorf("fcm: özel anahtar okunamadı: %w", err)
	}
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 15 * time.Second}
	}
	return &Client{
		projectID:   sa.ProjectID,
		clientEmail: sa.ClientEmail,
		tokenURI:    sa.TokenURI,
		sendURL:     fmt.Sprintf(defaultSendURL, sa.ProjectID),
		key:         key,
		http:        httpClient,
	}, nil
}

// ProjectID: kayıtlarda/loglarda hangi Firebase projesine gidildiği.
func (c *Client) ProjectID() string { return c.projectID }

// token: önbellekteki erişim belirteci (bitmesine 5 dk kala yenilenir).
func (c *Client) token(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.accessToken != "" && time.Until(c.expires) > 5*time.Minute {
		return c.accessToken, nil
	}
	now := time.Now()
	assertion, err := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{
		"iss":   c.clientEmail,
		"scope": scope,
		"aud":   c.tokenURI,
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	}).SignedString(c.key)
	if err != nil {
		return "", fmt.Errorf("fcm: imza: %w", err)
	}
	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {assertion},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.tokenURI, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := c.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("fcm: erişim belirteci alınamadı: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("fcm: erişim belirteci reddedildi (%d): %s", resp.StatusCode, truncate(body))
	}
	var tok struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &tok); err != nil || tok.AccessToken == "" {
		return "", fmt.Errorf("fcm: erişim belirteci yanıtı okunamadı: %s", truncate(body))
	}
	c.accessToken = tok.AccessToken
	c.expires = now.Add(time.Duration(tok.ExpiresIn) * time.Second)
	return c.accessToken, nil
}

// Send: tek cihaza bildirim. Token geçersizse ErrUnregistered.
func (c *Client) Send(ctx context.Context, m Message) error {
	access, err := c.token(ctx)
	if err != nil {
		return err
	}
	androidNotif := map[string]any{"channel_id": "arvend_bildirimler"}
	if m.Tag != "" {
		androidNotif["tag"] = m.Tag
	}
	payload := map[string]any{
		"message": map[string]any{
			"token":        m.Token,
			"notification": map[string]string{"title": m.Title, "body": m.Body},
			"data":         m.Data,
			"android": map[string]any{
				"priority":     "high",
				"notification": androidNotif,
			},
		},
	}
	buf, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.sendURL, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("fcm: gönderilemedi: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	if isUnregistered(resp.StatusCode, body) {
		return ErrUnregistered
	}
	if resp.StatusCode == http.StatusUnauthorized {
		// Belirteç beklenmedik biçimde düşmüş: bir sonraki gönderim yenilesin.
		c.mu.Lock()
		c.accessToken = ""
		c.mu.Unlock()
	}
	return fmt.Errorf("fcm: gönderim reddedildi (%d): %s", resp.StatusCode, truncate(body))
}

// isUnregistered: FCM v1 hata gövdesindeki errorCode'a bakar. UNREGISTERED
// (404) kaldırılmış uygulama; INVALID_ARGUMENT yalnızca token'la ilgiliyse
// (yanlış biçimli token) kayıt silinir -- başka bir alan hatası yüzünden
// sağlam cihazlar silinmesin.
func isUnregistered(status int, body []byte) bool {
	var e struct {
		Error struct {
			Status  string `json:"status"`
			Message string `json:"message"`
			Details []struct {
				ErrorCode string `json:"errorCode"`
			} `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &e); err != nil {
		return status == http.StatusNotFound
	}
	for _, d := range e.Error.Details {
		if d.ErrorCode == "UNREGISTERED" {
			return true
		}
	}
	if status == http.StatusNotFound {
		return true
	}
	return e.Error.Status == "INVALID_ARGUMENT" && strings.Contains(strings.ToLower(e.Error.Message), "registration token")
}

func truncate(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 300 {
		return s[:300] + "…"
	}
	return s
}
