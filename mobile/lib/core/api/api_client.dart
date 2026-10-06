import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:meta/meta.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../errors/api_exception.dart';

/// Backend'in refresh/login/logout kendi döngüsüne girmemesi ve login 401'inin
/// (şifre hatalı) refresh tetiklememesi için hariç tutulan yollar
/// (bkz. mobile/API_CONTRACT.md - auth bölümü).
const _noRefreshPaths = ['/auth/login', '/auth/refresh', '/auth/logout'];

bool _isNoRefreshPath(String path) => _noRefreshPaths.any(path.endsWith);

/// Tek Dio örneği + HttpOnly cookie kalıcılığı (PersistCookieJar, tarayıcının
/// çerez kavanozunun eşdeğeri - access_token/refresh_token DEĞERİ hiçbir zaman
/// Dart koduna çıkarılmaz, yalnızca cookie header'ı olarak taşınır) + tek uçuş
/// 401 -> refresh -> retry akışı.
///
/// Backend refresh token'ı rotasyonla TEK KULLANIMLIK verir (bkz.
/// AuthService.Refresh) ve başarısız refresh'te her iki cookie'yi de siler;
/// bu yüzden paralel isteklerin aynı refresh'i paylaşması (single-flight)
/// zorunludur - aksi halde ikinci refresh 401 alır ve oturum düşer.
class ApiClient {
  ApiClient._(this._dio, this._cookieJar) {
    dio.interceptors.add(CookieManager(_cookieJar));
    if (!const bool.fromEnvironment('dart.vm.product')) {
      dio.interceptors.add(_RedactingLogInterceptor());
    }
    dio.interceptors.add(_buildAuthRefreshInterceptor());
  }

  final Dio _dio;
  final CookieJar _cookieJar;

  Dio get dio => _dio;

  Completer<bool>? _refreshCompleter;

  /// Refresh başarısız olduğunda (401/403 - token geçersiz, sınıflandırılamayan
  /// bir sebep) tetiklenir; AuthController bunu dinleyip oturumu temizler ve
  /// go_router'ın auth redirect'i /giris'e yönlendirir. Ağ hatası/5xx'te
  /// TETİKLENMEZ (geçici kesintide oturum düşürülmez).
  void Function()? onSessionExpired;

  /// `classifyAccountAccessIssue` sabit imzalarından biri (tenant_context_
  /// required / organizationBlocked / userBlocked) -- refresh başarısızlığı
  /// SIRASINDA ya da herhangi bir sıradan istek 403'ünde tetiklenebilir.
  /// AuthController bunu dinleyip oturumu temizler VE hangi mesajın
  /// gösterileceğini bilmesi için sebebi ayrıca saklar (bkz. app_router.dart
  /// accountAccessIssueProvider). `onSessionExpired` İLE AYNI anda ASLA
  /// çağrılmaz -- ikisi karşılıklı dışlayıcıdır (bkz. _notifyAccountAccessBlocked/
  /// _refreshOnce).
  void Function(AccountAccessIssue issue)? onAccountAccessBlocked;

  /// Aynı organizasyon/kullanıcı engelinin PARALEL uçan birden fazla
  /// isteğin her biri tarafından ayrı ayrı bildirilmesini (ve gereksiz
  /// tekrar tekrar clearSession çağrısını -- "istek fırtınası") önler.
  /// Yalnızca EXPLICIT yeni bir girişte (bkz. resetAccountAccessGuard,
  /// AuthController.login) tekrar açılır.
  bool _accountBlockNotified = false;

  void resetAccountAccessGuard() => _accountBlockNotified = false;

  Future<void> _notifyAccountAccessBlocked(AccountAccessIssue issue) async {
    if (_accountBlockNotified) return;
    _accountBlockNotified = true;
    await clearSession();
    onAccountAccessBlocked?.call(issue);
  }

  static Future<ApiClient> create() async {
    final supportDir = await getApplicationSupportDirectory();
    final cookieJar = PersistCookieJar(
      ignoreExpires: false,
      storage: FileStorage('${supportDir.path}/.cookies/'),
    );

    final dio = Dio(
      BaseOptions(
        // Prefix'i tabana gömüyoruz ki repository'ler her çağrıda
        // AppConfig.apiPrefix'i tekrar tekrar yazmasın (ör. "/auth/login",
        // "/offers" - "/api/v1" örtük).
        baseUrl: AppConfig.apiBaseUrl + AppConfig.apiPrefix,
        connectTimeout: const Duration(seconds: 15),
        // 25 MiB dosya/fotoğraf transferi yavaş mobil bağlantıda uzun
        // sürebilir; backend'in kendi ReadTimeout/WriteTimeout'u (5 dk) ile
        // aynı mertebede tutuluyor ki istemci backend'den önce vazgeçmesin.
        sendTimeout: const Duration(minutes: 5),
        receiveTimeout: const Duration(minutes: 5),
        headers: {'Content-Type': 'application/json'},
        // Varsayılan validateStatus (yalnız 2xx başarılı) kasıtlı olarak
        // KORUNUYOR: 401 gibi durumların DioException olarak onError'a
        // düşmesi gerekiyor, aksi halde _buildAuthRefreshInterceptor hiç
        // tetiklenmez (401'i "başarılı" bir Response sanır).
      ),
    );

    return ApiClient._(dio, cookieJar);
  }

