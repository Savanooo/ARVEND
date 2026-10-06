import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/messages/presentation/announcement_screen.dart';
import 'package:arvend/features/messages/presentation/feedback_screen.dart';

import '../../test_utils/fake_api_client.dart';

class _Auth extends AuthController {
  _Auth(this._user);
  final User _user;
  @override
  Future<User?> build() async => _user;
}

User _user(List<String> permissions, {String role = 'kullanici'}) => User.fromJson({
      'id': 'u1',
      'organization_id': 'org1',
      'username': 'ali',
      'full_name': 'Ali Usta',
      'role': role,
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': permissions,
    });

Future<FakeHttpClientAdapter> _pump(
  WidgetTester tester,
  Widget screen, {
  List<String> permissions = const [],
  String role = 'kullanici',
  Map<String, List<ScriptedResponse>> script = const {},
}) async {
  final adapter = FakeHttpClientAdapter(script: script);
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: TextButton(onPressed: () => context.push('/ekran'), child: const Text('menü')),
        ),
      ),
      GoRoute(path: '/ekran', builder: (_, _) => screen),
    ],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(client),
      authControllerProvider.overrideWith(() => _Auth(_user(permissions, role: role))),
    ],
    child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('menü'));
  await tester.pumpAndSettle();
  return adapter;
}

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'ARVEND', packageName: 'com.arvendyapi.arvend', version: '1.5.7', buildNumber: '13', buildSignature: '',
    );
  });

  group('Duyuru Gönder', () {
    testWidgets('yetkisi olmayan formu görmez', (tester) async {
      await _pump(tester, const AnnouncementScreen(), permissions: ['projects.read']);
      expect(find.byKey(const Key('duyuru-baslik')), findsNothing);
      expect(find.textContaining('kullanıcı yönetimi yetkisi'), findsOneWidget);
    });

    testWidgets('boş gönderilemez; onaydan sonra gönderilir ve kaç kişiye gittiğini söyler', (tester) async {
      // Kullanıcı yönetimi izni mobilde kaba admin rolü de ister (kAdminRoleOnlyPermissions).
      final adapter = await _pump(tester, const AnnouncementScreen(), permissions: ['organization.users.manage'], role: 'admin', script: {
        '/announcements': [(status: 201, body: {'recipients': 7, 'push_enabled': true})],
      });
      await tester.tap(find.byKey(const Key('duyuru-gonder')));
      await tester.pumpAndSettle();
      expect(find.text('Başlık zorunlu'), findsOneWidget);
      expect(adapter.calls, isEmpty);

      await tester.enterText(find.byKey(const Key('duyuru-baslik')), 'Yarın şantiye kapalı');
      await tester.enterText(find.byKey(const Key('duyuru-metin')), ' Yağmur nedeniyle çalışma yok. ');
      await tester.tap(find.byKey(const Key('duyuru-gonder')));
      await tester.pumpAndSettle();
      expect(find.text('Duyuru gönderilsin mi?'), findsOneWidget);
      await tester.tap(find.text('Gönder').last);
      await tester.pumpAndSettle();

      final i = adapter.calls.indexOf('/announcements');
      expect(adapter.requestBodies[i], {'title': 'Yarın şantiye kapalı', 'body': 'Yağmur nedeniyle çalışma yok.'});
      expect(find.text('Duyuru 7 kişiye gönderildi.'), findsOneWidget);
      expect(find.text('menü'), findsOneWidget); // ekran kapandı
    });
  });

  group('Öneri Gönder', () {
    testWidgets('tür seçilir, metinle birlikte sürüm bilgisi gider; yönetici görmez notu var', (tester) async {
      final adapter = await _pump(tester, const FeedbackScreen(), script: {
        '/feedback': [(status: 201, body: {'ok': true})],
      });
      expect(find.textContaining('firma yöneticin görmez'), findsOneWidget);

      await tester.tap(find.byKey(const Key('oneri-gonder')));
      await tester.pumpAndSettle();
      expect(find.text('Mesaj boş olamaz'), findsOneWidget);

      await tester.tap(find.byKey(const Key('oneri-tur-hata')));
      await tester.enterText(find.byKey(const Key('oneri-metin')), 'Mesai ekranında tarih kayıyor');
      await tester.tap(find.byKey(const Key('oneri-gonder')));
      await tester.pumpAndSettle();

      final i = adapter.calls.indexOf('/feedback');
      expect(adapter.requestBodies[i], {'category': 'hata', 'body': 'Mesai ekranında tarih kayıyor', 'app_version': '1.5.7+13'});
      expect(find.text('Teşekkürler, ARVEND ekibine iletildi.'), findsOneWidget);
    });
  });
}
