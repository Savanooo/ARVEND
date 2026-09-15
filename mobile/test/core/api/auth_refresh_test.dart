import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/errors/api_exception.dart';

import '../../test_utils/fake_api_client.dart';

void main() {
  group('ApiClient tek uçuş 401 refresh', () {
    test('401 -> tek refresh -> orijinal istek bir kez tekrarlanır', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers': [
          (status: 401, body: {'error': 'oturum geçersiz veya süresi dolmuş'}),
          (status: 200, body: {'offers': []}),
        ],
        '/auth/refresh': [
          (status: 200, body: {'id': 'u1', 'username': 'admin', 'full_name': 'Admin', 'role': 'admin', 'is_active': true}),
        ],
      });
      final client = await buildFakeApiClient(adapter);

      final result = await client.get<Map<String, dynamic>>('/offers');

      expect(result, {'offers': []});
      expect(adapter.calls, ['/offers', '/auth/refresh', '/offers']);
    });

    test('paralel 401ler tek refresh paylaşır (single-flight)', () async {
      final script = <String, List<ScriptedResponse>>{
        '/auth/refresh': [
          (status: 200, body: {'id': 'u1', 'username': 'a', 'full_name': 'A', 'role': 'admin', 'is_active': true}),
        ],
      };
      for (var i = 0; i < 5; i++) {
        script['/projects/$i'] = [
          (status: 401, body: {'error': 'x'}),
          (status: 200, body: {'id': '$i'}),
        ];
      }
      final adapter = FakeHttpClientAdapter(script: script);
      final client = await buildFakeApiClient(adapter);

      final results = await Future.wait(
        List.generate(5, (i) => client.get<Map<String, dynamic>>('/projects/$i')),
      );

      expect(results.map((r) => r['id']), ['0', '1', '2', '3', '4']);
      expect(adapter.calls.where((p) => p == '/auth/refresh').length, 1);
    });

    test('refresh 401 dönerse onSessionExpired tetiklenir, orijinal hata dışarı çıkar', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers': [
          (status: 401, body: {'error': 'oturum geçersiz veya süresi dolmuş'}),
        ],
        '/auth/refresh': [
          (status: 401, body: {'error': 'refresh token yok'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      var sessionExpired = false;
      client.onSessionExpired = () => sessionExpired = true;

      await expectLater(
        client.get<Map<String, dynamic>>('/offers'),
        throwsA(isA<ApiException>().having((e) => e.isAuthError, 'isAuthError', true)),
      );
      expect(sessionExpired, isTrue);
      expect(adapter.calls, ['/offers', '/auth/refresh']);
    });

    test('login 401 refresh tetiklemez', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/login': [
          (status: 401, body: {'error': 'kullanıcı adı veya şifre hatalı'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);

      await expectLater(
        client.post<Map<String, dynamic>>('/auth/login', data: {'username': 'x', 'password': 'y'}),
        throwsA(isA<ApiException>()),
      );
      expect(adapter.calls, ['/auth/login']);
    });

    test('retry de 401 dönerse ikinci bir refresh başlatılmaz', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers': [
          (status: 401, body: {'error': 'x'}),
          (status: 401, body: {'error': 'x'}),
        ],
        '/auth/refresh': [
          (status: 200, body: {'id': 'u1', 'username': 'a', 'full_name': 'A', 'role': 'admin', 'is_active': true}),
        ],
      });
      final client = await buildFakeApiClient(adapter);

      await expectLater(client.get<Map<String, dynamic>>('/offers'), throwsA(isA<ApiException>()));
      expect(adapter.calls, ['/offers', '/auth/refresh', '/offers']);
    });
  });
}
