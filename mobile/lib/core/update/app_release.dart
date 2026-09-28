/// Sunucudaki güncel uygulama sürümü -- `GET /mobile/app-version?platform=
/// android` yanıtı (sözleşme: backend'in mobile app-version handler'ı ile
/// BİREBİR, bkz. HANDOFF.md). Uç herkese açıktır (giriş ekranından da
/// sorulur) ve yalnızca bu alanları döner; sunucuda geçerli bir sürüm
/// yoksa gövde `{"platform":"android","build":0}`'dır.
///
/// Güvenlik modeli üç katmanlıdır (eski BYZ uygulamasındakiyle aynı):
/// 1. APK'nın kendisi `/mobile/app-download`'dan YALNIZCA giriş yapmış
///    kullanıcıya iner.
/// 2. İstemci inen dosyanın SHA-256 özetini buradaki [sha256] ile
///    karşılaştırır; tutmazsa kurulum ekranı HİÇ açılmaz.
/// 3. Android güncellemeyi ancak kurulu uygulamayla AYNI anahtarla
///    imzalanmışsa kurar.
class AppRelease {
  const AppRelease({
    required this.platform,
    required this.build,
    this.version = '',
    this.sha256 = '',
    this.size = 0,
    this.notes = '',
    this.minBuild = 0,
    this.publishedAt,
  });

  /// Sunucuda sürüm yok -- istemci hiçbir zaman güncelleme önermez.
  const AppRelease.none({this.platform = 'android'})
      : build = 0,
        version = '',
        sha256 = '',
        size = 0,
        notes = '',
        minBuild = 0,
        publishedAt = null;

  final String platform;
  final int build;
  final String version;

  /// 64 karakter küçük harf hex. Geçersizse sürüm "yok" sayılır (bkz.
  /// [isPublished]) -- doğrulanamayacak bir dosya asla önerilmez.
  final String sha256;

  /// Bayt cinsinden APK boyutu (sunucu gerçek dosya boyutuyla eşleştiğini
  /// doğrular). 0 = bilinmiyor.
  final int size;
  final String notes;

  /// Kurulu build bundan KÜÇÜKSE güncelleme zorunludur.
  final int minBuild;
  final DateTime? publishedAt;

  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  /// Eksik/yanlış tipli alanlar hata FIRLATMAZ, "sürüm yok"a düşer --
  /// güncelleme denetimi uygulamayı asla bozmamalı.
  factory AppRelease.fromJson(Map<String, dynamic> json) {
    return AppRelease(
      platform: _string(json['platform']),
      build: _int(json['build']),
      version: _string(json['version']).trim(),
      sha256: _string(json['sha256']).trim().toLowerCase(),
      size: _int(json['size']),
      notes: _string(json['notes']).trim(),
      minBuild: _int(json['min_build']),
      publishedAt: DateTime.tryParse(_string(json['published_at'])),
    );
  }

  /// İndirilip doğrulanabilecek bir sürüm var mı.
  bool get isPublished => build > 0 && _sha256Pattern.hasMatch(sha256);

  /// Sunucudaki build kurulu olandan büyükse güncelleme var.
  bool isNewerThan(int installedBuild) => isPublished && build > installedBuild;

  /// Zorunlu güncelleme: yeni bir sürüm VAR ve kurulu build `min_build`'in
  /// altında. Sunucu `min_build`'i yeni sürümün kendisinden büyük yazsa
  /// bile kurulacak bir şey yoksa zorunlu SAYILMAZ (kullanıcı kilitlenmez).
  bool isMandatoryFor(int installedBuild) => isNewerThan(installedBuild) && installedBuild < minBuild;

  /// Ekranda gösterilen sürüm: "1.2.0" yoksa build numarası.
  String get displayVersion => version.isNotEmpty ? version : 'build $build';

  static int _int(Object? value) => switch (value) {
        int v => v,
        num v => v.toInt(),
        String v => int.tryParse(v.trim()) ?? 0,
        _ => 0,
      };

  static String _string(Object? value) => value is String ? value : '';
}

/// Cihazda kurulu sürüm (`PackageInfo`'dan) -- build numarası pubspec'teki
/// `+N`, yani Android `versionCode`.
class InstalledVersion {
  const InstalledVersion({required this.version, required this.build});

  final String version;
  final int build;

  String get label => '$version ($build)';
}
