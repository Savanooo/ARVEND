import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/push/push_watcher.dart' show rootScaffoldMessengerKey;
import 'package:arvend/features/ai_images/data/ai_images_providers.dart';
import 'package:arvend/features/ai_images/domain/ai_image.dart';
import 'package:arvend/features/ai_images/domain/ai_settings.dart';
import 'package:arvend/features/ai_images/domain/ai_studio.dart';
import 'package:arvend/features/ai_images/presentation/ai_settings_screen.dart';
import 'package:arvend/features/ai_images/presentation/ai_studio_screen.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/profile/presentation/other_menu_screen.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';

import '../../test_utils/fake_api_client.dart';
import '../contract_co/contract_co_test_support.dart' as cc;

/// Yapay Zekâ Ayarları (backend 0081): yönetici firmada açar/kapatır, kimin
/// kullanacağını ve aylık sınırları belirler, bu ayki kullanımı görür.

User _user({bool manage = true, bool ai = true}) => User.fromJson({
      'id': 'u1',
      'organization_id': 'org1',
      'username': 'sahip',
      'full_name': 'Firma Sahibi',
      'role': 'admin',
      'organization_role_code': 'owner',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': [
        'projects.read',
        'projects.expenses.create',
        if (ai) kAiImagesPermission,
        if (manage) kAiSettingsPermission,
      ],
    });

Map<String, dynamic> _settings({
  bool enabled = true,
  int? monthly,
  int? perUser,
  String aliSource = 'role',
  bool aliCanUse = false,
}) =>
    {
      'enabled': enabled,
      'monthly_limit': monthly,
      'effective_monthly_limit': monthly ?? 100,
      'server_max': 100,
      'per_user_monthly_limit': perUser,
      'used_this_month': 7,
      'resets_at': '2026-11-01T00:00:00+03:00',
      'users': [
        {
          'user_id': 'u1',
          'full_name': 'Firma Sahibi',
          'role_code': 'owner',
          'role_name': 'Sahip',
          'is_owner': true,
          'can_use': true,
          'source': 'role',
          'used_this_month': 5,
        },
        {
          'user_id': 'u2',
          'full_name': 'Ali Saha',
          'role_code': 'field',
          'role_name': 'Saha',
          'is_owner': false,
          'can_use': aliCanUse,
          'source': aliSource,
          'used_this_month': 2,
        },
      ],
    };

Map<String, dynamic> _status({bool firmEnabled = true, String blocked = '', int remaining = 93}) => {
      'enabled': firmEnabled,
      'server_enabled': true,
      'firm_enabled': firmEnabled,
      'can_use': true,
      'can_manage': true,
      'blocked_code': blocked.isEmpty ? '' : 'ai_disabled_by_admin',
      'blocked_reason': blocked,
      'quota': {
        'monthly_limit': 100,
        'used_this_month': 100 - remaining,
        'remaining': remaining,
        'user_hourly_limit': 10,
        'resets_at': '2026-11-01T00:00:00+03:00',
        'user_monthly_limit': null,
        'user_used_this_month': 5,
        'user_remaining': null,
      },
    };

List<ScriptedResponse> _many(Object? body, {int status = 200, int n = 8}) =>
    [for (var i = 0; i < n; i++) (status: status, body: body)];

Future<void> _advance(WidgetTester tester, [Duration total = const Duration(milliseconds: 600)]) async {
  const step = Duration(milliseconds: 100);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

Future<FakeHttpClientAdapter> _pump(
  WidgetTester tester, {
  required Widget home,
  User? user,
  Map<String, List<ScriptedResponse>> script = const {},
  Size size = const Size(400, 1400),
  double textScale = 1,
}) async {
  final adapter = FakeHttpClientAdapter(script: {
    '/ai/status': _many(_status(), n: 20),
    '/ai/settings': _many(_settings()),
    ...script,
  });
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    key: UniqueKey(),
    overrides: [
      apiClientProvider.overrideWithValue(client),
      authControllerProvider.overrideWith(() => cc.FakeAuth(user ?? _user())),
      projectPhotoCacheProvider.overrideWithValue(ProjectPhotoCache(directory: () async => null)),
    ],
    child: MaterialApp(
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    ),
  ));
  await _advance(tester);
  return adapter;
}

int _count(FakeHttpClientAdapter a, String path, String method) => [
      for (var i = 0; i < a.calls.length; i++)
        if (a.calls[i] == path && a.methods[i] == method) i,
    ].length;

