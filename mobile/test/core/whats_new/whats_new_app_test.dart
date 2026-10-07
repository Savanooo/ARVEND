import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/app/app.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/update/app_release.dart';
import 'package:arvend/core/update/play_update.dart';
import 'package:arvend/core/update/update_controller.dart';
import 'package:arvend/core/whats_new/whats_new.dart';
import 'package:arvend/core/whats_new/whats_new_content.dart';

import '../../features/dashboard/fixtures.dart';
import '../../test_utils/fake_api_client.dart';
import '../update/update_fakes.dart';

/// Uygulamanın GERÇEK kablolamasıyla (ArvendApp + router + AppShell +
/// güncelleme gözcüleri): "Yenilikler" güncellemeden sonraki ilk açılışta
/// kabukta bir kez açılır; giriş ekranında, zorunlu güncellemede ve
/// sıfırdan kurulumda açılmaz.

Map<String, dynamic> _userJson({List<String>? permissions, String role = 'admin'}) => {
      'id': 'user-1',
      'organization_id': 'org-1',
      'username': 'test_kullanici',
      'full_name': 'Test Kullanıcı',
      'role': role,
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'organization_name': 'Arvend Yapı',
      'permissions': permissions ?? kAllPermissions,
    };

// Büyüyebilir liste: sahte adaptör kuyruğu removeAt ile tüketir.
List<ScriptedResponse> _many(ScriptedResponse r) => List.generate(8, (_) => r);

class _FakePlayClient implements PlayUpdateClient {
  _FakePlayClient(this.info);

  final PlayUpdateInfo info;
  final calls = <String>[];

  @override
  Future<PlayUpdateInfo> check() async {
    calls.add('check');
    return info;
  }

  @override
  Future<PlayUpdateOutcome> startFlexible() async {
    calls.add('flexible');
    return PlayUpdateOutcome.denied;
  }

  @override
  Future<PlayUpdateOutcome> performImmediate() async {
    calls.add('immediate');
    // Kullanıcı Play'in tam ekranından geri döndü -- zorunluluk sürer.
    return PlayUpdateOutcome.denied;
  }

  @override
  Future<void> completeFlexible() async => calls.add('complete');
}

final _sheet = find.byKey(const Key('whats-new-sheet'));

