import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/auth/last_user_store.dart';
import 'package:arvend/core/errors/api_exception.dart';

import '../../test_utils/fake_api_client.dart';

Map<String, dynamic> _me({String id = 'u1', String fullName = 'Ali Usta'}) => {
      'id': id,
      'organization_id': 'org1',
      'username': 'ali',
      'full_name': fullName,
      'role': 'kullanici',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'organization_name': 'ARVEND Yapı',
      'organization_role_code': 'field',
      'organization_role_name': 'Saha',
      'permissions': ['projects.read', 'projects.operations.manage'],
    };

Future<ProviderContainer> _container(FakeHttpClientAdapter adapter) async {
  final client = await buildFakeApiClient(adapter);
  final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
  addTearDown(container.dispose);
  return container;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('açılışta oturum doğrulanamazsa (şantiyede çekmiyor)', () {
    test('son bilinen kullanıcıyla açılır, giriş ekranına atılmaz', () async {
      SharedPreferences.setMockInitialValues({
        LastUserStore.userKey: jsonEncode(_me()),
        LastUserStore.userIdKey: 'u1',
      });
      // /auth/me betiklenmedi -> bağlantı hatası.
      final c = await _container(FakeHttpClientAdapter(script: {}));

      final user = await c.read(authControllerProvider.future);

      expect(user?.id, 'u1');
      expect(user?.fullName, 'Ali Usta');
      expect(user?.hasPermission('projects.operations.manage'), isTrue);
    });

    test('bilinen kullanıcı yoksa hata kalır (null değil) -- router giriş ekranını gösterir, sonsuz yükleme yok',
        () async {
      final c = await _container(FakeHttpClientAdapter(script: {}));

      await expectLater(c.read(authControllerProvider.future), throwsA(isA<ApiException>()));
      final state = c.read(authControllerProvider);
      expect(state.isLoading, isFalse);
      expect(state.valueOrNull, isNull);
    });

    test('sunucu hatası (5xx) da oturumu düşürmez', () async {
      SharedPreferences.setMockInitialValues({LastUserStore.userKey: jsonEncode(_me())});
      final c = await _container(FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 502, body: {'error': 'bad gateway'})],
      }));

      expect((await c.read(authControllerProvider.future))?.id, 'u1');
    });
  });

  test('oturum doğrulanınca kullanıcı saklanır; 401 olunca silinir', () async {
    final c = await _container(FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 200, body: _me(fullName: 'Ali Usta (güncel)'))],
    }));
    await c.read(authControllerProvider.future);
    await _settle();
    final stored = await LastUserStore().read();
    expect(stored?.fullName, 'Ali Usta (güncel)');

    final c2 = await _container(FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 401, body: {'error': 'oturum bulunamadı'})],
      '/auth/refresh': [(status: 401, body: {'error': 'oturum bulunamadı'})],
    }));
    expect(await c2.read(authControllerProvider.future), isNull);
    await _settle();
    expect(await LastUserStore().read(), isNull);
    // Kimlik ayrı tutulur: oturum yokken dokunulan bildirimin sahibini
    // bilmek için (bkz. PushWatcher).
    expect(await LastUserStore().lastUserId(), 'u1');
  });
}
