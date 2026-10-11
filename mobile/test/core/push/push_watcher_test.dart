import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/push/push_messaging.dart';
import 'package:arvend/core/push/push_watcher.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/notifications/data/notifications_providers.dart';

import '../../test_utils/fake_api_client.dart';

class _FakePush implements PushMessaging {
  final foreground = StreamController<PushMessage>.broadcast();
  final opened = StreamController<PushMessage>.broadcast();
  final refresh = StreamController<String>.broadcast();
  PushMessage? initial;
  int permissionRequests = 0;
  int deletes = 0;
  int deleteAttempts = 0;

  /// Verilirse anahtar silinemez (ör. ağ yok).
  Object? deleteError;

  /// Verilirse silme bu tamamlanana kadar sürer (yavaş Play Hizmetleri).
  Completer<void>? deleteGate;

  /// Verilirse silmeden sonra Firebase'in vereceği yeni anahtar.
  String? tokenAfterDelete;
  String? currentToken = 'fcm-token-${'x' * 40}';

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<String?> token() async => currentToken;
  @override
  Stream<String> get onTokenRefresh => refresh.stream;
  @override
  Stream<PushMessage> get onForegroundMessage => foreground.stream;
  @override
  Stream<PushMessage> get onMessageOpenedApp => opened.stream;
  @override
  Future<PushMessage?> initialMessage() async => initial;
  @override
  Future<void> deleteToken() async {
    deleteAttempts++;
    if (deleteGate case final gate?) await gate.future;
    if (deleteError != null) throw deleteError!;
    deletes++;
    if (tokenAfterDelete case final next?) currentToken = next;
  }
}

class _Auth extends AuthController {
  _Auth(this._user);
  final User? _user;
  @override
  Future<User?> build() async => _user;

  void signIn(User user) => state = AsyncData(user);
  void signOut() => state = const AsyncData(null);
}

User _user({String id = 'u1'}) => User.fromJson({
      'id': id,
      'organization_id': 'org1',
      'username': 'ali',
      'full_name': 'Ali Usta',
      'role': 'kullanici',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': <String>[],
    });

