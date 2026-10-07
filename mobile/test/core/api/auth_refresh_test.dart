import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/projects/data/projects_repository.dart';

import '../../test_utils/fake_api_client.dart';

/// Gerçek bir adaptör gibi istek gövdesini (multipart akışını) SONUNA KADAR
/// okur ve her isteğin baytlarını saklar -- `FakeHttpClientAdapter` akışa
/// dokunmaz, bu yüzden yeniden gönderilen bir FormData'nın gerçekten
/// okunabildiğini o tek başına göstermez.
class _DrainingAdapter implements HttpClientAdapter {
  _DrainingAdapter(this._inner);
  final FakeHttpClientAdapter _inner;
  final List<String> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    bodies.add(latin1.decode(bytes));
    return _inner.fetch(options, null, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

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

    test('401 alan dosya yüklemesi refresh sonrası AYNI dosyayla yeniden gönderilir', () async {
      // Erişim çerezi 15 dk yaşar: boşta kalınca ilk yükleme 401 alır.
      // Eskiden retry, ilk gönderimde "finalize" edilmiş FormData'yı tekrar
      // yollamaya çalışıp StateError'a düşüyor, kullanıcı "Bağlantı
      // kurulamadı" görüyordu.
      final dir = await Directory.systemTemp.createTemp('arvend_retry_upload');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/santiye.jpg');
      await file.writeAsBytes(utf8.encode('FOTO-BAYTLARI'));

      final fake = FakeHttpClientAdapter(
        script: {
          '/projects/p1/photos': [
            (status: 401, body: {'error': 'oturum geçersiz veya süresi dolmuş'}),
            (
              status: 201,
              body: {
                'id': 'ph1',
                'project_id': 'p1',
                'stage': 'progress',
                'description': '',
                'original_name': 'santiye.jpg',
                'mime_type': 'image/jpeg',
                'size_bytes': 13,
                'created_at': '2026-10-06T08:00:00Z',
              },
            ),
          ],
          '/auth/refresh': [
            (status: 200, body: {'id': 'u1', 'username': 'a', 'full_name': 'A', 'role': 'admin', 'is_active': true}),
          ],
        },
      );
      final adapter = _DrainingAdapter(fake);
      final client = await buildFakeApiClient(fake);
      client.dio.httpClientAdapter = adapter;

      final photo = await ProjectsRepository(client).uploadPhoto('p1', filePath: file.path, fileName: 'santiye.jpg');

      expect(photo.id, 'ph1');
      expect(fake.calls, ['/projects/p1/photos', '/auth/refresh', '/projects/p1/photos']);
      final uploads = [adapter.bodies[0], adapter.bodies[2]];
      for (final body in uploads) {
        expect(body, contains('FOTO-BAYTLARI'));
        expect(body, contains('name="stage"'));
      }
      // Aynı sınır (boundary): Content-Type başlığı ilk denemeden kalır.
      expect(uploads[1], uploads[0]);
    });
  });
}
