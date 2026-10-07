import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/config/app_config.dart';

typedef ScriptedResponse = ({int status, Object? body});

/// Yol bazlı sahte HTTP adaptörü: her yol için sırayla tüketilen yanıt
/// kuyruğu. `ApiClient`'ın single-flight refresh/retry mantığını gerçek ağ
/// olmadan test etmek için (bkz. test/core/api/auth_refresh_test.dart).
class FakeHttpClientAdapter implements HttpClientAdapter {
  FakeHttpClientAdapter({required Map<String, List<ScriptedResponse>> script}) : _script = Map.of(script);

  final Map<String, List<ScriptedResponse>> _script;
  final List<String> calls = [];

  /// `options.path` ile 1:1 sırada -- gönderilen istek gövdesi (POST/PUT/
  /// PATCH). GET/DELETE için genelde null. Request-serialization testleri
  /// içindir (bkz. test/subcontract_form_test.dart).
  final List<Object?> requestBodies = [];

  /// `options.path` ile 1:1 sırada -- GET/DELETE sorgu parametreleri (ör.
  /// `?filter=aktif&q=ali`), `calls`'ın aksine query string DAHİL. Arama/
  /// filtre testleri içindir (bkz. test/customers_workflow_test.dart).
  final List<Map<String, dynamic>> requestQueries = [];

  /// `options.path` ile 1:1 sırada -- HTTP yöntemi (GET/POST/PUT…). Aynı
  /// yola giden oluşturma/düzenleme ayrımı içindir.
  final List<String> methods = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options.path);
    methods.add(options.method);
    requestBodies.add(options.data);
    requestQueries.add(options.queryParameters);
    final queue = _script[options.path];
    if (queue == null || queue.isEmpty) {
      throw StateError('beklenmeyen istek: ${options.path} (${calls.length}. çağrı)');
    }
    final response = queue.removeAt(0);
    // Ham bayt gövdesi (ör. bir fotoğraf/dosya indirme yanıtı) -- `body`
    // bir `List<int>` ise JSON-encode EDİLMEZ, olduğu gibi akıtılır.
    // Bkz. test/project_files_photos_test.dart (getBytes/photoBytes/
    // fileBytes testleri).
    if (response.body is List<int>) {
      return ResponseBody.fromBytes(response.body as List<int>, response.status, headers: {
        Headers.contentTypeHeader: ['application/octet-stream'],
      });
    }
    final data = response.body == null ? '' : jsonEncode(response.body);
    return ResponseBody.fromString(data, response.status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Future<ApiClient> buildFakeApiClient(FakeHttpClientAdapter adapter) async {
  final dio = Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl + AppConfig.apiPrefix));
  dio.httpClientAdapter = adapter;
  return ApiClient.test(dio);
}
