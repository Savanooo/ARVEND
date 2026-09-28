import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import '../api/api_client.dart';
import 'app_release.dart';

/// Uzaktan güncellemenin tek platform değeri -- iOS/web'de modülün tamamı
/// devre dışıdır (bkz. updateSupportedProvider).
const kUpdatePlatform = 'android';

/// `/mobile/app-version` ve `/mobile/app-download` uçları. İkisi de TEK
/// `ApiClient` üzerinden gider: sürüm uç herkese açık olduğu için giriş
/// ekranında (oturum yokken) de çalışır; indirme çerez kavanozundaki
/// oturumu (ve tek-uçuş 401->refresh akışını) kullanır.
class UpdateRepository {
  UpdateRepository(this._client);
  final ApiClient _client;

  Future<AppRelease> fetchLatest() async {
    final data = await _client.get<dynamic>('/mobile/app-version', query: {'platform': kUpdatePlatform});
    if (data is! Map) return const AppRelease.none();
    return AppRelease.fromJson(Map<String, dynamic>.from(data));
  }
}

/// APK indirme soyutlaması -- testlerde gerçek ağ olmadan sahtesi verilir.
abstract interface class UpdateDownloader {
  /// Güncel APK'yı [savePath]'e indirir. Oturum yoksa `ApiException`
  /// (`ApiErrorKind.unauthorized`) fırlatır. Sunucu [expectedSha256]'dan
  /// başka bir dosya sunuyorsa (bu arada yeni sürüm yayınlandı) gövdeyi
  /// indirmeden [DownloadRejected] fırlatır.
  Future<void> download(
    String savePath, {
    required String expectedSha256,
    required void Function(int received, int total) onProgress,
    required CancelToken cancelToken,
  });
}

class ApiUpdateDownloader implements UpdateDownloader {
  ApiUpdateDownloader(this._client);
  final ApiClient _client;

  @override
  Future<void> download(
    String savePath, {
    required String expectedSha256,
    required void Function(int received, int total) onProgress,
    required CancelToken cancelToken,
  }) =>
      _client.download(
        '/mobile/app-download',
        savePath,
        query: {'platform': kUpdatePlatform},
        onReceiveProgress: onProgress,
        cancelToken: cancelToken,
        acceptHeaders: (headers) => etagAllows(headers['etag'], expectedSha256),
      );
}

final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// İndirme ucunun ETag'i sunduğu APK'nın SHA-256'sıdır (`"<sha256>"`).
/// Beklenen özetten FARKLI bir özet ilan ediyorsa false -- sunucu artık
/// başka bir sürüm sunuyor, gövdeyi indirmeye gerek yok. ETag yoksa ya da
/// özet biçiminde değilse (ör. bir ara katman değiştirdi) true: karar
/// indirme sonrası SHA-256 denetimine kalır. Bu yalnızca erken bir
/// kısayoldur; güvenlik kapısı her durumda indirilen dosyanın özetidir.
@visibleForTesting
bool etagAllows(List<String>? etagValues, String expectedSha256) {
  if (etagValues == null || etagValues.length != 1) return true;
  var tag = etagValues.single.trim();
  // Bir ara katman sıkıştırırsa ETag zayıflatılır: W/"<sha256>".
  if (tag.startsWith('W/')) tag = tag.substring(2);
  if (tag.length >= 2 && tag.startsWith('"') && tag.endsWith('"')) tag = tag.substring(1, tag.length - 1);
  tag = tag.toLowerCase();
  if (!_sha256Pattern.hasMatch(tag)) return true;
  return tag == expectedSha256;
}
