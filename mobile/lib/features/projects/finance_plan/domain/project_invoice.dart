import '../../../../core/widgets/status_badge.dart';
import 'finance_dates.dart';

/// Proje faturası -- backend `invoiceResponse`
/// (`GET /projects/{id}/invoices`) ile birebir. Sunucu sırası: fatura
/// tarihi (yeni -> eski), sonra oluşturulma.
///
/// Backend'de fatura ALANLARINI düzenleyen bir uç YOKTUR (web'de de yok):
/// oluşturulduktan sonra yalnızca durum değişir
/// (`PUT /invoices/{invoiceId}/status`).
class ProjectInvoice {
  const ProjectInvoice({
    required this.id,
    required this.invoiceNo,
    required this.invoiceType,
    required this.invoiceDate,
    required this.dueDate,
    required this.amount,
    required this.currency,
    required this.status,
    this.customerName = '',
    this.notes = '',
    this.createdAt = '',
  });

  final String id;
  final String invoiceNo;

  /// `sales` | `purchase`.
  final String invoiceType;

  /// "YYYY-MM-DD".
  final String invoiceDate;

  /// "YYYY-MM-DD" ya da null.
  final String? dueDate;
  final double amount;
  final String currency;
  final String status;
  final String customerName;
  final String notes;

  /// RFC3339.
  final String createdAt;

  factory ProjectInvoice.fromJson(Map<String, dynamic> json) => ProjectInvoice(
        id: json['id'] as String,
        invoiceNo: json['invoice_no'] as String? ?? '',
        invoiceType: json['invoice_type'] as String? ?? kInvoiceTypeSales,
        invoiceDate: json['invoice_date'] as String? ?? '',
        dueDate: _nonEmpty(json['due_date'] as String?),
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'TRY',
        status: json['status'] as String? ?? kInvoiceDraft,
        customerName: json['customer_name'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
      );

  bool get isSales => invoiceType == kInvoiceTypeSales;
  bool get isCancelled => status == kInvoiceCancelled;

  /// Ana sayfadaki "satış faturasının vadesi geçti" kuralının AYNISI
  /// (backend dashboard.sql): satış faturası, durumu Kesildi/Gönderildi ve
  /// vadesi [today]'den önce. Yalnızca gösterim içindir.
  bool isOverdueOn(DateTime today) {
    if (!isSales) return false;
    if (status != kInvoiceIssued && status != kInvoiceSent) return false;
    final days = daysUntilDue(dueDate, today);
    return days != null && days < 0;
  }
}

/// `POST /projects/{id}/invoices` gövdesi -- backend `invoiceRequest` ile
/// birebir. Yeni fatura web'deki gibi "Taslak" başlar; para birimi projenin
/// para birimidir (backend farklısını reddeder). Müşteri adı boşsa backend
/// proje müşterisini yazar.
class InvoiceInput {
  const InvoiceInput({
    required this.invoiceNo,
    required this.invoiceType,
    required this.invoiceDate,
    this.dueDate,
    required this.amount,
    required this.currency,
    this.customerName = '',
    this.notes = '',
  });

  final String invoiceNo;
  final String invoiceType;
  final String invoiceDate;
  final String? dueDate;
  final double amount;
  final String currency;
  final String customerName;
  final String notes;

  Map<String, dynamic> toJson() => {
        'invoice_no': invoiceNo.trim(),
        'invoice_type': invoiceType,
        'invoice_date': invoiceDate,
        'due_date': dueDate,
        'amount': amount,
        'currency': currency,
        'status': kInvoiceDraft,
        'customer_name': customerName.trim(),
        'notes': notes.trim(),
      };
}

const kInvoiceTypeSales = 'sales';
const kInvoiceTypePurchase = 'purchase';

/// Web ile aynı: "Satış" / "Alış".
const Map<String, String> kInvoiceTypeLabels = {
  kInvoiceTypeSales: 'Satış',
  kInvoiceTypePurchase: 'Alış',
};

String invoiceTypeLabel(String type) => kInvoiceTypeLabels[type] ?? type;

const kInvoiceDraft = 'draft';
const kInvoiceIssued = 'issued';
const kInvoiceSent = 'sent';
const kInvoicePaid = 'paid';
const kInvoiceCancelled = 'cancelled';

/// Web `INVOICE_STATUS` (lib/status.ts) ile aynı etiketler, tonlar ve sıra
/// (web'deki durum seçicisinin seçenek sırası).
const Map<String, (String, StatusTone)> kInvoiceStatuses = {
  kInvoiceDraft: ('Taslak', StatusTone.muted),
  kInvoiceIssued: ('Kesildi', StatusTone.gold),
  kInvoiceSent: ('Gönderildi', StatusTone.info),
  kInvoicePaid: ('Ödendi', StatusTone.success),
  kInvoiceCancelled: ('İptal', StatusTone.danger),
};

String invoiceStatusLabel(String status) => kInvoiceStatuses[status]?.$1 ?? status;

/// Backend'de fatura durumu için bir durum makinesi YOKTUR: web'deki gibi
/// her durum seçilebilir (`ValidInvoiceStatus`). Mobil yalnızca olağan akışın
/// SONRAKİ adımını tek dokunuşluk birincil aksiyon olarak öne çıkarır; diğer
/// geçişler "Durumu Değiştir" ile yapılır.
///
/// - Satış: Taslak -> Kesildi -> Gönderildi -> Ödendi.
/// - Alış: Taslak -> Kesildi -> Ödendi. Tedarikçinin faturası bize gelir;
///   "Gönderildi" adımı anlamsızdır.
/// - Vadesi geçmiş satış faturası ([ProjectInvoice.isOverdueOn]): doğrudan
///   Ödendi -- kırmızı şerit "Ödendi yap" derken birincil düğme
///   "Gönderildi" demesin.
String? nextInvoiceStatus(ProjectInvoice invoice, DateTime today) {
  if (invoice.isOverdueOn(today)) return kInvoicePaid;
  return switch (invoice.status) {
    kInvoiceDraft => kInvoiceIssued,
    kInvoiceIssued => invoice.isSales ? kInvoiceSent : kInvoicePaid,
    kInvoiceSent => kInvoicePaid,
    _ => null,
  };
}

String? _nonEmpty(String? v) => (v == null || v.isEmpty) ? null : v;
