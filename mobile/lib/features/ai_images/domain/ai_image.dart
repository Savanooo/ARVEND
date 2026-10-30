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
  /// Firmanın bu ayki ETKİN sınırı (yöneticinin sınırı, sunucu üst sınırıyla kırpılmış).
  final int monthlyLimit;
  final int usedThisMonth;
  final int remaining;
  final int userHourlyLimit;
  final String resetsAt;

  /// Yapay Zekâ Ayarları'ndaki kişi başı aylık sınır; null = sınırsız
  /// (yalnızca firma hakkı). Eski sunucu bu alanları göndermez.
  final int? userMonthlyLimit;
  final int userUsedThisMonth;
  final int? userRemaining;

  const AiImageQuota({
    required this.monthlyLimit,
    required this.usedThisMonth,
    required this.remaining,
    required this.userHourlyLimit,
    required this.resetsAt,
    this.userMonthlyLimit,
    this.userUsedThisMonth = 0,
    this.userRemaining,
  });

  /// Kişinin bu ay daha kaç görsel isteyebileceği: kişi sınırı varsa o ile
  /// firma hakkından küçüğü -- hangisi önce dolarsa o durdurur.
  int get ownRemaining {
    final user = userRemaining;
    if (user == null) return remaining;
    return user < remaining ? user : remaining;
  }

  factory AiImageQuota.fromJson(Map<String, dynamic> json) => AiImageQuota(
        monthlyLimit: (json['monthly_limit'] as num?)?.toInt() ?? 0,
        usedThisMonth: (json['used_this_month'] as num?)?.toInt() ?? 0,
        remaining: (json['remaining'] as num?)?.toInt() ?? 0,
        userHourlyLimit: (json['user_hourly_limit'] as num?)?.toInt() ?? 0,
        resetsAt: json['resets_at'] as String? ?? '',
        userMonthlyLimit: (json['user_monthly_limit'] as num?)?.toInt(),
        userUsedThisMonth: (json['user_used_this_month'] as num?)?.toInt() ?? 0,
        userRemaining: (json['user_remaining'] as num?)?.toInt(),
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

/// GET /ai/status. [serverEnabled]: sunucuda anahtar ayarlı mı;
/// [firmEnabled]: yönetici firmada açık bırakmış mı (Yapay Zekâ Ayarları);
/// [enabled] ikisi birden (eski uygulamalar buna bakar ve kapalıyken
/// girişleri gizler). [canUse]: kişinin izni var mı. [blockedReason]: şu an
/// yeni görsel istenemiyorsa sunucunun Türkçe nedeni (firma kapalı, firma ya
/// da kişi aylık hakkı doldu). [usageByUser] yalnızca Sahip/Yönetici'ye gelir.
class AiImageStatus {
  final bool enabled;
  final bool serverEnabled;
  final bool firmEnabled;
  final bool canUse;
  final bool canManage;
  final String blockedCode;
  final String blockedReason;
  final AiImageQuota? quota;
  final List<AiImageUsage>? usageByUser;

  const AiImageStatus({
    required this.enabled,
    required this.canUse,
    bool? serverEnabled,
    this.firmEnabled = true,
    this.canManage = false,
    this.blockedCode = '',
    this.blockedReason = '',
    this.quota,
    this.usageByUser,
  }) : serverEnabled = serverEnabled ?? enabled;

  static const off = AiImageStatus(enabled: false, canUse: false);

  /// Girişler görünsün mü: sunucuda anahtar var VE kişinin izni var. Firma
  /// kapalıyken de görünür -- kişi nedenini ("yönetici kapattı") içeride
  /// okusun, düğmeler kapalı kalır ([blocked]).
  bool get available => serverEnabled && canUse;

  /// Şu an yeni görsel istenemez: sunucu bir neden söyledi ya da kişinin
  /// (ya da firmanın) bu ayki hakkı bitti. Asıl sınır yine sunucuda.
  bool get blocked => blockedReason.isNotEmpty || !firmEnabled || (quota != null && quota!.ownRemaining <= 0);

  /// Üstte gösterilecek bir neden var mı (hak satırı zaten "doldu" der;
  /// firma kapalıysa ya da kişi sınırı dolduysa ayrıca söylenir).
  bool get hasBlockNotice => blockedReason.isNotEmpty || !firmEnabled;

  factory AiImageStatus.fromJson(Map<String, dynamic> json) {
    final enabled = json['enabled'] == true;
    return AiImageStatus(
      enabled: enabled,
      // Eski sunucu server_enabled/firm_enabled göndermez: enabled'a düş.
      serverEnabled: json.containsKey('server_enabled') ? json['server_enabled'] == true : enabled,
      firmEnabled: json.containsKey('firm_enabled') ? json['firm_enabled'] == true : true,
      canUse: json['can_use'] == true,
      canManage: json['can_manage'] == true,
      blockedCode: json['blocked_code'] as String? ?? '',
      blockedReason: json['blocked_reason'] as String? ?? '',
      quota: json['quota'] is Map<String, dynamic> ? AiImageQuota.fromJson(json['quota'] as Map<String, dynamic>) : null,
      usageByUser: (json['usage_by_user'] as List<dynamic>?)
          ?.cast<Map<String, dynamic>>()
          .map(AiImageUsage.fromJson)
          .toList(),
    );
  }
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
