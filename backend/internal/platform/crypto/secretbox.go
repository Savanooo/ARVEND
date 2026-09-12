// Package crypto, ayarlar tablosunda saklanan hassas alanları (ör. SMTP
// şifresi) DB'de düz metin durmasın diye AES-256-GCM ile şifreler. Anahtar
// .env'deki SETTINGS_ENCRYPTION_KEY'den gelir; şifreli değer DB'ye yazılır.
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
)

type SecretBox struct {
	gcm cipher.AEAD
}

func NewSecretBox(base64Key string) (*SecretBox, error) {
	if base64Key == "" {
		return nil, errors.New("SETTINGS_ENCRYPTION_KEY ayarlanmamış")
	}
	key, err := base64.StdEncoding.DecodeString(base64Key)
	if err != nil {
		return nil, fmt.Errorf("SETTINGS_ENCRYPTION_KEY base64 değil: %w", err)
	}
	if len(key) != 32 {
		return nil, errors.New("SETTINGS_ENCRYPTION_KEY 32 byte (base64) olmalı")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &SecretBox{gcm: gcm}, nil
}

func (s *SecretBox) Encrypt(plaintext string) (string, error) {
	nonce := make([]byte, s.gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return "", err
	}
	sealed := s.gcm.Seal(nonce, nonce, []byte(plaintext), nil)
	return base64.StdEncoding.EncodeToString(sealed), nil
}

func (s *SecretBox) Decrypt(encoded string) (string, error) {
	if encoded == "" {
		return "", nil
	}
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "", err
	}
	nonceSize := s.gcm.NonceSize()
	if len(data) < nonceSize {
		return "", errors.New("geçersiz şifreli veri")
	}
	nonce, ciphertext := data[:nonceSize], data[nonceSize:]
	plain, err := s.gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return "", err
	}
	return string(plain), nil
}
