import '../../../../core/utils/event_labels.dart';

/// Teklif olayı (`GET /offers/{id}/events`, backend `offerEventResponse`).
/// Backend sırası: `created_at ASC` (en eski önce) -- web zaman çizelgesi
/// de bu sırayla gösterir.
class OfferEvent {
  const OfferEvent({
    required this.id,
    required this.eventType,
    required this.createdAt,
    this.revisionId,
    this.userId,
    this.metadata = const {},
  });

  final String id;
  final String? revisionId;
  final String eventType;
  final String? userId;
  final Map<String, dynamic> metadata;

  /// RFC3339.
  final String createdAt;

  factory OfferEvent.fromJson(Map<String, dynamic> json) => OfferEvent(
        id: json['id'] as String,
        revisionId: json['revision_id'] as String?,
        eventType: json['event_type'] as String? ?? '',
        userId: json['user_id'] as String?,
        metadata: (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
        createdAt: json['created_at'] as String? ?? '',
      );
}

/// Teklif e-posta kaydı (`GET /offers/{id}/email-logs`, backend
/// `emailLogResponse`). Backend sırası: `sent_at DESC` (en yeni önce).
class OfferEmailLog {
  const OfferEmailLog({
    required this.id,
    required this.revisionId,
    required this.recipient,
    required this.subject,
    required this.status,
    required this.sentAt,
    this.errorMessage = '',
    this.sentBy,
  });

  static const statusSent = 'sent';
  static const statusFailed = 'failed';

  final String id;
  final String revisionId;
  final String recipient;
  final String subject;

  /// `sent` | `failed`.
  final String status;
  final String errorMessage;
  final String? sentBy;

  /// RFC3339.
  final String sentAt;

  bool get isSent => status == statusSent;

  factory OfferEmailLog.fromJson(Map<String, dynamic> json) => OfferEmailLog(
        id: json['id'] as String,
        revisionId: json['revision_id'] as String? ?? '',
        recipient: json['recipient'] as String? ?? '',
        subject: json['subject'] as String? ?? '',
        status: json['status'] as String? ?? statusFailed,
        errorMessage: json['error_message'] as String? ?? '',
        sentBy: json['sent_by'] as String?,
        sentAt: json['sent_at'] as String? ?? '',
      );
}

/// Teklif geçmişi ekranının tek seferde yüklenen verisi: olaylar, e-posta
/// kayıtları ve revizyon kimliği -> revizyon numarası eşlemesi (metinlerde
/// "Revizyon 2" diyebilmek için; web `revisionNoById` ile aynı).
class OfferHistory {
  const OfferHistory({required this.events, required this.emailLogs, required this.revisionNoById});

  final List<OfferEvent> events;
  final List<OfferEmailLog> emailLogs;
  final Map<String, int> revisionNoById;

  int? revisionNoOf(String? revisionId) => revisionId == null ? null : revisionNoById[revisionId];

