/// Yapay zekâ görselleri (backend migration 0079, bkz. mobile/API_CONTRACT.md
/// "Yapay zekâ görselleri"). Görseli sunucu firmanın OpenAI anahtarıyla
/// üretir; uygulama yalnızca iş açar ve durumunu sorar.
library;

/// İzin kodu: maliyetli (her görsel firmanın OpenAI hesabından ücretlenir),
/// varsayılan yalnızca Sahip/Yönetici.
const kAiImagesPermission = 'ai.images.use';

abstract final class AiImageKind {
  /// Fotoğraf + açıklamadan işin bitmiş hali ("önce/sonra").
  static const beforeAfter = 'before_after';

  /// Karanlık/bulanık fotoğrafı iyileştirme -- içerik değişmez.
  static const enhance = 'enhance';

  /// Açıklamadan yeni görsel (isteğe bağlı referans fotoğrafla).
  static const generate = 'generate';

  /// Fotoğrafa (yapay zekâ sonucuna da) serbest talimatla değişiklik --
  /// "gelen resme düzenleme olsun": sonuç yeniden düzenlenebilir.
  static const edit = 'edit';
}

/// "Bitmiş halini göster" için dokununca alana yazılan örnekler.
const kAiBeforeAfterExamples = [
  'Alçıpan asma tavan, spot ışıklı',
  'Duvarlar beyaz boyalı, laminat parke',
  'Banyo seramik, duşakabin',
  'Mutfak dolapları beyaz, granit tezgâh',
];

/// "Kendin yaz (düzenle)" / Stüdyo "Düzenle" için örnek talimatlar.
const kAiEditExamples = [
  'Daha aydınlık yap',
  'Tavanı koyu gri yap',
  'Spot ışık ekle',
  'Zemini ahşap parke yap',
];

/// Backend aiPromptMaxRunes ile aynı.
const kAiPromptMaxLength = 1000;

class AiImageQuota {
  final int monthlyLimit;
  final int usedThisMonth;
  final int remaining;
  final int userHourlyLimit;
  final String resetsAt;

  const AiImageQuota({
    required this.monthlyLimit,
    required this.usedThisMonth,
    required this.remaining,
    required this.userHourlyLimit,
    required this.resetsAt,
  });

  factory AiImageQuota.fromJson(Map<String, dynamic> json) => AiImageQuota(
        monthlyLimit: (json['monthly_limit'] as num?)?.toInt() ?? 0,
        usedThisMonth: (json['used_this_month'] as num?)?.toInt() ?? 0,
        remaining: (json['remaining'] as num?)?.toInt() ?? 0,
        userHourlyLimit: (json['user_hourly_limit'] as num?)?.toInt() ?? 0,
        resetsAt: json['resets_at'] as String? ?? '',
      );
}

class AiImageUsage {
  final String? userId;
  final String fullName;
  final int images;

  const AiImageUsage({this.userId, required this.fullName, required this.images});

  factory AiImageUsage.fromJson(Map<String, dynamic> json) => AiImageUsage(
        userId: json['user_id'] as String?,
        fullName: json['full_name'] as String? ?? '',
        images: (json['images'] as num?)?.toInt() ?? 0,
      );
}

/// GET /ai/status. [enabled]: sunucuda anahtar ayarlı mı; [canUse]: kişinin
/// izni var mı. [usageByUser] yalnızca Sahip/Yönetici'ye gelir.
class AiImageStatus {
  final bool enabled;
  final bool canUse;
  final AiImageQuota? quota;
  final List<AiImageUsage>? usageByUser;

  const AiImageStatus({required this.enabled, required this.canUse, this.quota, this.usageByUser});

  static const off = AiImageStatus(enabled: false, canUse: false);

  bool get available => enabled && canUse;

  factory AiImageStatus.fromJson(Map<String, dynamic> json) => AiImageStatus(
        enabled: json['enabled'] == true,
        canUse: json['can_use'] == true,
        quota: json['quota'] is Map<String, dynamic> ? AiImageQuota.fromJson(json['quota'] as Map<String, dynamic>) : null,
        usageByUser: (json['usage_by_user'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>()
            .map(AiImageUsage.fromJson)
            .toList(),
      );
}

abstract final class AiJobStatus {
  static const queued = 'queued';
  static const running = 'running';
  static const done = 'done';
  static const failed = 'failed';
}

class AiImageJob {
  final String id;
  final String projectId;
  final String kind;
  final String prompt;
  final String? sourcePhotoId;
  final String status;

  /// Sunucunun Türkçe nedeni (yalnızca failed).
  final String error;
  /// Proje işinde sonuç proje fotoğrafı; Stüdyo işinde ([studio]) stüdyo
  /// görselinin kimliği (studio_image_id).
  final String? resultPhotoId;
  final String createdAt;

  /// Yapay Zekâ Stüdyo işi (projesiz; /ai/studio/jobs/{id} sorulur).
  final bool studio;

  const AiImageJob({
    required this.id,
    required this.projectId,
    required this.kind,
    required this.prompt,
    required this.status,
    required this.error,
    required this.createdAt,
    this.sourcePhotoId,
    this.resultPhotoId,
    this.studio = false,
  });

  bool get isActive => status == AiJobStatus.queued || status == AiJobStatus.running;
  bool get isDone => status == AiJobStatus.done;
  bool get isFailed => status == AiJobStatus.failed;

  factory AiImageJob.fromJson(Map<String, dynamic> json) => AiImageJob(
        id: json['id'] as String,
        projectId: json['project_id'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        prompt: json['prompt'] as String? ?? '',
        sourcePhotoId: json['source_photo_id'] as String?,
        status: json['status'] as String? ?? AiJobStatus.queued,
        error: json['error'] as String? ?? '',
        resultPhotoId: json['result_photo_id'] as String?,
        createdAt: json['created_at'] as String? ?? '',
      );
}

/// Galeri ve ızgara rozeti / açıklaması için tür adı.
String aiKindLabel(String kind) => switch (kind) {
      AiImageKind.beforeAfter => 'Bitmiş hali',
      AiImageKind.enhance => 'İyileştirilmiş fotoğraf',
      AiImageKind.generate => 'Yeni görsel',
      AiImageKind.edit => 'Düzenlenmiş fotoğraf',
      _ => 'Yapay zekâ görseli',
    };
