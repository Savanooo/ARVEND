import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/errors/api_exception.dart';

import '../../test_utils/fake_api_client.dart';

/// ARVEND Mobile — FINAL entegrasyon fazı: backend'in organizasyon/kullanıcı
/// engeli için döndüğü SABİT (kod YOK, yalnızca belirli Türkçe mesaj metni)
/// 403 imzalarının doğru sınıflandırıldığını ve ApiClient'ın bunu TEK
/// seferlik bir bildirime (istek fırtınası koruması) çevirdiğini doğrular
/// (bkz. lib/core/errors/api_exception.dart classifyAccountAccessIssue,
/// lib/core/api/api_client.dart _notifyAccountAccessBlocked).
void main() {
  group('classifyAccountAccessIssue', () {
    test('code=tenant_context_required -> tenantContextRequired', () {
      expect(
        classifyAccountAccessIssue(statusCode: 403, code: 'tenant_context_required', rawMessage: 'x'),
        AccountAccessIssue.tenantContextRequired,
      );
    });

    test('"firma askıya alınmış veya erişilemiyor" -> organizationBlocked', () {
      expect(
        classifyAccountAccessIssue(
            statusCode: 403, code: null, rawMessage: 'firma askıya alınmış veya erişilemiyor'),
        AccountAccessIssue.organizationBlocked,
      );
    });

    test('"kullanıcı pasif durumda" -> userBlocked', () {
      expect(
        classifyAccountAccessIssue(statusCode: 403, code: null, rawMessage: 'kullanıcı pasif durumda'),
        AccountAccessIssue.userBlocked,
      );
    });

    test('sınıflandırılamayan 403 (ör. tek bir aksiyon için izin yok) -> null', () {
      expect(
        classifyAccountAccessIssue(statusCode: 403, code: null, rawMessage: 'bu işlem için yetkiniz yok'),
        isNull,
      );
    });

    test('401 asla sınıflandırılmaz (bu imzalar YALNIZCA 403)', () {
      expect(
        classifyAccountAccessIssue(
            statusCode: 401, code: null, rawMessage: 'oturum geçersiz veya süresi dolmuş'),
        isNull,
      );
    });
  });

  group('ApiClient hesap-erişim engeli bildirimi', () {
    test('organizasyon engeli: onAccountAccessBlocked bir kez tetiklenir, onSessionExpired TETİKLENMEZ', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects': [
          (status: 403, body: {'error': 'firma askıya alınmış veya erişilemiyor'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final blocked = <AccountAccessIssue>[];
      var sessionExpiredCount = 0;
      client.onAccountAccessBlocked = blocked.add;
      client.onSessionExpired = () => sessionExpiredCount++;

      await expectLater(client.get<Map<String, dynamic>>('/projects'), throwsA(isA<ApiException>()));

      expect(blocked, [AccountAccessIssue.organizationBlocked]);
      expect(sessionExpiredCount, 0);
    });

    test('kullanıcı engeli: userBlocked ile bildirilir', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/': [
          (status: 403, body: {'error': 'kullanıcı pasif durumda'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final blocked = <AccountAccessIssue>[];
      client.onAccountAccessBlocked = blocked.add;

      await expectLater(client.get<Map<String, dynamic>>('/offers/'), throwsA(isA<ApiException>()));

      expect(blocked, [AccountAccessIssue.userBlocked]);
    });

    test('super_admin bir kiracı ucuna isabet eder: tenant_context_required koduyla bildirilir', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects': [
          (
            status: 403,
            body: {'error': 'bu uç yalnızca bir firmaya bağlı hesaplar içindir', 'code': 'tenant_context_required'}
          ),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final blocked = <AccountAccessIssue>[];
      client.onAccountAccessBlocked = blocked.add;

      await expectLater(client.get<Map<String, dynamic>>('/projects'), throwsA(isA<ApiException>()));

      expect(blocked, [AccountAccessIssue.tenantContextRequired]);
    });

    test('paralel birden fazla 403: YALNIZCA bir kez bildirilir (istek fırtınası koruması)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects': [(status: 403, body: {'error': 'firma askıya alınmış veya erişilemiyor'})],
        '/offers/': [(status: 403, body: {'error': 'firma askıya alınmış veya erişilemiyor'})],
        '/tasks/mine': [(status: 403, body: {'error': 'firma askıya alınmış veya erişilemiyor'})],
      });
      final client = await buildFakeApiClient(adapter);
      final blocked = <AccountAccessIssue>[];
      client.onAccountAccessBlocked = blocked.add;

      await Future.wait([
        client.get<Map<String, dynamic>>('/projects').catchError((_) => <String, dynamic>{}),
        client.get<Map<String, dynamic>>('/offers/').catchError((_) => <String, dynamic>{}),
        client.get<Map<String, dynamic>>('/tasks/mine').catchError((_) => <String, dynamic>{}),
      ]);

      expect(blocked, [AccountAccessIssue.organizationBlocked]);
    });

    test('sıradan (sınıflandırılamayan) 403: onAccountAccessBlocked de onSessionExpired de TETİKLENMEZ', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontracts': [
          (status: 403, body: {'error': 'bu işlem için yetkiniz yok'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final blocked = <AccountAccessIssue>[];
      var sessionExpiredCount = 0;
      client.onAccountAccessBlocked = blocked.add;
      client.onSessionExpired = () => sessionExpiredCount++;

      await expectLater(
        client.get<Map<String, dynamic>>('/projects/p1/subcontracts'),
        throwsA(isA<ApiException>().having((e) => e.isForbidden, 'isForbidden', true)),
      );

      expect(blocked, isEmpty);
      expect(sessionExpiredCount, 0);
    });

    test('resetAccountAccessGuard çağrılana kadar tekrar bildirilmez; çağrıldıktan sonra tekrar açılır', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects': [
          (status: 403, body: {'error': 'firma askıya alınmış veya erişilemiyor'}),
          (status: 403, body: {'error': 'firma askıya alınmış veya erişilemiyor'}),
          (status: 403, body: {'error': 'firma askıya alınmış veya erişilemiyor'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final blocked = <AccountAccessIssue>[];
      client.onAccountAccessBlocked = blocked.add;

      await expectLater(client.get<Map<String, dynamic>>('/projects'), throwsA(isA<ApiException>()));
      expect(blocked, [AccountAccessIssue.organizationBlocked]);

      // Guard sıfırlanmadan İKİNCİ bir 403 -- tekrar bildirilmemeli (AuthController
      // zaten oturumu düşürmüş, ekran çoktan yönlendirilmiş olmalı -- bkz.
      // app_router.dart).
      await expectLater(client.get<Map<String, dynamic>>('/projects'), throwsA(isA<ApiException>()));
      expect(blocked, [AccountAccessIssue.organizationBlocked]);

      // Yeni bir girişte (bkz. AuthController.login) guard açılır -- SONRAKİ
      // bir engel tekrar bildirilebilmeli.
      client.resetAccountAccessGuard();
      await expectLater(client.get<Map<String, dynamic>>('/projects'), throwsA(isA<ApiException>()));
      expect(blocked, [AccountAccessIssue.organizationBlocked, AccountAccessIssue.organizationBlocked]);
    });
  });
}
