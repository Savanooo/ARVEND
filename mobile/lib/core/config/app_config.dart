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

  static String api(String path) => '$apiBaseUrl$apiPrefix$path';

  /// 25 MiB - backend'in project_operations_handler.go'daki
  /// service.MaxUploadBytes ile birebir aynı sınır (bkz. mobile/API_CONTRACT.md).
  static const int maxUploadBytes = 25 * 1024 * 1024;
}
