// Proje ve teklif olay tiplerinin Türkçe etiketleri -- TEK kaynak. Proje
// detayının Aktivite sekmesi (ProfitabilitySection), teklif zaman
// çizelgesi (ActivityTimeline) ve ana sayfanın "Son Hareketler" paneli
// buradan okur; mobil lib/core/utils/event_labels.dart bunun kopyasıdır.
// next/* ya da React içermez (node testleri içe aktarabilir).

export type EventSource = "project" | "offer";

// Bilinmeyen (sonradan eklenmiş) bir olay tipi ham kod olarak değil bu
// nötr metinle görünür.
export const UNKNOWN_EVENT_LABEL = "Kayıt güncellendi";

// project_events.event_type -> etiket. İlk blok proje detayındaki eski
// haritanın BİREBİR aynısıdır; sonrakiler backend domain.ProjectEvent*
// sabitlerinin (satın alma, bütçe, sözleşme, taşeron) karşılıklarıdır.
export const PROJECT_EVENT_LABELS: Record<string, string> = {
  project_created: "Proje oluşturuldu",
  project_updated: "Proje bilgileri güncellendi",
  project_status_changed: "Proje durumu değişti",
  payment_plan_created: "Ödeme planı kalemi eklendi",
  payment_plan_updated: "Ödeme planı kalemi güncellendi",
  payment_plan_cancelled: "Ödeme planı kalemi iptal edildi",
  collection_received: "Tahsilat kaydedildi",
  collection_voided: "Tahsilat iptal edildi",
  expense_added: "Masraf eklendi",
  expense_updated: "Masraf güncellendi",
  expense_voided: "Masraf iptal edildi",
  invoice_created: "Fatura eklendi",
  invoice_status_changed: "Fatura durumu değişti",
  subcontractor_added: "Taşeron eklendi",
  subcontractor_updated: "Taşeron güncellendi",
  subcontractor_payment_added: "Taşerona ödeme yapıldı",
  subcontractor_payment_voided: "Taşeron ödemesi iptal edildi",
  // Faz 7: operasyon olayları (aynı zaman çizelgesinde finans olaylarıyla birlikte).
  member_assigned: "Ekibe personel atandı",
  member_removed: "Personel ekipten çıkarıldı",
  schedule_created: "Planlama aşaması eklendi",
  schedule_updated: "Planlama aşaması güncellendi",
  schedule_completed: "Planlama aşaması tamamlandı",
  task_created: "Görev oluşturuldu",
  task_assigned: "Görev atandı",
  task_completed: "Görev tamamlandı",
  task_updated: "Görev güncellendi",
  file_uploaded: "Dosya yüklendi",
  file_removed: "Dosya silindi",
  photo_uploaded: "Şantiye fotoğrafı yüklendi",
  photo_removed: "Şantiye fotoğrafı silindi",
  note_added: "Not eklendi",
  // Faz 8: ek iş (değişiklik emri) olayları.
  change_order_created: "Ek iş oluşturuldu",
  change_order_updated: "Ek iş güncellendi",
  change_order_sent: "Ek iş müşteriye gönderildi",
  change_order_viewed: "Müşteri ek işi görüntüledi",
  change_order_approved: "Müşteri ek işi onayladı",
  change_order_rejected: "Müşteri ek işi reddetti",
  change_order_cancelled: "Ek iş iptal edildi",
  change_order_superseded: "Ek iş revize edildi",
  change_order_email_sent: "Ek iş e-postası gönderildi",
  change_order_email_failed: "Ek iş e-postası gönderilemedi",
  // Satın alma (talep -> RFQ -> sipariş).
  purchase_request_created: "Satın alma talebi oluşturuldu",
  purchase_request_updated: "Satın alma talebi güncellendi",
  purchase_request_submitted: "Satın alma talebi onaya gönderildi",
  purchase_request_withdrawn: "Satın alma talebi geri çekildi",
  purchase_request_approved: "Satın alma talebi onaylandı",
  purchase_request_rejected: "Satın alma talebi reddedildi",
  purchase_request_cancelled: "Satın alma talebi iptal edildi",
  rfq_created: "RFQ oluşturuldu",
  rfq_updated: "RFQ güncellendi",
  rfq_issued: "RFQ tedarikçilere gönderildi",
  rfq_closed: "RFQ kapatıldı",
  rfq_cancelled: "RFQ iptal edildi",
  rfq_awarded: "RFQ sonuçlandırıldı",
  quotation_created: "Tedarikçi teklifi eklendi",
  quotation_updated: "Tedarikçi teklifi güncellendi",
  quotation_deleted: "Tedarikçi teklifi silindi",
  purchase_order_created: "Sipariş oluşturuldu",
  purchase_order_updated: "Sipariş güncellendi",
  purchase_order_approved: "Sipariş onaylandı",
  purchase_order_cancelled: "Sipariş iptal edildi",
  purchase_order_closed: "Sipariş kapatıldı",
  // Bütçe ve maliyet kontrolü.
  budget_created: "Bütçe oluşturuldu",
  budget_baselined: "Bütçe onaylandı (baseline)",
  budget_line_created: "Bütçe kalemi eklendi",
  budget_line_updated: "Bütçe kalemi güncellendi",
  budget_line_deleted: "Bütçe kalemi silindi",
  budget_adjustment_created: "Bütçe revizyonu oluşturuldu",
  budget_adjustment_approved: "Bütçe revizyonu onaylandı",
  budget_adjustment_rejected: "Bütçe revizyonu reddedildi",
  wbs_created: "İş kırılımı kalemi eklendi",
  wbs_updated: "İş kırılımı kalemi güncellendi",
  wbs_archived: "İş kırılımı kalemi arşivlendi",
  commitment_created: "Taahhüt eklendi",
  commitment_voided: "Taahhüt iptal edildi",
  forecast_updated: "Maliyet tahmini güncellendi",
  // Proje sözleşmesi.
  contract_created: "Sözleşme oluşturuldu",
  contract_updated: "Sözleşme güncellendi",
  contract_notes_updated: "Sözleşme notları güncellendi",
  contract_activated: "Sözleşme aktifleştirildi",
  contract_completed: "Sözleşme tamamlandı",
  contract_cancelled: "Sözleşme iptal edildi",
  contract_terminated: "Sözleşme feshedildi",
  // Taşeron sözleşmeleri, değişiklik emirleri, hakedişler ve ödemeler.
  subcontract_created: "Taşeron sözleşmesi oluşturuldu",
  subcontract_updated: "Taşeron sözleşmesi güncellendi",
  subcontract_activated: "Taşeron sözleşmesi aktifleştirildi",
  subcontract_completed: "Taşeron sözleşmesi tamamlandı",
  subcontract_cancelled: "Taşeron sözleşmesi iptal edildi",
  subcontract_terminated: "Taşeron sözleşmesi feshedildi",
  subcontract_change_order_created: "Taşeron değişiklik emri oluşturuldu",
  subcontract_change_order_updated: "Taşeron değişiklik emri güncellendi",
  subcontract_change_order_submitted: "Taşeron değişiklik emri onaya gönderildi",
  subcontract_change_order_approved: "Taşeron değişiklik emri onaylandı",
  subcontract_change_order_rejected: "Taşeron değişiklik emri reddedildi",
  subcontract_change_order_cancelled: "Taşeron değişiklik emri iptal edildi",
  subcontract_progress_claim_created: "Taşeron hakedişi oluşturuldu",
  subcontract_progress_claim_updated: "Taşeron hakedişi güncellendi",
  subcontract_progress_claim_submitted: "Taşeron hakedişi onaya gönderildi",
  subcontract_progress_claim_certified: "Taşeron hakedişi onaylandı",
  subcontract_progress_claim_rejected: "Taşeron hakedişi reddedildi",
  subcontract_progress_claim_cancelled: "Taşeron hakedişi iptal edildi",
  subcontract_payment_made: "Taşerona ödeme yapıldı",
  subcontract_payment_void: "Taşeron ödemesi iptal edildi",
};

