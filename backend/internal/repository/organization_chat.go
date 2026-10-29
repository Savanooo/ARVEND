package repository

import (
	"github.com/Savanooo/ARVEND/backend/internal/domain"
	"github.com/Savanooo/ARVEND/backend/internal/repository/sqlc"
)

// ToDomainChatMessage: Firma Grubu mesajı (migration 0077). Silinmiş
// mesajın metni ve fotoğrafı burada düşer -- hiçbir yanıt yolu içeriği
// yanlışlıkla taşıyamasın.
func ToDomainChatMessage(m sqlc.OrganizationChatMessage, authorName string) domain.ChatMessage {
	dm := domain.ChatMessage{
		ID:         m.ID.String(),
		Seq:        m.Seq,
		AuthorName: authorName,
		CreatedAt:  m.CreatedAt.Time,
	}
	if m.AuthorID.Valid {
		s := m.AuthorID.String()
		dm.AuthorID = &s
	}
	if m.DeletedAt.Valid {
		t := m.DeletedAt.Time
		dm.Deleted = true
		dm.DeletedAt = &t
		return dm
	}
	dm.Body = m.Body
	if m.PhotoKey != nil && m.PhotoMime != nil {
		p := &domain.ChatPhoto{MIMEType: *m.PhotoMime}
		if m.PhotoSize != nil {
			p.SizeBytes = *m.PhotoSize
		}
		dm.Photo = p
	}
	return dm
}
