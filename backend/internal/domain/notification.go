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
//
// TEK istisna müşterinin paylaşım linkindeki hareketleridir (teklif/ek iş
// kararı, teklifin ilk açılışı -- bkz. customer_link_notify.go): gövde
// teklif no + müşteri adı + tutar taşır. Ürün sahibinin isteği (2026-10):
// "müşteri onaylayınca bildirim gelsin" -- telefonda HANGİ teklifin
// kazanıldığı bir bakışta görünmeli. Alıcıların hepsi o kaydı zaten
// açabilen kişilerdir (okuma izni + proje erişimi süzülür), bildirim
// yetkisi olmayana veri taşımaz.
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
	NotificationTaskUpdated   = "task_updated"
	NotificationTaskCompleted = "task_completed"
	// Teklif kararı -- müşterinin linkinden ya da personelin durum
	// değişikliğinden (UpdateStatus): bkz. resolveOfferDecisionAudience.
	NotificationOfferAccepted = "offer_accepted"
	NotificationOfferRejected = "offer_rejected"
	// Müşteri teklif linkini, revizyon kararını beklerken İLK kez açtı
	// (revizyon başına bir kez): teklifi hazırlayana.
	NotificationOfferViewed = "offer_viewed"
	// Ek işte müşteri kararı -- linkten ya da personelin kaydı (record-
	// decision): bkz. resolveChangeOrderDecisionAudience.
	NotificationChangeOrderApproved             = "change_order_approved"
	NotificationChangeOrderRejected             = "change_order_rejected"
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
	// Bütçe revizyonu oluşturuldu (migration 0062): projede
	// projects.budget.approve taşıyanlara -- oluşturan hariç (kendi
	// revizyonuna zaten karar veremez).
	NotificationBudgetAdjustmentSubmitted = "budget_adjustment_submitted"
	// Planlama aşamasına sorumlu atandı (migration 0052): o personele.
	NotificationScheduleAssigned = "schedule_assigned"
	// Projeye fotoğraf/dosya yüklendi: projenin yöneticilerine (yükleyen
	// hariç). Gruplanır -- art arda yüklemeler tek bildirimde sayılır.
	NotificationPhotoUploaded = "photo_uploaded"
	NotificationFileUploaded  = "file_uploaded"
	// Masraf onayı (migration 0060): yeni/düzenlenen masraf projenin
	// onaylayıcılarına (gruplanır, giren hariç); karar masrafı girene.
	NotificationExpensePendingApproval = "expense_pending_approval"
	NotificationExpenseApproved        = "expense_approved"
	NotificationExpenseRejected        = "expense_rejected"
)

// Varlık türleri -- mobil/web istemcinin ActionTarget'ı yorumlamadan,
// EntityType'a bakarak doğru simge/liste filtresini seçebilmesi için.
const (
	NotificationEntityTask                   = "task"
	NotificationEntityOffer                  = "offer"
	NotificationEntityChangeOrder            = "change_order"
	NotificationEntitySubcontract            = "subcontract"
	NotificationEntitySubcontractChangeOrder = "subcontract_change_order"
	NotificationEntityProgressClaim          = "progress_claim"
	NotificationEntityPurchaseRequest        = "purchase_request"
	NotificationEntityRFQ                    = "rfq"
	NotificationEntityPurchaseOrder          = "purchase_order"
	NotificationEntityBudgetAdjustment       = "budget_adjustment"
	NotificationEntityScheduleItem           = "schedule_item"
	NotificationEntityProjectPhoto           = "project_photo"
	NotificationEntityProjectFile            = "project_file"
	NotificationEntityProjectExpense         = "project_expense"
)
