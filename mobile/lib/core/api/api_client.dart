import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  /// Refresh başarısız olduğunda (401/403 - token geçersiz/kullanıcı pasif)
  /// tetiklenir; AuthController bunu dinleyip oturumu temizler ve
  /// go_router'ın auth redirect'i /giris'e yönlendirir. Ağ hatası/5xx'te
  /// TETİKLENMEZ (geçici kesintide oturum düşürülmez).
  void Function()? onSessionExpired;

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
      if (err is DioException &&
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
