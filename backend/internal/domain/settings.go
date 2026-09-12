package domain

type SmtpSettings struct {
	Host        string
	Port        int
	Username    string
	Password    string // çözülmüş (plaintext) şifre -- yalnızca gönderim için, hiçbir API response'una yazılmaz
	PasswordSet bool
	FromEmail   string
	FromName    string
	UseTLS      bool
	Configured  bool
}
