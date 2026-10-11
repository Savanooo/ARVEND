import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/auth/permission_refresh_watcher.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';

import '../../test_utils/fake_api_client.dart';

/// Yetki değişiklikleri uygulama yeniden başlatılmadan görünür: öne
/// gelişte, açıkken belli aralıkla ve bir uç "yetkiniz yok" deyince
/// /auth/me tazelenir. Eskiden izin listesi yalnızca açılışta ve girişte
/// okunuyordu.

Map<String, dynamic> _me(List<String> permissions, {String id = 'u1'}) => {
      'id': id,
      'organization_id': 'org1',
      'username': 'pm',
      'full_name': 'Proje Yöneticisi',
      'role': 'kullanici',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'organization_name': 'ARVEND Yapı',
      'organization_role_code': 'project_manager',
      'organization_role_name': 'Proje Yöneticisi',
      'permissions': permissions,
    };

ScriptedResponse _ok(List<String> permissions) => (status: 200, body: _me(permissions));

int _meCalls(FakeHttpClientAdapter a) => a.calls.where((c) => c == '/auth/me').length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AuthController.recheckPermissions', () {
    Future<(ProviderContainer, FakeHttpClientAdapter)> container(List<ScriptedResponse> me) async {
      final adapter = FakeHttpClientAdapter(script: {'/auth/me': me});
      final c = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(await buildFakeApiClient(adapter))]);
      addTearDown(c.dispose);
      return (c, adapter);
    }

    test('sunucuda verilen yetki tazelemeyle görünür; aralık dolmadan tekrar istek atılmaz', () async {
      var now = DateTime(2026, 10, 11, 9);
      await withClock(Clock(() => now), () async {
        final (c, adapter) = await container([
          _ok(['projects.read']),
          _ok(['projects.read', 'projects.expenses.approve']),
        ]);
        await c.read(authControllerProvider.future);
        final notifier = c.read(authControllerProvider.notifier);

        // Girişin hemen ardından: aralık dolmadı, istek yok.
        await notifier.recheckPermissions();
        expect(_meCalls(adapter), 1);

        now = now.add(AuthController.permissionRecheckInterval + const Duration(seconds: 1));
        await notifier.recheckPermissions();
        expect(_meCalls(adapter), 2);
        expect(c.read(authControllerProvider).valueOrNull?.hasPermission('projects.expenses.approve'), isTrue);

        // Hemen ardından tekrar: seyreltilir.
        await notifier.recheckPermissions();
        expect(_meCalls(adapter), 2);
      });
    });

    test('geri alınan yetki de düşer; force aralığı beklemez', () async {
      final (c, adapter) = await container([
        _ok(['projects.read', 'projects.expenses.approve']),
        _ok(['projects.read']),
      ]);
      await c.read(authControllerProvider.future);

      await c.read(authControllerProvider.notifier).recheckPermissions(force: true);

      expect(_meCalls(adapter), 2);
      expect(c.read(authControllerProvider).valueOrNull?.hasPermission('projects.expenses.approve'), isFalse);
    });

    test('kullanıcı değişmediyse durum yeniden yazılmaz (ekranlar boşuna çizilmez)', () async {
      final (c, _) = await container([
        _ok(['projects.read', 'offers.read']),
        _ok(['offers.read', 'projects.read']), // aynı küme, farklı sıra
      ]);
      await c.read(authControllerProvider.future);
      var notified = 0;
      c.listen<AsyncValue<User?>>(authControllerProvider, (_, _) => notified++);

      await c.read(authControllerProvider.notifier).recheckPermissions(force: true);

      expect(notified, 0);
    });

    test('ağ hatasında eldeki kullanıcı ve izinleri korunur', () async {
      final (c, _) = await container([_ok(['projects.read'])]); // ikinci /auth/me betiklenmedi -> hata
      await c.read(authControllerProvider.future);

      await c.read(authControllerProvider.notifier).recheckPermissions(force: true);

      expect(c.read(authControllerProvider).valueOrNull?.hasPermission('projects.read'), isTrue);
    });

    test('oturum yokken hiçbir şey yapmaz', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 401, body: {'error': 'oturum bulunamadı'})],
        '/auth/refresh': [(status: 401, body: {'error': 'oturum bulunamadı'})],
      });
      final c = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(await buildFakeApiClient(adapter))]);
      addTearDown(c.dispose);
      expect(await c.read(authControllerProvider.future), isNull);

      await c.read(authControllerProvider.notifier).recheckPermissions(force: true);

      expect(_meCalls(adapter), 1);
    });
  });

  group('PermissionRefreshWatcher', () {
    Future<FakeHttpClientAdapter> pump(WidgetTester tester, List<ScriptedResponse> me) async {
      final adapter = FakeHttpClientAdapter(script: {'/auth/me': me});
      final client = await buildFakeApiClient(adapter);
      await tester.pumpWidget(ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(client)],
        child: MaterialApp(
          home: PermissionRefreshWatcher(
            child: Consumer(builder: (context, ref, _) {
              final user = ref.watch(authControllerProvider).valueOrNull;
              final canApprove = user?.hasPermission('projects.expenses.approve') ?? false;
              return Text(canApprove ? 'Onayla görünür' : 'Onayla yok');
            }),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return adapter;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    void backgroundThenForeground(WidgetTester tester) {
      for (final s in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
    }

    testWidgets('uygulama öne gelince web\'den verilen yetki görünür', (tester) async {
      final adapter = await pump(tester, [
        _ok(['projects.read']),
        _ok(['projects.read', 'projects.expenses.approve']),
      ]);
      expect(find.text('Onayla yok'), findsOneWidget);

      await tester.pump(AuthController.permissionRecheckInterval);
      backgroundThenForeground(tester);
      await settle(tester);

      expect(_meCalls(adapter), 2);
      expect(find.text('Onayla görünür'), findsOneWidget);
    });

    testWidgets('uygulama açıkken belli aralıkla tazelenir', (tester) async {
      final adapter = await pump(tester, [
        _ok(['projects.read']),
        _ok(['projects.read', 'projects.expenses.approve']),
      ]);

      await tester.pump(PermissionRefreshWatcher.defaultInterval);
      await settle(tester);

      expect(_meCalls(adapter), 2);
      expect(find.text('Onayla görünür'), findsOneWidget);
    });

    testWidgets('arka plandayken zamanlayıcı istek atmaz', (tester) async {
      final adapter = await pump(tester, [_ok(['projects.read'])]);
      for (final s in const [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }

      await tester.pump(PermissionRefreshWatcher.defaultInterval * 3);
      await settle(tester);

      expect(_meCalls(adapter), 1);
      // Sonraki testler "resumed" durumundan başlasın.
      for (final s in const [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await settle(tester);
    });
  });

  group('ApiClient.onPermissionDenied', () {
    test('403 permission_denied bildirilir, oturum düşürülmez', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/expenses/e1/approve': [
          (status: 403, body: {'error': 'bu işlem için yetkiniz yok', 'code': 'permission_denied'}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      var denied = 0;
      var expired = 0;
      client.onPermissionDenied = () => denied++;
      client.onSessionExpired = () => expired++;

      await expectLater(
        client.post<void>('/projects/p1/expenses/e1/approve'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403)),
      );

      expect(denied, 1);
      expect(expired, 0);
    });

    test('kodsuz 403 ve 404 bildirilmez', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/a': [(status: 403, body: {'error': 'teklif kilitli'})],
        '/b': [(status: 404, body: {'error': 'bulunamadı', 'code': 'permission_denied'})],
      });
      final client = await buildFakeApiClient(adapter);
      var denied = 0;
      client.onPermissionDenied = () => denied++;

      await expectLater(client.get<void>('/a'), throwsA(isA<ApiException>()));
      await expectLater(client.get<void>('/b'), throwsA(isA<ApiException>()));

      expect(denied, 0);
    });
  });
}
