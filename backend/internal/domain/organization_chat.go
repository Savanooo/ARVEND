package domain

import "time"

// Firma Grubu (migration 0077): firma başına TEK grup -- firmanın aktif
// çalışanları yazar ve okur; taşeron hesapları grubu hiç görmez.

// ChatMessage: grubun bir mesajı. Silinmiş mesajda (Deleted) Body boş ve
// Photo nil döner -- içerik veritabanında kalır ama hiçbir yanıta girmez.
type ChatMessage struct {
	ID         string
	Seq        int64
	AuthorID   *string // hesap fiziksel silindiyse nil
	AuthorName string
	Body       string
	Photo      *ChatPhoto
	CreatedAt  time.Time
	Deleted    bool
	DeletedAt  *time.Time
}

// ChatPhoto: mesajın fotoğraf ekinin dışarı açılan üst verisi (anahtar ve
// özet dışarı çıkmaz).
type ChatPhoto struct {
	MIMEType  string
	SizeBytes int64
}

const (
	// ChatMaxBodyRunes: mesaj metni sınırı (migration 0077 CHECK ile aynı).
	ChatMaxBodyRunes = 4000

	// ChatActionTarget: bildirime dokununca açılan mobil ekran.
	ChatActionTarget = "/diger/firma-grubu"

	// ChatPushTag: Firma Grubu bildirimleri telefonda TEK kartta durur --
	// okunduktan sonra açılan yeni bildirim satırı da (farklı kimlik) aynı
	// kartın yerine geçer.
	ChatPushTag = "firma-grubu"
)

// CanModerateChat: herkesin mesajını silebilen roller (Sahip/Yönetici).
// Diğerleri yalnızca kendi mesajını siler.
func CanModerateChat(orgRoleCode string) bool {
	return orgRoleCode == OrgRoleOwner || orgRoleCode == OrgRoleAdmin
}