  /// Yalnız testler için: gerçek dosya sistemi/ağ yerine verilen
  /// `HttpClientAdapter` ve bellek-içi bir çerez kavanozuyla kurulur -
  /// path_provider'ın platform kanalına ihtiyaç duymaz.
  @visibleForTesting
  factory ApiClient.test(Dio dio) => ApiClient._(dio, CookieJar());

  Future<T> get<T>(String path, {Map<String, dynamic>? query}) =>
      _send<T>(() => _dio.get(path, queryParameters: query));

  Future<T> post<T>(String path, {Object? data}) =>
      _send<T>(() => _dio.post(path, data: data));

  Future<T> put<T>(String path, {Object? data}) =>
      _send<T>(() => _dio.put(path, data: data));

  Future<T> patch<T>(String path, {Object? data}) =>
      _send<T>(() => _dio.patch(path, data: data));

  Future<T> delete<T>(String path, {Object? data}) =>
      _send<T>(() => _dio.delete(path, data: data));

  /// Multipart yükleme (dosya/fotoğraf). [onSendProgress] upload progress
  /// bar'ı için; boyut ön-kontrolü çağıran tarafta (AppConfig.maxUploadBytes)
  /// yapılmalı ki 25 MiB'yi aşan bir istek hiç gönderilmesin.
  Future<T> upload<T>(
    String path,
    FormData form, {
    void Function(int sent, int total)? onSendProgress,
  }) =>
      _send<T>(() => _dio.post(path, data: form, onSendProgress: onSendProgress));

