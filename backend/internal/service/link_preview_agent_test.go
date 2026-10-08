package service

import "testing"

func TestIsLinkPreviewAgent(t *testing.T) {
	previews := []string{
		"WhatsApp/2.24.20.89 A",
		"WhatsApp/2.2437.7 i",
		"TelegramBot (like TwitterBot)",
		"facebookexternalhit/1.1 Facebot Twitterbot/1.0", // iMessage
		"Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)",
		"Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/120.0 Safari/537.36",
		"Viber/21.0",
		"Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)",
	}
	for _, ua := range previews {
		if !IsLinkPreviewAgent(ua) {
			t.Errorf("önizleme sayılmalı: %q", ua)
		}
	}
	people := []string{
		"",
		"node",
		"Mozilla/5.0 (Linux; Android 14; SM-A546E) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36",
		"Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1",
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0",
		// Model adında "bot" geçen telefonlar.
		"Mozilla/5.0 (Linux; Android 10; CUBOT_X19 Build/QP1A.190711.020) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
		"Mozilla/5.0 (Linux; Android 13; CUBOT KINGKONG 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Mobile Safari/537.36",
	}
	for _, ua := range people {
		if IsLinkPreviewAgent(ua) {
			t.Errorf("insan sayılmalı: %q", ua)
		}
	}
}
