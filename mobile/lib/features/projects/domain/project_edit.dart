/// "Proje bilgilerini düzenle" ekranının modeli (web `projeler/[id]/duzenle`).
/// Mevcut `Project` modeline dokunmamak için ayrı tutulur: düzenleme için
/// gereken `internal_notes` ve kaynak teklif bilgileri yalnızca burada.
///
/// Düzenlenebilir alanlar YALNIZCA backend `updateProjectRequest`
/// alanlarıdır (ad, tip, durum, tarihler, açıklama, dahili not). Sözleşme
/// bedeli, para birimi, kaynak teklif ve müşteri anlık görüntüsü kabul
/// edilen tekliften DONDURULMUŞTUR -- ne formda ne istek gövdesinde yer alır.
class ProjectEditable {
  final String id;
  final String projectNo;
  final String name;
  final String projectType;
  final String status;
  final String? startDate;
  final String? endDate;
  final String description;
  final String internalNotes;

  // Değiştirilemeyen (salt okunur gösterilen) bilgiler.
  final String customerName;
  final double contractAmount;
  final String currency;
  final String sourceOfferNo;
  final int sourceRevisionNo;

  const ProjectEditable({
    required this.id,
    required this.projectNo,
    required this.name,
    required this.projectType,
    required this.status,
    required this.startDate,
    required this.endDate,
    required this.description,
    required this.internalNotes,
    required this.customerName,
    required this.contractAmount,
    required this.currency,
    required this.sourceOfferNo,
    required this.sourceRevisionNo,
  });

  factory ProjectEditable.fromJson(Map<String, dynamic> json) => ProjectEditable(
        id: json['id'] as String,
        projectNo: json['project_no'] as String? ?? '',
        name: json['name'] as String? ?? '',
        projectType: json['project_type'] as String? ?? '',
        status: json['status'] as String? ?? 'planned',
        startDate: _date(json['start_date'] as String?),
        endDate: _date(json['end_date'] as String?),
        description: json['description'] as String? ?? '',
        internalNotes: json['internal_notes'] as String? ?? '',
        customerName: json['customer_name'] as String? ?? '',
        contractAmount: (json['contract_amount'] as num?)?.toDouble() ?? 0,
        currency: json['currency'] as String? ?? 'TRY',
        sourceOfferNo: json['source_offer_no'] as String? ?? '',
        sourceRevisionNo: (json['source_revision_no'] as num?)?.toInt() ?? 0,
      );
}

String? _date(String? v) => (v == null || v.isEmpty) ? null : v;

/// `PUT /projects/{id}` gövdesi -- backend `updateProjectRequest` ile birebir.
class ProjectEditInput {
  final String name;
  final String projectType;
  final String status;
  final String? startDate;
  final String? endDate;
  final String description;
  final String internalNotes;

  const ProjectEditInput({
    required this.name,
    required this.projectType,
    required this.status,
    required this.startDate,
    required this.endDate,
    required this.description,
    required this.internalNotes,
  });

  Map<String, dynamic> toJson() => {
        'name': name.trim(),
        'project_type': projectType.trim(),
        'status': status,
        'start_date': startDate,
        'end_date': endDate,
        'description': description.trim(),
        'internal_notes': internalNotes.trim(),
      };
}

/// Duruma göre formda sunulan seçenekler -- web `ProjectEditForm`
/// `TRANSITIONS` tablosunun aynası (asıl kontrol backend'de; burası
/// yalnızca imkânsız seçeneği göstermemek için). Web ile aynı şekilde
/// tamamlanmış/iptal edilmiş proje bu ekrandan yeniden açılamaz.
const kProjectEditTransitions = <String, List<String>>{
  'planned': ['planned', 'active', 'paused', 'cancelled'],
  'active': ['active', 'paused', 'completed', 'cancelled'],
  'paused': ['paused', 'active', 'completed', 'cancelled'],
  'completed': ['completed'],
  'cancelled': ['cancelled'],
};

List<String> projectStatusOptions(String current) => kProjectEditTransitions[current] ?? [current];

/// `DateTime` -> backend tarih biçimi "YYYY-MM-DD".
String formatApiDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