Object? _lastBody(FakeHttpClientAdapter a, String path, String method) {
  for (var i = a.calls.length - 1; i >= 0; i--) {
    if (a.calls[i] == path && a.methods[i] == method) return a.requestBodies[i];
  }
  return null;
}

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));
  setUp(() => SharedPreferences.setMockInitialValues({AiConsentStore.keyFor('u1'): true}));

  testWidgets('bölümler: firma anahtarı, kişiler (rozetle), sınırlar, bu ay kullanım', (tester) async {
    await _pump(tester, home: const AiSettingsScreen());
    expect(find.text('Yapay zekâ bu firmada açık'), findsOneWidget);
    expect(find.text('Kimler kullanabilir'), findsOneWidget);
    expect(find.text('Sınırlar'), findsOneWidget);
    expect(find.text('Bu ay kullanım'), findsOneWidget);
    expect(find.textContaining('Sahip her zaman kullanabilir'), findsOneWidget);
    expect(find.text('Saha · Rolünden'), findsOneWidget);
    expect(find.textContaining('Sunucu üst sınırı: 100'), findsOneWidget);
    expect(find.text('Firma: 7 / 100 görsel'), findsOneWidget);
    expect(find.text('5 görsel'), findsOneWidget);
    expect(find.text('2 görsel'), findsOneWidget);
    // Sahip'in düğmesi kilitli ve açık.
    final owner = tester.widget<Switch>(find.byKey(const ValueKey('ai-settings-switch-u1')));
    expect(owner.value, isTrue);
    expect(owner.onChanged, isNull);
    // Rolünden gelen satırda "Rolüne bırak" menüsü yok.
    expect(find.byKey(const ValueKey('ai-settings-menu-u2')), findsNothing);
  });

  testWidgets('kişi düğmesi PUT users/{id} can_use=true; yanıtla "Kişiye özel açık", sonra Rolüne bırak null gönderir',
      (tester) async {
    final adapter = await _pump(tester, home: const AiSettingsScreen(), script: {
      '/ai/settings/users/u2': [
        (status: 200, body: _settings(aliSource: 'override_allow', aliCanUse: true)),
        (status: 200, body: _settings()),
      ],
    });
    await tester.tap(find.byKey(const ValueKey('ai-settings-switch-u2')));
    await _advance(tester);
    expect(_lastBody(adapter, '/ai/settings/users/u2', 'PUT'), {'can_use': true});
    expect(find.text('Saha · Kişiye özel açık'), findsOneWidget);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('ai-settings-switch-u2'))).value, isTrue);

    await tester.tap(find.byKey(const ValueKey('ai-settings-menu-u2')));
    await _advance(tester);
    await tester.tap(find.text('Rolüne bırak'));
    await _advance(tester);
    expect(_lastBody(adapter, '/ai/settings/users/u2', 'PUT'), {'can_use': null});
    expect(find.text('Saha · Rolünden'), findsOneWidget);
  });

  testWidgets('kişiye özel kapalı: basılı tutunca Rolüne bırak; sunucu hatası olduğu gibi', (tester) async {
    final adapter = await _pump(tester, home: const AiSettingsScreen(), script: {
      '/ai/settings': _many(_settings(aliSource: 'override_deny')),
      '/ai/settings/users/u2': [
        (status: 409, body: {'error': 'Sahip her zaman yapay zekâyı kullanabilir; kapatılamaz'}),
      ],
    });
    expect(find.text('Saha · Kişiye özel kapalı'), findsOneWidget);
    await tester.longPress(find.byKey(const ValueKey('ai-settings-user-u2')));
    await _advance(tester);
    expect(_lastBody(adapter, '/ai/settings/users/u2', 'PUT'), {'can_use': null});
    expect(find.text('Sahip her zaman yapay zekâyı kullanabilir; kapatılamaz'), findsOneWidget);
  });

  testWidgets('sınırlar: boş = null, sayı gider; üst sınırı aşan sayı istek atmadan reddedilir', (tester) async {
    final adapter = await _pump(tester, home: const AiSettingsScreen(), script: {
      '/ai/settings': [
        (status: 200, body: _settings()),
        (status: 200, body: _settings(monthly: 60, perUser: 10)),
      ],
    });
    await tester.enterText(find.byKey(const ValueKey('ai-settings-monthly')), '150');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-settings-save')));
    await _advance(tester);
    expect(find.text('Aylık firma sınırı en fazla 100 olabilir (sunucu üst sınırı)'), findsOneWidget);
    expect(_count(adapter, '/ai/settings', 'PUT'), 0);

    await tester.enterText(find.byKey(const ValueKey('ai-settings-monthly')), '60');
    await tester.enterText(find.byKey(const ValueKey('ai-settings-per-user')), '10');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-settings-save')));
    await _advance(tester);
    expect(_lastBody(adapter, '/ai/settings', 'PUT'), {'enabled': true, 'monthly_limit': 60, 'per_user_monthly_limit': 10});
    expect(find.text('Firma: 7 / 60 görsel'), findsOneWidget);
    expect(find.text('5 / 10'), findsOneWidget);
  });

  testWidgets('firma anahtarı hemen kaydedilir (kayıtlı sınırlarla)', (tester) async {
    final adapter = await _pump(tester, home: const AiSettingsScreen(), script: {
      '/ai/settings': [
        (status: 200, body: _settings(monthly: 50)),
        (status: 200, body: _settings(enabled: false, monthly: 50)),
      ],
    });
    // Kaydedilmemiş sayı anahtarla birlikte gitmez.
    await tester.enterText(find.byKey(const ValueKey('ai-settings-monthly')), '20');
    await tester.tap(find.byKey(const ValueKey('ai-settings-enabled')));
    await _advance(tester);
    expect(_lastBody(adapter, '/ai/settings', 'PUT'), {'enabled': false, 'monthly_limit': 50, 'per_user_monthly_limit': null});
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('ai-settings-enabled'))).value, isFalse);
  });

  testWidgets('320 pt + büyük yazı: taşma yok', (tester) async {
    await _pump(
      tester,
      home: const AiSettingsScreen(),
      size: const Size(320, 2400),
      textScale: 1.6,
      script: {'/ai/settings': _many(_settings(aliSource: 'override_allow', aliCanUse: true, perUser: 10))},
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Kimler kullanabilir'), findsOneWidget);
  });

  group('giriş', () {
    testWidgets('Diğer: izin varsa Stüdyo\'nun hemen altında; yoksa yok', (tester) async {
      await _pump(tester, home: const OtherMenuScreen(), size: const Size(360, 1600));
      expect(find.text(kAiSettingsTitle), findsOneWidget);
      final studioY = tester.getTopLeft(find.text(kAiStudioTitle)).dy;
      final settingsY = tester.getTopLeft(find.text(kAiSettingsTitle)).dy;
      expect(settingsY, greaterThan(studioY));
      expect(settingsY, lessThan(tester.getTopLeft(find.text('Masraflar')).dy));

      await _pump(tester, home: const OtherMenuScreen(), size: const Size(360, 1600), user: _user(manage: false));
      expect(find.text(kAiSettingsTitle), findsNothing);
    });

    testWidgets('Diğer: firma kapalıyken de ayarlar görünür (yönetici yeniden açabilsin)', (tester) async {
      await _pump(
        tester,
        home: const OtherMenuScreen(),
        size: const Size(360, 1600),
        script: {'/ai/status': _many(_status(firmEnabled: false, blocked: kAiFirmDisabledText), n: 20)},
      );
      expect(find.text(kAiSettingsTitle), findsOneWidget);
      // Stüdyo da görünür: kişi nedenini içeride okur.
      expect(find.text(kAiStudioTitle), findsOneWidget);
    });

    testWidgets('Stüdyo: dişli yalnızca izinle', (tester) async {
      await _pump(tester, home: const AiStudioScreen(), script: {
        '/ai/studio/images': _many({'images': [], 'pending_jobs': [], 'next_before': null}),
      });
      expect(find.byKey(const ValueKey('ai-studio-settings')), findsOneWidget);

      await _pump(tester, home: const AiStudioScreen(), user: _user(manage: false), script: {
        '/ai/studio/images': _many({'images': [], 'pending_jobs': [], 'next_before': null}),
      });
      expect(find.byKey(const ValueKey('ai-studio-settings')), findsNothing);
    });

    testWidgets('Stüdyo: firma kapalıyken neden görünür, kartlar dokunulmaz', (tester) async {
      await _pump(tester, home: const AiStudioScreen(), script: {
        '/ai/status': _many(_status(firmEnabled: false, blocked: kAiFirmDisabledText), n: 20),
        '/ai/studio/images': _many({'images': [], 'pending_jobs': [], 'next_before': null}),
      });
      expect(find.text(kAiFirmDisabledText), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-studio-generate')));
      await _advance(tester);
      // Oluşturma sayfası açılmadı.
      expect(find.text('Nasıl bir görsel istediğini yaz; yapay zekâ sıfırdan hazırlar.'), findsNothing);
    });

    testWidgets('kişi sınırı: "Bu ay kalan" kişinin kalanı; dolunca kişiye özel metin', (tester) async {
      final quota = AiImageQuota.fromJson({
        'monthly_limit': 100,
        'used_this_month': 30,
        'remaining': 70,
        'user_hourly_limit': 10,
        'resets_at': '2026-11-01T00:00:00+03:00',
        'user_monthly_limit': 10,
        'user_used_this_month': 10,
        'user_remaining': 0,
      });
      expect(quota.ownRemaining, 0);
      final status = AiImageStatus.fromJson({
        'enabled': true,
        'can_use': true,
        'blocked_code': 'ai_user_monthly_limit',
        'blocked_reason': 'Bu ay sana ayrılan yapay zekâ hakkı doldu (10/10)',
      });
      expect(status.available, isTrue);
      expect(status.blocked, isTrue);
      // Eski sunucu: yeni alanlar yok, davranış eskisi gibi.
      final old = AiImageStatus.fromJson({'enabled': false, 'can_use': true});
      expect(old.available, isFalse);
      expect(old.blocked, isFalse);
    });
  });
}
