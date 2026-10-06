import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/push/push_messaging.dart';
import 'package:arvend/core/push/push_watcher.dart';
import 'package:arvend/features/auth/domain/user.dart';

import '../../test_utils/fake_api_client.dart';

class _FakePush implements PushMessaging {
  final foreground = StreamController<PushMessage>.broadcast();
  final opened = StreamController<PushMessage>.broadcast();
  final refresh = StreamController<String>.broadcast();
  PushMessage? initial;
  int permissionRequests = 0;
  int deletes = 0;
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
  Future<void> deleteToken() async => deletes++;
}

class _Auth extends AuthController {
  _Auth(this._user);
  final User? _user;
  @override
  Future<User?> build() async => _user;
}

User _user() => User.fromJson({
      'id': 'u1',
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

Future<({FakeHttpClientAdapter adapter, ProviderContainer container})> _pump(
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
  return (adapter: adapter, container: container);
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
}
