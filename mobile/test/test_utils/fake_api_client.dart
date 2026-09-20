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

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options.path);
    requestBodies.add(options.data);
    final queue = _script[options.path];
    if (queue == null || queue.isEmpty) {
      throw StateError('beklenmeyen istek: ${options.path} (${calls.length}. çağrı)');
    }
    final response = queue.removeAt(0);
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
