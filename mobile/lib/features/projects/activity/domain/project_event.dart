import '../../../../core/utils/event_labels.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../finance_plan/domain/project_invoice.dart' show invoiceStatusLabel;
import '../../ops_team/domain/schedule_item.dart' show ScheduleStatus;

/// `GET /projects/{id}/events` satırı (backend `projectEventResponse`).
/// Sunucu sırası `created_at ASC`'dir; ekran en yeniyi üste alır.
class ProjectEvent {
  const ProjectEvent({
    required this.id,
    required this.eventType,
    required this.createdAt,
    this.userId,
    this.metadata = const {},
  });

  final String id;
  final String eventType;

  /// RFC3339 (UTC).
  final String createdAt;
  final String? userId;

  /// Olaya göre değişen serbest alanlar (name, title, invoice_no, amount,
  /// from/to, status, reason ...). Tutar alanları [kProjectEventMoneyKeys].
  final Map<String, dynamic> metadata;

  factory ProjectEvent.fromJson(Map<String, dynamic> json) => ProjectEvent(
        id: json['id'] as String? ?? '',
        eventType: json['event_type'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        userId: json['user_id'] as String?,
        metadata: (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

/// Web `ProjectActivitySection.detail()`'in tutar gösterdiği alanlar. Uç
/// bunları proje erişimi olan HERKESE döndürür (HANDOFF §8 "bilinen veri
/// sızıntıları"); uygulama bunları yalnızca `projects.finance.read` sahibine
/// gösterir -- tutar finans izni olmayana hiçbir ekranda görünmez.
const kProjectEventMoneyKeys = ['amount', 'planned_amount', 'contract_amount', 'grand_total'];

/// Olayın Türkçe etiketi (web `PROJECT_EVENT_LABELS`); bilinmeyen tip ham
/// kod olarak DEĞİL "Kayıt güncellendi" olarak görünür (spec §7.1).
String projectEventLabel(String eventType) => kProjectEventLabels[eventType] ?? kUnknownEventLabel;

/// Web `detail()` ile aynı alanlar ve sıra: ad · başlık · proje no · fatura
/// no · tutar(lar) · eski → yeni durum · durum · gerekçe. Fark: durum kodları
/// Türkçe etiketlere çevrilir (web ham kodu yazar) ve tutarlar yalnızca
/// [showMoney] ile eklenir.
String projectEventDetail(ProjectEvent e, {required String currency, required bool showMoney}) {
  final m = e.metadata;
  final parts = <String>[];
  void text(String key) {
    final v = m[key];
    if (v is String && v.trim().isNotEmpty) parts.add(v.trim());
  }

  text('name');
  text('title');
  text('project_no');
  text('invoice_no');
  if (showMoney) {
    for (final key in kProjectEventMoneyKeys) {
      final v = m[key];
      // Tutar ile para birimi aynı satırda kalsın (bölünmez boşluk).
      if (v is num) parts.add(Formatters.money(v, currency: currency).replaceAll(' ', kNbsp));
    }
  }
  final from = m['from'];
  final to = m['to'];
  if (from is String && to is String) {
    parts.add('${_statusLabel(e.eventType, from)} → ${_statusLabel(e.eventType, to)}');
  }
  final status = m['status'];
  if (status is String && status.isNotEmpty) parts.add(_statusLabel(e.eventType, status));
  text('reason');
  return parts.join(' · ');
}

/// Durum kodu -> Türkçe etiket, olayın ait olduğu kayda göre (fatura,
/// planlama aşaması, görev, proje). Tanınmayan kod olduğu gibi kalır.
String _statusLabel(String eventType, String code) {
  if (eventType.startsWith('invoice_')) return invoiceStatusLabel(code);
  if (eventType.startsWith('schedule_')) return ScheduleStatus.label(code);
  if (eventType.startsWith('task_')) return StatusRegistry.task[code]?.$1 ?? code;
  if (eventType.startsWith('project_')) return StatusRegistry.project[code]?.$1 ?? code;
  return code;
}

/// Zaman çizelgesindeki noktanın tonu: olumlu sonuç yeşil, iptal/red/hata
/// kırmızı, müşteriye giden/müşteriden gelen bilgi mavi, geri kalanı nötr.
enum ProjectEventTone { success, danger, info, normal }

ProjectEventTone projectEventTone(String eventType) {
  const danger = ['_voided', '_void', '_cancelled', '_rejected', '_terminated', '_failed', '_removed', '_deleted'];
  const success = ['_approved', '_completed', '_received', '_certified', '_activated', '_baselined', '_awarded'];
  const info = ['_sent', '_viewed', '_submitted', '_issued'];
  if (danger.any(eventType.endsWith)) return ProjectEventTone.danger;
  if (success.any(eventType.endsWith)) return ProjectEventTone.success;
  if (info.any(eventType.endsWith)) return ProjectEventTone.info;
  return ProjectEventTone.normal;
}

/// RFC3339 -> İstanbul duvar saati (Türkiye sabit UTC+3; cihaz saat
/// diliminden bağımsız, ana sayfa ve teklif geçmişiyle aynı kural).
DateTime? projectEventIstanbul(String rfc3339) => DateTime.tryParse(rfc3339)?.toUtc().add(const Duration(hours: 3));

/// Gün başlığı anahtarı ("2026-09-29", İstanbul günü).
String projectEventDayKey(String rfc3339) {
  final t = projectEventIstanbul(rfc3339);
  if (t == null) return '';
  return '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}';
}

/// "HH:mm" (İstanbul).
String projectEventClock(String rfc3339) {
  final t = projectEventIstanbul(rfc3339);
  return t == null ? '-' : '${_two(t.hour)}:${_two(t.minute)}';
}

String _two(int n) => n.toString().padLeft(2, '0');