  /// İkili (fotoğraf/dosya) indirme -- AYNI Dio örneği üzerinden gider,
  /// dolayısıyla çerez kavanozu VE tek-uçuş 401->refresh->retry akışı
  /// otomatik uygulanır. `Image.network`/`NetworkImage` KASITLI OLARAK
  /// KULLANILMAZ -- onlar bu uygulamanın httpOnly çerez kavanozuna
  /// erişemeyen AYRI bir HTTP istemcisidir, bu yüzden kimlik doğrulamalı
  /// uçlarda sessizce 401 alıp hata ikonuna düşerdi.
  Future<Uint8List> getBytes(String path, {Map<String, dynamic>? queryParameters}) async {
    try {
      final res = await _dio.get<List<int>>(
        path,
        queryParameters: queryParameters,
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(res.data ?? const []);
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  /// Büyük bir dosyayı (ör. ~60 MB'lık güncelleme APK'sı) belleğe ALMADAN
  /// doğrudan [savePath]'e akıtır -- `getBytes`'ın aksine. AYNI Dio örneği
  /// kullanılır: çerez kavanozu ve tek-uçuş 401->refresh->retry burada da
  /// geçerlidir. Hata durumunda yarım dosyayı Dio siler. İptal
  /// ([cancelToken]) de bir `ApiException` olarak döner -- iptalin
  /// kullanıcıdan geldiğini token'ın sahibi (`cancelToken.isCancelled`)
  /// bilir, ayrı bir hata sınıfı İCAT EDİLMEDİ.
  ///
  /// [acceptHeaders] verilirse yanıt başlıkları gelir gelmez, gövdeden TEK
  /// bayt yazılmadan çağrılır; false dönerse bağlantı kesilir ve
  /// [DownloadRejected] fırlatılır (ör. sunucu beklenenden başka bir dosya
  /// sunuyorsa ~60 MB boşuna inmesin).
  ///
  /// Diske yazma hatası (ör. telefonda yer kalmadı) ağ hatası DEĞİLDİR:
  /// `ApiException`'a çevrilmez, asıl `FileSystemException` olarak fırlar.
  Future<void> download(
    String path,
    String savePath, {
    Map<String, dynamic>? query,
    void Function(int received, int total)? onReceiveProgress,
    CancelToken? cancelToken,
    bool Function(Headers headers)? acceptHeaders,
  }) async {
    // Başlıklar reddedilince gövdeyi okumadan kesebilmek için İÇ token.
    // Çağıranın iptali buna aktarılır; tersi yapılmaz -- çağıranın token'ı
    // yalnızca kullanıcının iptalini gösterir, "reddedildi" ile karışmaz.
    final token = CancelToken();
    if (cancelToken != null) {
      if (cancelToken.isCancelled) {
        token.cancel(cancelToken.cancelError?.error);
      } else {
        unawaited(cancelToken.whenCancel.then((e) {
          if (!token.isCancelled) token.cancel(e.error);
        }));
      }
    }
    var rejected = false;
    try {
      await _dio.download(
        path,
        (Headers headers) {
          if (acceptHeaders != null && !acceptHeaders(headers)) {
            rejected = true;
            // Dio dosyayı açar, akışa abone olur ve iptali görünce aboneliği
            // (dolayısıyla bağlantıyı) kapatıp boş dosyayı siler.
            token.cancel('yanıt başlıkları reddedildi');
          }
          return savePath;
        },
        queryParameters: query,
        onReceiveProgress: onReceiveProgress,
        cancelToken: token,
      );
    } on DioException catch (e) {
      if (rejected && !(cancelToken?.isCancelled ?? false)) throw const DownloadRejected();
      // Dio, akış sırasında diske yazılamayınca (raf.writeFrom) hatayı
      // DioException(unknown) içine sarar -- aksi halde "yer yok" durumu
      // kullanıcıya "internet bağlantınızı kontrol edin" diye yansırdı.
      // (Dosyayı açarken oluşan hatayı Dio zaten sarmadan fırlatır.)
      final cause = e.error;
      if (e.type == DioExceptionType.unknown && cause is FileSystemException) {
        Error.throwWithStackTrace(cause, e.stackTrace);
      }
      // Akış (stream) yanıtında onError interceptor'ı hata gövdesini henüz
      // okuyamaz; Dio gövdeyi ancak burada JSON'a çevirmiş olur. Hesap-
      // erişim engeli (askıya alınmış firma vb.) bu yüzden burada da AYNI
      // merkezi sınıflandırmadan geçer -- tek-seferlik guard çift bildirimi
      // zaten önler.
      final issue = classifyAccountAccessIssue(
        statusCode: e.response?.statusCode,
        code: _extractCode(e.response?.data),
        rawMessage: _extractError(e.response?.data),
      );
      if (issue != null) await _notifyAccountAccessBlocked(issue);
      throw _mapDioException(e);
    }
  }

  Future<T> _send<T>(Future<Response<dynamic>> Function() request) async {
    try {
      final res = await request();
      return res.data as T;
    } on DioException catch (e) {
      throw _mapDioException(e);
    }
  }

  ApiException _mapDioException(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return const ApiException(
        statusCode: null,
        message: 'İstek zaman aşımına uğradı. Lütfen tekrar deneyin.',
        kind: ApiErrorKind.timeout,
      );
    }
    if (e.type == DioExceptionType.connectionError || e.error is SocketException) {
      return mapHttpError(null, null);
    }
    final status = e.response?.statusCode;
    final serverMessage = _extractError(e.response?.data);
    return mapHttpError(status, serverMessage);
  }

  String? _extractError(dynamic data) {
    try {
      final map = data is String ? jsonDecode(data) : data;
      if (map is Map && map['error'] is String) return map['error'] as String;
    } catch (_) {
      // Gövde JSON değilse (ör. ham HTML/plain text) sessizce yut, generic
      // mesaja düşülür - kullanıcıya parse hatası gösterilmez.
    }
    return null;
  }

  /// `code` alanı yalnızca ÜÇ backend ucunda bulunur (tenant_context_required/
  /// permission_denied/project_access_denied, bkz. classifyAccountAccessIssue
  /// yorumu) -- diğer TÜM hata gövdelerinde yoktur, bu yüzden `null` normaldir.
  String? _extractCode(dynamic data) {
    try {
      final map = data is String ? jsonDecode(data) : data;
      if (map is Map && map['code'] is String) return map['code'] as String;
    } catch (_) {
      // bkz. _extractError.
    }
    return null;
  }

  Future<void> clearSession() => _cookieJar.deleteAll();

  /// 401 -> tek uçuş refresh -> orijinal isteği bir kez retry. Yalnızca
  /// `_isNoRefreshPath` dışındaki isteklerde tetiklenir; retried isteğin
  /// extra'sında `_retried=true` işaretlenir ki tekrar 401 alırsa YENİ bir
  /// refresh zinciri başlamasın (sonsuz döngü koruması). Dio'nun
  /// QueuedInterceptor'ı yerine single-flight elle (_refreshCompleter ile)
  /// yönetiliyor; paralel 401'lerin hepsi AYNI Future'ı bekler.
  Interceptor _buildAuthRefreshInterceptor() {
    return InterceptorsWrapper(
      onError: (error, handler) async {
        // 401 refresh akışından BAĞIMSIZ: organizasyon/kullanıcı engeli HER
        // yoldaki isteğin cevabında (tenant_context_required dahil, o da 403)
        // ortaya çıkabilir -- token'ın kendisi hâlâ "geçerli" olsa bile.
        final issue = classifyAccountAccessIssue(
          statusCode: error.response?.statusCode,
          code: _extractCode(error.response?.data),
          rawMessage: _extractError(error.response?.data),
        );
        if (issue != null) {
          await _notifyAccountAccessBlocked(issue);
          return handler.next(error);
        }

        final path = error.requestOptions.path;
        final alreadyRetried = error.requestOptions.extra['_retried'] == true;

        if (error.response?.statusCode != 401 || _isNoRefreshPath(path) || alreadyRetried) {
          return handler.next(error);
        }

        final refreshed = await _refreshOnce();
        if (!refreshed) {
          return handler.next(error);
        }

        try {
          final retryOptions = error.requestOptions;
          retryOptions.extra['_retried'] = true;
          // Multipart gövde (dosya/fotoğraf yükleme) ilk gönderimde
          // "finalize" edildi; aynı FormData ikinci kez gönderilemez (Dio
          // StateError atar ve kullanıcı "Bağlantı kurulamadı" görürdü --
          // 15 dk boşta kalınca ilk yükleme hep böyle düşüyordu). Klon aynı
          // sınırı (boundary) ve dosyaları baştan okuyan yeni akışları taşır.
          final data = retryOptions.data;
          if (data is FormData) retryOptions.data = data.clone();
          final response = await _dio.fetch(retryOptions);
          return handler.resolve(response);
        } on DioException catch (retryError) {
          return handler.next(retryError);
        }
      },
    );
  }

  Future<bool> _refreshOnce() {
    final existing = _refreshCompleter;
    if (existing != null) return existing.future;

    final completer = Completer<bool>();
    _refreshCompleter = completer;

    _dio.post<dynamic>('/auth/refresh').then((_) {
      completer.complete(true);
    }).catchError((Object err) {
      // `onError` interceptor'ı (yukarıda) BU isteğin cevabını da görür ve
      // sınıflandırılabilir bir organizasyon/kullanıcı engeli varsa
      // `_accountBlockNotified`'ı ÇOKTAN true yapıp onAccountAccessBlocked'ı
      // ÇOKTAN tetiklemiştir -- burada TEKRAR (bu sefer onSessionExpired ile)
      // bildirmek "tek yetkili oturum-sıfırlama yolu" ilkesini bozar, bu
      // yüzden yalnızca guard hâlâ açıksa (sınıflandırılamayan -- ör. sıradan
      // geçersiz/süresi dolmuş refresh token -- bir 401/403 ise) düşülür.
      if (!_accountBlockNotified &&
          err is DioException &&
          (err.response?.statusCode == 401 || err.response?.statusCode == 403)) {
        onSessionExpired?.call();
      }
      completer.complete(false);
    }).whenComplete(() {
      _refreshCompleter = null;
    });

    return completer.future;
  }
}

/// [ApiClient.download]'ın `acceptHeaders`'ı yanıtı reddetti -- gövde
/// indirilmedi, diske hiçbir şey kalmadı.
class DownloadRejected implements Exception {
  const DownloadRejected();

  @override
  String toString() => 'DownloadRejected';
}

/// Debug build'de yararlı istek/yanıt logu; production'da HİÇ eklenmez
/// (bkz. ApiClient.create). Cookie/Set-Cookie/Authorization header'ları ve
/// gövdedeki password alanı loglanmaz.
class _RedactingLogInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // ignore: avoid_print
    print('--> ${options.method} ${options.path} ${_redactBody(options.data)}');
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    // ignore: avoid_print
    print('<-- ${response.statusCode} ${response.requestOptions.path}');
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    // ignore: avoid_print
    print('<-- ERROR ${err.response?.statusCode} ${err.requestOptions.path}: ${err.message}');
    handler.next(err);
  }

  dynamic _redactBody(dynamic data) {
    if (data is Map) {
      return data.map((k, v) => MapEntry(k, k == 'password' ? '***' : v));
    }
    return data is FormData ? '<multipart>' : data;
  }
}