// offer_events.event_type -> revizyon numarası BİLİNMEDİĞİNDE kullanılan
// etiket (teklif zaman çizelgesi revizyon numarası bilinen olaylarda
// "Revizyon 2 müşteriye gönderildi" gibi daha ayrıntılı bir metin kurar).
export const OFFER_EVENT_LABELS: Record<string, string> = {
  offer_created: "Teklif oluşturuldu",
  offer_updated: "Teklif düzenlendi",
  revision_created: "Yeni revizyon oluşturuldu",
  revision_sent: "Teklif müşteriye gönderildi",
  share_link_created: "Paylaşım linki oluşturuldu",
  share_link_revoked: "Paylaşım linki iptal edildi",
  customer_viewed: "Müşteri teklifi görüntüledi",
  customer_accepted: "Müşteri teklifi kabul etti",
  customer_rejected: "Müşteri teklifi reddetti",
  email_sent: "E-posta gönderildi",
  email_failed: "E-posta gönderilemedi",
  offer_cancelled: "Teklif arşivlendi / iptal edildi",
  project_created: "Teklif projeye dönüştürüldü",
};

/** Olayın Türkçe etiketi; bilinmeyen tipte "Kayıt güncellendi". */
export function eventLabel(source: EventSource | string, type: string): string {
  const map = source === "offer" ? OFFER_EVENT_LABELS : PROJECT_EVENT_LABELS;
  return map[type] ?? UNKNOWN_EVENT_LABEL;
}
