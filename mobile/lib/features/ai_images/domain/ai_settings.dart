/// "Yapay Zekâ Ayarları" (backend migration 0081, bkz. mobile/API_CONTRACT.md
/// "Yapay Zekâ Ayarları"): yönetici yapay zekâyı firmada açar/kapatır, kimin
/// kullanacağını ve firmanın/kişinin aylık sınırını belirler, bu ayki
/// kullanımı görür. Her görsel firmanın OpenAI hesabından ücretlenir.
library;

/// Ekranı açan izin: kişi düğmesi kişiye özel `ai.images.use` ayarı yazar --
/// Roller & Yetkiler'deki kişiye özel yetkiyle AYNI iş, aynı izin.
const kAiSettingsPermission = 'organization.roles.manage';

const kAiSettingsTitle = 'Yapay Zekâ Ayarları';
const kAiSettingsRoute = '/diger/yapay-zeka-ayarlari';

/// Sunucu kapalı firmada bu metni gönderir; gönderemezse (eski sunucu) bu.
const kAiFirmDisabledText = 'Yapay zekâ bu firmada yönetici tarafından kapatıldı';

/// Kişinin izninin nereden geldiği (rozet metni ekranda).
enum AiUseSource {
  role('role', 'Rolünden'),
  overrideAllow('override_allow', 'Kişiye özel açık'),
  overrideDeny('override_deny', 'Kişiye özel kapalı');

  const AiUseSource(this.code, this.label);
  final String code;
  final String label;

  static AiUseSource parse(String? code) =>
      AiUseSource.values.firstWhere((s) => s.code == code, orElse: () => AiUseSource.role);
}

class AiSettingsUser {
  final String userId;
  final String fullName;
  final String roleCode;
  final String roleName;
  final bool isOwner;
  final bool canUse;
  final AiUseSource source;
  final int usedThisMonth;

  const AiSettingsUser({
    required this.userId,
    required this.fullName,
    required this.roleCode,
    required this.roleName,
    required this.isOwner,
    required this.canUse,
    required this.source,
    required this.usedThisMonth,
  });

  factory AiSettingsUser.fromJson(Map<String, dynamic> json) => AiSettingsUser(
        userId: json['user_id'] as String,
        fullName: json['full_name'] as String? ?? '',
        roleCode: json['role_code'] as String? ?? '',
        roleName: json['role_name'] as String? ?? '',
        isOwner: json['is_owner'] == true || json['role_code'] == 'owner',
        canUse: json['can_use'] == true,
        source: AiUseSource.parse(json['source'] as String?),
        usedThisMonth: (json['used_this_month'] as num?)?.toInt() ?? 0,
      );
}

/// GET/PUT /ai/settings yanıtı. [monthlyLimit] null = sunucu varsayılanı;
/// [perUserMonthlyLimit] null = kişi başı sınır yok. [serverMax] sunucunun
/// üst sınırı (AI_IMAGE_MONTHLY_LIMIT): firma sınırı bunu aşamaz.
class AiSettings {
  final bool enabled;
  final int? monthlyLimit;
  final int effectiveMonthlyLimit;
  final int serverMax;
  final int? perUserMonthlyLimit;
  final int usedThisMonth;
  final String resetsAt;
  final List<AiSettingsUser> users;

  const AiSettings({
    required this.enabled,
    required this.effectiveMonthlyLimit,
    required this.serverMax,
    required this.usedThisMonth,
    required this.users,
    this.monthlyLimit,
    this.perUserMonthlyLimit,
    this.resetsAt = '',
  });

  factory AiSettings.fromJson(Map<String, dynamic> json) => AiSettings(
        enabled: json['enabled'] != false,
        monthlyLimit: (json['monthly_limit'] as num?)?.toInt(),
        effectiveMonthlyLimit: (json['effective_monthly_limit'] as num?)?.toInt() ?? 0,
        serverMax: (json['server_max'] as num?)?.toInt() ?? 0,
        perUserMonthlyLimit: (json['per_user_monthly_limit'] as num?)?.toInt(),
        usedThisMonth: (json['used_this_month'] as num?)?.toInt() ?? 0,
        resetsAt: json['resets_at'] as String? ?? '',
        users: (json['users'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(AiSettingsUser.fromJson)
            .toList(),
      );
}