Future<({FakeHttpClientAdapter adapter, ProviderContainer container, GoRouter router})> _pump(
  WidgetTester tester,
  _FakePush push, {
  User? user,
  Map<String, List<ScriptedResponse>> extra = const {},
}) async {
  final adapter = FakeHttpClientAdapter(script: {
    '/push/devices': [for (var i = 0; i < 5; i++) (status: 200, body: {'ok': true, 'push_enabled': true})],
    ...extra,
  });
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('ana'))),
      GoRoute(path: '/projeler/p1/gorevler/t1', builder: (_, _) => const Scaffold(body: Text('görev ekranı'))),
    ],
  );
  final container = ProviderContainer(overrides: [
    apiClientProvider.overrideWithValue(client),
    pushMessagingProvider.overrideWithValue(push),
    authControllerProvider.overrideWith(() => _Auth(user)),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        builder: (context, child) => PushWatcher(router: router, child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (adapter: adapter, container: container, router: router);
}

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'ARVEND', packageName: 'com.arvendyapi.arvend', version: '1.5.7', buildNumber: '13', buildSignature: '',
    );
  });

  testWidgets('oturum açıkken izin istenir ve telefon sunucuya kaydedilir', (tester) async {
    final push = _FakePush();
    final r = await _pump(tester, push, user: _user());
    expect(push.permissionRequests, 1);
    final i = r.adapter.calls.indexOf('/push/devices');
    expect(i, isNot(-1));
    final body = r.adapter.requestBodies[i] as Map;
    expect(body['token'], push.currentToken);
    expect(body['platform'], 'android');
    expect(body['app_version'], '1.5.7+13');

    // Firebase anahtarı yenileyince yeniden kaydedilir.
    push.refresh.add('yeni-token-${'y' * 40}');
    await tester.pumpAndSettle();
    expect(r.adapter.calls.where((c) => c == '/push/devices').length, 2);
  });

  testWidgets('oturum yokken kayıt yapılmaz', (tester) async {
    final push = _FakePush();
    final r = await _pump(tester, push);
    expect(push.permissionRequests, 0);
    expect(r.adapter.calls, isNot(contains('/push/devices')));
  });

  testWidgets('açıkken gelen bildirim alt bant olur; "Aç" hedef ekranı açar', (tester) async {
    final push = _FakePush();
    await _pump(tester, push, user: _user(), extra: {
      '/notifications/unread-count': [for (var i = 0; i < 3; i++) (status: 200, body: {'unread_count': 1})],
    });
    push.foreground.add(const PushMessage(
      title: 'Yeni görev atandı',
      body: 'Banyo seramiği',
      actionTarget: '/projeler/p1/gorevler/t1',
    ));
    await tester.pumpAndSettle();
    expect(find.text('Yeni görev atandı\nBanyo seramiği'), findsOneWidget);
    await tester.tap(find.text('Aç'));
    await tester.pumpAndSettle();
    expect(find.text('görev ekranı'), findsOneWidget);
  });

  testWidgets('dokunulan bildirim hedef ekranı açar', (tester) async {
    final push = _FakePush();
    await _pump(tester, push, user: _user());
    push.opened.add(const PushMessage(title: 'x', actionTarget: '/projeler/p1/gorevler/t1'));
    await tester.pumpAndSettle();
    expect(find.text('görev ekranı'), findsOneWidget);
  });

  testWidgets('uygulamayı açan bildirim, kapalıyken dokunulmuşsa yine hedefe gider', (tester) async {
    final push = _FakePush()..initial = const PushMessage(title: 'x', actionTarget: '/projeler/p1/gorevler/t1');
    await _pump(tester, push, user: _user());
    expect(find.text('görev ekranı'), findsOneWidget);
  });

  group('çıkışta bildirim anahtarı her durumda silinir (mobil-genel-b3)', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<bool> pending(WidgetTester tester) async =>
        (await tester.runAsync(() => PushCleanupStore().isPending()))!;

    void resume(WidgetTester tester) {
      for (final s in [
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

    testWidgets('sunucu kaydı silinemese de (503) anahtarın kendisi silinir, çıkış sürer', (tester) async {
      final push = _FakePush();
      final r = await _pump(tester, push, user: _user(), extra: {
        '/push/devices/unregister': [
          (status: 503, body: {'error': 'sunucu şu anda yanıt veremiyor', 'code': 'temporarily_unavailable'}),
        ],
        '/auth/logout': [(status: 200, body: {'ok': true})],
      });
      await tester.runAsync(() => r.container.read(authControllerProvider.notifier).logout());
      await tester.pumpAndSettle();

      expect(r.adapter.calls, contains('/push/devices/unregister'));
      expect(push.deletes, 1);
      expect(r.container.read(authControllerProvider).valueOrNull, isNull);
      expect(await pending(tester), isFalse);
    });

    testWidgets('anahtar silinemezse (ağ yok) kaydedilir; oturum yokken öne gelişte yeniden silinir', (tester) async {
      final push = _FakePush()..deleteError = Exception('SERVICE_NOT_AVAILABLE');
      final r = await _pump(tester, push, user: _user(), extra: {
        '/push/devices/unregister': [(status: 200, body: {'ok': true})],
        '/auth/logout': [(status: 200, body: {'ok': true})],
      });
      await tester.runAsync(() => r.container.read(authControllerProvider.notifier).logout());
      await tester.pumpAndSettle();
      expect(push.deleteAttempts, greaterThanOrEqualTo(1));
      expect(push.deletes, 0);
      expect(await pending(tester), isTrue);

      push.deleteError = null;
      resume(tester);
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      expect(push.deletes, 1);
      expect(await pending(tester), isFalse);
    });

    testWidgets('eski anahtar silinirken başka biri girerse yeni anahtarla kaydolur (silinecek olanla değil)',
        (tester) async {
      final push = _FakePush()
        ..deleteGate = Completer<void>()
        ..tokenAfterDelete = 'fcm-token-yeni-${'z' * 40}';
      final r = await _pump(tester, push, user: _user());
      final auth = r.container.read(authControllerProvider.notifier) as _Auth;
      final oldToken = push.currentToken;

      // Oturum süresi doldu: anahtar siliniyor (yavaş), bu arada u2 giriş yaptı.
      auth.sessionExpired();
      await tester.pumpAndSettle();
      auth.signIn(_user(id: 'u2'));
      await tester.pumpAndSettle();
      final registered = r.adapter.calls.where((c) => c == '/push/devices').length;
      expect(registered, 1, reason: 'u2, silme bitmeden kaydolmaz');

      push.deleteGate!.complete();
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      final bodies = [
        for (var i = 0; i < r.adapter.calls.length; i++)
          if (r.adapter.calls[i] == '/push/devices') r.adapter.requestBodies[i] as Map,
      ];
      expect(bodies, hasLength(2));
      expect(bodies.last['token'], push.tokenAfterDelete);
      expect(bodies.last['token'], isNot(oldToken));
    });

    testWidgets('bekleyen silme varken biri giriş yaparsa anahtar silinmez, onun adına kaydedilir', (tester) async {
      SharedPreferences.setMockInitialValues({PushCleanupStore.key: true});
      final push = _FakePush();
      final r = await _pump(tester, push, user: _user(id: 'u2'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();

      expect(push.deleteAttempts, 0);
      expect(r.adapter.calls, contains('/push/devices'));
      expect(await pending(tester), isFalse);
    });
  });

  testWidgets('çıkışta telefonun kaydı silinir', (tester) async {
    final push = _FakePush();
    final r = await _pump(tester, push, user: _user(), extra: {
      '/push/devices/unregister': [(status: 200, body: {'ok': true})],
      '/auth/logout': [(status: 200, body: {'ok': true})],
    });
    await tester.runAsync(() => r.container.read(authControllerProvider.notifier).logout());
    await tester.pumpAndSettle();
    final i = r.adapter.calls.indexOf('/push/devices/unregister');
    expect(i, isNot(-1));
    expect((r.adapter.requestBodies[i] as Map)['token'], push.currentToken);
    // Kayıt silme, oturum kapanmadan önce.
    expect(i, lessThan(r.adapter.calls.indexOf('/auth/logout')));
    expect(push.deletes, 1);
  });

  group('dokunulan bildirim', () {
    test('notification_id korunur', () {
      final m = PushMessage.fromData(title: 'x', data: {
        'notification_id': 'n-42',
        'action_target': '/projeler/p1/gorevler/t1',
        'type': 'task_assigned',
      });
      expect(m.notificationId, 'n-42');
    });

    testWidgets('okundu işaretlenir ve hedef açılır', (tester) async {
      final push = _FakePush();
      final r = await _pump(tester, push, user: _user(), extra: {
        '/notifications/n-42/read': [(status: 200, body: {'ok': true})],
        '/notifications/unread-count': [for (var i = 0; i < 3; i++) (status: 200, body: {'unread_count': 0})],
      });
      push.opened.add(const PushMessage(title: 'x', actionTarget: '/projeler/p1/gorevler/t1', notificationId: 'n-42'));
      await tester.pumpAndSettle();

      expect(find.text('görev ekranı'), findsOneWidget);
      expect(r.adapter.calls, contains('/notifications/n-42/read'));
    });

    testWidgets('oturum yokken dokunuldu, BAŞKA biri giriş yaptı: bildirim ona açılmaz', (tester) async {
      final push = _FakePush();
      final r = await _pump(tester, push, user: _user(id: 'u1'));
      final auth = r.container.read(authControllerProvider.notifier) as _Auth;
      auth.signOut();
      await tester.pumpAndSettle();

      push.opened.add(const PushMessage(title: 'x', actionTarget: '/projeler/p1/gorevler/t1', notificationId: 'n-1'));
      await tester.pumpAndSettle();
      auth.signIn(_user(id: 'u2'));
      await tester.pumpAndSettle();

      expect(find.text('görev ekranı'), findsNothing);
      expect(r.adapter.calls, isNot(contains('/notifications/n-1/read')));
    });

    testWidgets('oturum yokken dokunuldu, AYNI kişi giriş yaptı: hedef açılır', (tester) async {
      final push = _FakePush();
      final r = await _pump(tester, push, user: _user(id: 'u1'), extra: {
        '/notifications/n-1/read': [(status: 200, body: {'ok': true})],
        '/notifications/unread-count': [for (var i = 0; i < 3; i++) (status: 200, body: {'unread_count': 0})],
      });
      final auth = r.container.read(authControllerProvider.notifier) as _Auth;
      auth.signOut();
      await tester.pumpAndSettle();

      push.opened.add(const PushMessage(title: 'x', actionTarget: '/projeler/p1/gorevler/t1', notificationId: 'n-1'));
      await tester.pumpAndSettle();
      expect(find.text('görev ekranı'), findsNothing);

      auth.signIn(_user(id: 'u1'));
      await tester.pumpAndSettle();
      expect(find.text('görev ekranı'), findsOneWidget);
      expect(r.adapter.calls, contains('/notifications/n-1/read'));
    });

    testWidgets('hedef zaten açık ekransa ikinci kopyası açılmaz', (tester) async {
      final push = _FakePush();
      final r = await _pump(tester, push, user: _user());
      final before = r.router.routerDelegate.currentConfiguration.matches.length;
      push.opened.add(const PushMessage(title: 'Duyuru', actionTarget: '/'));
      await tester.pumpAndSettle();
      expect(r.router.routerDelegate.currentConfiguration.matches.length, before);
    });
  });

  testWidgets('uygulama öne gelince zil sayacı tazelenir', (tester) async {
    final push = _FakePush();
    final r = await _pump(tester, push, user: _user(), extra: {
      '/notifications/unread-count': [for (var i = 0; i < 3; i++) (status: 200, body: {'unread_count': 2})],
    });
    // Sayaç bir ekranda izleniyormuş gibi canlı tutulur.
    final sub = r.container.listen(unreadNotificationCountProvider, (_, _) {});
    addTearDown(sub.close);
    await tester.pumpAndSettle();
    final before = r.adapter.calls.where((c) => c == '/notifications/unread-count').length;

    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    // Ekran sayacı yeniden okuduğunda (geçersiz kılındığı için) yeni istek.
    final count = r.container.read(unreadNotificationCountProvider.future);
    await tester.pumpAndSettle();

    expect(await count, 2);
    expect(r.adapter.calls.where((c) => c == '/notifications/unread-count').length, before + 1);
  });
}
