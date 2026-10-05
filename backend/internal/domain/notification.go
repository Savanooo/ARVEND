package domain

import "time"

// Notification, uygulama-içi (in-app) bir bildirim kaydıdır -- Faz 1:
// yalnızca kalıcılık + okuma, GERÇEK push (FCM/APNs) YOK (bkz. migration
// 0042 başlık yorumu). entity_id KASITLI OLARAK FK TAŞIMAZ -- EntityType'a
// göre farklı tablolara işaret eder (polimorfik referans).
//
// Title/Body ASLA tutar veya taşeron/tedarikçi/müşteri adı gibi hassas
// ticari veri İÇERMEZ -- yalnızca varlık numarası/başlığı gibi nötr bir
// referans taşır (bkz. notification_service.go şablonları). Detay için
// kullanıcı ActionTarget'ı açıp kimlik doğrulamalı uygulamadan görür.
type Notification struct {
	ID             string
	OrganizationID string
	UserID         string
	Type           string
	Title          string
	Body           string
	EntityType     string
	EntityID       *string
	ProjectID      *string
	ActionTarget   string
	ReadAt         *time.Time
	CreatedAt      time.Time
}

// Bildirim türleri -- her biri tam olarak TEK bir zaten-var-olan senkron
// iş akışının başarılı tamamlanma noktasına bağlanır (bkz. Faz 1
// araştırması: hangi servis metodunun hangi satırına bağlandığı için
// notification_service.go'daki çağrı noktalarına bakın). Bu liste
// KASITLI OLARAK dar tutulmuştur -- yalnızca "birine atandı", "onay/red
// kararı", ya da "eylem gerektiren" olaylar; her CRUD olayı DEĞİL (spam'den
// kaçınma ilkesi).
const (
	NotificationTaskAssigned = "task_assigned"
	// Göreve not yazıldı / durum değişti / tamamlandı (migration 0051):
	// görevi atayana ve atanan kişiye -- yazan hariç.
	NotificationTaskUpdated                     = "task_updated"
	NotificationTaskCompleted                   = "task_completed"
	NotificationOfferAccepted                   = "offer_accepted"
	NotificationOfferRejected                   = "offer_rejected"
	NotificationSubcontractActivated            = "subcontract_activated"
	NotificationSubcontractChangeOrderSubmitted = "subcontract_change_order_submitted"
	NotificationSubcontractChangeOrderApproved  = "subcontract_change_order_approved"
	NotificationSubcontractChangeOrderRejected  = "subcontract_change_order_rejected"
	NotificationProgressClaimSubmitted          = "progress_claim_submitted"
	NotificationProgressClaimCertified          = "progress_claim_certified"
	NotificationProgressClaimRejected           = "progress_claim_rejected"
	NotificationPurchaseRequestSubmitted        = "purchase_request_submitted"
	NotificationPurchaseRequestApproved         = "purchase_request_approved"
	NotificationPurchaseRequestRejected         = "purchase_request_rejected"
	NotificationRFQAwarded                      = "rfq_awarded"
	NotificationPurchaseOrderApproved           = "purchase_order_approved"
	NotificationPurchaseOrderCancelled          = "purchase_order_cancelled"
	// Planlama aşamasına sorumlu atandı (migration 0052): o personele.
	NotificationScheduleAssigned = "schedule_assigned"
	// Projeye fotoğraf/dosya yüklendi: projenin yöneticilerine (yükleyen
	// hariç). Gruplanır -- art arda yüklemeler tek bildirimde sayılır.
	NotificationPhotoUploaded = "photo_uploaded"
	NotificationFileUploaded  = "file_uploaded"
)

// Varlık türleri -- mobil/web istemcinin ActionTarget'ı yorumlamadan,
// EntityType'a bakarak doğru simge/liste filtresini seçebilmesi için.
const (
	NotificationEntityTask                   = "task"
	NotificationEntityOffer                  = "offer"
	NotificationEntitySubcontract            = "subcontract"
	NotificationEntitySubcontractChangeOrder = "subcontract_change_order"
	NotificationEntityProgressClaim          = "progress_claim"
	NotificationEntityPurchaseRequest        = "purchase_request"
	NotificationEntityRFQ                    = "rfq"
	NotificationEntityPurchaseOrder          = "purchase_order"
	NotificationEntityScheduleItem           = "schedule_item"
	NotificationEntityProjectPhoto           = "project_photo"
	NotificationEntityProjectFile            = "project_file"
)
