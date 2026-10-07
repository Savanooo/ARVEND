/// Backend HER hata durumunda `{"error": "mesaj"}` gövdesi döner (bkz.
/// internal/platform/httpjson.Error ve middleware'lerdeki http.Error
/// çağrıları) - Content-Type bazen text/plain olsa da gövde her zaman bu
/// şekildedir; bkz. mobile/API_CONTRACT.md.
class ApiException implements Exception {
  final int? statusCode;
  final String message;
  final ApiErrorKind kind;

  /// Gövdedeki makine-okunur `code` (ör. `duplicate_customer`); çoğu hatada
  /// yoktur.
  final String? code;

  /// Ham JSON hata gövdesi -- `code` taşıyan hatalarda ek alanlar için
  /// (ör. 409 duplicate_customer'daki `existing_customer`).
  final Map<String, dynamic>? body;

  const ApiException({
    required this.statusCode,
    required this.message,
    required this.kind,
    this.code,
    this.body,
  });

  bool get isAuthError => kind == ApiErrorKind.unauthorized;
  bool get isForbidden => kind == ApiErrorKind.forbidden;

  @override
  String toString() => message;
}

enum ApiErrorKind {
  badRequest,
  unauthorized,
  forbidden,
  notFound,
  conflict,
  validation,
  server,
  network,
  timeout,
  unknown,
}

/// HTTP status -> Türkçe kullanıcı mesajı ve hata sınıfı.
/// `serverMessage`, backend'in gerçek `error` alanıdır - varsa ONA öncelik
/// verilir (backend zaten Türkçe, kullanıcıya en doğru bilgiyi o verir);
/// yoksa generic Türkçe mesaja düşülür.
ApiException mapHttpError(int? statusCode, String? serverMessage, {String? code, Map<String, dynamic>? body}) {
  final kind = switch (statusCode) {
    400 => ApiErrorKind.badRequest,
    401 => ApiErrorKind.unauthorized,
    403 => ApiErrorKind.forbidden,
    404 => ApiErrorKind.notFound,
    409 => ApiErrorKind.conflict,
    422 => ApiErrorKind.validation,
    null => ApiErrorKind.network,
    _ when statusCode >= 500 => ApiErrorKind.server,
    _ => ApiErrorKind.unknown,
  };

  final fallback = switch (kind) {
    ApiErrorKind.badRequest => 'Geçersiz istek. Girdiğiniz bilgileri kontrol edin.',
    ApiErrorKind.unauthorized => 'Oturumunuz sona erdi. Lütfen tekrar giriş yapın.',
    ApiErrorKind.forbidden => 'Bu işlem için yetkiniz yok.',
    ApiErrorKind.notFound => 'Kayıt bulunamadı.',
    ApiErrorKind.conflict => 'Bu işlem mevcut bir kayıtla çakışıyor.',
    ApiErrorKind.validation => 'Girdiğiniz bilgiler geçersiz.',
    ApiErrorKind.server => 'Sunucuda beklenmeyen bir hata oluştu. Lütfen tekrar deneyin.',
    ApiErrorKind.network => 'Bağlantı kurulamadı. İnternet bağlantınızı kontrol edin.',
    ApiErrorKind.timeout => 'İstek zaman aşımına uğradı. Lütfen tekrar deneyin.',
    ApiErrorKind.unknown => 'Beklenmeyen bir hata oluştu.',
  };

  return ApiException(
    statusCode: statusCode,
    message: (serverMessage != null && serverMessage.trim().isNotEmpty) ? serverMessage : fallback,
    kind: kind,
    code: code,
    body: body,
  );
}

/// Oturumu SONLANDIRAN 403 sınıfları -- normal `ApiErrorKind.forbidden`
/// (ör. tek bir aksiyon için yetki yok) İLE KARIŞTIRILMAMALI: bunlar
/// "bu hesap artık kiracı uygulamasını hiç kullanamaz" anlamına gelir.
/// Backend bu üçünü sabit, belgelenen imzalarla döner (bkz. API_CONTRACT.md
/// #hesap-erişim-durumları) -- mobil YALNIZCA bu sabitlere göre sınıflandırır.
enum AccountAccessIssue {
  /// `super_admin` bir kiracı (tenant) ucuna istek attı --
  /// `{"code":"tenant_context_required"}`. Normalde YAŞANMAMALI (router
  /// super_admin'i hiçbir kiracı ekranına sokmuyor) -- burada yalnızca
  /// savunma amaçlı yakalanır.
  tenantContextRequired,

  /// Organizasyon suspended/cancelled/deleted -- backend ÜÇÜNÜ DE aynı sabit
  /// mesajla döner, mobil bunları birbirinden AYIRT EDEMEZ (ve etmemeli).
  organizationBlocked,

  /// Kullanıcı is_active=false VEYA soft-deleted -- backend İKİSİNİ DE aynı
  /// sabit mesajla döner, mobil bunları birbirinden AYIRT EDEMEZ.
  userBlocked,
}

const _kOrgBlockedMessage = 'firma askıya alınmış veya erişilemiyor';
const _kUserBlockedMessage = 'kullanıcı pasif durumda';

/// Yalnızca backend'in BELGELENMİŞ, sabit imzalarına göre sınıflandırır --
/// serbest metin/heuristik eşleştirme YOK. `code` alanı varsa ona öncelik
/// verilir (tek güvenilir makine-okunur sinyal); yoksa `rawMessage`'ın TAM
/// eşleştiği iki sabit mesajdan biri kontrol edilir. Diğer TÜM 403'ler
/// (ör. tek bir yazma işlemi için izin eksikliği) null döner -- normal
/// `ApiException(kind: forbidden)` akışına bırakılır.
AccountAccessIssue? classifyAccountAccessIssue({
  required int? statusCode,
  required String? code,
  required String? rawMessage,
}) {
  if (statusCode != 403) return null;
  if (code == 'tenant_context_required') return AccountAccessIssue.tenantContextRequired;
  if (rawMessage == _kOrgBlockedMessage) return AccountAccessIssue.organizationBlocked;
  if (rawMessage == _kUserBlockedMessage) return AccountAccessIssue.userBlocked;
  return null;
}

const _kPasswordChangeRequiredMessage = 'devam etmeden önce şifrenizi değiştirmeniz gerekiyor';
const _kOnboardingRequiredMessage = 'devam etmeden önce firma kurulumunu tamamlamanız gerekiyor';

/// Backend `RequireOnboarded` kapısının iki sabit 403'ü (bkz.
/// backend/internal/httpapi/middleware/require_onboarded.go): oturum açıkken
/// geçici şifre zorunlu kılındı ya da firma kurulumu bitmedi. Hesap engeli
/// DEĞİLDİR (oturum düşürülmez) -- istemci kullanıcıyı tazeleyip router'ın
/// zorunlu ekranına (şifre belirleme / kurulum) gitmelidir. Yalnızca TAM
/// eşleşen sabit mesajlar tanınır.
bool isAccountSetupGate({required int? statusCode, required String? rawMessage}) =>
    statusCode == 403 && (rawMessage == _kPasswordChangeRequiredMessage || rawMessage == _kOnboardingRequiredMessage);