  /// Müşterinin görüntüleme olayları (web özet satırı: "N görüntülenme ·
  /// ilk … · son …").
  List<OfferEvent> get views => [
        for (final e in events)
          if (e.eventType == 'customer_viewed') e,
      ];
}

/// Olay metninin vurgu tonu -- web `ActivityTimeline.tsx` TONE haritası.
enum OfferEventTone { normal, success, danger, muted, info }

OfferEventTone offerEventTone(String eventType) => switch (eventType) {
      'customer_accepted' || 'project_created' => OfferEventTone.success,
      'customer_rejected' || 'email_failed' => OfferEventTone.danger,
      'share_link_revoked' => OfferEventTone.muted,
      // Web'de gold; mobilde marka rengi durum anlamı taşımaz (bkz.
      // StatusTone) -- bilgi tonu.
      'customer_viewed' => OfferEventTone.info,
      _ => OfferEventTone.normal,
    };

// Türkçe belirtme eki sayının OKUNUŞUNA göre değişir (0'ı, 1'i, 2'yi,
// 3'ü...). 10'un katlarında okunuş "on/yirmi/otuz..." olduğu için son
// basamak tablosu yanlış sonuç verir; onlar ayrıca ele alınır (web
// `ActivityTimeline.tsx` accusative() ile BİREBİR).
const _accByLastDigit = ['ı', 'i', 'yi', 'ü', 'ü', 'i', 'yı', 'yi', 'i', 'u'];
const _accByTens = ['', 'u', 'yi', 'u', 'ı', 'yi', 'ı', 'i', 'i', 'ı'];

String turkishAccusativeSuffix(int n) {
  if (n >= 10 && n < 100 && n % 10 == 0) return _accByTens[n ~/ 10];
  return _accByLastDigit[n % 10];
}

/// Olayın Türkçe metni -- web `ActivityTimeline.tsx` label() ile BİREBİR.
/// Revizyon numarası bilinmiyorsa revizyonsuz metin (ortak
/// `kOfferEventLabels`), tanınmayan tip "Kayıt güncellendi".
String offerEventLabel(OfferEvent e, int? revNo) {
  final rev = revNo == null ? '' : 'Revizyon $revNo';
  final revAcc = revNo == null ? '' : "$rev'${turkishAccusativeSuffix(revNo)}";
  String base(String type) => kOfferEventLabels[type] ?? kUnknownEventLabel;
  final hasRev = rev.isNotEmpty;
  switch (e.eventType) {
    case 'offer_created':
      return base('offer_created');
    case 'offer_updated':
      return hasRev ? '$rev düzenlendi' : base('offer_updated');
    case 'revision_created':
      return hasRev ? '$rev oluşturuldu' : base('revision_created');
    case 'revision_sent':
      return hasRev ? '$rev müşteriye gönderildi' : base('revision_sent');
    case 'share_link_created':
      return hasRev ? '$rev için paylaşım linki oluşturuldu' : base('share_link_created');
    case 'share_link_revoked':
      if (e.metadata['reason'] == 'revision_sent') {
        return hasRev ? '$rev linki, yeni revizyon gönderildiği için iptal edildi' : 'Eski paylaşım linki iptal edildi';
      }
      return hasRev ? '$rev paylaşım linki iptal edildi' : base('share_link_revoked');
    case 'customer_viewed':
      return hasRev ? 'Müşteri $revAcc görüntüledi' : base('customer_viewed');
    case 'customer_accepted':
      return hasRev ? 'Müşteri $revAcc kabul etti' : base('customer_accepted');
    case 'customer_rejected':
      return hasRev ? 'Müşteri $revAcc reddetti' : base('customer_rejected');
    case 'email_sent':
      return hasRev ? '$rev e-posta ile gönderildi' : base('email_sent');
    case 'email_failed':
      return hasRev ? '$rev e-postası gönderilemedi' : base('email_failed');
    case 'offer_cancelled':
      return base('offer_cancelled');
    case 'project_created':
      final projectNo = e.metadata['project_no'];
      return projectNo is String ? 'Projeye dönüştürüldü ($projectNo)' : base('project_created');
    default:
      return kUnknownEventLabel;
  }
}

/// RFC3339 -> İstanbul duvar saati (Türkiye sabit UTC+3). Cihaz saat
/// diliminden bağımsız: ekranlar ve ekran görüntüleri her yerde aynı.
DateTime? _istanbul(String rfc3339) {
  final t = DateTime.tryParse(rfc3339);
  return t?.toUtc().add(const Duration(hours: 3));
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Web `shortStamp`: "dd.MM HH:mm".
String offerShortStamp(String rfc3339) {
  final t = _istanbul(rfc3339);
  if (t == null) return '-';
  return '${_two(t.day)}.${_two(t.month)} ${_two(t.hour)}:${_two(t.minute)}';
}

/// "dd.MM.yyyy HH:mm".
String offerFullStamp(String rfc3339) {
  final t = _istanbul(rfc3339);
  if (t == null) return '-';
  return '${_two(t.day)}.${_two(t.month)}.${t.year} ${_two(t.hour)}:${_two(t.minute)}';
}