const _gated = [
  WhatsNewRelease(build: 15, version: '1.5.9', items: [
    WhatsNewItem(icon: Icons.percent, title: 'Masrafa KDV', body: '.', permission: 'projects.finance.manage'),
  ]),
];

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'ARVEND',
      packageName: 'com.arvendyapi.arvend',
      version: '1.5.9',
      buildNumber: '15',
      buildSignature: '',
    );
  });

  Future<int?> stored() async => (await SharedPreferences.getInstance()).getInt(WhatsNewStore.lastSeenBuildKey);

  Future<FakeHttpClientAdapter> pumpApp(
    WidgetTester tester, {
    bool loggedIn = true,
    bool upgraded = true,
    int installedBuild = 15,
    List<String>? permissions,
    String role = 'admin',
    List<WhatsNewRelease>? releases,
    PlayUpdateClient? play,
    bool sideload = false,
    List<ScriptedResponse> version = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final user = _userJson(permissions: permissions, role: role);
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [loggedIn ? (status: 200, body: user) : (status: 401, body: {'error': 'yetkisiz'})],
      '/auth/refresh': [(status: 401, body: {'error': 'oturum yok'})],
      '/auth/login': [(status: 200, body: user)],
      '/mobile/app-version': version,
      '/dashboard': _many((status: 200, body: fixtureJson('owner'))),
      '/offers/': _many((status: 200, body: {'offers': <dynamic>[], 'total': 0})),
      '/notifications/unread-count': _many((status: 200, body: {'unread_count': 0})),
    });
    final client = await buildFakeApiClient(adapter);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(client),
          installedVersionProvider.overrideWith(
            (ref) async => InstalledVersion(version: '1.5.9', build: installedBuild),
          ),
          appUpdatedInPlaceProvider.overrideWith((ref) async => upgraded),
          if (releases != null) whatsNewReleasesProvider.overrideWithValue(releases),
          playUpdateSupportedProvider.overrideWithValue(play != null),
          if (play != null) playUpdateClientProvider.overrideWithValue(play),
          updateSupportedProvider.overrideWithValue(sideload),
          if (sideload) updateInstallServiceProvider.overrideWithValue(FakeInstallService()),
        ],
        child: const ArvendApp(),
      ),
    );
    await tester.pumpAndSettle();
    return adapter;
  }

  /// Uygulamayı kapatıp yeniden açar (SharedPreferences kalır).
  Future<void> restart(WidgetTester tester, {bool upgraded = true}) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpApp(tester, upgraded: upgraded);
  }

  Future<void> tapDone(WidgetTester tester) async {
    await tester.tap(find.descendant(of: _sheet, matching: find.text('Tamam')));
    await tester.pumpAndSettle();
  }

  testWidgets('1.5.8\'den güncelleme: kabukta bir kez açılır, açılır açılmaz kaydedilir, bir daha açılmaz',
      (tester) async {
    await pumpApp(tester);

    expect(_sheet, findsOneWidget);
    expect(find.descendant(of: _sheet, matching: find.text('Yenilikler')), findsOneWidget);
    expect(find.text('Sürüm 1.5.9'), findsOneWidget);
    for (final title in ['Masraf onayı', 'Masrafa KDV', 'KDV hariç kâr', 'Teklif PDF', 'Kolay kapanan formlar']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    // Kapatılmadan ÖNCE yazıldı: uygulama şimdi kapansa da tekrar gelmez.
    expect(await stored(), 15);

    await tapDone(tester);
    expect(_sheet, findsNothing);
    expect(find.byType(BottomNavigationBar), findsOneWidget);

    await restart(tester);
    expect(find.byType(BottomNavigationBar), findsOneWidget);
    expect(_sheet, findsNothing);
  });

  testWidgets('uygulama sayfa açıkken kapanırsa bir daha gösterilmez', (tester) async {
    await pumpApp(tester);
    expect(_sheet, findsOneWidget);

    await restart(tester);
    expect(_sheet, findsNothing);
    expect(await stored(), 15);
  });

  testWidgets('sıfırdan kurulum: hiçbir şey gösterilmez, kurulu build sessizce kaydedilir', (tester) async {
    await pumpApp(tester, upgraded: false);
    expect(find.byType(BottomNavigationBar), findsOneWidget);
    expect(_sheet, findsNothing);
    expect(await stored(), 15);
  });

  testWidgets('sürüm atlayan kullanıcı: görmediği sürümlerin notları birleşir, en yeni önce', (tester) async {
    SharedPreferences.setMockInitialValues({WhatsNewStore.lastSeenBuildKey: 15});
    await pumpApp(
      tester,
      installedBuild: 17,
      releases: const [
        WhatsNewRelease(build: 17, version: '1.6.1', items: [
          WhatsNewItem(icon: Icons.star_outline, title: 'On yedi notu', body: 'Yedi.'),
        ]),
        WhatsNewRelease(build: 16, version: '1.6.0', items: [
          WhatsNewItem(icon: Icons.star_outline, title: 'On altı notu', body: 'Altı.'),
        ]),
        WhatsNewRelease(build: 15, version: '1.5.9', items: [
          WhatsNewItem(icon: Icons.star_outline, title: 'Görülmüş not', body: 'Beş.'),
        ]),
      ],
    );

    expect(find.text('Sürüm 1.6.1'), findsOneWidget);
    expect(find.text('On yedi notu'), findsOneWidget);
    expect(find.text('On altı notu'), findsOneWidget);
    expect(find.text('Görülmüş not'), findsNothing);
    expect(
      tester.getTopLeft(find.text('On yedi notu')).dy,
      lessThan(tester.getTopLeft(find.text('On altı notu')).dy),
    );
    expect(await stored(), 17);
  });

  testWidgets('izni olmayan madde gösterilmez (saha çalışanı finans/teklif maddelerini görmez)', (tester) async {
    await pumpApp(tester, role: 'kullanici', permissions: ['projects.read', 'notifications.read']);

    expect(_sheet, findsOneWidget);
    expect(find.text('Kolay kapanan formlar'), findsOneWidget);
    expect(find.text('Doğru tutar girişi'), findsOneWidget);
    for (final title in ['Masraf onayı', 'Masrafa KDV', 'KDV hariç kâr', 'Teklif PDF']) {
      expect(find.text(title), findsNothing, reason: title);
    }
  });

  testWidgets('izinlerden sonra madde kalmazsa sayfa açılmaz ama build yine kaydedilir', (tester) async {
    await pumpApp(tester, role: 'kullanici', permissions: ['projects.read'], releases: _gated);
    expect(find.byType(BottomNavigationBar), findsOneWidget);
    expect(_sheet, findsNothing);
    expect(await stored(), 15);
  });

  testWidgets('giriş ekranında açılmaz; girişten sonra kabukta açılır', (tester) async {
    await pumpApp(tester, loggedIn: false);
    expect(find.text('Yönetim Sistemine Giriş'), findsOneWidget);
    expect(_sheet, findsNothing);
    expect(await stored(), isNull);

    await tester.enterText(find.widgetWithText(TextFormField, 'Kullanıcı Adı'), 'test_kullanici');
    await tester.enterText(find.widgetWithText(TextFormField, 'Şifre'), 'gizli-sifre');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Giriş Yap'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomNavigationBar), findsOneWidget);
    expect(_sheet, findsOneWidget);
    expect(await stored(), 15);
  });

  group('zorunlu güncelleme akışının üstüne açılmaz', () {
    const available = PlayUpdateInfo(available: true, immediateAllowed: true, flexibleAllowed: true, versionCode: 16);

    testWidgets('Play: zorunlu güncelleme bekliyor -> gösterilmez, kaydedilmez', (tester) async {
      final play = _FakePlayClient(available);
      await pumpApp(tester, play: play, version: [(status: 200, body: releaseJson(build: 16, minBuild: 16))]);

      expect(play.calls, ['check', 'immediate']);
      expect(find.byType(BottomNavigationBar), findsOneWidget);
      expect(_sheet, findsNothing);
      // Taban yerinde, 15 görülmüş sayılmadı: güncellemeden sonra 16'nın
      // notlarıyla birlikte gelir.
      expect(await stored(), kWhatsNewLegacyBuild);
    });

    testWidgets('Play: güncelleme yoksa denetimin kararından sonra açılır', (tester) async {
      final play = _FakePlayClient(const PlayUpdateInfo());
      await pumpApp(tester, play: play);

      expect(play.calls, ['check']);
      expect(_sheet, findsOneWidget);
      expect(await stored(), 15);
    });

    testWidgets('sideload: zorunlu güncelleme istemi açıkken gösterilmez', (tester) async {
      await pumpApp(tester, sideload: true, version: [(status: 200, body: releaseJson(build: 16, minBuild: 16))]);

      expect(find.textContaining('Bu güncelleme zorunlu'), findsOneWidget);
      expect(_sheet, findsNothing);
      expect(await stored(), kWhatsNewLegacyBuild);
    });
  });

  testWidgets('Diğer > Hakkında > Yenilikler son notları yeniden açar; aşağı çekince kapanır', (tester) async {
    await pumpApp(tester, upgraded: false);
    expect(_sheet, findsNothing);

    await tester.tap(find.descendant(of: find.byType(BottomNavigationBar), matching: find.text('Diğer')));
    await tester.pumpAndSettle();
    final about = find.text('Hakkında');
    await tester.scrollUntilVisible(about, 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(about);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Yenilikler'));
    await tester.pumpAndSettle();
    expect(_sheet, findsOneWidget);
    expect(find.text('Sürüm 1.5.9'), findsOneWidget);
    expect(find.text('Masraf onayı'), findsOneWidget);

    // showAppSheet: çekme çubuğu var, aşağı çekmek kapatır ("X" yok).
    expect(find.byKey(const Key('sheet-drag-handle')), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
    await tester.drag(find.text('Sürüm 1.5.9'), const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
    expect(find.text('Hakkında'), findsOneWidget);
  });
}
