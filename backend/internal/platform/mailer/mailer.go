// Package mailer, ayarlar tablosundaki SMTP bilgileriyle düz metin/HTML
// e-posta gönderir. Port 465 için örtük (implicit) TLS, diğer portlar için
// STARTTLS varsayılır -- yaygın sağlayıcıların (Gmail, Resend, SendGrid vb.
// SMTP arayüzü) ikisini de bu şekilde bekler.
package mailer

import (
	"crypto/tls"
	"errors"
	"fmt"
	"net/smtp"
	"strings"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

type Message struct {
	To      string
	Subject string
	Body    string // düz metin
}

func Send(settings domain.SmtpSettings, msg Message) error {
	if !settings.Configured {
		return errors.New("SMTP ayarları yapılandırılmamış")
	}
	if msg.To == "" {
		return errors.New("alıcı e-posta adresi boş olamaz")
	}

	addr := fmt.Sprintf("%s:%d", settings.Host, settings.Port)
	from := settings.FromEmail
	fromHeader := from
	if settings.FromName != "" {
		fromHeader = fmt.Sprintf("%s <%s>", settings.FromName, from)
	}

	raw := strings.Join([]string{
		"From: " + fromHeader,
		"To: " + msg.To,
		"Subject: " + msg.Subject,
		"MIME-Version: 1.0",
		"Content-Type: text/plain; charset=UTF-8",
		"",
		msg.Body,
	}, "\r\n")

	var auth smtp.Auth
	if settings.Username != "" {
		auth = smtp.PlainAuth("", settings.Username, settings.Password, settings.Host)
	}

	if settings.Port == 465 {
		return sendImplicitTLS(addr, settings.Host, auth, from, []string{msg.To}, []byte(raw))
	}
	return smtp.SendMail(addr, auth, from, []string{msg.To}, []byte(raw))
}

func sendImplicitTLS(addr, host string, auth smtp.Auth, from string, to []string, body []byte) error {
	conn, err := tls.Dial("tcp", addr, &tls.Config{ServerName: host})
	if err != nil {
		return err
	}
	defer conn.Close()

	client, err := smtp.NewClient(conn, host)
	if err != nil {
		return err
	}
	defer client.Close()

	if auth != nil {
		if err := client.Auth(auth); err != nil {
			return err
		}
	}
	if err := client.Mail(from); err != nil {
		return err
	}
	for _, addr := range to {
		if err := client.Rcpt(addr); err != nil {
			return err
		}
	}
	w, err := client.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write(body); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return client.Quit()
}
