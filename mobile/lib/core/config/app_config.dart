/// Uygulama genelinde tek yapılandırma noktası.
///
/// API_BASE_URL yalnızca `--dart-define=API_BASE_URL=...` ile build-time'da
/// verilir. Production fallback DAİMA production domain'idir; localhost/
/// 127.0.0.1 hiçbir zaman release build'e gömülmez (bkz. core/api/api_client.dart
/// `_RedactingLogInterceptor` -- `dart.vm.product` sabitiyle debug-only).
class AppConfig {
  const AppConfig._();

  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://app.arvendyapi.com.tr',
  );

  static const String apiPrefix = '/api/v1';

  /// Dağıtım kanalı: `play` (Google Play) ya da `sideload` (mağaza öncesi,
  /// sunucudan kendini güncelleyen APK). Yalnızca `--dart-define=DISTRIBUTION=`
  /// ile verilir ve Gradle flavor'ıyla AYNI olmalıdır -- scripts/derle.sh
  /// ikisini tek argümandan verir.
  ///
  /// Play sürümü kendini Play dışından güncellemez (Play politikası; bkz.
  /// android/app/src/play/AndroidManifest.xml): updateSupportedProvider bu
  /// bayrağa bakıp kendi güncelleyicimizi kapatır, yerine Play'in uygulama içi
  /// güncellemesi çalışır (playUpdateSupportedProvider, play_update.dart).
  static const String distribution = String.fromEnvironment(
    'DISTRIBUTION',
    defaultValue: 'sideload',
  );

  static const bool isPlayBuild = distribution == 'play';

  static String api(String path) => '$apiBaseUrl$apiPrefix$path';

  /// Gizlilik politikası + KVKK metni + hesap silme (web
  /// frontend/app/gizlilik). Mağazalar uygulama içinde de bağlantı ister.
  /// API adresinden türetilmez: yerel geliştirme yapısı da gerçek metni açsın.
  static const String privacyPolicyUrl = 'https://app.arvendyapi.com.tr/gizlilik';

  /// 25 MiB - backend'in project_operations_handler.go'daki
  /// service.MaxUploadBytes ile birebir aynı sınır (bkz. mobile/API_CONTRACT.md).
  static const int maxUploadBytes = 25 * 1024 * 1024;
}
